import Foundation
import ImageIO
import MetalKit
import Testing
import UIKit
@testable import Endless_Drawing

@Suite(.serialized)
@MainActor
struct ExportRenderTests {
    private func gpuStroke(_ renderer: MetalRenderer, points: [WorldPoint], width: Double = 10) throws -> MetalRenderer.GPUStroke {
        var style = BrushStyle()
        style.width = width
        let prepared = try #require(BrushGeometry.prepare(LocalStroke(id: UUID(), points: points, style: style)))
        return try renderer.upload(prepared)
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels // premultiplied BGRA
    }

    private func component(_ pixels: [UInt8], width: Int, x: Int, y: Int, _ channel: Int) -> Int {
        Int(pixels[(y * width + x) * 4 + channel])
    }

    /// Two strokes cross at the origin; the export renders only the selected horizontal one.
    @Test func rendersOnlyTheSelectedStrokeOnWhiteAndTransparentBackgrounds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device)
        let horizontal = try gpuStroke(renderer, points: [WorldPoint(x: -50, y: 0), WorldPoint(x: 50, y: 0)])
        let vertical = try gpuStroke(renderer, points: [WorldPoint(x: 0, y: -50), WorldPoint(x: 0, y: 50)])
        let frame = ExportFrame(minX: -60, minY: -60, maxX: 60, maxY: 60)
        // world → pixel: (x + 60, y + 60). (40, 60) is on the horizontal line only; (60, 40) vertical only.
        for background in [ExportBackground.white, .transparent] {
            let result = try renderer.renderExport(strokes: [horizontal], frame: frame, requestedScale: 1, background: background)
            result.command.waitUntilCompleted()
            #expect(result.command.status == .completed)
            #expect(result.size.width == 120 && result.size.height == 120)
            let pixels = read(result.texture)
            if background == .white {
                #expect(component(pixels, width: 120, x: 40, y: 60, 0) < 255) // inked
                #expect(component(pixels, width: 120, x: 60, y: 40, 0) == 255) // untouched white
            } else {
                #expect(component(pixels, width: 120, x: 40, y: 60, 3) > 0) // inked, opaque
                #expect(component(pixels, width: 120, x: 60, y: 40, 3) == 0) // transparent
            }
        }
        _ = vertical
    }

    @Test func exportScalesDoubleThePixelSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device)
        let stroke = try gpuStroke(renderer, points: [WorldPoint(x: -10, y: 0), WorldPoint(x: 10, y: 0)])
        let frame = ExportFrame(minX: -60, minY: -60, maxX: 60, maxY: 60)
        for (requested, expected) in [(1, 120), (2, 240), (4, 480)] {
            let result = try renderer.renderExport(strokes: [stroke], frame: frame, requestedScale: requested, background: .white)
            result.command.waitUntilCompleted()
            #expect(result.size.width == expected)
            #expect(result.size.height == expected)
        }
    }

    @Test func pngEncodesAndDecodesAtTheExportSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device)
        let stroke = try gpuStroke(renderer, points: [WorldPoint(x: -10, y: 0), WorldPoint(x: 10, y: 0)])
        let frame = ExportFrame(minX: -60, minY: -60, maxX: 60, maxY: 60)
        let result = try renderer.renderExport(strokes: [stroke], frame: frame, requestedScale: 2, background: .transparent)
        let png = try ExportPNG.encode(texture: result.texture, command: result.command, background: .transparent)
        #expect(!png.isEmpty)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 240 && image.height == 240)
    }
}
