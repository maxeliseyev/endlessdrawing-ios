import Observation
import SwiftUI
import UIKit

/// The active tool: draw with the selected brush, move the canvas, or erase own strokes (web parity M6.2).
nonisolated enum CanvasTool: String, CaseIterable, Codable, Sendable {
    case brush, hand, eraser
}

@MainActor
@Observable
final class CanvasModel {
    enum Command { case undo, resetCamera, retry }

    var style = BrushStyle() {
        didSet { if oldValue.brush != style.brush { previousBrush = oldValue.brush } }
    }
    /// For the Pencil "switch to previous tool" preference: the brush shape used before the current one.
    @ObservationIgnored private(set) var previousBrush: BrushKind?
    var paletteAnchor: CGPoint?
    /// Custom colors used for strokes, shown under the presets; persisted only in the live app.
    private(set) var recentColors: RecentColors
    @ObservationIgnored private let defaults: UserDefaults?
    private static let recentColorsKey = "recentColors"
    private static let hiddenStrokesKey = "hiddenStrokes", hiddenAuthorsKey = "hiddenAuthors"
    private static let termsKey = "acceptedTerms"
    private static let fingerDrawingKey = "fingerDrawing", pencilSeenKey = "pencilSeen"
    private static let toolKey = "tool"
    /// Bump when /terms changes materially: everyone is asked again before drawing.
    static let termsVersion = "terms.v1"
    static let termsURL = URL(string: "https://endlessdrawing.com/terms")!
    static let supportURL = URL(string: "mailto:support@endlessdrawing.com")!

    // MARK: App Review 1.2: terms, reports, local hiding
    /// Reported strokes and blocked authors, hidden on this device only.
    private(set) var hiddenContent: HiddenContent
    @ObservationIgnored var onHiddenChanged: (() -> Void)?
    /// The live app asks once per terms version before the first stroke.
    private(set) var termsAccepted: Bool
    var termsPrompt = false
    /// Report mode: taps select strokes instead of drawing.
    var reporting = false { didSet { if !reporting { reportSelection = []; reportSheet = false } } }
    var reportSelection: [ReportTarget] = [] { didSet { onReportChanged?() } }
    @ObservationIgnored var onReportChanged: (() -> Void)?
    var reportSheet = false
    /// Short, self-dismissing confirmation (e.g. after a report).
    var notice: String?
    var failure: String?
    /// Explicit "Draw with finger" choice from the menu; nil is automatic (see `FingerDrawingPolicy`).
    private(set) var fingerChoice: Bool?
    private(set) var pencilSeen: Bool
    var fingersDraw: Bool {
        FingerDrawingPolicy.fingersDraw(choice: fingerChoice, pencilSeen: pencilSeen,
                                        systemPencilOnly: UIPencilInteraction.prefersPencilOnlyDrawing)
    }
    var canUndo = false
    var graphicsLimited = false
    /// Active tool; persisted only in the live app, never forced back to brush on launch.
    var tool = CanvasTool.brush { didSet { defaults?.set(tool.rawValue, forKey: Self.toolKey) } }
    /// Rounded world centre shown bottom-left (web parity M6.1); updated only when the rounded value changes.
    var centerCoordinates = "x: 0  y: 0"
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
    init(environment: DrawingEnvironment? = nil, session: WorldSession? = nil, defaults: UserDefaults? = nil) {
        self.environment = environment; world = session; storageReady = session != nil
        self.defaults = defaults
        recentColors = RecentColors(hexes: defaults?.stringArray(forKey: Self.recentColorsKey) ?? [])
        hiddenContent = HiddenContent(storedStrokes: defaults?.stringArray(forKey: Self.hiddenStrokesKey) ?? [],
                                      storedAuthors: defaults?.stringArray(forKey: Self.hiddenAuthorsKey) ?? [])
        // Only the live app (with persistent defaults) asks; tests and previews never block drawing.
        termsAccepted = defaults == nil || defaults?.string(forKey: Self.termsKey) == Self.termsVersion
        fingerChoice = defaults?.object(forKey: Self.fingerDrawingKey) as? Bool
        pencilSeen = defaults?.bool(forKey: Self.pencilSeenKey) ?? false
        if let stored = defaults?.string(forKey: Self.toolKey), let value = CanvasTool(rawValue: stored) { tool = value }
    }

    func setFingerDrawing(_ on: Bool) {
        fingerChoice = on
        defaults?.set(on, forKey: Self.fingerDrawingKey)
    }

