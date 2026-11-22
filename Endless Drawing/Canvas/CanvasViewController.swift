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
    /// The touch drawing the current stroke: a Pencil, or a finger in finger-drawing mode.
    private var drawingID: ObjectIdentifier?
    private var drawingWithFinger = false
    private var fingerIDs: [ObjectIdentifier: Int] = [:]
    private var nextFingerID = 0
    /// Finger-drawing mode, decided when the first finger of a gesture lands and kept until all lift.
    private var fingersDraw = false
    private var fingerGesture = FingerGesture()
    /// Latest screen position of every finger: navigation may start from fingers that were drawing.
    private var fingerPoints: [Int: WorldPoint] = [:]
    /// A finger that would draw but the terms are not accepted yet: asks once it is clearly a stroke.
    private var termsCandidate: Int?
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
    /// Confirmed shared records by id (for report hit testing: own flag and author tag).
    private var recordsByID: [UUID: SceneStroke] = [:]
    /// Report mode: where each touch started, to tell a tap (select) from a pan.
    private var reportTaps: [ObjectIdentifier: WorldPoint] = [:]
    /// Dashed outlines of the strokes selected for a report.
    private let reportLayer = CAShapeLayer()
    private var renderBudgetBlocked = false
    private var viewportTask: Task<Void, Never>?
    private var viewportToSend: (Camera, CanvasSize)?
    private var lastViewportCamera: Camera?
    private var lastViewportSize: CanvasSize?
    private var activeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var memoryObserver: NSObjectProtocol?
    /// The only frame source. Once attached to the layer, MTKView must never take a drawable itself
    /// (`-nextDrawable should not be called when using CAMetalDisplayLink`), so MTKView never draws.
    /// Runs continuously during gestures; otherwise wakes for requested frames and pauses again.
    /// Last Pencil contact in surface coordinates: palette anchor when a tap/squeeze has no hover pose.
    private var lastPencilPoint: CGPoint?
    private var displayLink: CAMetalDisplayLink?
    private var frameLoopRunning = false
    private var frameRequested = false
    private var delayedFrame: DispatchWorkItem?

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
        surface.enableSetNeedsDisplay = false // frames come only from the CAMetalDisplayLink
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
        model.onHiddenChanged = { [weak self] in self?.rebuildSharedScene() }
        model.onReportChanged = { [weak self] in self?.updateReportOverlay() }
        reportLayer.fillColor = nil
        reportLayer.strokeColor = UIColor.systemBlue.cgColor
        reportLayer.lineWidth = 2
        reportLayer.lineDashPattern = [6, 4]
        surface.layer.addSublayer(reportLayer)
        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(secondaryClick(_:)))
        secondaryClick.buttonMaskRequired = .secondary
        // Mouse/trackpad only: otherwise a quick Pencil tap was recognized here, opened the palette and
        // cancelled the dot being drawn.
        secondaryClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        surface.addGestureRecognizer(secondaryClick)
        surface.addInteraction(UIPencilInteraction(delegate: self))
        Signposts.input.notice("pencil interaction installed; preferred tap=\(UIPencilInteraction.preferredTapAction.rawValue, privacy: .public) squeeze=\(UIPencilInteraction.preferredSqueezeAction.rawValue, privacy: .public)")
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
        displayLink?.invalidate(); displayLink = nil; frameLoopRunning = false; frameRequested = false
        delayedFrame?.cancel(); delayedFrame = nil
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
        // MTKView only pushes its drawableSize to the layer from its own draw loop, which is off (the
        // CAMetalDisplayLink is the frame source): without this the layer kept the pre-rotation size and
        // the old-aspect drawable was stretched onto the rotated bounds.
        if let layer = surface.layer as? CAMetalLayer {
            let scale = surface.contentScaleFactor
            let size = CGSize(width: (surface.bounds.width * scale).rounded(), height: (surface.bounds.height * scale).rounded())
            if size.width > 0, size.height > 0, layer.drawableSize != size {
                layer.drawableSize = size
                renderer?.mtkView(surface, drawableSizeWillChange: size)
            }
        }
        if previousSize != surface.bounds.size {
            cancelGesture()
            lastPencilPoint = nil // stale after resize/rotation
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
        if model.reporting {
            // Taps (finger or Pencil) pick strokes; fingers still pan and zoom. Nothing is drawn.
            for touch in touches where touch.type == .pencil || touch.type == .direct { reportTaps[ObjectIdentifier(touch)] = screen(touch) }
        }
        if fingerIDs.isEmpty { fingersDraw = model.fingersDraw && !model.reporting }
        // Handle Pencil first even when UIKit batches direct and Pencil touches together.
        for touch in touches where touch.type == .pencil && !model.reporting {
            model.pencilUsed()
            if drawingWithFinger { abandonFingerStroke() } // the Pencil wins over a finger stroke
            fingerGesture.abandonDrawing()
            guard drawingID == nil else { continue }
            guard startStroke(touch) else { continue }
            lastPencilPoint = touch.location(in: surface)
        }
        for touch in touches where touch.type == .direct {
            model.userInteracted(camera: camera)
            nextFingerID += 1
            let id = nextFingerID, point = screen(touch)
            fingerIDs[ObjectIdentifier(touch)] = id
            fingerPoints[id] = point
            if fingersDraw { fingerBegan(touch, id: id, at: point); continue }
            navigation.begin(id: id, point: point, camera: camera)
            if drawingID != nil { navigation.blockUntilTouchesEnd() }
            if navigation.touches.count == 1 && drawingID == nil && !navigation.blocked && !model.reporting {
                armLongPress(at: point) { [weak self] in
                    guard let self, drawingID == nil, !navigation.blocked, navigation.touches.count == 1 else { return nil }
                    return navigation.touches.values.first
                }
            } else { longPress?.cancel() }
        }
        updateFrameLoop()
    }

    /// Finger-drawing mode: one finger draws, a quick second finger turns it into navigation (`FingerGesture`).
    private func fingerBegan(_ touch: UITouch, id: Int, at point: WorldPoint) {
        let pencilDrawing = drawingID != nil && !drawingWithFinger
        switch fingerGesture.began(id: id, at: touch.timestamp) {
        case .draw:
            if pencilDrawing { fingerGesture.abandonDrawing(); return } // palm next to the Pencil
            if model.termsAccepted {
                guard startStroke(touch) else { fingerGesture.abandonDrawing(); return }
                drawingWithFinger = true
            } else {
                termsCandidate = id
            }
            armLongPress(at: point) { [weak self] in
                guard let self, fingerGesture.drawing == id else { return nil }
                return fingerPoints[id]
            }
        case .navigate(let ids):
            longPress?.cancel()
            termsCandidate = nil
            if drawingWithFinger { abandonFingerStroke() } // it was the start of a pinch
            for each in ids { if let start = fingerPoints[each] { navigation.begin(id: each, point: start, camera: camera) } }
            if pencilDrawing { navigation.blockUntilTouchesEnd() }
        case .none:
            break
        }
    }

    /// Starts a stroke for a Pencil or a drawing finger; false when drawing is not possible now.
    private func startStroke(_ touch: UITouch) -> Bool {
        // App Review 1.2: the terms are accepted before anything is published.
        guard model.termsAccepted else { model.termsPrompt = true; return false }
        guard model.canDraw,
              !model.isShared || (sharedState?.pendingCount ?? 0) + volatileStrokes.count < 64 else { return false }
        model.userInteracted(camera: camera)
        longPress?.cancel()
        navigation.blockUntilTouchesEnd()
        drawingID = ObjectIdentifier(touch)
        input.begin(at: world(touch), timestamp: touch.timestamp, style: model.style)
        model.strokeStarted(with: model.style.color)
        updatePreview()
        return true
    }

    private func abandonFingerStroke() {
        input.cancel()
        drawingID = nil
        drawingWithFinger = false
        pendingPreview = nil
        renderer?.preview = nil
        requestFrame()
    }

    func moved(_ touches: Set<UITouch>, event: UIEvent?) {
        for touch in touches {
            let finger = fingerIDs[ObjectIdentifier(touch)]
            if let finger {
                let point = screen(touch)
                fingerPoints[finger] = point
                if let origin = longPressOrigin, origin.distance(to: point) > 10 {
                    longPress?.cancel()
                    if termsCandidate == finger { askTerms() } // clearly a stroke: explain why nothing is drawn
                }
            }
            if ObjectIdentifier(touch) == drawingID {
                for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                    input.appendReal(world(sample), timestamp: sample.timestamp)
                }
                input.replacePredictions((event?.predictedTouches(for: touch) ?? []).map(world))
                if !drawingWithFinger { lastPencilPoint = touch.location(in: surface) }
                updatePreview()
            } else if let finger, drawingID == nil,
                      let next = navigation.move(id: finger, point: screen(touch), viewport: viewport) {
                camera = next
                model.userInteracted(camera: camera)
                requestFrame()
            }
        }
    }

    func ended(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        for touch in touches {
            if ObjectIdentifier(touch) == drawingID {
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
                drawingID = nil
                drawingWithFinger = false
                pendingPreview = nil
                renderer?.preview = nil
            }
            if let id = fingerIDs.removeValue(forKey: ObjectIdentifier(touch)) {
                navigation.end(id: id)
                fingerGesture.ended(id: id)
                fingerPoints[id] = nil
                if termsCandidate == id { if !cancelled { askTerms() }; termsCandidate = nil }
            }
            if let start = reportTaps.removeValue(forKey: ObjectIdentifier(touch)), !cancelled, model.reporting,
               start.distance(to: screen(touch)) <= 10, let target = reportTarget(at: screen(touch)) {
                model.toggleReport(target)
                requestFrame()
            }
        }
        longPress?.cancel()
        updateFrameLoop()
        requestFrame()
    }

    private func askTerms() {
        termsCandidate = nil
        fingerGesture.abandonDrawing()
        model.termsPrompt = true
    }

    func cancelGesture() {
        longPress?.cancel()
        input.cancel()
        drawingID = nil
        drawingWithFinger = false
        pendingPreview = nil
        renderer?.preview = nil
        navigation.reset()
        fingerGesture.reset()
        fingerIDs.removeAll()
        fingerPoints.removeAll()
        termsCandidate = nil
        reportTaps.removeAll()
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
        let coordinates = coordinateText(x: camera.center.x, y: camera.center.y)
        if model.centerCoordinates != coordinates { model.centerCoordinates = coordinates }
        frameRequested = true
        resumeDisplayLink()
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
        // Reported strokes and blocked authors are hidden on this device (App Review 1.2).
        let blocked = model.hiddenContent
        let confirmed = (sharedState?.confirmed ?? []).filter { !blocked.hides($0.server.payload.id, author: $0.server.author) }
        recordsByID = Dictionary(confirmed.map { ($0.server.payload.id, $0) }, uniquingKeysWith: { $1 })
        for record in confirmed {
            sequences[record.drawable.id] = record.server.sequence
            if strokeExtents[record.drawable.id] == nil { strokeExtents[record.drawable.id] = record.extent }
        }
        let strokes = confirmed.map(\.drawable) + (sharedState?.pending ?? []) + volatileStrokes
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

    /// Gesture: the display link runs every vsync with one frame of latency. Idle: it wakes for requested
    /// frames only (see `scheduleAfterFrame`).
    private func updateFrameLoop() {
        guard surface != nil else { return }
        let navigating = !navigation.blocked && !navigation.touches.isEmpty
        let running = renderer?.isRenderingEnabled == true && (drawingID != nil || navigating)
        if renderer?.isRenderingEnabled != true { displayLink?.isPaused = true }
        guard running != frameLoopRunning else { return }
        frameLoopRunning = running
        if running { resumeDisplayLink() }
        else { frameRequested = true; resumeDisplayLink() } // final frame; pending tile work continues on demand
    }

    private func resumeDisplayLink() {
        guard renderer?.isRenderingEnabled == true, let surface, surface.window != nil else { return }
        if displayLink == nil, let layer = surface.layer as? CAMetalLayer {
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.preferredFrameLatency = 1
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        delayedFrame?.cancel(); delayedFrame = nil
        displayLink?.isPaused = false
    }

    /// After a frame: keep running for gestures and immediate follow-up work, wake later for zoom settling,
    /// otherwise pause until the next request.
    private func scheduleAfterFrame(rendered: Bool) {
        if !rendered { return } // no in-flight slot: the running link retries next vsync
        if frameLoopRunning || frameRequested { return }
        guard let delay = renderer?.nextFrameDelay else { displayLink?.isPaused = true; return }
        if delay <= 1.0 / 120 { return }
        displayLink?.isPaused = true
        let work = DispatchWorkItem { [weak self] in self?.delayedFrame = nil; self?.requestFrame() }
        delayedFrame = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Opens the palette when `current` (the pressing finger) stays within 10 pt of `point` for 500 ms.
    private func armLongPress(at point: WorldPoint, current: @escaping () -> WorldPoint?) {
        longPress?.cancel()
        longPressOrigin = point
        let initialCamera = camera
        longPress = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled, let now = current(), now.distance(to: point) <= 10 else { return }
            camera = initialCamera
            model.userInteracted(camera: camera)
            showTools(at: CGPoint(x: point.x, y: point.y)) // also abandons a finger stroke (a dot so far)
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
                self?.displayLink?.isPaused = true; self?.frameLoopRunning = false; self?.frameRequested = false
                if self?.model.failure == nil { self?.model.failure = message }
            }
            renderer = next
            surface.delegate = next
        } catch { model.failure = error.localizedDescription }
    }

    /// The topmost stroke of someone else under a tap, for report mode.
    private func reportTarget(at point: WorldPoint) -> ReportTarget? {
        let world = camera.worldPoint(at: point, viewport: viewport)
        let hit = StrokeHitTest.topmost(at: world, slop: 12 / camera.zoom, in: recordsByID.values) { $0.server.own }
        return hit.map { ReportTarget(id: $0.server.payload.id, author: $0.server.author, extent: $0.extent) }
    }

    /// Outlines the strokes selected for a report, in screen space; follows pan and zoom.
    private func updateReportOverlay() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        reportLayer.frame = surface.bounds
        guard model.reporting, !model.reportSelection.isEmpty else { reportLayer.path = nil; return }
        let path = CGMutablePath()
        for target in model.reportSelection {
            let e = target.extent
            let a = camera.screenPoint(at: WorldPoint(x: e.minX, y: e.minY), viewport: viewport)
            let b = camera.screenPoint(at: WorldPoint(x: e.maxX, y: e.maxY), viewport: viewport)
            path.addRect(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: -4, dy: -4))
        }
        reportLayer.path = path
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

