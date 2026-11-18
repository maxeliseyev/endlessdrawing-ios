import Foundation

nonisolated enum SceneFailure: Error, Equatable, Sendable { case inconsistent, capacity }

nonisolated struct SceneStroke: Sendable, Equatable {
    let server: ServerStroke
    let drawable: LocalStroke
    let extent: StrokeExtent
    init(_ stroke: ServerStroke) {
        server = stroke; drawable = stroke.payload.drawable; extent = StrokeExtent(drawable)
    }
}

/// Synchronous reducer owned by WorldSession. Snapshot membership commits only at end.
nonisolated struct SceneStore {
    static let maximumStrokes = 20_000
    static let maximumPoints = 1_000_000
    private(set) var subscriptionID: String?
    private(set) var bounds: WireBounds?
    private(set) var loading = false
    private var confirmed: [UUID: SceneStroke] = [:] { didSet { order = nil } }
    private var staging: [UUID: SceneStroke]? { didSet { order = nil } }
    private var acknowledgements: [UUID: SceneStroke] = [:] { didSet { order = nil } }
    private var tombstones: [UUID: Int64] = [:] { didSet { order = nil } } // 0 = authoritative absence without a disclosed seq
    /// Displayed records in seq order, rebuilt only after a mutation (publishing must not re-sort per message).
    private var order: [SceneStroke]?
    private var sequenceIDs: [Int64: UUID] = [:]
    private var pointCosts: [UUID: Int] = [:]
    private var points = 0
    private var lastSnapshotSequence: Int64 = 0
    /// v3+: cached fetches and v4 visible-first deliver members out of seq order; each id still once.
    private var unordered = false

    mutating func reconnect() {
        if let staging { confirmed.merge(staging) { _, new in new } }
        confirmed.merge(acknowledgements) { _, new in new }
        confirmed = confirmed.filter { tombstones[$0.key] == nil }
        staging = nil; acknowledgements.removeAll(); tombstones.removeAll()
        subscriptionID = nil; bounds = nil; loading = false; lastSnapshotSequence = 0
        rebuildCosts()
    }

    mutating func subscribe(id: String, bounds: WireBounds, unordered: Bool = false) {
        self.unordered = unordered
        // Previously shown staging can stay as bounded stale display, never complete membership.
        if let staging { confirmed.merge(staging) { _, new in new } }
        confirmed.merge(acknowledgements) { _, new in new }
        confirmed = confirmed.filter { tombstones[$0.key] == nil && $0.value.extent.intersects(bounds) }
        subscriptionID = id; self.bounds = bounds; loading = true
        staging = nil; acknowledgements.removeAll(); lastSnapshotSequence = 0
        rebuildCosts()
    }

    mutating func begin(id: String) throws {
        guard id == subscriptionID else { return }
        guard loading, staging == nil else { throw SceneFailure.inconsistent }
        staging = [:]
    }

    mutating func chunk(id: String, strokes: [ServerStroke]) throws {
        guard id == subscriptionID else { return }
        guard loading, staging != nil else { throw SceneFailure.inconsistent }
        // Transactional even for direct reducer tests; no partial application on malformed chunks.
        var next = self
        for stroke in strokes {
            if unordered {
                guard next.staging?[stroke.payload.id] == nil else { throw SceneFailure.inconsistent }
            } else {
                guard stroke.sequence > next.lastSnapshotSequence else { throw SceneFailure.inconsistent }
                next.lastSnapshotSequence = stroke.sequence
            }
            let record = SceneStroke(stroke)
            try next.validate(record)
            if next.tombstones[stroke.payload.id] != nil { continue }
            try next.reserve(record)
            next.staging?[stroke.payload.id] = record
        }
        self = next
    }

    mutating func end(id: String) throws {
        guard id == subscriptionID else { return }
        guard loading, let staging else { throw SceneFailure.inconsistent }
        confirmed = staging
        confirmed.merge(acknowledgements) { _, new in new }
        confirmed = confirmed.filter { tombstones[$0.key] == nil }
        self.staging = nil; acknowledgements.removeAll(); loading = false
        rebuildCosts()
    }

    mutating func created(id: String, stroke: ServerStroke) throws {
        guard id == subscriptionID else { return }
        // The backend buffers scoped live messages until snapshot.end.
        guard !loading else { throw SceneFailure.inconsistent }
        try upsert(stroke, acknowledged: false)
    }

    mutating func acknowledged(_ stroke: ServerStroke) throws { try upsert(stroke, acknowledged: true) }

    mutating func deleted(id: String, strokeID: UUID, sequence: Int64) throws {
        guard id == subscriptionID else { return }
        try remove(strokeID, sequence: sequence)
    }

    mutating func remove(_ id: UUID, sequence: Int64? = nil) throws {
        if let sequence, let existing = record(id), existing.server.sequence != sequence { throw SceneFailure.inconsistent }
        if let previous = tombstones[id], previous != 0, let sequence, previous != sequence { throw SceneFailure.inconsistent }
        guard tombstones[id] != nil || tombstones.count < Self.maximumStrokes else { throw SceneFailure.capacity }
        tombstones[id] = sequence ?? tombstones[id] ?? 0
        confirmed[id] = nil; staging?[id] = nil; acknowledgements[id] = nil
        if let cost = pointCosts.removeValue(forKey: id) { points -= cost }
    }

    func visible(in bounds: WireBounds, hidden: Set<UUID>) -> [SceneStroke] {
        var result = confirmed
        if let staging { result.merge(staging) { _, new in new } }
        result.merge(acknowledgements) { _, new in new }
        return result.values.filter {
            tombstones[$0.server.payload.id] == nil && !hidden.contains($0.server.payload.id) && $0.extent.intersects(bounds)
        }.sorted { $0.server.sequence < $1.server.sequence }
    }

    /// Every displayed record of the scope in seq order; visibility is the renderer's job (tiles/index).
    mutating func ordered(hidden: Set<UUID>) -> [SceneStroke] {
        if order == nil {
            var result = confirmed
            if let staging { result.merge(staging) { _, new in new } }
            result.merge(acknowledgements) { _, new in new }
            order = result.values.filter { tombstones[$0.server.payload.id] == nil }.sorted { $0.server.sequence < $1.server.sequence }
        }
        guard let order else { return [] }
        return hidden.isEmpty ? order : order.filter { !hidden.contains($0.server.payload.id) }
    }

    /// Immutable record this connection already holds for a manifest member (v3 cache reuse).
    func cached(_ id: UUID) -> SceneStroke? {
        guard tombstones[id] == nil else { return nil }
        return acknowledgements[id] ?? confirmed[id]
    }

    /// Pins already-known records into the loading snapshot without network geometry; transactional.
    mutating func retain(id: String, records: [SceneStroke]) throws {
        guard id == subscriptionID else { return }
        guard loading, staging != nil else { throw SceneFailure.inconsistent }
        var next = self
        for record in records {
            guard next.staging?[record.server.payload.id] == nil else { throw SceneFailure.inconsistent }
            try next.validate(record)
            if next.tombstones[record.server.payload.id] != nil { continue }
            try next.reserve(record)
            next.staging?[record.server.payload.id] = record
        }
        self = next
    }

    private func record(_ id: UUID) -> SceneStroke? { acknowledgements[id] ?? staging?[id] ?? confirmed[id] }

    private func validate(_ value: SceneStroke) throws {
        let id = value.server.payload.id, seq = value.server.sequence
        if let old = record(id), old.server != value.server { throw SceneFailure.inconsistent }
        if let other = sequenceIDs[seq], other != id { throw SceneFailure.inconsistent }
        if let deletedSequence = tombstones[id], deletedSequence != 0, deletedSequence != seq { throw SceneFailure.inconsistent }
    }

    private mutating func reserve(_ value: SceneStroke) throws {
        let id = value.server.payload.id
        if pointCosts[id] == nil {
            let count = value.server.payload.points.count
            guard pointCosts.count < Self.maximumStrokes, points + count <= Self.maximumPoints else { throw SceneFailure.capacity }
            pointCosts[id] = count; points += count
        }
        guard sequenceIDs[value.server.sequence] != nil || sequenceIDs.count < Self.maximumStrokes * 2 else { throw SceneFailure.capacity }
        sequenceIDs[value.server.sequence] = id
    }

    private mutating func upsert(_ stroke: ServerStroke, acknowledged: Bool) throws {
        let value = SceneStroke(stroke), id = stroke.payload.id
        try validate(value)
        guard tombstones[id] == nil, let bounds, value.extent.intersects(bounds) else { return }
        try reserve(value)
        if acknowledged && loading { acknowledgements[id] = value }
        else { confirmed[id] = value }
    }

    private mutating func rebuildCosts() {
        pointCosts.removeAll(keepingCapacity: true); sequenceIDs.removeAll(keepingCapacity: true); points = 0
        for value in confirmed.values {
            pointCosts[value.server.payload.id] = value.server.payload.points.count
            sequenceIDs[value.server.sequence] = value.server.payload.id
            points += value.server.payload.points.count
        }
        for (id, sequence) in tombstones where sequence > 0 { sequenceIDs[sequence] = id }
    }
}