    /// The first Pencil touch: in automatic mode fingers stop drawing and only move the canvas.
    func pencilUsed() {
        guard !pencilSeen else { return }
        let drew = fingersDraw
        pencilSeen = true
        defaults?.set(true, forKey: Self.pencilSeenKey)
        if drew, !fingersDraw { notice = String(localized: "Apple Pencil draws now; fingers move the canvas.") }
    }

    func acceptTerms() {
        termsAccepted = true; termsPrompt = false
        defaults?.set(Self.termsVersion, forKey: Self.termsKey)
    }

    func startReporting() {
        paletteAnchor = nil; reportSelection = []; reporting = true
    }

    /// Adds or removes a stroke from the report selection (at most 20, like the protocol).
    func toggleReport(_ target: ReportTarget) {
        if let index = reportSelection.firstIndex(where: { $0.id == target.id }) { reportSelection.remove(at: index) }
        else if reportSelection.count < ClientMessage.maximumReportStrokes { reportSelection.append(target) }
    }

    /// Hides the selection (and its authors when blocking) right away, then informs moderation.
    func submitReport(reason: ReportReason, blockAuthor: Bool) {
        let targets = reportSelection
        guard !targets.isEmpty else { return }
        reporting = false
        hide(strokes: targets.map(\.id), authors: blockAuthor ? targets.compactMap(\.author) : [])
        notice = String(localized: "Thanks. Hidden for you — we review reports within 24 hours.")
        let world = world
        Task { await world?.report(strokeIDs: targets.map(\.id), reason: reason, blockAuthor: blockAuthor) }
    }

    func showHiddenContent() { hiddenContent = HiddenContent(); persistHidden() }

    private func hide(strokes: [UUID], authors: [String]) {
        hiddenContent.hide(strokes: strokes, authors: authors)
        persistHidden()
    }

    private func persistHidden() {
        defaults?.set(hiddenContent.storedStrokes, forKey: Self.hiddenStrokesKey)
        defaults?.set(hiddenContent.authors, forKey: Self.hiddenAuthorsKey)
        onHiddenChanged?()
    }

    /// Called when a stroke starts: remembers the custom color it was drawn with.
    func strokeStarted(with color: InkColor) {
        guard recentColors.use(color) else { return }
        defaults?.set(recentColors.hexes, forKey: Self.recentColorsKey)
    }
    deinit {
        bootstrap?.cancel(); updates?.cancel(); cameraSave?.cancel()
        let session = world
        Task { await session?.stop() }
    }

    var isShared: Bool { environment != nil }

    func switchToPreviousBrush() {
        guard let previousBrush else { return }
        style.brush = previousBrush // didSet records the current shape as the next "previous"
    }

    /// The Pencil squeeze / double-tap action: toggle the brush and the eraser.
    func switchEraser() { tool = tool == .eraser ? .brush : .eraser }
    var canDraw: Bool {
        !isShared || (storageReady && !graphicsLimited && worldState?.status != .blocked && worldState?.status != .dense
                      && worldState?.issue != .storage && worldState?.issue != .banned && (worldState?.pendingCount ?? 0) < 64)
    }
    var statusText: String {
        guard isShared else { return String(localized: "Local prototype — drawings are not saved or shared.") }
        guard storageReady else {
            return openingFailed ? String(localized: "Local storage is unavailable. Retry to open it.")
                : String(localized: "Opening local drawing storage…")
        }
        if graphicsLimited { return String(localized: "This area is too dense. Zoom in to continue.") }
        if worldState?.issue == .banned {
            return String(localized: "Drawing is no longer available for this device because of a moderation decision.")
        }
        if worldState?.issue == .storage {
            return String(localized: "Local storage failed — unsaved drafts are only in memory. Retry before closing the app.")
        }
        switch worldState?.status {
        case .live: return String(localized: "Shared canvas")
        case .loading: return String(localized: "Loading shared canvas…")
        case .blocked: return String(localized: "Connection paused. Open tools to retry.")
        case .dense: return String(localized: "This area is too dense. Zoom in to continue.")
        case .offline, .stopped: return String(localized: "Offline — pending drawings remain on this device.")
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

    /// Eraser: hides the stroke optimistically and cancels a pending create or queues a server delete.
    func erase(strokeID: UUID) async throws {
        if world == nil { await bootstrap?.value }
        guard let world else { throw DrawingDataError.invalidTransition }
        accept(try await world.delete(strokeID: strokeID))
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
