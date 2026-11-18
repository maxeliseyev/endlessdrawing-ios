import SwiftUI
import Testing
import UIKit
@testable import Endless_Drawing

@MainActor
struct PaletteLayoutTests {
    /// Every tool, Undo included, must be reachable without scrolling on all current iPads in either
    /// orientation (smallest: iPad mini landscape, 744 pt tall, minus the 16 pt margins).
    @Test func paletteFitsWithoutScrollingOnEveryIPad() {
        let model = CanvasModel(environment: nil)
        let host = UIHostingController(rootView: ContextPalette(model: model))
        let natural = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        print("PALETTE natural height \(natural.height) pt")
        #expect(natural.height > 300)
        #expect(natural.height <= 744 - 32)
    }

    /// Dragging moves the palette freely but never past the 16 pt margin, on any side.
    @Test func draggedPaletteStaysOnScreen() {
        let layout = PaletteLayout(area: CGSize(width: 1000, height: 800), paletteHeight: 500)
        #expect(layout.center(for: CGPoint(x: 500, y: 400)) == CGPoint(x: 500, y: 400))
        #expect(layout.center(for: CGPoint(x: -300, y: -300)) == CGPoint(x: 176, y: 266))
        #expect(layout.center(for: CGPoint(x: 5000, y: 5000)) == CGPoint(x: 824, y: 534))
    }

    /// After rotating to a shorter screen the palette shrinks to fit and is re-clamped from the same anchor.
    @Test func paletteFitsTallerThanScreen() {
        let layout = PaletteLayout(area: CGSize(width: 300, height: 400), paletteHeight: 500)
        #expect(layout.width == 268 && layout.height == 368)
        #expect(layout.center(for: CGPoint(x: 900, y: 900)) == CGPoint(x: 150, y: 200))
    }
}
