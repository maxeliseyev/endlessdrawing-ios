import MetalKit
import Testing
@testable import Endless_Drawing

@Suite(.serialized)
@MainActor
struct MetalRendererTests {
    private func render(_ paths: [[WorldPoint]], camera: Camera = Camera(), color: InkColor = .palette[0],
                        brush: BrushKind = .round, width: Double = 12) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device)
        renderer.camera = camera
        var style = BrushStyle()
        style.brush = brush
        style.width = width
        style.opacity = 0.5
        style.color = color
        renderer.strokes = try paths.map { points in
            let prepared = try #require(BrushGeometry.prepare(LocalStroke(id: UUID(), points: points, style: style)))
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

    @Test func additionalBrushesRenderTheirActualShapesAndApplyOpacityOnce() throws {
        let square = try render([[.zero]], brush: .square)
        let round = try render([[.zero]])
        #expect(channel(square, x: 69, y: 69) < channel(round, x: 69, y: 69))
        let chisel = try render([[.zero]], brush: .chisel)
        #expect(channel(chisel, x: 66, y: 61) < 255)
        #expect(channel(chisel, x: 66, y: 66) == 255)
        let spray = try render([[.zero, .zero]], brush: .spray, width: 64)
        #expect(spray.contains { $0 < 255 })
        #expect(stride(from: 0, to: spray.count, by: 4).allSatisfy { spray[$0] >= 143 })
    }

    /// Mixed brushes, opacities, overlaps and a preview: single-pass ink must equal the legacy two-pass path.
    @Test func singlePassInkMatchesLegacyTwoPassOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fast = try MetalRenderer(device: device)
        print("RENDER singlePassInk=\(fast.usesSinglePassInk) \(fast.singlePassUnavailableReason ?? "")")
        guard fast.usesSinglePassInk else { return } // no framebuffer fetch: legacy path is the only path
        let legacy = try MetalRenderer(device: device, singlePassInk: false)
        #expect(!legacy.usesSinglePassInk)
        var camera = Camera()
        camera.zoom(to: 0.08, anchor: WorldPoint(x: 64, y: 64), viewport: CanvasSize(width: 128, height: 128))
        let scene = RenderPerformanceTests.scene(count: 80)
        for renderer in [fast, legacy] {
            renderer.camera = camera
            renderer.strokes = try scene.dropLast().map { try renderer.upload(#require(BrushGeometry.prepare($0))) }
            renderer.preview = try renderer.upload(#require(BrushGeometry.prepare(scene[scene.count - 1])))
        }
        let a = try readFrame(fast), b = try readFrame(legacy)
        // Single-pass composites each MSAA sample over its own background; legacy composites resolved
        // coverage over the resolved canvas. They legitimately differ only where edges of different
        // strokes share a pixel. In this dense 8% scene almost every inked pixel is an edge: iPad and
        // Apple M4 both measure 2.3–2.8% of inked channels, max 43. The broken reset-in-composite pass
        // differed on over half of all channels with max 168.
        let differences = zip(a, b).map { abs(Int($0) - Int($1)) }
        let inkedChannels = stride(from: 0, to: b.count, by: 4).filter { b[$0] < 250 }.count * 4
        #expect(inkedChannels > 0) // the scene actually drew ink
        #expect(differences.filter { $0 > 1 }.count * 20 <= inkedChannels)
        #expect(differences.max() ?? 0 <= 64)
    }

    @Test func emptyCanvasIsWhite() throws {
        let pixels = try render([])
        #expect(pixels.allSatisfy { $0 == 255 })
    }

    @Test func strokeRemainsVisibleAtEightPercentZoom() throws {
        var camera = Camera()
        camera.zoom(to: 0.08, anchor: WorldPoint(x: 64, y: 64), viewport: CanvasSize(width: 128, height: 128))
        #expect(camera.zoom == 0.08)
        let pixels = try render([[WorldPoint(x: -400, y: 0), WorldPoint(x: 400, y: 0)]], camera: camera)
        #expect(channel(pixels, x: 64, y: 64) < 255)
        #expect(channel(pixels, x: 64, y: 20) == 255)
        #expect(channel(pixels, x: 10, y: 64) == 255)
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

    @Test func pencilLiftKeepsRealInkVisibleUntilFinalGeometryArrives() async throws {
        let model = CanvasModel()
        let controller = CanvasViewController(model: model)
        controller.loadViewIfNeeded()
        let surface = try #require(controller.view as? MTKView)
        let renderer = try #require(surface.delegate as? MetalRenderer)
        var style = BrushStyle()
        style.width = 12
        style.opacity = 0.5
        let id = UUID()
        let realPoints = [WorldPoint(x: -40, y: 0), .zero]
        let previewStroke = LocalStroke(id: id, points: realPoints + [WorldPoint(x: 40, y: 0)], style: style)
        let previewGeometry = try #require(RoundGeometry.prepare(previewStroke, realPointCount: realPoints.count))
        let preview = try renderer.upload(previewGeometry)
        renderer.preview = preview
        let activeFrame = try readFrame(renderer)
        #expect(abs(channel(activeFrame, x: 40, y: 64) - 144) <= 1)
        #expect(abs(channel(activeFrame, x: 90, y: 64) - 144) <= 1)

        let finished = LocalStroke(id: id, points: realPoints + [WorldPoint(x: 10, y: 0)], style: style)
        controller.complete(finished)
        let held = try #require(renderer.strokes.first)
        #expect(renderer.preview == nil)
        #expect(held.triangles === preview.triangles)
        #expect(held.circles === preview.circles)
        #expect(held.triangleCount == previewGeometry.realTriangleCount)
        // Do not yield to the finalization task yet: render several frames while it is still pending.
        for _ in 0..<3 {
            let pendingFrame = try readFrame(renderer)
            #expect(abs(channel(pendingFrame, x: 40, y: 64) - 144) <= 1)
            #expect(channel(pendingFrame, x: 90, y: 64) == 255) // no predicted ink after lift
        }
        renderer.releaseTargets()
        let rebuiltFrame = try readFrame(renderer)
        #expect(abs(channel(rebuiltFrame, x: 40, y: 64) - 144) <= 1)

        for _ in 0..<100 {
            if renderer.strokes.first?.triangleCount == 12 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(renderer.strokes.first?.triangleCount == 12)
        let finalFrame = try readFrame(renderer)
        #expect(abs(channel(finalFrame, x: 40, y: 64) - 144) <= 1)
        #expect(abs(channel(finalFrame, x: 74, y: 64) - 144) <= 1)
        #expect(channel(finalFrame, x: 90, y: 64) == 255)
    }

    @Test func rapidStrokesAndUndoPreservePendingHandoffsWithoutResurrection() async throws {
        let model = CanvasModel()
        let controller = CanvasViewController(model: model)
        controller.loadViewIfNeeded()
        let surface = try #require(controller.view as? MTKView)
        let renderer = try #require(surface.delegate as? MetalRenderer)
        var style = BrushStyle()
        style.width = 12
        style.opacity = 0.5
        var ids: [UUID] = []
        for y in [-20.0, 20.0] {
            let real = LocalStroke(id: UUID(), points: [WorldPoint(x: -40, y: y), WorldPoint(x: 0, y: y)], style: style)
            let predicted = LocalStroke(id: real.id, points: real.points + [WorldPoint(x: 40, y: y)], style: style)
            let prepared = try #require(RoundGeometry.prepare(predicted, realPointCount: real.points.count))
            renderer.preview = try renderer.upload(prepared)
            controller.complete(real)
            ids.append(real.id)
        }
        #expect(renderer.strokes.map(\.id) == ids)
        let bothPending = try readFrame(renderer)
        #expect(abs(channel(bothPending, x: 40, y: 44) - 144) <= 1)
        #expect(abs(channel(bothPending, x: 40, y: 84) - 144) <= 1)
        let heldFirst = try #require(renderer.strokes.first)
        model.command?(.undo)
        #expect(renderer.strokes.map(\.id) == [ids[0]])
        let afterUndo = try readFrame(renderer)
        #expect(channel(afterUndo, x: 40, y: 84) == 255)
        for _ in 0..<100 {
            if renderer.strokes.first?.triangles !== heldFirst.triangles { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(renderer.strokes.first?.triangles !== heldFirst.triangles)
        #expect(renderer.strokes.map(\.id) == [ids[0]])
        let finalFrame = try readFrame(renderer)
        #expect(abs(channel(finalFrame, x: 40, y: 44) - 144) <= 1)
        #expect(channel(finalFrame, x: 40, y: 84) == 255)
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
