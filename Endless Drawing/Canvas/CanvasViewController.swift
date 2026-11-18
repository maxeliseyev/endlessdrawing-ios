import MetalKit
import os
import SwiftUI

struct CanvasRepresentable: UIViewControllerRepresentable {
    let model: CanvasModel
    func makeUIViewController(context: Context) -> CanvasViewController { CanvasViewController(model: model) }
    func updateUIViewController(_ controller: CanvasViewController, context: Context) {
        if model.paletteAnchor != nil { controller.cancelGesture() }
    }
}

@MainActor
final class CanvasViewController: UIViewController {
    private let model: CanvasModel
    private var renderer: MetalRenderer?
    private var surface: CanvasSurface!
    private let worker = GeometryWorker()
    private var input = StrokeInput()
    private var navigation = NavigationInput()
    private var camera = Camera()
    private var pencilID: ObjectIdentifier?
    private var fingerIDs: [ObjectIdentifier: Int] = [:]
    private var nextFingerID = 0
    private var longPress: Task<Void, Never>?
    private var longPressOrigin: WorldPoint?
    private var previousSize = CGSize.zero
    private var localStrokes: [LocalStroke] = []
    private var gpuStrokes = GeometryCache()
    /// Shared scene by id, strokes still lacking GPU geometry, and whether their priority must be re-sorted.
    private var strokesByID: [UUID: LocalStroke] = [:]
    private var sequenceByID: [UUID: Int64] = [:]
    private var missingGeometry: Set<UUID> = []
    private var geometryOrderStale = true
    private static let geometryBudget = 64 * 1024 * 1024
    private var finalTasks: [UUID: Task<Void, Never>] = [:]
    private var previewTask: Task<Void, Never>?
    private var pendingPreview: (stroke: LocalStroke, realPointCount: Int)?
    private enum PersistAction { case create(LocalStroke), undo }
    private var volatileStrokes: [LocalStroke] = []
    private var persistenceQueue: [PersistAction] = []
    private var persistenceTask: Task<Void, Never>?
    private var sceneGeometryTask: Task<Void, Never>?
    private var sharedState: WorldRenderState?
    private var strokeExtents: [UUID: StrokeExtent] = [:]
    private var renderBudgetBlocked = false
    private var viewportTask: Task<Void, Never>?
    private var viewportToSend: (Camera, CanvasSize)?
    private var lastViewportCamera: Camera?
    private var lastViewportSize: CanvasSize?
    private var activeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var memoryObserver: NSObjectProtocol?

