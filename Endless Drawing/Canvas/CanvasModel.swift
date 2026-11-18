import Observation
import SwiftUI

@MainActor
@Observable
final class CanvasModel {
    enum Command { case undo, resetCamera, retry }

    var style = BrushStyle()
    var paletteAnchor: CGPoint?
    var failure: String?
    var canUndo = false
    var graphicsLimited = false
    private(set) var worldState: WorldRenderState?
    private(set) var storageReady = false
    @ObservationIgnored var command: ((Command) -> Void)?
    @ObservationIgnored var onWorld: ((WorldRenderState) -> Void)?
    @ObservationIgnored var onCamera: ((Camera) -> Void)?
    @ObservationIgnored private let environment: DrawingEnvironment?
    @ObservationIgnored private var world: WorldSession?
    @ObservationIgnored private var cameraStore: CameraStore?
    @ObservationIgnored private var bootstrap: Task<Void, Never>?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private var cameraSave: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var openingFailed = false
    @ObservationIgnored private var activation = UUID()
    @ObservationIgnored private var hasCamera = false
    @ObservationIgnored private var region: CanvasRegion?
    @ObservationIgnored private var lastCamera = Camera()

    /// Nil is explicit local/test mode. The application injects .live, never a runtime fallback.
    init(environment: DrawingEnvironment? = nil, session: WorldSession? = nil) {
        self.environment = environment; world = session; storageReady = session != nil
    }
    deinit {
        bootstrap?.cancel(); updates?.cancel(); cameraSave?.cancel()
        let session = world
        Task { await session?.stop() }
    }

    var isShared: Bool { environment != nil }
    var canDraw: Bool {
        !isShared || (storageReady && !graphicsLimited && worldState?.status != .blocked && worldState?.status != .dense
                      && worldState?.issue != .storage && (worldState?.pendingCount ?? 0) < 64)
    }
    var statusText: String {
        guard isShared else { return String(localized: "Local prototype — drawings are not saved or shared.") }
        guard storageReady else {
            return openingFailed ? String(localized: "Local storage is unavailable. Retry to open it.")
                : String(localized: "Opening local drawing storage…")
        }
        if graphicsLimited { return String(localized: "This area is too dense. Zoom in to continue.") }
        if worldState?.issue == .storage {
            return String(localized: "Local storage failed — unsaved drafts are only in memory. Retry before closing the app.")
        }
        switch worldState?.status {
        case .live: return String(localized: "Shared canvas")
        case .loading: return String(localized: "Loading shared canvas…")
        case .blocked: return String(localized: "Connection paused. Open tools to retry.")
        case .dense: return String(localized: "This area is too dense. Zoom in to continue.")
        case .offline, .stopped: return String(localized: "Offline — pending drawings remain on this iPad.")
        default: return String(localized: "Connecting to shared canvas…")
        }
    }

    func activate() {
        guard isShared, !active else { return }
        active = true; activation = UUID()
        if let world { start(world); return }
        openingFailed = false
        let token = activation
        bootstrap = Task { [weak self] in
            guard let self, let environment else { return }
            defer { if activation == token { bootstrap = nil } }
            do {
                let identity = try await IdentityStore(environment: environment).loadOrCreate()
                try Task.checkCancellation()
                let storage = try JournalFileStorage.applicationSupport(environment: environment)
                let journal = try await OperationJournal.open(environment: environment, identityID: identity.id, storage: storage)
                let initial = await journal.snapshot()
                let cameraStore = CameraStore(storage: JournalFileStorage(url: storage.url.deletingLastPathComponent().appendingPathComponent("camera.json")))
                let restored = try? await cameraStore.load()
                guard token == activation, active, !Task.isCancelled else { return }
                self.cameraStore = cameraStore
                if let restored, !hasCamera { hasCamera = true; lastCamera = restored; onCamera?(restored) }
                let session = WorldSession(transport: WebSocketTransport(environment: environment), identity: identity,
                                           journal: journal, initial: initial, onSpawn: { [weak self] point in
                    await self?.spawn(point)
                })
                world = session; storageReady = true
                start(session)
            } catch {
                guard token == activation else { return }
                storageReady = false; openingFailed = true
                failure = String(localized: "Drawing storage could not be opened. Your existing identity and pending drawings have not been replaced.")
            }
        }
    }

    private func start(_ world: WorldSession) {
        let previous = lifecycle, token = activation
        lifecycle = Task { [weak self] in
            await previous?.value
            guard let self, active, token == activation else { return }
            let stream = await world.states()
            if let region { await world.update(region: region) }
            await world.start()
            guard active, token == activation else { return }
            updates?.cancel()
            updates = Task { [weak self] in
                for await state in stream {
                    guard !Task.isCancelled, let self, active, token == activation else { return }
                    accept(state)
                }
            }
        }
    }

    func deactivate() {
        guard isShared else { return }
        active = false; activation = UUID()
        bootstrap?.cancel(); bootstrap = nil; updates?.cancel(); updates = nil
        if let world {
            let previous = lifecycle
            lifecycle = Task { await previous?.value; await world.stop() }
        }
        if let cameraStore, hasCamera {
            let camera = lastCamera
            cameraSave?.cancel(); cameraSave = Task { try? await cameraStore.save(camera) }
        }
    }

    func retryConnection() { guard isShared else { return }; deactivate(); activate() }

    func viewportChanged(camera: Camera, viewport: CanvasSize) async {
        guard isShared, let next = try? CanvasRegion(camera: camera, viewport: viewport) else { return }
        lastCamera = camera; region = next
        await world?.update(region: next)
    }

    func userInteracted(camera: Camera) {
        hasCamera = true; lastCamera = camera
        guard let cameraStore else { return }
        cameraSave?.cancel()
        cameraSave = Task {
            do { try await Task.sleep(for: .milliseconds(300)); try await cameraStore.save(camera) } catch { /* view preference, not journal */ }
        }
    }

    private func spawn(_ point: WorldPoint) {
        guard !hasCamera else { return }
        hasCamera = true
        var camera = Camera(); camera.pan(screenDelta: WorldPoint(x: -point.x, y: -point.y))
        lastCamera = camera; onCamera?(camera)
    }

    func persist(_ stroke: LocalStroke) async throws {
        if world == nil { await bootstrap?.value }
        guard let world else { throw DrawingDataError.invalidTransition }
        accept(try await world.enqueue(stroke))
    }

    func undoShared() async throws {
        if world == nil { await bootstrap?.value }
        guard let world else { throw DrawingDataError.invalidTransition }
        accept(try await world.undo())
    }

    private func accept(_ value: WorldRenderState) {
        guard value.revision > (worldState?.revision ?? 0) else { return }
        let priorIssue = worldState?.issue
        worldState = value; canUndo = value.canUndo
        onWorld?(value)
        if value.issue == .rejected, priorIssue != .rejected {
            failure = String(localized: "The server rejected a drawing operation. It was not saved as a new stroke.")
        }
    }
}
