import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Endless_Drawing

@MainActor
struct ColorChoiceTests {
    @Test func pickedColorsBecomeOpaqueSRGBBytes() throws {
        let sample = try #require(InkColor(CGColor(srgbRed: 0.5, green: 0.25, blue: 1, alpha: 0.3)))
        #expect(sample == InkColor(red: 128, green: 64, blue: 255)) // alpha is dropped: the wire has none
        let gray = try #require(InkColor(CGColor(gray: 0.5, alpha: 1)))
        #expect(gray.red == gray.green && gray.green == gray.blue)
        // Display P3 red is outside sRGB: channels clamp instead of wrapping.
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let p3Red = try #require(CGColor(colorSpace: p3, components: [1, 0, 0, 1]))
        let vivid = try #require(InkColor(p3Red))
        #expect(vivid.red == 255 && vivid.green == 0 && vivid.blue == 0)
        for ink in InkColor.palette { #expect(InkColor(ink.cgColor) == ink) } // round trip is exact
    }

    @Test func recentColorsKeepCustomColorsNewestFirstWithoutPresets() {
        var recent = RecentColors()
        let preset = recent.use(InkColor.palette[1])
        #expect(!preset) // presets are already one tap away
        let a = InkColor(red: 1, green: 2, blue: 3), b = InkColor(red: 4, green: 5, blue: 6)
        let added = (recent.use(a), recent.use(b), recent.use(b), recent.use(a))
        #expect(added == (true, true, false, true)) // drawing again with the same color changes nothing
        #expect(recent.colors == [a, b])
        for value in 10..<20 { recent.use(InkColor(red: UInt8(value), green: 0, blue: 0)) }
        #expect(recent.colors.count == RecentColors.capacity)
        #expect(recent.colors.first == InkColor(red: 19, green: 0, blue: 0))
        #expect(RecentColors(hexes: recent.hexes + ["bad"]) == recent)
    }

    @Test func recentColorsPersistAcrossLaunches() throws {
        let name = "ColorChoiceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let custom = InkColor(red: 12, green: 200, blue: 99)
        CanvasModel(defaults: defaults).strokeStarted(with: custom)
        #expect(CanvasModel(defaults: defaults).recentColors.colors == [custom])
        #expect(CanvasModel().recentColors.colors.isEmpty) // tests and local mode never touch disk
    }

    /// With a full recent row the palette still fits the shortest iPad screen without scrolling.
    @Test func paletteWithRecentColorsFitsWithoutScrolling() throws {
        let name = "ColorChoiceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CanvasModel(defaults: defaults)
        for value in 0..<RecentColors.capacity { model.strokeStarted(with: InkColor(red: UInt8(value), green: 9, blue: 9)) }
        let host = UIHostingController(rootView: ContextPalette(model: model))
        let natural = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        print("PALETTE with recents \(natural.height) pt")
        #expect(natural.height <= 744 - 32)
    }
}