    init(model: CanvasModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        surface = CanvasSurface(frame: .zero, device: MTLCreateSystemDefaultDevice())
        surface.inputController = self
        surface.isMultipleTouchEnabled = true
        surface.isOpaque = true
        surface.backgroundColor = .white
        surface.colorPixelFormat = .bgra8Unorm
        surface.clearColor = MTLClearColorMake(1, 1, 1, 1)
        surface.framebufferOnly = true
        surface.isPaused = true
        surface.enableSetNeedsDisplay = true
        surface.preferredFramesPerSecond = 120
        surface.layer.isOpaque = true
        (surface.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        surface.accessibilityLabel = String(localized: "Canvas")
        surface.isAccessibilityElement = true
        surface.accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Tools"),
                                                                         target: self, selector: #selector(accessibleTools))]
        view = surface
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureRenderer()
        model.command = { [weak self] command in self?.perform(command) }
        model.onWorld = { [weak self] state in self?.applyShared(state) }
        model.onCamera = { [weak self] next in self?.camera = next; self?.requestFrame() }
        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(secondaryClick(_:)))
        secondaryClick.buttonMaskRequired = .secondary
        surface.addGestureRecognizer(secondaryClick)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        renderer?.isRenderingEnabled = UIApplication.shared.applicationState == .active
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderer?.isRenderingEnabled = false
                self?.sceneGeometryTask?.cancel()
                self?.cancelGesture()
                self?.model.deactivate()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderer?.isRenderingEnabled = true
                self?.model.activate()
                self?.drainPersistence()
                self?.requestFrame()
            }
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderer?.releaseTargets()
                self?.requestFrame()
            }
        }
        becomeFirstResponder()
        model.activate()
        if let state = model.worldState { applyShared(state) }
        requestFrame()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        renderer?.isRenderingEnabled = false
        sceneGeometryTask?.cancel()
        cancelGesture()
        model.deactivate()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        activeObserver = nil
        foregroundObserver = nil
        memoryObserver = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if previousSize != surface.bounds.size {
            cancelGesture()
            previousSize = surface.bounds.size
            requestFrame()
        }
    }

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: String(localized: "Undo"), action: #selector(keyboardUndo), input: "z", modifierFlags: .command),
         UIKeyCommand(title: String(localized: "Tools"), action: #selector(keyboardTools), input: "k", modifierFlags: .command)]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardF10 && $0.key?.modifierFlags.contains(.shift) == true }) {
            showTools()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    private var viewport: CanvasSize { CanvasSize(width: surface.bounds.width, height: surface.bounds.height) }
    private func screen(_ touch: UITouch) -> WorldPoint {
        let point = touch.location(in: surface)
        return WorldPoint(x: point.x, y: point.y)
    }
    private func world(_ touch: UITouch) -> WorldPoint { camera.worldPoint(at: screen(touch), viewport: viewport) }

    func began(_ touches: Set<UITouch>, event: UIEvent?) {
        guard model.paletteAnchor == nil, model.failure == nil,
              renderer?.isRenderingEnabled == true, viewport.isValid else { return }
        // Handle Pencil first even when UIKit batches direct and Pencil touches together.
        for touch in touches where touch.type == .pencil {
            guard pencilID == nil, model.canDraw,
                  !model.isShared || (sharedState?.pendingCount ?? 0) + volatileStrokes.count < 64 else { continue }
            model.userInteracted(camera: camera)
            longPress?.cancel()
            navigation.blockUntilTouchesEnd()
            pencilID = ObjectIdentifier(touch)
            input.begin(at: world(touch), timestamp: touch.timestamp, style: model.style)
            updatePreview()
        }
        for touch in touches where touch.type == .direct {
            model.userInteracted(camera: camera)
            nextFingerID += 1
            fingerIDs[ObjectIdentifier(touch)] = nextFingerID
            navigation.begin(id: nextFingerID, point: screen(touch), camera: camera)
            if pencilID != nil { navigation.blockUntilTouchesEnd() }
            if navigation.touches.count == 1 && pencilID == nil && !navigation.blocked { armLongPress(at: screen(touch)) }
            else { longPress?.cancel() }
        }
        updateFrameLoop()
    }

    func moved(_ touches: Set<UITouch>, event: UIEvent?) {
        for touch in touches {
            if ObjectIdentifier(touch) == pencilID {
                for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                    input.appendReal(world(sample), timestamp: sample.timestamp)
                }
                input.replacePredictions((event?.predictedTouches(for: touch) ?? []).map(world))
                updatePreview()
            } else if let id = fingerIDs[ObjectIdentifier(touch)] {
                let point = screen(touch)
                if let origin = longPressOrigin, origin.distance(to: point) > 10 { longPress?.cancel() }
                if pencilID == nil, let next = navigation.move(id: id, point: point, viewport: viewport) {
                    camera = next
                    model.userInteracted(camera: camera)
                    requestFrame()
                }
            }
        }
    }

    func ended(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        for touch in touches {
            if ObjectIdentifier(touch) == pencilID {
                if !cancelled {
                    for sample in event?.coalescedTouches(for: touch) ?? [] {
                        input.appendReal(world(sample), timestamp: sample.timestamp)
                    }
                    let hadDraft = input.id != nil
                    if let stroke = input.finish(at: world(touch), timestamp: touch.timestamp) {
                        complete(stroke)
                    } else if hadDraft {
                        model.failure = String(localized: "This stroke exceeds the drawing limits.")
                    }
                }
                input.cancel()
                pencilID = nil
                pendingPreview = nil
                renderer?.preview = nil
            }
            if let id = fingerIDs.removeValue(forKey: ObjectIdentifier(touch)) { navigation.end(id: id) }
        }
        longPress?.cancel()
        updateFrameLoop()
        requestFrame()
    }

    func cancelGesture() {
        longPress?.cancel()
        input.cancel()
        pencilID = nil
        pendingPreview = nil
        renderer?.preview = nil
        navigation.reset()
        fingerIDs.removeAll()
        updateFrameLoop()
        requestFrame()
    }

    private func updatePreview() {
        guard let stroke = input.preview else { return }
        pendingPreview = (stroke, input.realPoints.count)
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            while let next = pendingPreview {
                pendingPreview = nil
                let prepared = await worker.prepare(next.stroke, realPointCount: next.realPointCount)
                guard let prepared, let renderer else { continue }
                do {
                    if input.id == next.stroke.id {
                        renderer.preview = try renderer.upload(prepared)
                        requestFrame()
                    } else if finalTasks[next.stroke.id] != nil, gpuStrokes[next.stroke.id] == nil,
                              localStrokes.contains(where: { $0.id == next.stroke.id }) {
                        // Pencil may lift before the first preview job returns. Publish only its real prefix;
                        // never resurrect a cancelled/undone stroke or replace a newer final buffer.
                        guard reserveGeometry(prepared.byteCost, for: next.stroke.id, retained: true) else { continue }
                        gpuStrokes[next.stroke.id] = try renderer.upload(prepared).withoutPredictions
                        missingGeometry.remove(next.stroke.id)
                        synchronizeStrokes()
                    }
                } catch { model.failure = error.localizedDescription }
            }
            previewTask = nil
        }
    }

    /// Accept an input-finalized stroke; visible real geometry must survive the asynchronous final build.
    func complete(_ stroke: LocalStroke) {
        if model.isShared {
            guard volatileStrokes.count < 64 else {
                model.failure = String(localized: "Pending storage is full. Wait or undo a stroke.")
                return
            }
            // Visible immediately, but not durable/server-saved until the respective transactions finish.
            volatileStrokes.append(stroke)
            rebuildSharedScene()
            persistenceQueue.append(.create(stroke))
            drainPersistence()
        } else {
            guard localStrokes.count < 256,
                  localStrokes.reduce(0, { $0 + $1.points.count }) + stroke.points.count <= 100_000 else {
                model.failure = String(localized: "The local prototype is full. Undo a stroke to continue.")
                return
            }
            localStrokes.append(stroke)
        }
        model.canUndo = true
        if let preview = renderer?.preview, preview.id == stroke.id,
           reserveGeometry(GeometryCache.cost(preview), for: stroke.id, retained: true) {
            // Transfer the visible real geometry and remove prediction-only vertices in one main-actor turn.
            // The final worker replaces this buffer later; a new Pencil gesture cannot overwrite the handoff.
            gpuStrokes[stroke.id] = preview.withoutPredictions
            missingGeometry.remove(stroke.id)
            renderer?.preview = nil
            synchronizeStrokes()
        }
        finalTasks[stroke.id] = Task { [weak self, worker] in
            let prepared = await worker.prepare(stroke)
            guard let self else { return }
            defer { finalTasks[stroke.id] = nil }
            guard !Task.isCancelled, localStrokes.contains(where: { $0.id == stroke.id }), let prepared else { return }
            do {
                guard reserveGeometry(prepared.byteCost, for: stroke.id, retained: true) else { return }
                gpuStrokes[stroke.id] = try renderer?.upload(prepared)
                missingGeometry.remove(stroke.id)
                synchronizeStrokes()
            } catch { model.failure = error.localizedDescription }
        }
    }

    /// Shared: confirmed strokes (server seq order) are baked into tiles; pending/volatile drafts stay in the
    /// overlay because their global order is unknown until acknowledged. Local: everything is in local order.
    private func synchronizeStrokes() {
        if model.isShared {
            var confirmed: [MetalRenderer.GPUStroke] = [], overlay: [MetalRenderer.GPUStroke] = []
            for stroke in localStrokes {
                guard var geometry = gpuStrokes[stroke.id] else { continue }
                if let sequence = sequenceByID[stroke.id] { geometry.sequence = sequence; confirmed.append(geometry) }
                else { overlay.append(geometry) }
            }
            renderer?.strokes = confirmed
            renderer?.overlay = overlay
        } else {
            renderer?.strokes = localStrokes.compactMap { gpuStrokes[$0.id] }
        }
        requestFrame()
    }

    private func requestFrame() {
        renderer?.camera = camera
        if surface?.isPaused != false { surface?.setNeedsDisplay() } // the running loop draws the next vsync anyway
        guard model.isShared, viewport.isValid,
              camera != lastViewportCamera || viewport != lastViewportSize else { return }
        lastViewportCamera = camera; lastViewportSize = viewport
        if !missingGeometry.isEmpty { geometryOrderStale = true; prepareSharedGeometry() }
        viewportToSend = (camera, viewport)
        guard viewportTask == nil else { return }
        viewportTask = Task { [weak self] in
            guard let self else { return }
            while let (next, size) = viewportToSend {
                viewportToSend = nil
                await model.viewportChanged(camera: next, viewport: size)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
            viewportTask = nil
        }
    }

    private func applyShared(_ state: WorldRenderState) {
        guard state.revision > (sharedState?.revision ?? 0) else { return }
        sharedState = state
        let interval = Signposts.frame.beginInterval("applyScene")
        rebuildSharedScene()
        Signposts.frame.endInterval("applyScene", interval, "\(state.confirmed.count) confirmed")
    }

    /// Whole subscription scope, not only the viewport: pan must not rebuild the scene or drop geometry.
    private func rebuildSharedScene() {
        let previous = Set(strokesByID.keys)
        var ids: Set<UUID> = []
        let hidden = sharedState?.hidden ?? []
        var sequences: [UUID: Int64] = [:]
        for record in sharedState?.confirmed ?? [] {
            sequences[record.drawable.id] = record.server.sequence
            if strokeExtents[record.drawable.id] == nil { strokeExtents[record.drawable.id] = record.extent }
        }
        let strokes = (sharedState?.confirmed.map(\.drawable) ?? []) + (sharedState?.pending ?? []) + volatileStrokes
        localStrokes = strokes.filter { stroke in
            guard !hidden.contains(stroke.id), ids.insert(stroke.id).inserted else { return false }
            if strokeExtents[stroke.id] == nil { strokeExtents[stroke.id] = StrokeExtent(stroke) }
            return true
        }
        strokesByID = Dictionary(uniqueKeysWithValues: localStrokes.map { ($0.id, $0) })
        sequenceByID = sequences.filter { ids.contains($0.key) }
        if ids != previous { renderBudgetBlocked = false; model.graphicsLimited = false }
        gpuStrokes.retain { ids.contains($0) }
        strokeExtents = strokeExtents.filter { ids.contains($0.key) }
        missingGeometry = ids.filter { gpuStrokes[$0] == nil }
        geometryOrderStale = true
        model.canUndo = (sharedState?.canUndo ?? false) || !volatileStrokes.isEmpty
        synchronizeStrokes()
        prepareSharedGeometry()
    }

    /// Batches of strokes, nearest to the viewport first, prepared on all cores; one renderer update per batch.
    private func prepareSharedGeometry() {
        guard model.isShared, sceneGeometryTask == nil, !renderBudgetBlocked, !missingGeometry.isEmpty else { return }
        sceneGeometryTask = Task { [weak self] in
            guard let self else { return }
            let interval = Signposts.geometry.beginInterval("scene")
            var built = 0
            defer {
                Signposts.geometry.endInterval("scene", interval, "\(built) strokes")
                sceneGeometryTask = nil
                if Task.isCancelled, renderer?.isRenderingEnabled == true { prepareSharedGeometry() }
            }
            var queue: [UUID] = [] // farthest first; popLast takes the nearest
            while !Task.isCancelled {
                if geometryOrderStale { queue = geometryPriority(); geometryOrderStale = false }
                var batch: [LocalStroke] = []
                while batch.count < 256, let id = queue.popLast() {
                    guard missingGeometry.contains(id), finalTasks[id] == nil, let stroke = strokesByID[id] else { continue }
                    batch.append(stroke)
                }
                guard !batch.isEmpty else { return }
                let prepared = await GeometryWorker.prepareBatch(batch)
                guard !Task.isCancelled, let renderer else { return }
                let retained = retainedRect()
                var deferred = false
                for (stroke, geometry) in zip(batch, prepared) {
                    // The scene may have changed while preparing: never resurrect removed or replaced strokes.
                    guard missingGeometry.contains(stroke.id), strokesByID[stroke.id] != nil, let geometry else { continue }
                    guard reserveGeometry(geometry.byteCost, for: stroke.id, retained: isRetained(stroke.id, in: retained)) else {
                        if renderBudgetBlocked { synchronizeStrokes(); return }
                        deferred = true; break // far stroke without room: wait until the camera comes closer
                    }
                    do { gpuStrokes[stroke.id] = try renderer.upload(geometry); missingGeometry.remove(stroke.id); built += 1 }
                    catch { model.failure = String(localized: "Not enough graphics memory. Try again."); synchronizeStrokes(); return }
                }
                synchronizeStrokes()
                if deferred { return }
            }
        }
    }

    /// Missing strokes ordered farthest-first by distance from the camera centre to their extent.
    private func geometryPriority() -> [UUID] {
        let center = camera.center
        func distance(_ id: UUID) -> Double {
            guard let e = strokeExtents[id] else { return .infinity }
            return hypot(max(e.minX - center.x, 0, center.x - e.maxX), max(e.minY - center.y, 0, center.y - e.maxY))
        }
        return missingGeometry.map { ($0, distance($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Viewport plus a 512 pt margin: geometry here is never evicted (tiles near the screen rebuild from it).
    private func retainedRect() -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let halfWidth = (viewport.width / 2 + 512) / camera.zoom, halfHeight = (viewport.height / 2 + 512) / camera.zoom
        return (camera.center.x - halfWidth, camera.center.y - halfHeight, camera.center.x + halfWidth, camera.center.y + halfHeight)
    }

    private func isRetained(_ id: UUID, in rect: (minX: Double, minY: Double, maxX: Double, maxY: Double)) -> Bool {
        guard let e = strokeExtents[id] else { return true }
        return e.maxX >= rect.minX && e.minX <= rect.maxX && e.maxY >= rect.minY && e.minY <= rect.maxY
    }

    /// Room for `bytes` of geometry within the shared budget. Far geometry is evicted for retained strokes;
    /// a far stroke never evicts anything. Only a retained set beyond the budget is "too dense".
    private func reserveGeometry(_ bytes: Int, for id: UUID, retained: Bool) -> Bool {
        guard model.isShared else { return true }
        var excess = gpuStrokes.bytes - (gpuStrokes[id].map(GeometryCache.cost) ?? 0) + bytes - Self.geometryBudget
        guard excess > 0 else { return true }
        guard retained else { return false }
        let rect = retainedRect()
        let victims = gpuStrokes.ids.filter { $0 != id && !isRetained($0, in: rect) }
        for victim in victims {
            guard let stroke = gpuStrokes[victim] else { continue }
            excess -= GeometryCache.cost(stroke)
            gpuStrokes[victim] = nil
            if strokesByID[victim] != nil { missingGeometry.insert(victim) }
            if excess <= 0 { return true }
        }
        graphicsBudgetExceeded(); return false
    }

    private func graphicsBudgetExceeded() {
        if !renderBudgetBlocked { model.failure = String(localized: "This area is too dense. Zoom in to continue.") }
        renderBudgetBlocked = true; model.graphicsLimited = true
    }

    private func drainPersistence() {
        guard model.isShared, persistenceTask == nil, !persistenceQueue.isEmpty else { return }
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            defer { persistenceTask = nil }
            while let action = persistenceQueue.first {
                do {
                    switch action {
                    case .create(let stroke):
                        try await model.persist(stroke)
                        volatileStrokes.removeAll { $0.id == stroke.id }
                    case .undo: try await model.undoShared()
                    }
                    persistenceQueue.removeFirst()
                    rebuildSharedScene()
                } catch {
                    // Keep the failed action and its visible RAM draft, never claim it survived a restart.
                    model.failure = String(localized: "A drawing could not be stored locally. It is still in memory; retry before closing the app.")
                    return
                }
            }
        }
    }

    /// During a gesture MTKView's own display link draws every vsync. With `enableSetNeedsDisplay` left on,
    /// the internal loop never runs and frames only follow touch-driven setNeedsDisplay, so a late input
    /// batch slipped a frame (~9% of frames held two vsyncs on iPad). Idle: draw on demand only.
    private func updateFrameLoop() {
        guard let surface else { return }
        let navigating = !navigation.blocked && !navigation.touches.isEmpty
        let running = renderer?.isRenderingEnabled == true && (pencilID != nil || navigating)
        surface.enableSetNeedsDisplay = !running
        surface.isPaused = !running
    }

    private func armLongPress(at point: WorldPoint) {
        longPress?.cancel()
        longPressOrigin = point
        let initialCamera = camera
        longPress = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled, pencilID == nil, !navigation.blocked,
                  navigation.touches.count == 1,
                  let current = navigation.touches.values.first, current.distance(to: point) <= 10 else { return }
            camera = initialCamera
            model.userInteracted(camera: camera)
            showTools(at: CGPoint(x: point.x, y: point.y))
        }
    }

    private func showTools(at point: CGPoint? = nil) {
        cancelGesture()
        model.paletteAnchor = point ?? CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
    }

    private func perform(_ command: CanvasModel.Command) {
        cancelGesture()
        switch command {
        case .undo:
            if model.isShared {
                persistenceQueue.append(.undo); drainPersistence(); return
            }
            guard let stroke = localStrokes.popLast() else { return }
            finalTasks.removeValue(forKey: stroke.id)?.cancel()
            gpuStrokes[stroke.id] = nil
            model.canUndo = !localStrokes.isEmpty
            synchronizeStrokes()
        case .resetCamera:
            camera = Camera()
            model.userInteracted(camera: camera)
            requestFrame()
        case .retry:
            if renderer == nil { configureRenderer() }
            renderer?.releaseTargets()
            renderBudgetBlocked = false; model.graphicsLimited = false
            model.retryConnection()
            drainPersistence()
            prepareSharedGeometry()
            requestFrame()
        }
    }

    private func configureRenderer() {
        do {
            guard let device = surface.device else { throw MetalRenderer.Failure.unavailable }
            let next = try MetalRenderer(device: device)
            next.isRenderingEnabled = viewIfLoaded?.window != nil && UIApplication.shared.applicationState == .active
            next.onFailure = { [weak self] message in
                self?.surface.isPaused = true
                self?.surface.enableSetNeedsDisplay = true
                if self?.model.failure == nil { self?.model.failure = message }
            }
            renderer = next
            surface.delegate = next
        } catch { model.failure = error.localizedDescription }
    }

    @objc private func accessibleTools() -> Bool { showTools(); return true }
    @objc private func keyboardTools() { showTools() }
    @objc private func keyboardUndo() { perform(.undo) }
    @objc private func secondaryClick(_ gesture: UITapGestureRecognizer) { showTools(at: gesture.location(in: surface)) }
}

@MainActor
private final class CanvasSurface: MTKView {
    weak var inputController: CanvasViewController?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { inputController?.began(touches, event: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { inputController?.moved(touches, event: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { inputController?.ended(touches, event: event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { inputController?.ended(touches, event: event, cancelled: true) }
}

/// GPU geometry by stroke id with a running byte total: budget checks never re-sum the whole scene.
private struct GeometryCache {
    private(set) var bytes = 0
    private var entries: [UUID: MetalRenderer.GPUStroke] = [:]

    subscript(id: UUID) -> MetalRenderer.GPUStroke? {
        get { entries[id] }
        set {
            if let old = entries[id] { bytes -= Self.cost(old) }
            entries[id] = newValue
            if let newValue { bytes += Self.cost(newValue) }
        }
    }

    var ids: [UUID] { Array(entries.keys) }

    mutating func retain(_ keep: (UUID) -> Bool) {
        for id in ids where !keep(id) { self[id] = nil }
    }

    static func cost(_ stroke: MetalRenderer.GPUStroke) -> Int { (stroke.triangles?.length ?? 0) + (stroke.circles?.length ?? 0) }
}

private extension PreparedStroke {
    var byteCost: Int {
        triangles.count * MemoryLayout<SIMD2<Float>>.stride + circles.count * MemoryLayout<CircleInstance>.stride
    }
}
