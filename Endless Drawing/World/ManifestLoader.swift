import Foundation

/// One cached subscription's authoritative membership (protocol-v3-manifest.md, v4 keeps the flow).
/// Port of the web `ManifestLoader`: collects manifest ids, reuses records this connection already
/// holds, and requests the rest in stop-and-wait batches. Any contract violation throws `.resync`;
/// the caller then drops the connection's cache right and starts a full snapshot.
nonisolated struct ManifestLoader {
    enum Failure: Error, Equatable { case resync }

    struct FetchRequest: Equatable, Sendable {
        let subscriptionID: String
        let token: UUID
        let batch: Int
        let strokeIDs: [UUID]
        let final: Bool
        var message: ClientMessage {
            .fetch(subscriptionID: subscriptionID, token: token, batch: batch, strokeIDs: strokeIDs, final: final)
        }
    }

    private enum Phase { case idle, awaitingManifest, manifest, fetch }

    private(set) var subscriptionID: String?
    private var phase = Phase.idle
    private var token: UUID?
    private var strokeCount = 0
    private var pointCount = 0
    private var points = 0
    private var ids: [UUID] = []
    private var members: Set<UUID> = []
    private var missing: [UUID] = []
    private var expected: Set<UUID> = []
    private var offset = 0
    private var batch = 0
    private var final = false

    /// True while this subscription's snapshot must follow the manifest flow.
    var isActive: Bool { phase != .idle }
    var isFetching: Bool { phase == .fetch }
    /// Diagnostics: manifest size and how many members needed network geometry.
    var counts: (members: Int, missing: Int) { (strokeCount, missing.count) }

    /// `cached == false` (full subscribe or reset) leaves the loader idle.
    mutating func start(subscriptionID: String?, cached: Bool) {
        self = ManifestLoader()
        guard cached, let subscriptionID else { return }
        self.subscriptionID = subscriptionID
        phase = .awaitingManifest
    }

    func owns(_ id: String) -> Bool { isActive && id == subscriptionID }

    mutating func begin(id: String, token: UUID, strokeCount: Int, pointCount: Int) throws {
        guard owns(id) else { return }
        guard phase == .awaitingManifest, self.token == nil else { throw Failure.resync }
        self.token = token; self.strokeCount = strokeCount; self.pointCount = pointCount
        ids.reserveCapacity(strokeCount)
        phase = .manifest
    }

    mutating func chunk(id: String, token: UUID, strokeIDs: [UUID]) throws {
        guard owns(id) else { return }
        guard phase == .manifest, token == self.token else { throw Failure.resync }
        for strokeID in strokeIDs {
            guard members.count < strokeCount, members.insert(strokeID).inserted else { throw Failure.resync }
            ids.append(strokeID)
        }
    }

    /// Completes membership: returns records to pin from the connection's cache (manifest order,
    /// visible-first on v4) and the first fetch request for the rest.
    mutating func end(id: String, token: UUID, cached: (UUID) -> SceneStroke?) throws -> (retained: [SceneStroke], request: FetchRequest)? {
        guard owns(id) else { return nil }
        guard phase == .manifest, token == self.token, members.count == strokeCount else { throw Failure.resync }
        var retained: [SceneStroke] = []
        for strokeID in ids {
            if let record = cached(strokeID) { retained.append(record); points += record.server.payload.points.count }
            else { missing.append(strokeID) }
        }
        guard points <= pointCount else { throw Failure.resync }
        phase = .fetch
        return (retained, nextRequest())
    }

    /// Geometry of the current batch only: every stroke expected, none repeated, points within the manifest.
    mutating func geometry(id: String, strokes: [ServerStroke]) throws {
        guard owns(id) else { return }
        guard phase == .fetch else { throw Failure.resync }
        var seen: Set<UUID> = []
        for stroke in strokes {
            guard expected.contains(stroke.payload.id), seen.insert(stroke.payload.id).inserted else { throw Failure.resync }
            points += stroke.payload.points.count
        }
        guard points <= pointCount else { throw Failure.resync }
        expected.subtract(seen)
    }

    mutating func fetchEnd(id: String, token: UUID, batch: Int) throws -> FetchRequest? {
        guard owns(id) else { return nil }
        guard phase == .fetch, token == self.token, batch == self.batch, !final, expected.isEmpty else { throw Failure.resync }
        self.batch += 1
        return nextRequest()
    }

    /// Validates completeness before the scene commits membership; leaves the loader idle.
    mutating func snapshotEnd(id: String) throws {
        guard owns(id) else { return }
        guard phase == .fetch, final, expected.isEmpty, points == pointCount else { throw Failure.resync }
        self = ManifestLoader()
    }

    private mutating func nextRequest() -> FetchRequest {
        let slice = Array(missing[offset..<min(missing.count, offset + ManifestLimits.maximumIDsPerMessage)])
        offset += slice.count
        expected = Set(slice)
        final = offset == missing.count
        // A fully warm area still sends batch 0 with no ids and final=true.
        return FetchRequest(subscriptionID: subscriptionID ?? "", token: token ?? UUID(), batch: batch, strokeIDs: slice, final: final)
    }
}
