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

    init(device: MTLDevice) throws {
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
            try clear(canvas, color: MTLClearColorMake(1, 1, 1, 1), command: command)
            for stroke in strokes { try draw(stroke, to: canvas, viewport: viewport, command: command) }
            cachedCamera = camera
            cachedViewport = viewport
            sceneDirty = false
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

    private func draw(_ stroke: GPUStroke, to target: MTLTexture, viewport: CanvasSize,
                      command: MTLCommandBuffer) throws {
        guard let coverage else { throw Failure.allocation }
        let low = camera.screenPoint(at: WorldPoint(x: stroke.extent.minX, y: stroke.extent.minY), viewport: viewport)
        let high = camera.screenPoint(at: WorldPoint(x: stroke.extent.maxX, y: stroke.extent.maxY), viewport: viewport)
        let sx = Double(target.width) / viewport.width, sy = Double(target.height) / viewport.height
        guard sx.isFinite, sy.isFinite else { throw Failure.allocation }
        let x0 = Int(max(0, min(Double(target.width), floor(low.x * sx - 2))))
        let y0 = Int(max(0, min(Double(target.height), floor(low.y * sy - 2))))
        let x1 = Int(max(0, min(Double(target.width), ceil(high.x * sx + 2))))
        let y1 = Int(max(0, min(Double(target.height), ceil(high.y * sy + 2))))
        guard x1 > x0, y1 > y0 else { return }
        let clip = MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = multisampleCoverage ?? coverage
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        attachment.loadAction = .clear
        attachment.storeAction = multisampleCoverage == nil ? .store : .multisampleResolve
        attachment.resolveTexture = multisampleCoverage == nil ? nil : coverage
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.command }
        let screen = camera.screenPoint(at: stroke.origin, viewport: viewport)
        var projection = Projection(translation: SIMD2(Float(screen.x), Float(screen.y)),
                                    viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
                                    zoom: SIMD2(repeating: Float(camera.zoom)),
                                    pixelWorld: SIMD2(Float(viewport.width / Double(target.width) / camera.zoom),
                                                      Float(viewport.height / Double(target.height) / camera.zoom)))
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
