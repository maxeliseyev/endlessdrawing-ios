import Metal
import Testing
@testable import Endless_Drawing

@Suite(.serialized)
@MainActor
struct MetalRendererTests {
    private func render(_ paths: [[WorldPoint]], camera: Camera = Camera(), color: InkColor = .palette[0]) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device)
        renderer.camera = camera
        var style = BrushStyle()
        style.width = 12
        style.opacity = 0.5
        style.color = color
        renderer.strokes = try paths.map { points in
            let prepared = try #require(RoundGeometry.prepare(LocalStroke(id: UUID(), points: points, style: style)))
            return try renderer.upload(prepared)
        }
        return try readFrame(renderer)
    }

    private func readFrame(_ renderer: MetalRenderer) throws -> [UInt8] {
        let device = renderer.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(renderer.queue.makeCommandBuffer())
        try renderer.encode(to: target, viewport: CanvasSize(width: 128, height: 128), command: command)
        command.commit()
        // Deliberately synchronizing only in tests, never in the application's input path.
        command.waitUntilCompleted()
        #expect(command.status == .completed, "\(String(describing: command.error))")
        var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        pixels.withUnsafeMutableBytes { pointer in
            target.getBytes(pointer.baseAddress!, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
        }
        return pixels
    }

    private func channel(_ pixels: [UInt8], x: Int, y: Int) -> Int { Int(pixels[(y * 128 + x) * 4]) }

    @Test func emptyCanvasIsWhite() throws {
        let pixels = try render([])
        #expect(pixels.allSatisfy { $0 == 255 })
    }

    @Test func sameStrokeOverlapAppliesOpacityOnce() throws {
        let pixels = try render([[WorldPoint(x: -40, y: 0), .zero, WorldPoint(x: 40, y: 0), .zero]])
        let center = channel(pixels, x: 64, y: 64)
        let line = channel(pixels, x: 44, y: 64)
        #expect(abs(center - 144) <= 1)
        #expect(center == line)
        #expect(channel(pixels, x: 64, y: 20) == 255)
    }

    @Test func differentStrokesCompositeIndependently() throws {
        let path = [WorldPoint(x: -30, y: 0), WorldPoint(x: 30, y: 0)]
        let pixels = try render([path, path])
        #expect(abs(channel(pixels, x: 64, y: 64) - 88) <= 1)
    }

    @Test func removalAndPreviewDoNotLeaveGhostsInCachedCanvas() throws {
        let renderer = try MetalRenderer(device: #require(MTLCreateSystemDefaultDevice()))
        var style = BrushStyle()
        style.opacity = 0.5
        let geometry = try #require(RoundGeometry.prepare(LocalStroke(id: UUID(), points: [.zero], style: style)))
        let stroke = try renderer.upload(geometry)
        renderer.strokes = [stroke]
        let first = try readFrame(renderer)
        #expect(abs(channel(first, x: 64, y: 64) - 144) <= 1)
        renderer.strokes = []
        #expect(try readFrame(renderer).allSatisfy { $0 == 255 })
        renderer.preview = stroke
        let preview = try readFrame(renderer)
        #expect(abs(channel(preview, x: 64, y: 64) - 144) <= 1)
        renderer.preview = nil
        #expect(try readFrame(renderer).allSatisfy { $0 == 255 })
    }

    @Test func cameraChangeInvalidatesCachedCanvas() throws {
        let renderer = try MetalRenderer(device: #require(MTLCreateSystemDefaultDevice()))
        let geometry = try #require(RoundGeometry.prepare(LocalStroke(id: UUID(), points: [.zero], style: BrushStyle())))
        renderer.strokes = [try renderer.upload(geometry)]
        let first = try readFrame(renderer)
        #expect(channel(first, x: 64, y: 64) == 32)
        renderer.camera.pan(screenDelta: WorldPoint(x: 20, y: 0))
        let moved = try readFrame(renderer)
        #expect(channel(moved, x: 64, y: 64) == 255)
        #expect(channel(moved, x: 84, y: 64) == 32)
    }

    @Test func coloredStrokeUsesWebSourceOverWithoutSwappedChannels() throws {
        let pixels = try render([[.zero]], color: InkColor.palette[1])
        let offset = (64 * 128 + 64) * 4
        for (actual, expected) in zip(pixels[offset..<(offset + 4)], [176, 182, 242, 255]) {
            #expect(abs(Int(actual) - expected) <= 1)
        }
    }

    @Test func coordinatesAreNotVerticallyFlipped() throws {
        let pixels = try render([[WorldPoint(x: 20, y: -20)]])
        #expect(abs(channel(pixels, x: 84, y: 44) - 144) <= 1)
        #expect(channel(pixels, x: 84, y: 84) == 255)
    }

    @Test func roundDotAndCameraRelativePrecision() throws {
        var camera = Camera()
        camera.pan(screenDelta: WorldPoint(x: -999_999_990, y: 0))
        let pixels = try render([[WorldPoint(x: 999_999_990, y: 0)]], camera: camera)
        #expect(abs(channel(pixels, x: 64, y: 64) - 144) <= 1)
        #expect(channel(pixels, x: 80, y: 64) == 255)
    }
}
