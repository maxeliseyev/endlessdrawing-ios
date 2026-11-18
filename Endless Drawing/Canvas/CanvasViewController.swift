import MetalKit
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
    private var gpuStrokes: [UUID: MetalRenderer.GPUStroke] = [:]
    private var finalTasks: [UUID: Task<Void, Never>] = [:]
    private var previewTask: Task<Void, Never>?
    private var pendingPreview: LocalStroke?
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
                self?.cancelGesture()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderer?.isRenderingEnabled = true
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
        requestFrame()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        renderer?.isRenderingEnabled = false
        cancelGesture()
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
            guard pencilID == nil else { continue }
            longPress?.cancel()
            navigation.blockUntilTouchesEnd()
            pencilID = ObjectIdentifier(touch)
            input.begin(at: world(touch), timestamp: touch.timestamp, style: model.style)
            updatePreview()
        }
        for touch in touches where touch.type == .direct {
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
        pendingPreview = input.preview
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            while let next = pendingPreview {
                pendingPreview = nil
                let prepared = await worker.prepare(next)
                guard input.id == next.id, let prepared else { continue }
                do { renderer?.preview = try renderer?.upload(prepared) }
                catch { model.failure = error.localizedDescription }
                requestFrame()
            }
            previewTask = nil
        }
    }

    private func complete(_ stroke: LocalStroke) {
        // Bounded debug document, not a disk-backed or server-confirmed world.
        guard localStrokes.count < 256,
              localStrokes.reduce(0, { $0 + $1.points.count }) + stroke.points.count <= 100_000 else {
            model.failure = String(localized: "The local prototype is full. Undo a stroke to continue.")
            return
        }
        localStrokes.append(stroke)
        model.canUndo = true
        finalTasks[stroke.id] = Task { [weak self, worker] in
            let prepared = await worker.prepare(stroke)
            guard let self, !Task.isCancelled, localStrokes.contains(where: { $0.id == stroke.id }), let prepared else { return }
            defer { finalTasks[stroke.id] = nil }
            do {
                gpuStrokes[stroke.id] = try renderer?.upload(prepared)
                synchronizeStrokes()
            } catch { model.failure = error.localizedDescription }
        }
    }

    private func synchronizeStrokes() {
        renderer?.strokes = localStrokes.compactMap { gpuStrokes[$0.id] }
        requestFrame()
    }

    private func requestFrame() {
        renderer?.camera = camera
        surface?.setNeedsDisplay()
    }

    private func updateFrameLoop() {
        let navigating = !navigation.blocked && !navigation.touches.isEmpty
        surface?.isPaused = renderer?.isRenderingEnabled != true || (pencilID == nil && !navigating)
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
            guard let stroke = localStrokes.popLast() else { return }
            finalTasks.removeValue(forKey: stroke.id)?.cancel()
            gpuStrokes[stroke.id] = nil
            model.canUndo = !localStrokes.isEmpty
            synchronizeStrokes()
        case .resetCamera:
            camera = Camera()
            requestFrame()
        case .retry:
            if renderer == nil { configureRenderer() }
            renderer?.releaseTargets()
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
