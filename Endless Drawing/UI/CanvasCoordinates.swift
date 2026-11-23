import Foundation

/// Whole world units, symmetric rounding and no negative zero or exponential notation in world bounds.
/// Mirrors the web client's `coordinateText` so both apps show identical numbers.
nonisolated func coordinateText(x: Double, y: Double) -> String {
    func integer(_ value: Double) -> String {
        let magnitude = abs(value).rounded()
        let digits = String(Int64(magnitude))
        return value < 0 && magnitude != 0 ? "−\(digits)" : digits
    }
    return "x: \(integer(x))  y: \(integer(y))"
}
