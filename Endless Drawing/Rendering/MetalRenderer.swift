import MetalKit
import os

@MainActor
final class MetalRenderer: NSObject, MTKViewDelegate {
    enum Failure: LocalizedError {
        case unavailable, allocation, command
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Metal is unavailable on this device.")
            case .allocation: String(localized: "Not enough graphics memory. Try again.")
            case .command: String(localized: "The canvas could not be rendered.")
            }
        }
    }

    struct GPUStroke {
        let id: UUID
        let origin: WorldPoint
        let style: BrushStyle
        let extent: StrokeExtent
        let triangles: MTLBuffer?
        let triangleCount: Int
        let circles: MTLBuffer?
        let circleCount: Int
        let realTriangleCount: Int
        let realCircleCount: Int

        /// Reuse the current buffers during finalization, dropping predictions without an upload or wait.
        var withoutPredictions: Self {
            Self(id: id, origin: origin, style: style, extent: extent,
                 triangles: triangles, triangleCount: realTriangleCount,
                 circles: circles, circleCount: realCircleCount,
                 realTriangleCount: realTriangleCount, realCircleCount: realCircleCount)
        }
    }

    private struct Projection {
        var translation: SIMD2<Float>
        var viewport: SIMD2<Float>
        var zoom: SIMD2<Float>
        var pixelWorld: SIMD2<Float>
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let circlePipeline: MTLRenderPipelineState
    private let inkPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    /// Single-pass ink through framebuffer fetch; nil where unsupported (legacy two passes per stroke).
    private struct InkPipelines {
        let mesh: MTLRenderPipelineState
        let circle: MTLRenderPipelineState
        let composite: MTLRenderPipelineState
        let reset: MTLRenderPipelineState
        let copy: MTLRenderPipelineState
    }
    private let ink: InkPipelines?
    /// Transient per-size attachments: memoryless where available, never sampled.
    private var inkTargets: [SIMD2<Int>: (color: MTLTexture?, coverage: MTLTexture)] = [:]
    private let sampleCount: Int
    private let slots = DispatchSemaphore(value: 3)
    private var coverage: MTLTexture?
    private var multisampleCoverage: MTLTexture?
    private var canvas: MTLTexture?
    private var cachedCamera: Camera?
    private var cachedViewport: CanvasSize?
    private var sceneDirty = true
    private var failed = false

    var isRenderingEnabled = true
    var camera = Camera()
    var strokes: [GPUStroke] = [] { didSet { sceneDirty = true } }
    var preview: GPUStroke?
    var onFailure: ((String) -> Void)?

    var usesSinglePassInk: Bool { ink != nil }
    /// Diagnostics only (e.g. Simulator without framebuffer fetch); never user-facing.
    let singlePassUnavailableReason: String?

    init(device: MTLDevice, singlePassInk: Bool = true) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        self.queue = queue
        let library = try device.makeDefaultLibrary(bundle: .main)
        let samples = device.supportsTextureSampleCount(4) ? 4 : 1
        sampleCount = samples

        func pipeline(vertex: String, fragment: String, mask: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Endless Drawing: \(fragment)"
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.rasterSampleCount = mask ? samples : 1
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = mask ? .r8Unorm : .bgra8Unorm
            attachment.isBlendingEnabled = fragment != "copyCanvas"
            if mask {
                attachment.rgbBlendOperation = .max
                attachment.alphaBlendOperation = .max
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.writeMask = .red
            } else {
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        meshPipeline = try pipeline(vertex: "roundMesh", fragment: "solidCoverage", mask: true)
        circlePipeline = try pipeline(vertex: "roundCircle", fragment: "circleCoverage", mask: true)
        inkPipeline = try pipeline(vertex: "screenQuad", fragment: "compositeInk", mask: false)
        copyPipeline = try pipeline(vertex: "screenQuad", fragment: "copyCanvas", mask: false)

        enum InkRole { case coverage, composite, reset, copy }
        func fetchPipeline(vertex: String, fragment: String, role: InkRole) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Endless Drawing ink: \(fragment)"
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.rasterSampleCount = samples
            let color = descriptor.colorAttachments[0]!, coverage = descriptor.colorAttachments[1]!
            color.pixelFormat = .bgra8Unorm
            coverage.pixelFormat = .r8Unorm
            switch role {
            case .coverage:
                color.writeMask = []
                coverage.isBlendingEnabled = true
                coverage.rgbBlendOperation = .max
                coverage.alphaBlendOperation = .max
                coverage.sourceRGBBlendFactor = .one
                coverage.destinationRGBBlendFactor = .one
                coverage.writeMask = .red
            case .composite:
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                coverage.writeMask = []
            case .reset:
                color.writeMask = []
                coverage.writeMask = .red
            case .copy:
                coverage.writeMask = []
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        var reason: String?
        if singlePassInk {
            do {
                ink = try InkPipelines(
                    mesh: fetchPipeline(vertex: "roundMesh", fragment: "solidCoverageInk", role: .coverage),
                    circle: fetchPipeline(vertex: "roundCircle", fragment: "circleCoverageInk", role: .coverage),
                    composite: fetchPipeline(vertex: "boundsTriangle", fragment: "compositeInkFetch", role: .composite),
                    reset: fetchPipeline(vertex: "boundsTriangle", fragment: "resetCoverage", role: .reset),
                    copy: fetchPipeline(vertex: "screenQuad", fragment: "copyCanvasInk", role: .copy))
            } catch {
                ink = nil; reason = error.localizedDescription
            }
        } else { ink = nil; reason = "disabled" }
        singlePassUnavailableReason = reason
        super.init()
    }

    func upload(_ prepared: PreparedStroke) throws -> GPUStroke {
        func buffer<T>(_ values: [T]) throws -> MTLBuffer? {
            guard !values.isEmpty else { return nil }
            let result = values.withUnsafeBufferPointer { pointer in
                device.makeBuffer(bytes: pointer.baseAddress!, length: values.count * MemoryLayout<T>.stride,
                                  options: .storageModeShared)
            }
            guard let result else { throw Failure.allocation }
            return result
        }
        return try GPUStroke(id: prepared.id, origin: prepared.origin, style: prepared.style, extent: prepared.extent,
                             triangles: buffer(prepared.triangles), triangleCount: prepared.triangles.count,
                             circles: buffer(prepared.circles), circleCount: prepared.circles.count,
                             realTriangleCount: prepared.realTriangleCount, realCircleCount: prepared.realCircleCount)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { releaseTargets() }

    func draw(in view: MTKView) {
        guard isRenderingEnabled, !failed, view.bounds.width > 0, view.bounds.height > 0 else { return }
        // Never block the input thread waiting for the GPU.
        guard slots.wait(timeout: .now()) == .success else {
            requestRetry(in: view)
            return
        }
        guard let drawable = view.currentDrawable else {
            slots.signal()
            requestRetry(in: view)
            return
        }
        guard let command = queue.makeCommandBuffer() else {
            slots.signal()
            failed = true
            onFailure?(Failure.command.localizedDescription)
            return
        }
        do {
            let interval = Signposts.frame.beginInterval("encode")
            try encode(to: drawable.texture,
                       viewport: CanvasSize(width: view.bounds.width, height: view.bounds.height),
                       command: command)
            Signposts.frame.endInterval("encode", interval)
            let slots = slots
            command.addCompletedHandler { [weak self] buffer in
                slots.signal()
                let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                Signposts.frame.emitEvent("gpu", "\(gpu, format: .fixed(precision: 2)) ms")
                if buffer.status == .error {
                    Task { @MainActor [weak self] in
                        self?.failed = true
                        self?.onFailure?(Failure.command.localizedDescription)
                    }
                }
            }
            command.present(drawable)
            command.commit()
        } catch {
            slots.signal()
            failed = true
            onFailure?(error.localizedDescription)
        }
    }

    private func requestRetry(in view: MTKView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { [weak self, weak view] in
            guard let self, isRenderingEnabled, !failed, view?.window != nil else { return }
            view?.setNeedsDisplay()
        }
    }

    /// Also used by offscreen render tests. Callers own submission and synchronization.
    func encode(to target: MTLTexture, viewport: CanvasSize, command: MTLCommandBuffer) throws {
        guard viewport.isValid else { return }
        try ensureTargets(width: target.width, height: target.height)
        guard let canvas else { throw Failure.allocation }
        if sceneDirty || camera != cachedCamera || viewport != cachedViewport {
            if ink != nil {
                let encoder = try beginInkPass(resolvingInto: canvas, command: command)
                for stroke in strokes { encodeInk(stroke, encoder: encoder, target: canvas, viewport: viewport) }
                encoder.endEncoding()
            } else {
                try clear(canvas, color: MTLClearColorMake(1, 1, 1, 1), command: command)
                for stroke in strokes { try draw(stroke, to: canvas, viewport: viewport, command: command) }
            }
            cachedCamera = camera
            cachedViewport = viewport
            sceneDirty = false
        }
        if let ink {
            let encoder = try beginInkPass(resolvingInto: target, command: command)
            encoder.setRenderPipelineState(ink.copy)
            encoder.setFragmentTexture(canvas, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            if let preview { encodeInk(preview, encoder: encoder, target: target, viewport: viewport) }
            encoder.endEncoding()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.command }
        encoder.setRenderPipelineState(copyPipeline)
        encoder.setFragmentTexture(canvas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        if let preview { try draw(preview, to: target, viewport: viewport, command: command) }
    }

    func releaseTargets() {
        inkTargets.removeAll()
        coverage = nil
        multisampleCoverage = nil
        canvas = nil
        sceneDirty = true
        failed = false
    }

    private func ensureTargets(width: Int, height: Int) throws {
        guard canvas?.width != width || canvas?.height != height else { return }
        releaseTargets()
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw Failure.allocation }
        func texture(format: MTLPixelFormat, samples: Int = 1) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                      height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            descriptor.sampleCount = samples
            if samples > 1 { descriptor.textureType = .type2DMultisample }
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
            return texture
        }
        // Publish only after all allocations succeed; partial allocation must be retryable.
        let newCanvas = try texture(format: .bgra8Unorm)
        let newCoverage = try texture(format: .r8Unorm)
        let newMultisample = sampleCount > 1 ? try texture(format: .r8Unorm, samples: sampleCount) : nil
        canvas = newCanvas
        coverage = newCoverage
        multisampleCoverage = newMultisample
    }

    private func clear(_ target: MTLTexture, color: MTLClearColor, command: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].clearColor = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.command }
        encoder.endEncoding()
    }

    /// Target-pixel bounds (2 px AA margin, clamped) and camera-relative projection; nil when offscreen.
    private func placement(_ stroke: GPUStroke, width: Int, height: Int,
                           viewport: CanvasSize) -> (clip: MTLScissorRect, projection: Projection)? {
        let low = camera.screenPoint(at: WorldPoint(x: stroke.extent.minX, y: stroke.extent.minY), viewport: viewport)
        let high = camera.screenPoint(at: WorldPoint(x: stroke.extent.maxX, y: stroke.extent.maxY), viewport: viewport)
        let sx = Double(width) / viewport.width, sy = Double(height) / viewport.height
        guard sx.isFinite, sy.isFinite else { return nil }
        let x0 = Int(max(0, min(Double(width), floor(low.x * sx - 2))))
        let y0 = Int(max(0, min(Double(height), floor(low.y * sy - 2))))
        let x1 = Int(max(0, min(Double(width), ceil(high.x * sx + 2))))
        let y1 = Int(max(0, min(Double(height), ceil(high.y * sy + 2))))
        guard x1 > x0, y1 > y0 else { return nil }
        let screen = camera.screenPoint(at: stroke.origin, viewport: viewport)
        let projection = Projection(translation: SIMD2(Float(screen.x), Float(screen.y)),
                                    viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
                                    zoom: SIMD2(repeating: Float(camera.zoom)),
                                    pixelWorld: SIMD2(Float(viewport.width / Double(width) / camera.zoom),
                                                      Float(viewport.height / Double(height) / camera.zoom)))
        return (MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), projection)
    }

    /// One render pass for a whole target: white MSAA color resolved into `target`, transient coverage.
    private func beginInkPass(resolvingInto target: MTLTexture, command: MTLCommandBuffer) throws -> MTLRenderCommandEncoder {
        let size = SIMD2(target.width, target.height)
        if inkTargets[size] == nil {
            func transient(_ format: MTLPixelFormat) throws -> MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.x,
                                                                          height: size.y, mipmapped: false)
                descriptor.usage = .renderTarget
                descriptor.sampleCount = sampleCount
                if sampleCount > 1 { descriptor.textureType = .type2DMultisample }
                descriptor.storageMode = .memoryless
                if let texture = device.makeTexture(descriptor: descriptor) { return texture }
                descriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
                return texture
            }
            inkTargets[size] = (sampleCount > 1 ? try transient(.bgra8Unorm) : nil, try transient(.r8Unorm))
        }
        guard let attachments = inkTargets[size] else { throw Failure.allocation }
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.clearColor = MTLClearColorMake(1, 1, 1, 1)
        color.loadAction = .clear
        if let multisample = attachments.color {
            color.texture = multisample
            color.resolveTexture = target
            color.storeAction = .multisampleResolve
        } else {
            color.texture = target
            color.storeAction = .store
        }
        let coverage = pass.colorAttachments[1]!
        coverage.texture = attachments.coverage
        coverage.clearColor = MTLClearColorMake(0, 0, 0, 0)
        coverage.loadAction = .clear
        coverage.storeAction = .dontCare
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.command }
        return encoder
    }

    /// Union coverage of one logical stroke, then a single opacity composite that also clears it.
    private func encodeInk(_ stroke: GPUStroke, encoder: MTLRenderCommandEncoder, target: MTLTexture, viewport: CanvasSize) {
        guard let ink, let placed = placement(stroke, width: target.width, height: target.height, viewport: viewport) else { return }
        let clip = placed.clip
        var projection = placed.projection
        encoder.setVertexBytes(&projection, length: MemoryLayout<Projection>.stride, index: 1)
        if let triangles = stroke.triangles {
            encoder.setRenderPipelineState(ink.mesh)
            encoder.setVertexBuffer(triangles, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stroke.triangleCount)
        }
        if let circles = stroke.circles {
            encoder.setRenderPipelineState(ink.circle)
            encoder.setVertexBuffer(circles, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stroke.circleCount)
        }
        // The scissored triangle covers every pixel geometry can touch (extent + 2 px): no coverage leaks to the next stroke.
        let w = Float(target.width), h = Float(target.height)
        var rect = SIMD4(Float(clip.x) / w * 2 - 1, 1 - Float(clip.y) / h * 2,
                         Float(clip.x + clip.width) / w * 2 - 1, 1 - Float(clip.y + clip.height) / h * 2)
        let rgb = stroke.style.color.components
        var color = SIMD4(rgb.x, rgb.y, rgb.z, Float(stroke.style.opacity))
        encoder.setRenderPipelineState(ink.composite)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setScissorRect(clip)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(ink.reset)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
    }

    private func draw(_ stroke: GPUStroke, to target: MTLTexture, viewport: CanvasSize,
                      command: MTLCommandBuffer) throws {
        guard let coverage else { throw Failure.allocation }
        guard let (clip, placed) = placement(stroke, width: target.width, height: target.height, viewport: viewport) else { return }
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = multisampleCoverage ?? coverage
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        attachment.loadAction = .clear
        attachment.storeAction = multisampleCoverage == nil ? .store : .multisampleResolve
        attachment.resolveTexture = multisampleCoverage == nil ? nil : coverage
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.command }
        var projection = placed
        encoder.setScissorRect(clip)
        encoder.setVertexBytes(&projection, length: MemoryLayout<Projection>.stride, index: 1)
        if let triangles = stroke.triangles {
            encoder.setRenderPipelineState(meshPipeline)
            encoder.setVertexBuffer(triangles, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stroke.triangleCount)
        }
        if let circles = stroke.circles {
            encoder.setRenderPipelineState(circlePipeline)
            encoder.setVertexBuffer(circles, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stroke.circleCount)
        }
        encoder.endEncoding()

        let composite = MTLRenderPassDescriptor()
        composite.colorAttachments[0].texture = target
        composite.colorAttachments[0].loadAction = .load
        composite.colorAttachments[0].storeAction = .store
        guard let ink = command.makeRenderCommandEncoder(descriptor: composite) else { throw Failure.command }
        let rgb = stroke.style.color.components
        var color = SIMD4(rgb.x, rgb.y, rgb.z, Float(stroke.style.opacity))
        ink.setScissorRect(clip)
        ink.setRenderPipelineState(inkPipeline)
        ink.setFragmentTexture(coverage, index: 0)
        ink.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        ink.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        ink.endEncoding()
    }
}
