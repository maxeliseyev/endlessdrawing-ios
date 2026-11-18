import Observation
import SwiftUI

@MainActor
@Observable
final class CanvasModel {
    enum Command { case undo, resetCamera, retry }

    var style = BrushStyle()
    var paletteAnchor: CGPoint?
    var failure: String?
    var canUndo = false
    @ObservationIgnored var command: ((Command) -> Void)?
}
