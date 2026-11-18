import Foundation

nonisolated struct CircleInstance: Sendable {
    var center: SIMD2<Float>
    var radius: Float
    var padding: Float = 0
}

nonisolated struct PreparedStroke: Sendable {
    let id: UUID
    let origin: WorldPoint
    let style: BrushStyle
    let triangles: [SIMD2<Float>]
    let circles: [CircleInstance]
}

nonisolated enum RoundGeometry {
    /// The union of segment rectangles and vertex disks matches round caps/joins.
    static func prepare(_ stroke: LocalStroke) -> PreparedStroke? {
        guard let origin = stroke.points.first, stroke.style.isValid,
              stroke.points.count <= StrokeInput.maximumPoints + 32,
              stroke.points.allSatisfy(\.isValid) else { return nil }
        let points = stroke.points.map { SIMD2<Double>($0.x - origin.x, $0.y - origin.y) }
        let half = stroke.style.width / 2
        var triangles: [SIMD2<Float>] = []
        var circles: [CircleInstance] = []
        triangles.reserveCapacity(max(0, points.count - 1) * 6)
        circles.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            if index == 0 || point != points[index - 1] {
                circles.append(CircleInstance(center: SIMD2(Float(point.x), Float(point.y)), radius: Float(half)))
            }
            guard index > 0 else { continue }
            let previous = points[index - 1]
            let delta = point - previous
            let length = hypot(delta.x, delta.y)
            guard length >= 1e-8 else { continue }
            let normal = SIMD2(-delta.y, delta.x) * (half / length)
            let a = previous + normal, b = point + normal
            let c = point - normal, d = previous - normal
            triangles.append(contentsOf: [a, b, c, a, c, d].map { SIMD2(Float($0.x), Float($0.y)) })
        }
        return PreparedStroke(id: stroke.id, origin: origin, style: stroke.style,
                              triangles: triangles, circles: circles)
    }
}

/// Serial, off-main geometry generation; UIKit/Metal objects never enter this actor.
actor GeometryWorker {
    func prepare(_ stroke: LocalStroke) -> PreparedStroke? { RoundGeometry.prepare(stroke) }
}
