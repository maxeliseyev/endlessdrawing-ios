import Metal
import Testing
@testable import Endless_Drawing

/// Tile cache behaviour through the public renderer API, on whichever ink path the device supports.
@Suite(.serialized)
@MainActor
struct TileRenderTests {
    private static let size = 128

    private func renderer() throws -> MetalRenderer {
        try MetalRenderer(device: #require(MTLCreateSystemDefaultDevice()))
    }

    private func frame(_ renderer: MetalRenderer, size: Int = TileRenderTests.size) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let command = try #require(renderer.queue.makeCommandBuffer())
        try renderer.encode(to: target, viewport: CanvasSize(width: Double(size), height: Double(size)), command: command)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
        return pixels
    }

    private func stroke(_ renderer: MetalRenderer, _ points: [WorldPoint], opacity: Double = 0.5,
                        color: InkColor = .palette[0], sequence: Int64 = 0) throws -> MetalRenderer.GPUStroke {
        var style = BrushStyle(); style.width = 12; style.opacity = opacity; style.color = color
        var gpu = try renderer.upload(#require(BrushGeometry.prepare(LocalStroke(id: UUID(), points: points, style: style))))
        gpu.sequence = sequence
        return gpu
    }

    private func channel(_ pixels: [UInt8], x: Int, y: Int, size: Int = TileRenderTests.size) -> Int { Int(pixels[(y * size + x) * 4]) }

    @Test func panReusesTilesInsteadOfRedrawingTheScene() throws {
        let r = try renderer()
        var strokes: [MetalRenderer.GPUStroke] = []
        for column in 0..<20 {
            let x = Double(column * 6 - 60)
            strokes.append(try stroke(r, [WorldPoint(x: x, y: -30), WorldPoint(x: x, y: 30)]))
        }
        r.strokes = strokes
        _ = try frame(r)
        let built = r.tileStats.built
        for _ in 0..<10 {
            r.camera.pan(screenDelta: WorldPoint(x: 3, y: 1))
            _ = try frame(r)
        }
        #expect(r.tileStats.built == built)
    }

    @Test func newerStrokeIsAppendedAndMatchesAFreshRender() throws {
        let r = try renderer()
        let a = try stroke(r, [WorldPoint(x: -40, y: 0), WorldPoint(x: 40, y: 0)], sequence: 1)
        let b = try stroke(r, [WorldPoint(x: 0, y: -40), WorldPoint(x: 0, y: 40)], color: .palette[1], sequence: 2)
        r.strokes = [a]
        _ = try frame(r)
        let built = r.tileStats.built
        r.strokes = [a, b]
        let appended = try frame(r)
        #expect(r.tileStats.built == built)
        #expect(r.tileStats.appended > 0)
        let fresh = try renderer()
        fresh.strokes = [a, b]
        #expect(appended == (try frame(fresh)))
    }

    @Test func olderInsertionAndRemovalRebuildAffectedTilesWithoutGhosts() throws {
        let r = try renderer()
        let a = try stroke(r, [WorldPoint(x: -40, y: 0), WorldPoint(x: 40, y: 0)], sequence: 5)
        let b = try stroke(r, [WorldPoint(x: 0, y: -40), WorldPoint(x: 0, y: 40)], color: .palette[1], sequence: 9)
        let late = try stroke(r, [WorldPoint(x: -30, y: -30), WorldPoint(x: 30, y: 30)], color: .palette[2], sequence: 7)
        r.strokes = [a, b]
        _ = try frame(r)
        r.strokes = [a, late, b] // older seq arrives after newer: must sit below b, not on top
        let inserted = try frame(r)
        let fresh = try renderer()
        fresh.strokes = [a, late, b]
        #expect(inserted == (try frame(fresh)))
        r.strokes = [a, b]
        let removed = try frame(r)
        let reference = try renderer()
        reference.strokes = [a, b]
        #expect(removed == (try frame(reference)))
    }

    @Test func appendedTailWithOlderSequenceRebuildsInsteadOfDrawingOnTop() throws {
        let r = try renderer()
        let a = try stroke(r, [WorldPoint(x: -40, y: 0), WorldPoint(x: 40, y: 0)], sequence: 5)
        let b = try stroke(r, [WorldPoint(x: 0, y: -40), WorldPoint(x: 0, y: 40)], opacity: 1, color: .palette[1], sequence: 9)
        let older = try stroke(r, [WorldPoint(x: -30, y: -30), WorldPoint(x: 30, y: 30)], opacity: 1, color: .palette[2], sequence: 7)
        r.strokes = [a, b]
        _ = try frame(r)
        r.strokes = [a, b, older] // prefix unchanged, but the tail is older than b
        let got = try frame(r)
        let fresh = try renderer()
        fresh.strokes = [a, older, b]
        #expect(got == (try frame(fresh)))
    }

    @Test func strokeAcrossTileCornerHasNoSeam() throws {
        // Tile edges at world 0 and the camera centre at the origin: the stroke crosses four tiles.
        let r = try renderer()
        r.strokes = [try stroke(r, [WorldPoint(x: -50, y: -50), WorldPoint(x: 50, y: 50)])]
        let pixels = try frame(r)
        let along = stride(from: 30, through: 98, by: 1).map { channel(pixels, x: $0, y: $0) }
        #expect(along.allSatisfy { abs($0 - along[0]) <= 1 })
        #expect(abs(along[0] - 144) <= 1)
    }

    @Test func zoomShowsScaledTilesThenSharpensAfterSettling() throws {
        let r = try renderer()
        var now = 100.0
        r.clock = { now }
        r.strokes = [try stroke(r, [WorldPoint(x: -40, y: 0), WorldPoint(x: 40, y: 0)])]
        _ = try frame(r)
        r.camera.zoom(to: 1.2, anchor: WorldPoint(x: 64, y: 64), viewport: CanvasSize(width: 128, height: 128))
        let zooming = try frame(r)
        #expect(r.nextFrameDelay != nil)
        #expect(channel(zooming, x: 64, y: 64) < 200)
        now += TilePlan.settle + 0.01
        let settled = try frame(r)
        #expect(abs(channel(settled, x: 64, y: 64) - 144) <= 1)
        let fresh = try renderer()
        fresh.camera = r.camera
        fresh.strokes = r.strokes
        #expect(settled == (try frame(fresh)))
    }

    @Test func overlayDrawsAboveTilesAndIsNotBaked() throws {
        let r = try renderer()
        let base = try stroke(r, [WorldPoint(x: -40, y: 0), WorldPoint(x: 40, y: 0)], opacity: 1, sequence: 3)
        let pending = try stroke(r, [WorldPoint(x: 0, y: -40), WorldPoint(x: 0, y: 40)], opacity: 1, color: .palette[1])
        r.strokes = [base]
        r.overlay = [pending]
        let both = try frame(r)
        #expect(both[(64 * 128 + 64) * 4 + 2] > 100) // pending colour on top at the crossing
        r.overlay = []
        let without = try frame(r)
        #expect(channel(without, x: 64, y: 40) == 255)
        #expect(channel(without, x: 64, y: 64) == 32)
    }
}
