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
}
