import Foundation

/// Accurate eraser hit-testing per brush shape, mirroring the web renderer's shapes and its 4 px
/// screen tolerance (`ERASER_TOLERANCE`). Every tolerance here is already in world units: the caller
/// divides the screen tolerance by the camera zoom.
nonisolated enum BrushHitTest {
    static func contains(_ point: WorldPoint, in stroke: LocalStroke, tolerance: Double) -> Bool {
        switch stroke.style.brush {
        case .round: roundContains(point, in: stroke, tolerance: tolerance)
        case .square: squareContains(point, in: stroke, tolerance: tolerance)
        case .chisel: chiselContains(point, in: stroke, tolerance: tolerance)
        case .spray: sprayContains(point, in: stroke, tolerance: tolerance)
        }
    }

    /// Round is the centre line stroked with round caps and joins: distance to the polyline.
    static func roundContains(_ point: WorldPoint, in stroke: LocalStroke, tolerance: Double) -> Bool {
        guard let first = stroke.points.first else { return false }
        let reach = stroke.style.width / 2 + tolerance
        if stroke.points.count == 1 { return point.distance(to: first) <= reach }
        return StrokeHitTest.distance(from: point, to: stroke.points) <= reach
    }

    /// Square is the centre line stroked with square caps and bevel joins: each segment is a rotated
    /// rectangle whose cross-section is the nib width, extended by the tolerance on every side.
    static func squareContains(_ point: WorldPoint, in stroke: LocalStroke, tolerance: Double) -> Bool {
        guard let first = stroke.points.first else { return false }
        let reach = stroke.style.width / 2 + tolerance
        if stroke.points.count == 1 {
            return abs(point.x - first.x) <= reach && abs(point.y - first.y) <= reach
        }
        var previous = first
        for next in stroke.points.dropFirst() {
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = hypot(dx, dy)
            guard length > 1e-9 else { previous = next; continue }
            let dirX = dx / length, dirY = dy / length
            let relX = point.x - previous.x, relY = point.y - previous.y
            // Square caps extend the segment by `reach` past each endpoint.
            let along = min(max(relX * dirX + relY * dirY, -reach), length + reach)
            let closestX = previous.x + dirX * along, closestY = previous.y + dirY * along
            if hypot(point.x - closestX, point.y - closestY) <= reach { return true }
            previous = next
        }
        return false
    }

    /// Chisel is the union of swept −45° rectangular nibs: inside any swept hull or within the
    /// tolerance of its outline (the web's `isPointInPath` / `isPointInStroke`).
    static func chiselContains(_ point: WorldPoint, in stroke: LocalStroke, tolerance: Double) -> Bool {
        guard let first = stroke.points.first else { return false }
        let tip = BrushGeometry.chiselTip(width: stroke.style.width)
        let px = point.x - first.x, py = point.y - first.y
        let relative = stroke.points.map { SIMD2($0.x - first.x, $0.y - first.y) }
        if relative.count == 1 {
            return polygonContains(px, py, BrushGeometry.hull(tip), tolerance: tolerance)
        }
        var previous = tip
        for rel in relative.dropFirst() {
            let next = tip.map { $0 + rel }
            if polygonContains(px, py, BrushGeometry.hull(previous + next), tolerance: tolerance) { return true }
            previous = next
        }
        return false
    }

    /// Spray particles are deterministic from the stroke id (same `SprayRandom` as the renderer).
    static func sprayContains(_ point: WorldPoint, in stroke: LocalStroke, tolerance: Double) -> Bool {
        guard let first = stroke.points.first else { return false }
        let width = stroke.style.width, half = width / 2
        let radius = max(0.35, min(0.5, width / 20))
        let spread = max(0, half - radius)
        let particles = min(48, max(6, Int(ceil(width * 0.75))))
        let reach = radius + tolerance
        var random = SprayRandom(id: stroke.id.uuidString)
        let px = point.x - first.x, py = point.y - first.y

        func stamp(_ x: Double, _ y: Double) -> Bool {
            for _ in 0..<particles {
                let angle = random.next() * .pi * 2
                let distance = sqrt(random.next()) * spread
                if hypot(px - (x + cos(angle) * distance), py - (y + sin(angle) * distance)) <= reach { return true }
            }
            return false
        }

        if stamp(0, 0) { return true }
        var length = 0.0
        for index in 1..<stroke.points.count { length += stroke.points[index - 1].distance(to: stroke.points[index]) }
        let step = max(1, max(width / 4, length / 2047))
        var traveled = 0.0, sample = 1
        for index in 1..<stroke.points.count {
            let a = stroke.points[index - 1], b = stroke.points[index]
            let segment = a.distance(to: b)
            if segment == 0 { continue }
            while sample < 2048 && Double(sample) * step <= traveled + segment {
                let t = min(1, (Double(sample) * step - traveled) / segment)
                if stamp(a.x - first.x + (b.x - a.x) * t, a.y - first.y + (b.y - a.y) * t) { return true }
                sample += 1
            }
            traveled += segment
        }
        return false
    }

    private static func polygonContains(_ x: Double, _ y: Double, _ polygon: [SIMD2<Double>], tolerance: Double) -> Bool {
        guard polygon.count >= 3 else { return false }
        if pointInPolygon(x, y, polygon) { return true }
        guard tolerance > 0 else { return false }
        var best = Double.infinity
        for index in 0..<polygon.count {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared)) : 0
            best = min(best, hypot(x - (a.x + t * dx), y - (a.y + t * dy)))
        }
        return best <= tolerance
    }

    private static func pointInPolygon(_ x: Double, _ y: Double, _ polygon: [SIMD2<Double>]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// Picks the stroke an eraser tap removes: the newest unconfirmed create (cancelled without a network
/// round-trip), otherwise the confirmed own stroke with the highest seq. Server ownership still wins.
nonisolated enum EraseSelection {
    static func target(at point: WorldPoint, tolerance: Double, pending: [LocalStroke],
                       confirmed: [SceneStroke], hidden: Set<UUID>) -> UUID? {
        // Newest first: pending is ordinal-ascending, so the last entry is the most recent draft.
        for draft in pending.reversed() where BrushHitTest.contains(point, in: draft, tolerance: tolerance) {
            return draft.id
        }
        // Highest seq first: confirmed is seq-ascending, so the last entry is topmost.
        for record in confirmed.reversed() {
            guard record.server.own, !hidden.contains(record.server.payload.id) else { continue }
            let e = record.extent
            guard point.x >= e.minX - tolerance, point.x <= e.maxX + tolerance,
                  point.y >= e.minY - tolerance, point.y <= e.maxY + tolerance else { continue }
            if BrushHitTest.contains(point, in: record.drawable, tolerance: tolerance) {
                return record.server.payload.id
            }
        }
        return nil
    }
}
