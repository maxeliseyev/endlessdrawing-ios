import Foundation

/// What this viewer reported or blocked (App Review 1.2). Device-only: the server keeps no block list.
/// Author tags are per viewer (protocol v5), so they only mean something together with this identity.
nonisolated struct HiddenContent: Equatable, Sendable {
    static let maximumStrokes = 5_000
    static let maximumAuthors = 1_000
    private(set) var strokes: [UUID] = []
    private(set) var authors: [String] = []
    private var strokeSet: Set<UUID> = []
    private var authorSet: Set<String> = []

    init(strokes: [UUID] = [], authors: [String] = []) {
        hide(strokes: strokes, authors: authors)
    }

    var isEmpty: Bool { strokes.isEmpty && authors.isEmpty }

    func hides(_ id: UUID, author: String?) -> Bool {
        strokeSet.contains(id) || author.map(authorSet.contains) == true
    }

    /// Newest last; the oldest entries fall off beyond the bounds.
    mutating func hide(strokes newStrokes: [UUID], authors newAuthors: [String]) {
        for id in newStrokes where strokeSet.insert(id).inserted { strokes.append(id) }
        for tag in newAuthors where authorSet.insert(tag).inserted { authors.append(tag) }
        if strokes.count > Self.maximumStrokes {
            for id in strokes.prefix(strokes.count - Self.maximumStrokes) { strokeSet.remove(id) }
            strokes.removeFirst(strokes.count - Self.maximumStrokes)
        }
        if authors.count > Self.maximumAuthors {
            for tag in authors.prefix(authors.count - Self.maximumAuthors) { authorSet.remove(tag) }
            authors.removeFirst(authors.count - Self.maximumAuthors)
        }
    }

    // Persisted as plain strings; anything malformed is dropped.
    init(storedStrokes: [String], storedAuthors: [String]) {
        self.init(strokes: storedStrokes.compactMap { try? StrokePayload.uuid($0) },
                  authors: storedAuthors.compactMap { try? ServerStroke.authorTag($0) })
    }
    var storedStrokes: [String] { strokes.map { $0.uuidString.lowercased() } }
}

/// One stroke picked in report mode.
nonisolated struct ReportTarget: Equatable, Sendable {
    let id: UUID
    let author: String?
    let extent: StrokeExtent
}

nonisolated enum StrokeHitTest {
    /// Shortest distance from `point` to the stroke's centre line (a single point for a dot).
    static func distance(from point: WorldPoint, to path: [WorldPoint]) -> Double {
        guard var previous = path.first else { return .infinity }
        var best = point.distance(to: previous)
        for next in path.dropFirst() {
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((point.x - previous.x) * dx + (point.y - previous.y) * dy) / length)) : 0
            best = min(best, point.distance(to: WorldPoint(x: previous.x + t * dx, y: previous.y + t * dy)))
            previous = next
        }
        return best
    }

    /// Topmost (highest seq) stroke under `point` within half its width plus `slop`, skipping excluded ones.
    static func topmost(at point: WorldPoint, slop: Double, in records: some Sequence<SceneStroke>,
                        excluding: (SceneStroke) -> Bool) -> SceneStroke? {
        var best: SceneStroke?
        for record in records where !excluding(record) {
            let e = record.extent, reach = record.drawable.style.width / 2 + slop
            guard point.x >= e.minX - slop, point.x <= e.maxX + slop, point.y >= e.minY - slop, point.y <= e.maxY + slop,
                  distance(from: point, to: record.drawable.points) <= reach else { continue }
            if best.map({ record.server.sequence > $0.server.sequence }) ?? true { best = record }
        }
        return best
    }
}
