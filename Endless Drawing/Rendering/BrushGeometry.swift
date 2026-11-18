import Foundation

/// Port of the pinned web tessellator/effect geometry. All calculations precede Float conversion.
nonisolated enum BrushGeometry {
    private typealias Point = SIMD2<Double>

    static func prepare(_ stroke: LocalStroke, realPointCount: Int? = nil) -> PreparedStroke? {
        if stroke.style.brush == .round { return RoundGeometry.prepare(stroke, realPointCount: realPointCount) }
        let count = realPointCount ?? stroke.points.count
        guard count > 0, count <= stroke.points.count else { return nil }
        // Effect brushes use only measured samples: spray's spacing can redistribute as length grows.
        let real = LocalStroke(id: stroke.id, points: Array(stroke.points.prefix(count)), style: stroke.style)
        guard real.isValid, let origin = real.points.first else { return nil }
        let points = real.points.map { Point($0.x - origin.x, $0.y - origin.y) }
        var triangles: [SIMD2<Float>] = []
        var circles: [CircleInstance] = []
        func triangle(_ a: Point, _ b: Point, _ c: Point) {
            triangles.append(contentsOf: [a, b, c].map { SIMD2(Float($0.x), Float($0.y)) })
        }
        func quad(_ a: Point, _ b: Point, _ c: Point, _ d: Point) {
            triangle(a, b, c); triangle(a, c, d)
        }
        let width = real.style.width, half = width / 2
        switch real.style.brush {
        case .round: return nil // handled above, never substitute an unsupported shape
        case .square:
            struct Segment { let p: Point, dir: Point, l0: Point, r0: Point, l1: Point, r1: Point }
            var segments: [Segment] = []
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index], delta = b - a
                let length = hypot(delta.x, delta.y)
                if length < 1e-8 { continue }
                let dir = delta / length, normal = Point(-dir.y, dir.x) * half
                segments.append(Segment(p: b, dir: dir, l0: a + normal, r0: a - normal, l1: b + normal, r1: b - normal))
            }
            if let first = segments.first, let last = segments.last {
                let startHalf = hypot(first.l0.x - first.r0.x, first.l0.y - first.r0.y) / 2
                let start = first.dir * -startHalf
                quad(first.l0 + start, first.l0, first.r0, first.r0 + start)
                for (index, segment) in segments.enumerated() {
                    quad(segment.l0, segment.l1, segment.r1, segment.r0)
                    if index + 1 < segments.count {
                        let next = segments[index + 1]
                        let cross = segment.dir.x * next.dir.y - segment.dir.y * next.dir.x
                        if cross > 1e-8 { triangle(segment.r1, next.r0, segment.p) }
                        else if cross < -1e-8 { triangle(segment.l1, next.l0, segment.p) }
                    }
                }
                let endHalf = hypot(last.l1.x - last.r1.x, last.l1.y - last.r1.y) / 2
                let end = last.dir * endHalf
                quad(last.l1, last.l1 + end, last.r1 + end, last.r1)
            } else { quad(Point(-half, -half), Point(half, -half), Point(half, half), Point(-half, half)) }
        case .chisel:
            let thickness = max(1, width / 6) / 2
            let tip = [Point(-half, -thickness), Point(half, -thickness), Point(half, thickness), Point(-half, thickness)]
                .map { Point(($0.x + $0.y) / sqrt(2), (-$0.x + $0.y) / sqrt(2)) }
            func fan(_ polygon: [Point]) {
                guard polygon.count >= 3 else { return }
                for index in 1..<(polygon.count - 1) { triangle(polygon[0], polygon[index], polygon[index + 1]) }
            }
            var previous = tip
            if points.count == 1 { fan(hull(tip)) }
            else {
                for point in points.dropFirst() {
                    let next = tip.map { $0 + point }
                    fan(hull(previous + next)); previous = next
                }
            }
        case .spray:
            var random = SprayRandom(id: real.id.uuidString)
            let particles = min(48, max(6, Int(ceil(width * 0.75))))
            let radius = max(0.35, min(0.5, width / 20)) // maximum diameter 1, no legacy 2.5 branch
            let spread = max(0, half - radius)
            var length = 0.0
            for index in 1..<real.points.count { length += real.points[index - 1].distance(to: real.points[index]) }
            let step = max(1, max(width / 4, length / 2047))
            func stamp(_ center: Point) {
                for _ in 0..<particles {
                    let angle = random.next() * .pi * 2
                    let distance = sqrt(random.next()) * spread
                    circles.append(CircleInstance(center: SIMD2(Float(center.x + cos(angle) * distance),
                                                               Float(center.y + sin(angle) * distance)), radius: Float(radius)))
                }
            }
            circles.reserveCapacity(min(98_304, (Int(min(length / step, 2047)) + 1) * particles))
            stamp(.zero)
            var traveled = 0.0, sample = 1
            for index in 1..<real.points.count {
                let a = real.points[index - 1], b = real.points[index]
                let segment = a.distance(to: b)
                if segment == 0 { continue }
                while sample < 2048 && Double(sample) * step <= traveled + segment {
                    let t = min(1, (Double(sample) * step - traveled) / segment)
                    stamp(Point(a.x - origin.x + (b.x - a.x) * t, a.y - origin.y + (b.y - a.y) * t))
                    sample += 1
                }
                traveled += segment
            }
        }
        return PreparedStroke(id: real.id, origin: origin, style: real.style, triangles: triangles, circles: circles, extent: StrokeExtent(real),
                              realTriangleCount: triangles.count, realCircleCount: circles.count)
    }

    private static func hull(_ points: [Point]) -> [Point] {
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        func half(_ values: [Point]) -> [Point] {
            var result: [Point] = []
            for p in values {
                while result.count >= 2 {
                    let o = result[result.count - 2], a = result[result.count - 1]
                    if (a.x - o.x) * (p.y - o.y) - (a.y - o.y) * (p.x - o.x) > 0 { break }
                    result.removeLast()
                }
                result.append(p)
            }
            return result
        }
        return Array(half(sorted).dropLast()) + Array(half(Array(sorted.reversed())).dropLast())
    }
}

nonisolated struct SprayRandom {
    private var state: UInt32
    init(id: String) {
        var hash: UInt32 = 2_166_136_261
        for byte in id.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        state = hash == 0 ? 0x9e3779b9 : hash
    }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Double(state) / 4_294_967_296
    }
}
