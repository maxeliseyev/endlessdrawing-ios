import Foundation

/// Geometry bounds may extend past world edges and 30k; they are not subscription bounds.
nonisolated struct StrokeExtent: Equatable, Sendable {
    let minX: Double, minY: Double, maxX: Double, maxY: Double
    init(_ stroke: LocalStroke) {
        let padding = (stroke.style.brush == .square || stroke.style.brush == .chisel)
            ? stroke.style.width / sqrt(2) + 1 : stroke.style.width / 2 + 1
        minX = (stroke.points.map(\.x).min() ?? 0) - padding
        minY = (stroke.points.map(\.y).min() ?? 0) - padding
        maxX = (stroke.points.map(\.x).max() ?? 0) + padding
        maxY = (stroke.points.map(\.y).max() ?? 0) + padding
    }
    func intersects(_ bounds: WireBounds) -> Bool {
        maxX >= bounds.minX && minX <= bounds.maxX && maxY >= bounds.minY && minY <= bounds.maxY
    }
}

extension WireBounds {
    nonisolated func contains(_ other: WireBounds) -> Bool {
        minX <= other.minX && minY <= other.minY && maxX >= other.maxX && maxY >= other.maxY
    }
}

nonisolated struct CanvasRegion: Equatable, Sendable {
    let visible: WireBounds
    let subscription: WireBounds
    let rendering: WireBounds

    init(camera: Camera, viewport: CanvasSize) throws {
        guard viewport.isValid else { throw DrawingDataError.invalidMessage }
        let width = viewport.width / camera.zoom, height = viewport.height / camera.zoom
        guard width <= 30_000, height <= 30_000 else { throw DrawingDataError.limitExceeded }
        func bounds(factor: Double) throws -> WireBounds {
            let w = min(30_000, width * factor), h = min(30_000, height * factor)
            let x = max(-Camera.worldLimit, min(camera.center.x - w / 2, Camera.worldLimit - w))
            let y = max(-Camera.worldLimit, min(camera.center.y - h / 2, Camera.worldLimit - h))
            return try WireBounds(minX: x, minY: y, maxX: x + w, maxY: y + h)
        }
        visible = try bounds(factor: 1)
        subscription = try bounds(factor: 3)
        rendering = try bounds(factor: 1.3)
    }
}