/// The link is added to the main run loop; @preconcurrency verifies at runtime that updates arrive there.
extension CanvasViewController: @preconcurrency CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let renderer, let surface, renderer.isRenderingEnabled else { link.isPaused = true; return }
        frameRequested = false
        renderer.camera = camera
        if !model.reportSelection.isEmpty || reportLayer.path != nil { updateReportOverlay() }
        let rendered = renderer.draw(update, viewport: CanvasSize(width: surface.bounds.width, height: surface.bounds.height))
        if !rendered { frameRequested = true }
        scheduleAfterFrame(rendered: rendered)
    }
}

/// Apple Pencil tap (2nd gen / Pro) and squeeze (Pro), following the user's preferred actions (architecture §5).
extension CanvasViewController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        let action = UIPencilInteraction.preferredTapAction
        let command = PencilCommand.resolve(action)
        Signposts.input.notice("pencil tap preferred=\(action.rawValue, privacy: .public) command=\(String(describing: command), privacy: .public) hover=\(tap.hoverPose != nil, privacy: .public)")
        performPencil(command, at: tap.hoverPose?.location)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        let action = UIPencilInteraction.preferredSqueezeAction
        let command = PencilCommand.squeeze(action, phase: squeeze.phase)
        Signposts.input.notice("pencil squeeze phase=\(squeeze.phase.rawValue, privacy: .public) preferred=\(action.rawValue, privacy: .public) command=\(String(describing: command), privacy: .public) hover=\(squeeze.hoverPose != nil, privacy: .public)")
        performPencil(command, at: squeeze.hoverPose?.location)
    }

    func performPencil(_ command: PencilCommand, at hover: CGPoint?) {
        switch command {
        case .none: return
        case .switchPrevious:
            cancelGesture() // a draft never changes style mid-stroke
            model.switchToPreviousBrush()
        case .togglePalette:
            if model.paletteAnchor != nil { model.paletteAnchor = nil; return }
            // Anchor: hover pose → last Pencil contact → centre (clamped on screen by ContentView).
            showTools(at: hover ?? lastPencilPoint)
        }
    }
}
