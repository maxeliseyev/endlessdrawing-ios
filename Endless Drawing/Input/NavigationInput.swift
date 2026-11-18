import Foundation

/// Finger-only navigation. The active pair never changes mid-pinch.
nonisolated struct NavigationInput {
    private(set) var touches: [Int: WorldPoint] = [:]
    private(set) var blocked = false
    private var startCamera = Camera()
    private var initial: [Int: WorldPoint] = [:]
    private var pair: [Int] = []

    mutating func begin(id: Int, point: WorldPoint, camera: Camera) {
        touches[id] = point
        guard !blocked else { return }
        if touches.count <= 2 {
            startCamera = camera
            initial = touches
            pair = touches.keys.sorted()
        }
    }

    mutating func move(id: Int, point: WorldPoint, viewport: CanvasSize) -> Camera? {
        guard touches[id] != nil else { return nil }
        touches[id] = point
        guard !blocked, let first = pair.first, let a0 = initial[first], let a1 = touches[first] else { return nil }
        var result = startCamera
        if pair.count == 1 {
            result.pan(screenDelta: WorldPoint(x: a1.x - a0.x, y: a1.y - a0.y))
        } else if let b0 = initial[pair[1]], let b1 = touches[pair[1]] {
            let distance = a0.distance(to: b0)
            guard distance > 1 else { return nil }
            result.pinch(from: startCamera,
                         initialMidpoint: WorldPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2),
                         midpoint: WorldPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2),
                         ratio: a1.distance(to: b1) / distance, viewport: viewport)
        }
        return result
    }

    mutating func end(id: Int) {
        touches.removeValue(forKey: id)
        if touches.isEmpty { reset() }
        else if pair.contains(id) { blocked = true }
    }

    mutating func blockUntilTouchesEnd() {
        blocked = !touches.isEmpty
        pair.removeAll()
    }

    mutating func reset() {
        touches.removeAll()
        initial.removeAll()
        pair.removeAll()
        blocked = false
    }
}
