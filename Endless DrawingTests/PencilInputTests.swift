import MetalKit
import Testing
import UIKit
@testable import Endless_Drawing

@MainActor
struct PencilInputTests {
    @Test func preferredActionsMapToAppCommands() {
        #expect(PencilCommand.resolve(.switchPrevious) == .switchPrevious)
        for action in [UIPencilPreferredAction.showColorPalette, .showInkAttributes, .showContextualPalette] {
            #expect(PencilCommand.resolve(action) == .togglePalette)
        }
        // No eraser yet; the system runs shortcuts itself; ignore means ignore.
        for action in [UIPencilPreferredAction.switchEraser, .runSystemShortcut, .ignore] {
            #expect(PencilCommand.resolve(action) == .none)
        }
    }

    @Test func squeezeActsOnlyOnceWhenItEnds() {
        for phase in [UIPencilInteraction.Phase.began, .changed, .cancelled] {
            #expect(PencilCommand.squeeze(.showContextualPalette, phase: phase) == .none)
        }
        #expect(PencilCommand.squeeze(.showContextualPalette, phase: .ended) == .togglePalette)
    }

    @Test func switchPreviousSwapsBrushShapesBackAndForth() {
        let model = CanvasModel()
        model.switchToPreviousBrush() // nothing recorded yet
        #expect(model.style.brush == .round)
        model.style.width = 20 // other attributes are not a "tool" change
        #expect(model.previousBrush == nil)
        model.style.brush = .spray
        model.switchToPreviousBrush()
        #expect(model.style.brush == .round)
        model.switchToPreviousBrush()
        #expect(model.style.brush == .spray)
    }

    @Test func fingerAndPencilAreDistinguishedByTheCanvasRecognizers() throws {
        let controller = CanvasViewController(model: CanvasModel())
        controller.loadViewIfNeeded()
        let surface = try #require(controller.view as? MTKView)
        // The only tap recognizer is the mouse/trackpad secondary click: Pencil and finger taps never reach it.
        let taps = (surface.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        #expect(taps.count == 1)
        #expect(taps.first?.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
        #expect(surface.interactions.contains { $0 is UIPencilInteraction })
    }

    @Test func pencilPaletteToggleAnchorsAtThePencil() throws {
        let model = CanvasModel()
        let controller = CanvasViewController(model: model)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        controller.performPencil(.none, at: CGPoint(x: 10, y: 10))
        #expect(model.paletteAnchor == nil)
        controller.performPencil(.togglePalette, at: CGPoint(x: 120, y: 80))
        #expect(model.paletteAnchor == CGPoint(x: 120, y: 80))
        controller.performPencil(.togglePalette, at: nil) // second squeeze closes it
        #expect(model.paletteAnchor == nil)
        controller.performPencil(.togglePalette, at: nil) // no hover, no contact yet: centre
        #expect(model.paletteAnchor == CGPoint(x: 200, y: 150))
    }
}
