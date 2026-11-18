import Metal
import QuartzCore
import Testing
@testable import Endless_Drawing

/// Opt-in before/after comparison, not a pass/fail budget: `ENDLESS_RENDER_BENCH=1`.
/// Times include CPU encoding and GPU completion (tests may wait; the app never does).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ENDLESS_RENDER_BENCH"] == "1"))
@MainActor
struct RenderPerformanceTests {
    static let viewport = CanvasSize(width: 1210, height: 834) // iPad Pro 11" points
    static let scale = 2

    /// Deterministic mixed scene around the origin: mostly round, some translucent, all brush kinds.
    static func scene(count: Int, seed: UInt64 = 7) -> [LocalStroke] {
        var state = seed
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double(z ^ (z >> 31)) / Double(UInt64.max)
        }
        return (0..<count).map { index in
            var style = BrushStyle()
            let kind = next()
            style.brush = kind < 0.7 ? .round : kind < 0.8 ? .square : kind < 0.9 ? .chisel : .spray
            style.width = 4 + next() * 20
            style.opacity = next() < 0.3 ? 0.5 : 1
            style.color = InkColor.palette[index % InkColor.palette.count]
            var x = (next() - 0.5) * 1600, y = (next() - 0.5) * 1100
            var angle = next() * .pi * 2
            let points = (0..<64).map { _ -> WorldPoint in
                angle += (next() - 0.5) * 0.6
                x += cos(angle) * 6; y += sin(angle) * 6
                return WorldPoint(x: x, y: y)
            }
            return LocalStroke(id: UUID(), points: points, style: style)
        }
    }

    @MainActor private struct Bench {
        let renderer: MetalRenderer
        let target: MTLTexture

        init() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            renderer = try MetalRenderer(device: device)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: Int(RenderPerformanceTests.viewport.width) * RenderPerformanceTests.scale,
                height: Int(RenderPerformanceTests.viewport.height) * RenderPerformanceTests.scale, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            target = try #require(device.makeTexture(descriptor: descriptor))
        }

        struct Timing { var total = 0.0, encode = 0.0, gpu = 0.0 }

        /// Milliseconds: wall from encode start to completion, CPU encode alone, and GPU execution.
        func frame() throws -> Timing {
            let start = CACurrentMediaTime()
            let command = try #require(renderer.queue.makeCommandBuffer())
            try renderer.encode(to: target, viewport: RenderPerformanceTests.viewport, command: command)
            let encoded = CACurrentMediaTime()
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            return Timing(total: (CACurrentMediaTime() - start) * 1000, encode: (encoded - start) * 1000,
                          gpu: (command.gpuEndTime - command.gpuStartTime) * 1000)
        }

        func frames(_ count: Int, change: () -> Void) throws -> Timing {
            var sum = Timing()
            for _ in 0..<count {
                change(); let next = try frame()
                sum.total += next.total; sum.encode += next.encode; sum.gpu += next.gpu
            }
            let n = Double(count)
            return Timing(total: sum.total / n, encode: sum.encode / n, gpu: sum.gpu / n)
        }
    }

    private func run(count: Int) throws {
        let bench = try Bench()
        let strokes = Self.scene(count: count)
        let prepareStart = CACurrentMediaTime()
        let gpu = try strokes.map { try bench.renderer.upload(#require(BrushGeometry.prepare($0))) }
        let prepare = (CACurrentMediaTime() - prepareStart) * 1000
        bench.renderer.strokes = gpu
        let first = try bench.frame()
        let idle = try bench.frames(5) {}
        let pan = try bench.frames(20) { bench.renderer.camera.pan(screenDelta: WorldPoint(x: 10, y: 0)) }
        let zoom = try bench.frames(10) {
            bench.renderer.camera.zoom(to: bench.renderer.camera.zoom * 1.02, anchor: WorldPoint(x: 605, y: 417),
                                       viewport: Self.viewport)
        }
        let extra = try bench.renderer.upload(#require(BrushGeometry.prepare(Self.scene(count: 1, seed: 99)[0])))
        let add = try bench.frames(1) { bench.renderer.strokes.append(extra) }
        let remove = try bench.frames(1) { bench.renderer.strokes.remove(at: count / 2) }
        func f(_ value: Double) -> String { String(format: "%.2f", value) }
        func t(_ value: Bench.Timing) -> String { "\(f(value.total))(cpu \(f(value.encode))/gpu \(f(value.gpu)))" }
        print("BENCH n=\(count) prepare+upload=\(f(prepare))ms first=\(t(first)) idle=\(t(idle)) pan=\(t(pan)) "
              + "zoom=\(t(zoom)) add=\(t(add)) remove=\(t(remove)) ms/frame")
    }

    @Test func scalesWithStrokeCount() throws {
        for count in [250, 1000, 2000] { try run(count: count) }
    }
}
