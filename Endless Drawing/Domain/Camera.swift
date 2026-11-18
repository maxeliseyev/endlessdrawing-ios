import Foundation

nonisolated struct WorldPoint: Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = WorldPoint(x: 0, y: 0)
    var isValid: Bool {
        x.isFinite && y.isFinite && abs(x) <= Camera.worldLimit && abs(y) <= Camera.worldLimit
    }

    func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
}

nonisolated struct CanvasSize: Equatable, Sendable {
    var width: Double
    var height: Double
    var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }
}

nonisolated struct Camera: Equatable, Sendable {
    static let worldLimit = 1_000_000_000.0
    static let minimumZoom = 0.16
    static let maximumZoom = 4.0

    private(set) var center = WorldPoint.zero
    private(set) var zoom = 1.0

    func worldPoint(at screen: WorldPoint, viewport: CanvasSize) -> WorldPoint {
        WorldPoint(x: (screen.x - viewport.width / 2) / zoom + center.x,
                   y: (screen.y - viewport.height / 2) / zoom + center.y)
    }

    func screenPoint(at world: WorldPoint, viewport: CanvasSize) -> WorldPoint {
        WorldPoint(x: (world.x - center.x) * zoom + viewport.width / 2,
                   y: (world.y - center.y) * zoom + viewport.height / 2)
    }

    mutating func pan(screenDelta: WorldPoint) {
        guard screenDelta.x.isFinite, screenDelta.y.isFinite else { return }
        center = Self.clamped(WorldPoint(x: center.x - screenDelta.x / zoom,
                                        y: center.y - screenDelta.y / zoom))
    }

    mutating func zoom(to proposed: Double, anchor: WorldPoint, viewport: CanvasSize) {
        guard proposed.isFinite, anchor.x.isFinite, anchor.y.isFinite, viewport.isValid else { return }
        let fixed = worldPoint(at: anchor, viewport: viewport)
        zoom = min(Self.maximumZoom, max(Self.minimumZoom, proposed))
        center = Self.clamped(WorldPoint(x: fixed.x - (anchor.x - viewport.width / 2) / zoom,
                                        y: fixed.y - (anchor.y - viewport.height / 2) / zoom))
    }

    /// Apply a pinch relative to the initial camera, never to the preceding frame.
    mutating func pinch(from start: Camera, initialMidpoint: WorldPoint, midpoint: WorldPoint,
                        ratio: Double, viewport: CanvasSize) {
        guard ratio.isFinite, ratio >= 0, viewport.isValid,
              initialMidpoint.x.isFinite, initialMidpoint.y.isFinite,
              midpoint.x.isFinite, midpoint.y.isFinite else { return }
        self = start
        zoom(to: start.zoom * ratio, anchor: initialMidpoint, viewport: viewport)
        pan(screenDelta: WorldPoint(x: midpoint.x - initialMidpoint.x, y: midpoint.y - initialMidpoint.y))
    }

    private static func clamped(_ point: WorldPoint) -> WorldPoint {
        WorldPoint(x: min(worldLimit, max(-worldLimit, point.x)),
                   y: min(worldLimit, max(-worldLimit, point.y)))
    }
}
