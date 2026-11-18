import MetalKit
import os

/// Confirmed strokes are rasterised once into world-aligned tiles (port of the web tile cache); a frame
/// copies visible tiles and draws only the overlay (pending drafts) and the active preview on top.
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
        /// Server seq for confirmed strokes; 0 = local order (the renderer keys it on first sight).
        var sequence: Int64 = 0

        /// Reuse the current buffers during finalization, dropping predictions without an upload or wait.
        var withoutPredictions: Self {
            Self(id: id, origin: origin, style: style, extent: extent,
                 triangles: triangles, triangleCount: realTriangleCount,
                 circles: circles, circleCount: realCircleCount,
                 realTriangleCount: realTriangleCount, realCircleCount: realCircleCount, sequence: sequence)
        }

        func sameGeometry(as other: Self) -> Bool {
            triangles === other.triangles && circles === other.circles
                && triangleCount == other.triangleCount && circleCount == other.circleCount
        }
    }

    private struct Projection {
        var translation: SIMD2<Float>
        var viewport: SIMD2<Float>
        var zoom: SIMD2<Float>
        var pixelWorld: SIMD2<Float>
    }

    private final class Tile {
        let key: TilePlan.Key
        let bounds: TilePlan.Rect
        var texture: MTLTexture
        /// Highest order key drawn into the texture.
        var maxKey = Int64.min
        /// Contains content that must not be shown (removed, replaced or reordered strokes): rebuild first.
        var spoiled = false
        /// Newer strokes to draw on top of the current texture.
        var appends: [UUID] = []
        var lastUsed: UInt64 = 0
        init(key: TilePlan.Key, texture: MTLTexture) {
            self.key = key; bounds = TilePlan.bounds(key); self.texture = texture
        }
    }

    /// Counters for tests and signposts.
    struct TileStats: Equatable { var resident = 0, built = 0, appended = 0 }

    static let tileCapacity = 64 // 512² BGRA8 = 1 MiB each (architecture §8: tile LRU ≤ 64 MiB)
    private static let maxAppends = 256
    private static let optionalBuildBudget: TimeInterval = 0.004

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let circlePipeline: MTLRenderPipelineState
    private let inkPipeline: MTLRenderPipelineState
    private let tilePipeline: MTLRenderPipelineState
    /// Single-pass ink through framebuffer fetch; nil where unsupported (legacy two passes per stroke).
    private struct InkPipelines {
        let mesh: MTLRenderPipelineState
        let circle: MTLRenderPipelineState
        let composite: MTLRenderPipelineState
        let reset: MTLRenderPipelineState
        let copy: MTLRenderPipelineState
        let tile: MTLRenderPipelineState
    }
    private let ink: InkPipelines?
    /// Transient per-size attachments: memoryless where available, never sampled.
    private var inkTargets: [SIMD2<Int>: (color: MTLTexture?, coverage: MTLTexture)] = [:]
    /// Legacy coverage masks per target size (resolved mask is sampled by the composite pass).
    private var legacyCoverage: [SIMD2<Int>: (resolved: MTLTexture, multisample: MTLTexture?)] = [:]
    private let sampleCount: Int
    private let slots = DispatchSemaphore(value: 3)
    private var failed = false

    private var tiles: [TilePlan.Key: Tile] = [:]
    private var spareTextures: [MTLTexture] = []
    private var retiredTextures: [(texture: MTLTexture, frame: UInt64)] = []
    private var frameNumber: UInt64 = 0
    private var zoomClock = TilePlan.ZoomClock()
    private var index = StrokeIndex()
    private var byID: [UUID: GPUStroke] = [:]
    private var orderKeys: [UUID: Int64] = [:]
    private var nextLocalKey: Int64 = 0
    /// Delay until the frame loop must run again (zoom settle, tiles still missing); nil when complete.
    private(set) var nextFrameDelay: TimeInterval?
    private(set) var tileStats = TileStats()

    var isRenderingEnabled = true
    var camera = Camera()
    /// Confirmed scene in drawing order (ascending order keys). Baked into tiles.
    var strokes: [GPUStroke] = [] { didSet { sceneChanged(from: oldValue) } }
    /// Drawn every frame above tiles in this order: pending drafts whose global order is not known yet.
    var overlay: [GPUStroke] = []
    var preview: GPUStroke?
    var onFailure: ((String) -> Void)?
    /// Injected in tests for deterministic zoom settling.
    var clock: () -> TimeInterval = { CACurrentMediaTime() }

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

        func pipeline(vertex: String, fragment: String, mask: Bool, blend: Bool = true) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Endless Drawing: \(fragment)"
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.rasterSampleCount = mask ? samples : 1
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = mask ? .r8Unorm : .bgra8Unorm
            attachment.isBlendingEnabled = blend
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
        tilePipeline = try pipeline(vertex: "tileQuad", fragment: "tileCopy", mask: false, blend: false)

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
                    copy: fetchPipeline(vertex: "screenQuad", fragment: "copyCanvasInk", role: .copy),
                    tile: fetchPipeline(vertex: "tileQuad", fragment: "tileCopyInk", role: .copy))
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

    // MARK: - Frame loop

    /// Tiles depend on world position and scale, not on the drawable: rotation keeps them; only
    /// size-specific transient attachments are dropped.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        inkTargets.removeAll()
        legacyCoverage.removeAll()
    }

    func draw(in view: MTKView) {
        guard isRenderingEnabled, !failed, view.bounds.width > 0, view.bounds.height > 0 else { return }
        // Never block the input thread waiting for the GPU.
        guard slots.wait(timeout: .now()) == .success else {
            requestFrame(in: view, after: 1.0 / 120)
            return
        }
        guard let drawable = view.currentDrawable else {
            slots.signal()
            requestFrame(in: view, after: 1.0 / 120)
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
            // Zoom settling and budgeted tile builds continue on later frames even when input is idle.
            if let delay = nextFrameDelay { requestFrame(in: view, after: max(delay, 1.0 / 120)) }
        } catch {
            slots.signal()
            failed = true
            onFailure?(error.localizedDescription)
        }
    }

    private func requestFrame(in view: MTKView, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
            guard let self, isRenderingEnabled, !failed, view?.window != nil else { return }
            view?.setNeedsDisplay()
        }
    }

    /// Also used by offscreen render tests. Callers own submission and synchronization.
    func encode(to target: MTLTexture, viewport: CanvasSize, command: MTLCommandBuffer) throws {
        guard viewport.isValid, target.width > 0, target.height > 0 else { return }
        frameNumber &+= 1
        recycleTextures()
        let frame = TilePlan.plan(camera: camera, viewport: viewport, pixelsPerPoint: Double(target.width) / viewport.width,
                                  width: target.width, height: target.height, now: clock(), clock: zoomClock)
        zoomClock = frame.clock
        let interval = Signposts.tiles.beginInterval("tiles")
        let before = tileStats
        let start = CACurrentMediaTime()
        func withinBudget() -> Bool { CACurrentMediaTime() - start < Self.optionalBuildBudget }

        var shown: [Tile] = [], missing: [TilePlan.Key] = []
        for key in frame.needed {
            guard let tile = tiles[key] else { missing.append(key); continue }
            // Visible tiles never show removed strokes, and never lose ink handed over from the overlay.
            try refresh(tile, command: command)
            tile.lastUsed = frameNumber
            shown.append(tile)
        }
        var incomplete = false
        var stillMissing: [TilePlan.Key] = []
        for key in missing {
            // Without a usable fallback the area would be blank: build regardless of the budget.
            if !hasFallback(for: key) || withinBudget() {
                shown.append(try build(key, command: command))
            } else { stillMissing.append(key); incomplete = true }
        }
        if !incomplete, frame.settleIn == nil {
            for key in frame.ring where tiles[key] == nil {
                guard tiles.count < Self.tileCapacity || evictOne(keeping: frame) else { break }
                guard withinBudget() else { incomplete = true; break }
                _ = try build(key, command: command)
            }
        }
        let fallbacks = stillMissing.isEmpty ? [] : fallbackTiles(for: frame, shown: shown)
        try compose(into: target, frame: frame, tiles: fallbacks + shown, command: command)
        while tiles.count > Self.tileCapacity, evictOne(keeping: frame) {}
        tileStats.resident = tiles.count
        Signposts.tiles.endInterval("tiles", interval,
                                    "\(self.tileStats.built - before.built) built \(self.tileStats.appended - before.appended) appended")
        nextFrameDelay = frame.settleIn ?? (incomplete ? 0 : nil)
    }

    /// Memory warning or explicit retry: drop every GPU cache; the next frame rebuilds from the index.
    func releaseTargets() {
        inkTargets.removeAll()
        legacyCoverage.removeAll()
        tiles.removeAll()
        spareTextures.removeAll()
        retiredTextures.removeAll()
        tileStats.resident = 0
        failed = false
    }

    // MARK: - Scene changes → tile invalidation

    private func sceneChanged(from old: [GPUStroke]) {
        let previous = byID
        var current: [UUID: GPUStroke] = [:]
        current.reserveCapacity(strokes.count)
        for stroke in strokes { current[stroke.id] = stroke }
        byID = current
        for (id, stroke) in previous {
            if let next = current[id], next.sameGeometry(as: stroke) { continue }
            index.remove(id)
            spoilTiles(intersecting: stroke.extent)
            if current[id] == nil { orderKeys[id] = nil }
        }
        var lastKey = Int64.min, ordered = true
        for stroke in strokes {
            let key: Int64
            if stroke.sequence > 0 { key = stroke.sequence }
            else if let known = orderKeys[stroke.id] { key = known }
            else { nextLocalKey += 1; key = nextLocalKey }
            orderKeys[stroke.id] = key
            if key <= lastKey { ordered = false }
            lastKey = key
            if let before = previous[stroke.id], before.sameGeometry(as: stroke) { continue }
            index.insert(stroke.id, extent: stroke.extent)
            for tile in tiles.values where !tile.spoiled && tile.bounds.intersects(stroke.extent) {
                // Only a stroke above everything already in the tile can be drawn on top of it.
                if key > tile.maxKey, tile.appends.count < Self.maxAppends { tile.appends.append(stroke.id) }
                else { tile.spoiled = true; tile.appends.removeAll() }
            }
        }
        if !ordered {
            // Callers pass seq order; anything else rebuilds instead of trusting stale order.
            for tile in tiles.values { tile.spoiled = true; tile.appends.removeAll() }
        }
    }

    private func spoilTiles(intersecting extent: StrokeExtent) {
        for tile in tiles.values where tile.bounds.intersects(extent) { tile.spoiled = true; tile.appends.removeAll() }
    }

    // MARK: - Tile building

    private func strokes(in bounds: TilePlan.Rect) -> [GPUStroke] {
        index.query(bounds).compactMap { byID[$0] }.sorted { (orderKeys[$0.id] ?? 0) < (orderKeys[$1.id] ?? 0) }
    }

    private func refresh(_ tile: Tile, command: MTLCommandBuffer) throws {
        if tile.spoiled {
            try render(tile, strokes: strokes(in: tile.bounds), base: nil, command: command)
            tileStats.built += 1
        } else if !tile.appends.isEmpty {
            let added = tile.appends.compactMap { byID[$0] }.sorted { (orderKeys[$0.id] ?? 0) < (orderKeys[$1.id] ?? 0) }
            try render(tile, strokes: added, base: tile.texture, command: command)
            tileStats.appended += 1
        }
    }

    private func build(_ key: TilePlan.Key, command: MTLCommandBuffer) throws -> Tile {
        let tile = Tile(key: key, texture: try takeTexture())
        tile.lastUsed = frameNumber
        tiles[key] = tile
        try render(tile, strokes: strokes(in: tile.bounds), base: nil, command: command, reuseTexture: true)
        tileStats.built += 1
        return tile
    }

    /// Renders into a fresh texture (white or a copy of `base`, then strokes), never into one the GPU
    /// may still be sampling for an earlier frame; the replaced texture is recycled later.
    private func render(_ tile: Tile, strokes: [GPUStroke], base: MTLTexture?, command: MTLCommandBuffer,
                        reuseTexture: Bool = false) throws {
        let texture = reuseTexture ? tile.texture : try takeTexture()
        let view = TilePlan.view(tile.key)
        if ink != nil {
            let encoder = try beginInkPass(resolvingInto: texture, command: command)
            if let base, let ink {
                encoder.setRenderPipelineState(ink.copy)
                encoder.setFragmentTexture(base, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            for stroke in strokes { encodeInk(stroke, encoder: encoder, target: texture, view: view) }
            encoder.endEncoding()
        } else {
            if let base {
                guard let blit = command.makeBlitCommandEncoder() else { throw Failure.command }
                blit.copy(from: base, to: texture)
                blit.endEncoding()
            } else {
                try clear(texture, color: MTLClearColorMake(1, 1, 1, 1), command: command)
            }
            for stroke in strokes { try draw(stroke, to: texture, view: view, command: command) }
        }
        if !reuseTexture { retire(tile.texture) }
        tile.texture = texture
        tile.spoiled = false
        tile.appends.removeAll()
        tile.maxKey = max(base == nil ? Int64.min : tile.maxKey, strokes.last.flatMap { orderKeys[$0.id] } ?? Int64.min)
    }

    private func hasFallback(for key: TilePlan.Key) -> Bool {
        let bounds = TilePlan.bounds(key)
        return tiles.values.contains { $0.key.scale != key.scale && !$0.spoiled && $0.bounds.overlaps(bounds) }
    }

    /// Clean tiles of other scales over the visible area, farthest scale first so the nearest lands on top.
    private func fallbackTiles(for frame: TilePlan.Frame, shown: [Tile]) -> [Tile] {
        let visible = TilePlan.Rect(minX: frame.view.origin.x, minY: frame.view.origin.y,
                                    maxX: frame.view.origin.x + Double(frame.view.width) / frame.view.scale,
                                    maxY: frame.view.origin.y + Double(frame.view.height) / frame.view.scale)
        let distance = { (tile: Tile) in abs(log(tile.key.scale / frame.scale)) }
        return tiles.values.filter { $0.key.scale != frame.scale && !$0.spoiled && $0.bounds.overlaps(visible) }
            .sorted { distance($0) > distance($1) }
            .map { $0.lastUsed = self.frameNumber; return $0 }
    }

    private func evictOne(keeping frame: TilePlan.Frame) -> Bool {
        let needed = Set(frame.needed)
        guard let victim = tiles.values.filter({ $0.lastUsed < frameNumber && !needed.contains($0.key) })
            .min(by: { $0.lastUsed < $1.lastUsed }) else { return false }
        tiles[victim.key] = nil
        retire(victim.texture)
        return true
    }

    private func takeTexture() throws -> MTLTexture {
        if let texture = spareTextures.popLast() { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: TilePlan.size,
                                                                  height: TilePlan.size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        return texture
    }

    private func retire(_ texture: MTLTexture) { retiredTextures.append((texture, frameNumber)) }

    /// At most three frames are in flight, so a texture retired three frames ago is no longer sampled.
    private func recycleTextures() {
        while let first = retiredTextures.first, frameNumber > first.frame + 3 {
            retiredTextures.removeFirst()
            if spareTextures.count < 8 { spareTextures.append(first.texture) }
        }
    }

    // MARK: - Composition

    private func compose(into target: MTLTexture, frame: TilePlan.Frame, tiles shown: [Tile],
                         command: MTLCommandBuffer) throws {
        let w = Double(target.width), h = Double(target.height)
        func tileRect(_ tile: Tile) -> SIMD4<Float> {
            let p = TilePlan.placement(tile.key, in: frame.view)
            return SIMD4(Float(Double(p.x0) / w * 2 - 1), Float(1 - Double(p.y0) / h * 2),
                         Float(Double(p.x1) / w * 2 - 1), Float(1 - Double(p.y1) / h * 2))
        }
        func drawTiles(_ encoder: MTLRenderCommandEncoder) {
            for tile in shown {
                var rect = tileRect(tile)
                var linear: UInt32 = tile.key.scale == frame.exact ? 0 : 1
                encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setFragmentBytes(&linear, length: MemoryLayout<UInt32>.stride, index: 0)
                encoder.setFragmentTexture(tile.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        let layers = overlay + (preview.map { [$0] } ?? [])
        if let ink {
            let encoder = try beginInkPass(resolvingInto: target, command: command)
            encoder.setRenderPipelineState(ink.tile)
            drawTiles(encoder)
            for stroke in layers { encodeInk(stroke, encoder: encoder, target: target, view: frame.view) }
            encoder.endEncoding()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.command }
        encoder.setRenderPipelineState(tilePipeline)
        drawTiles(encoder)
        encoder.endEncoding()
        for stroke in layers { try draw(stroke, to: target, view: frame.view, command: command) }
    }

    // MARK: - Stroke encoding

    private func clear(_ target: MTLTexture, color: MTLClearColor, command: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].clearColor = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.command }
        encoder.endEncoding()
    }

    /// Target-pixel bounds (2 px AA margin, clamped) and view-relative projection; nil when outside.
    /// Stroke origin minus view origin is taken in Double, so far world coordinates keep sub-pixel precision.
    private func placement(_ stroke: GPUStroke, view: TilePlan.View) -> (clip: MTLScissorRect, projection: Projection)? {
        let s = view.scale, width = Double(view.width), height = Double(view.height)
        let x0 = Int(max(0, min(width, floor((stroke.extent.minX - view.origin.x) * s - 2))))
        let y0 = Int(max(0, min(height, floor((stroke.extent.minY - view.origin.y) * s - 2))))
        let x1 = Int(max(0, min(width, ceil((stroke.extent.maxX - view.origin.x) * s + 2))))
        let y1 = Int(max(0, min(height, ceil((stroke.extent.maxY - view.origin.y) * s + 2))))
        guard x1 > x0, y1 > y0 else { return nil }
        let projection = Projection(translation: SIMD2(Float((stroke.origin.x - view.origin.x) * s),
                                                       Float((stroke.origin.y - view.origin.y) * s)),
                                    viewport: SIMD2(Float(width), Float(height)),
                                    zoom: SIMD2(repeating: Float(s)),
                                    pixelWorld: SIMD2(repeating: Float(1 / s)))
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

    /// Union coverage of one logical stroke, a single opacity composite, then a coverage reset.
    private func encodeInk(_ stroke: GPUStroke, encoder: MTLRenderCommandEncoder, target: MTLTexture, view: TilePlan.View) {
        guard let ink, let placed = placement(stroke, view: view) else { return }
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

    /// Legacy path (no framebuffer fetch): coverage pass, resolve, then one composite pass per stroke.
    private func draw(_ stroke: GPUStroke, to target: MTLTexture, view: TilePlan.View, command: MTLCommandBuffer) throws {
        guard let (clip, placed) = placement(stroke, view: view) else { return }
        let size = SIMD2(target.width, target.height)
        if legacyCoverage[size] == nil {
            func texture(samples: Int) throws -> MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size.x,
                                                                          height: size.y, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                descriptor.sampleCount = samples
                if samples > 1 { descriptor.textureType = .type2DMultisample }
                guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
                return texture
            }
            legacyCoverage[size] = (try texture(samples: 1), sampleCount > 1 ? try texture(samples: sampleCount) : nil)
        }
        guard let masks = legacyCoverage[size] else { throw Failure.allocation }
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = masks.multisample ?? masks.resolved
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        attachment.loadAction = .clear
        attachment.storeAction = masks.multisample == nil ? .store : .multisampleResolve
        attachment.resolveTexture = masks.multisample == nil ? nil : masks.resolved
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
        ink.setFragmentTexture(masks.resolved, index: 0)
        ink.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        ink.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        ink.endEncoding()
    }
}

private extension TilePlan.Rect {
    nonisolated func overlaps(_ other: Self) -> Bool {
        maxX >= other.minX && minX <= other.maxX && maxY >= other.minY && minY <= other.maxY
    }
}
