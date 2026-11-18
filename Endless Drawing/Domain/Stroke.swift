import Foundation

nonisolated struct InkColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let palette: [InkColor] = [
        InkColor(red: 32, green: 32, blue: 32),
        InkColor(red: 228, green: 108, blue: 96),
        InkColor(red: 233, green: 175, blue: 89),
        InkColor(red: 105, green: 162, blue: 127),
        InkColor(red: 113, green: 149, blue: 208),
        InkColor(red: 173, green: 138, blue: 203)
    ]

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
    init?(hex: String) {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        red = UInt8((value >> 16) & 255); green = UInt8((value >> 8) & 255); blue = UInt8(value & 255)
    }

    var components: SIMD3<Float> { SIMD3(Float(red), Float(green), Float(blue)) / 255 }
}

nonisolated struct BrushStyle: Equatable, Sendable {
    var brush = BrushKind.round
    var width = 6.0
    var opacity = 1.0
    var color = InkColor.palette[0]
    var isValid: Bool {
        width.isFinite && (1...64).contains(width) && opacity.isFinite && opacity > 0 && opacity <= 1
    }
}

/// Immutable drawable geometry; confirmation/ownership belong to the world, not this value.
nonisolated struct LocalStroke: Identifiable, Equatable, Sendable {
    let id: UUID
    let points: [WorldPoint]
    let style: BrushStyle

    var isValid: Bool {
        guard style.isValid, !points.isEmpty, points.count <= StrokeInput.maximumPoints,
              points.allSatisfy(\.isValid) else { return false }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return maxX - minX <= 100_000 && maxY - minY <= 100_000
    }
}

nonisolated struct StrokeInput: Sendable {
    static let maximumPoints = 2000
    private(set) var id: UUID?
    private(set) var style = BrushStyle()
    private(set) var realPoints: [WorldPoint] = []
    private(set) var predictedPoints: [WorldPoint] = []
    private var lastTimestamp = -Double.infinity

    var preview: LocalStroke? {
        guard let id else { return nil }
        return LocalStroke(id: id, points: realPoints + predictedPoints, style: style)
    }

    mutating func begin(at point: WorldPoint, timestamp: Double, style: BrushStyle) {
        cancel()
        guard point.isValid, style.isValid, timestamp.isFinite else { return }
        id = UUID()
        self.style = style
        appendReal(point, timestamp: timestamp, force: true)
    }

    mutating func appendReal(_ point: WorldPoint, timestamp: Double, force: Bool = false) {
        guard id != nil, point.isValid, timestamp.isFinite, timestamp >= lastTimestamp else { return }
        predictedPoints.removeAll(keepingCapacity: true)
        lastTimestamp = timestamp
        Self.append(point, to: &realPoints, force: force)
    }

    mutating func replacePredictions(_ points: [WorldPoint]) {
        guard id != nil else { return }
        predictedPoints = Array(points.filter(\.isValid).prefix(32))
    }

    mutating func finish(at point: WorldPoint, timestamp: Double) -> LocalStroke? {
        appendReal(point, timestamp: timestamp, force: true)
        let result = id.map { LocalStroke(id: $0, points: realPoints, style: style) }
        cancel()
        return result.flatMap { $0.isValid ? $0 : nil }
    }

    mutating func cancel() {
        id = nil
        realPoints.removeAll(keepingCapacity: true)
        predictedPoints.removeAll(keepingCapacity: true)
        lastTimestamp = -.infinity
    }

    private static func append(_ point: WorldPoint, to points: inout [WorldPoint], force: Bool) {
        if let last = points.last {
            if last == point || (!force && last.distance(to: point) < 0.75) { return }
        }
        if points.count >= maximumPoints {
            let lastIndex = points.count - 1
            points = points.enumerated().compactMap { index, point in
                index.isMultiple(of: 2) || index == lastIndex ? point : nil
            }
        }
        points.append(point)
    }
}
