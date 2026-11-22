import UIKit

/// What a Pencil tap / squeeze does in this app, decided by the user's system preference
/// (Settings → Apple Pencil) rather than hard-coded (architecture §5).
nonisolated enum PencilCommand: Equatable, Sendable {
    case none
    /// Swap the current and the previous brush shape.
    case switchPrevious
    /// Open the contextual palette at the pencil, or close it when already open.
    case togglePalette
    /// Toggle the brush and the eraser (M6.2).
    case switchEraser

    static func resolve(_ action: UIPencilPreferredAction) -> PencilCommand {
        switch action {
        case .switchPrevious: .switchPrevious
        case .showColorPalette, .showInkAttributes, .showContextualPalette: .togglePalette
        case .switchEraser: .switchEraser
        // The system runs the user's shortcut itself; never duplicate it.
        case .ignore, .runSystemShortcut: .none
        @unknown default: .none // future actions are a safe no-op
        }
    }

    /// Squeeze acts exactly once, on `.ended` (a quick squeeze may arrive ended-only);
    /// began/changed are only for transient feedback and cancelled clears it without a command.
    static func squeeze(_ action: UIPencilPreferredAction, phase: UIPencilInteraction.Phase) -> PencilCommand {
        phase == .ended ? resolve(action) : .none
    }
}
