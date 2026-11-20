import Foundation

/// Finger-drawing mode (no Apple Pencil, or chosen in the menu): one finger draws, two fingers navigate.
/// A second finger shortly after the first means the gesture was the start of a pinch: the stroke is
/// abandoned and both fingers navigate. Later extra fingers (a resting hand) are ignored until all lift.
nonisolated struct FingerGesture {
    enum Action: Equatable {
        case none
        /// Start a stroke with this finger.
        case draw(Int)
        /// Abandon any finger stroke; these fingers navigate (from their current positions).
        case navigate([Int])
    }

    /// Long enough for two fingers that land "together", short enough that a stroke in progress keeps going.
    static let pinchGrace: TimeInterval = 0.25

    private(set) var drawing: Int?
    private(set) var navigating = false
    private var down: Set<Int> = []
    private var drawStart: TimeInterval = 0

    mutating func began(id: Int, at time: TimeInterval) -> Action {
        down.insert(id)
        if navigating { return .navigate([id]) }
        if drawing != nil {
            guard time - drawStart <= Self.pinchGrace else { return .none }
            drawing = nil; navigating = true
            return .navigate(down.sorted())
        }
        guard down.count == 1 else { return .none } // left over from an abandoned gesture
        drawing = id; drawStart = time
        return .draw(id)
    }

    mutating func ended(id: Int) {
        down.remove(id)
        if drawing == id { drawing = nil }
        if down.isEmpty { navigating = false }
    }

    /// The stroke could not start or was taken over (Pencil, palette): remaining fingers do nothing.
    mutating func abandonDrawing() { drawing = nil }

    mutating func reset() { self = FingerGesture() }
}

/// Whether one finger draws. An explicit menu choice wins; otherwise fingers draw until an Apple Pencil
/// is first used, unless the system asks for Pencil-only drawing (Settings → Apple Pencil).
nonisolated enum FingerDrawingPolicy {
    static func fingersDraw(choice: Bool?, pencilSeen: Bool, systemPencilOnly: Bool) -> Bool {
        choice ?? (!pencilSeen && !systemPencilOnly)
    }
}
