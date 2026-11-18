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
    let extent: StrokeExtent
    /// Prefixes that contain only measured samples, never the predicted tail.
    let realTriangleCount: Int
    let realCircleCount: Int
}

nonisolated enum RoundGeometry {
    /// The union of segment rectangles and vertex disks matches round caps/joins.
    static func prepare(_ stroke: LocalStroke, realPointCount: Int? = nil) -> PreparedStroke? {
        let realPointCount = realPointCount ?? stroke.points.count
        guard realPointCount > 0, realPointCount <= stroke.points.count,
              let origin = stroke.points.first, stroke.style.isValid,
              stroke.points.count <= StrokeInput.maximumPoints + 32,
              stroke.points.allSatisfy(\.isValid) else { return nil }
        let points = stroke.points.map { SIMD2<Double>($0.x - origin.x, $0.y - origin.y) }
        let half = stroke.style.width / 2
        var triangles: [SIMD2<Float>] = []
        var circles: [CircleInstance] = []
        var realTriangleCount = 0
        var realCircleCount = 0
        triangles.reserveCapacity(max(0, points.count - 1) * 6)
        circles.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            if index == 0 || point != points[index - 1] {
                circles.append(CircleInstance(center: SIMD2(Float(point.x), Float(point.y)), radius: Float(half)))
            }
            if index > 0 {
                let previous = points[index - 1]
                let delta = point - previous
                let length = hypot(delta.x, delta.y)
                if length >= 1e-8 {
                    let normal = SIMD2(-delta.y, delta.x) * (half / length)
                    let a = previous + normal, b = point + normal
                    let c = point - normal, d = previous - normal
                    triangles.append(contentsOf: [a, b, c, a, c, d].map { SIMD2(Float($0.x), Float($0.y)) })
                }
            }
            if index + 1 == realPointCount {
                realTriangleCount = triangles.count
                realCircleCount = circles.count
            }
        }
        return PreparedStroke(id: stroke.id, origin: origin, style: stroke.style,
                              triangles: triangles, circles: circles, extent: StrokeExtent(stroke),
                              realTriangleCount: realTriangleCount, realCircleCount: realCircleCount)
    }
}

/// Serial, off-main geometry generation; UIKit/Metal objects never enter this actor.
actor GeometryWorker {
    func prepare(_ stroke: LocalStroke, realPointCount: Int? = nil) -> PreparedStroke? {
        BrushGeometry.prepare(stroke, realPointCount: realPointCount)
    }
}
