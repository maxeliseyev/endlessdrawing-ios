import Foundation
import os

protocol CanvasTransport: Actor {
    func connect() async throws -> WebSocketTransport.Connection
    func send(_ message: ClientMessage) async throws
    func ping() async throws
    func disconnect() async
}
extension WebSocketTransport: CanvasTransport {}

nonisolated enum WorldStatus: Sendable, Equatable { case connecting, loading, live, offline, stopped, blocked, dense }
/// `banned`: a moderator banned this drawing identity; creates and reports are refused.
nonisolated enum WorldIssue: Sendable, Equatable { case storage, protocolMismatch, rejected, dense, banned }
nonisolated struct WorldRenderState: Sendable {
    let revision: UInt64
    let status: WorldStatus
    let issue: WorldIssue?
    let confirmed: [SceneStroke]
    let pending: [LocalStroke]
    let hidden: Set<UUID>
    let pendingCount: Int
    let canUndo: Bool
}

nonisolated struct WorldTiming: Sendable {
    var hello = 8.0
    var snapshot = 35.0
    var acknowledgement = 12.0
    var ping = 20.0
}

/// Owns protocol FSM, scene and semantic outbox. No UIKit/Metal objects cross this actor.
actor WorldSession {
    private struct Attempt {
        let requestID: String
        let operation: JournalOperation
        let deadline: TimeInterval
    }
    private let transport: any CanvasTransport
    private let identity: DrawingIdentity
    private let journal: OperationJournal
    private let timing: WorldTiming
    private var journalState: JournalSnapshot
    private var journalRevision: UInt64 = 0
    private var scene = SceneStore()
    private var region: CanvasRegion?
    private var epoch = UUID()
    private var running = false
    private var networkTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var output: AsyncStream<WorldRenderState>.Continuation?
    private var revision: UInt64 = 0
    private var status = WorldStatus.stopped
    private var issue: WorldIssue?
    private var connectionID: UUID?
    private var helloDeadline: TimeInterval?
    private var snapshotDeadline: TimeInterval?
    private var snapshotTimeouts = 0
    private var attempt: Attempt?
    private var pacer = RequestPacer()
    private var lastPing = 0.0
    private var retryAfter = 0.0
    private var reconnectRequested = false
    private var suspendedForRegion: WireBounds?
    private var blocked = false
    /// Negotiated per connection; v3+ allows cached subscriptions, v4 requires the visible hint.
    private var profile = TransportProfile.messagePackV2
    /// A completed snapshot on this connection lets the next subscription reuse its records (v3+).
    private var reusable = false
    private var manifest = ManifestLoader()
    /// Fetch denied by the pacer; sent from tick before anything else.
    private var pendingFetch: ManifestLoader.FetchRequest?
    /// Fallback asks for a full subscription after a short pause, without reconnecting.
    private var resubscribeAt: TimeInterval?
    private var snapshotInterval: OSSignpostIntervalState?
    private var lastPublish = 0.0
    private var publishFlush: Task<Void, Never>?
    private var snapshotChunks = 0
    private let onSpawn: @Sendable (WorldPoint) async -> Void
    /// v5 reports waiting to be sent, oldest first. In memory only: the local hide is what persists.
    private struct Report { let requestID: String; let strokeIDs: [UUID]; let reason: ReportReason; let blockAuthor: Bool }
    private var reports: [Report] = []
    private var reportInFlight: (requestID: String, deadline: TimeInterval)?
    static let maximumQueuedReports = 20

    init(transport: any CanvasTransport, identity: DrawingIdentity, journal: OperationJournal,
         initial: JournalSnapshot, timing: WorldTiming = WorldTiming(), onSpawn: @escaping @Sendable (WorldPoint) async -> Void = { _ in }) {
        self.transport = transport; self.identity = identity; self.journal = journal
        journalState = initial; self.timing = timing; self.onSpawn = onSpawn
    }

    func snapshot() -> WorldRenderState { state() }

    func states() -> AsyncStream<WorldRenderState> {
        output?.finish()
        let (stream, continuation) = AsyncStream<WorldRenderState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        output = continuation; continuation.yield(state())
        return stream
    }

    func start() {
        guard !running else { return }
        running = true; epoch = UUID(); blocked = false; suspendedForRegion = nil; snapshotTimeouts = 0; issue = nil
        let token = epoch
        networkTask = Task { [weak self] in await self?.run(token: token) }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                await self?.tick(token: token)
            }
        }
    }

    func stop() async {
        running = false; epoch = UUID(); connectionID = nil; attempt = nil
        helloDeadline = nil; snapshotDeadline = nil
        networkTask?.cancel(); networkTask = nil; ticker?.cancel(); ticker = nil
        let stopToken = epoch
        await transport.disconnect()
        guard stopToken == epoch else { return }
        status = .stopped; publish()
    }

    func retry() async {
        await stop(); issue = nil; start()
    }

    /// Queues a report for the server (sent on a v5 connection, one at a time). The caller hides the
    /// strokes locally right away; this only informs moderation. False when the queue is full.
    @discardableResult
    func report(strokeIDs: [UUID], reason: ReportReason, blockAuthor: Bool) -> Bool {
        let ids = Array(NSOrderedSet(array: strokeIDs).compactMap { $0 as? UUID }.prefix(ClientMessage.maximumReportStrokes))
        guard !ids.isEmpty, reports.count < Self.maximumQueuedReports else { return false }
        reports.append(Report(requestID: UUID().uuidString.lowercased(), strokeIDs: ids, reason: reason, blockAuthor: blockAuthor))
        return true
    }

    var queuedReports: Int { reports.count }

    /// Pan/zoom only steer subscriptions; the published scene does not depend on the viewport.
    func update(region: CanvasRegion) {
        self.region = region
        if let suspendedForRegion, suspendedForRegion != region.subscription {
            self.suspendedForRegion = nil; snapshotTimeouts = 0; issue = nil
            publish()
        }
    }

    func enqueue(_ stroke: LocalStroke) async throws -> WorldRenderState {
        do {
            try await journal.enqueueCreate(StrokePayload(localStroke: stroke))
            await refreshJournal()
            return publish()
        } catch { issue = .storage; _ = publish(); throw error }
    }

    func undo() async throws -> WorldRenderState {
        do {
            try await journal.undoNewest()
            await refreshJournal()
            return publish()
        } catch { issue = .storage; _ = publish(); throw error }
    }

    /// Erases one own stroke: cancels an unconfirmed create or queues an idempotent delete. The stroke is
    /// hidden optimistically; a server rejection restores it (the journal keeps its undo entry).
    func delete(strokeID: UUID) async throws -> WorldRenderState {
        do {
            try await journal.requestDelete(strokeID: strokeID)
            await refreshJournal()
            return publish()
        } catch { issue = .storage; _ = publish(); throw error }
    }

    private func refreshJournal() async {
        let snapshot = await journal.versionedSnapshot()
        if snapshot.revision >= journalRevision { journalRevision = snapshot.revision; journalState = snapshot.state }
    }

    @discardableResult private func publish() -> WorldRenderState {
        revision &+= 1
        publishFlush?.cancel(); publishFlush = nil
        lastPublish = ProcessInfo.processInfo.systemUptime
        let value = state(); output?.yield(value); return value
    }

    /// Bursts of network messages publish at most about once per display frame; the last one always lands.
    private func publishSoon() {
        let wait = lastPublish + 1.0 / 60 - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else { publish(); return }
        guard publishFlush == nil else { return }
        publishFlush = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            await self?.flushPublish()
        }
    }

    private func flushPublish() { if publishFlush != nil { publishFlush = nil; publish() } }

    private func state() -> WorldRenderState {
        let hidden = Set(journalState.operations.compactMap { operation -> UUID? in
            switch operation.payload {
            case .create(let payload): operation.cancelled ? payload.id : nil
            case .delete(let id): id
            }
        })
        let records = scene.ordered(hidden: hidden)
        let confirmedIDs = Set(records.map { $0.server.payload.id })
        let pending = journalState.operations.sorted { $0.ordinal < $1.ordinal }.compactMap { operation -> LocalStroke? in
            guard case .create(let payload) = operation.payload, !operation.cancelled,
                  !confirmedIDs.contains(payload.id) else { return nil }
            return payload.drawable
        }
        let canUndo = journalState.operations.contains { if case .create = $0.payload { return !$0.cancelled }; return false }
            || journalState.undo.contains { !hidden.contains($0.strokeID) }
        return WorldRenderState(revision: revision, status: status, issue: issue, confirmed: records, pending: pending,
                                hidden: hidden, pendingCount: journalState.operations.count, canUndo: canUndo)
    }

    private func run(token: UUID) async {
        var failures = 0
        while running, token == epoch, !Task.isCancelled {
            if blocked || suspendedForRegion != nil {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                continue
            }
            status = .connecting; publish()
            reconnectRequested = false
            do {
                let connection = try await transport.connect()
                guard running, token == epoch else { return }
                connectionID = connection.id; pacer = RequestPacer(); attempt = nil; reportInFlight = nil
                profile = connection.profile; reusable = false; manifest = ManifestLoader(); pendingFetch = nil; resubscribeAt = nil
                let now = ProcessInfo.processInfo.systemUptime
                helloDeadline = now + timing.hello; lastPing = now
                _ = pacer.admit(.hello, now: now)
                try await transport.send(.hello(identity.secret))
                for try await message in connection.messages {
                    guard running, token == epoch, connectionID == connection.id else { return }
                    try await receive(message, token: token)
                }
            } catch let failure as SceneFailure {
                if token == epoch {
                    if failure == .capacity { status = .dense; issue = .dense; suspendedForRegion = region?.subscription }
                    else { blocked = true; status = .blocked; issue = .protocolMismatch }
                }
            } catch let failure as TransportFailure {
                if token == epoch, [.unexpectedProfile, .incompatibleVersion, .wrongMessageType, .malformedMessage, .messageTooLarge].contains(failure) {
                    blocked = true; status = .blocked; issue = .protocolMismatch
                }
            } catch is CancellationError {
                if token != epoch || !running { return }
            } catch {
                if token == epoch { blocked = true; status = .blocked; issue = .storage }
            }
            guard running, token == epoch else { return }
            connectionID = nil; attempt = nil; helloDeadline = nil; snapshotDeadline = nil
            await transport.disconnect()
            if status == .live { failures = 0 }
            if !blocked && suspendedForRegion == nil { status = .offline }
            publish()
            failures = min(failures + 1, 6)
            let delay = min(10, 0.5 * pow(2, Double(failures - 1))) * Double.random(in: 0.85...1.15)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    private func tick(token: UUID) async {
        guard running, token == epoch, connectionID != nil, !reconnectRequested else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let helloDeadline {
            if now >= helloDeadline { await reconnect() }
            return
        }
        if let snapshotDeadline, now >= snapshotDeadline {
            snapshotTimeouts += 1
            if snapshotTimeouts >= 3 {
                suspendedForRegion = region?.subscription; status = .dense; issue = .dense; publish()
            }
            await reconnect(); return
        }
        if let attempt, now >= attempt.deadline { await reconnect(); return }
        do {
            if let request = pendingFetch {
                guard pacer.admit(.fetch, now: now) else { return }
                pendingFetch = nil
                try await transport.send(request.message)
                return
            }
            let fallbackDue = resubscribeAt.map { now >= $0 } ?? false
            if let region, resubscribeAt == nil || fallbackDue,
               fallbackDue || scene.subscriptionID == nil || scene.bounds?.contains(region.visible) != true,
               pacer.admit(.subscribe, now: now) {
                let id = UUID().uuidString.lowercased()
                let cached = profile.supportsManifest && reusable
                // v4 hint: the visible window clipped to the subscription (and thereby to the world).
                let visible = profile.requiresVisibleBounds ? (region.visible.intersection(region.subscription) ?? region.subscription) : nil
                resubscribeAt = nil
                manifest.start(subscriptionID: id, cached: cached)
                scene.subscribe(id: id, bounds: region.subscription, unordered: profile.supportsManifest)
                if let snapshotInterval { Signposts.snapshot.endInterval("subscription", snapshotInterval, "superseded") }
                snapshotInterval = Signposts.snapshot.beginInterval("subscription", "\(cached ? "cached" : "full", privacy: .public)")
                snapshotChunks = 0
                snapshotDeadline = now + timing.snapshot; status = .loading; publish()
                try await transport.send(cached ? .subscribeCached(id: id, bounds: region.subscription, visible: visible)
                                                : .subscribe(id: id, bounds: region.subscription, visible: visible))
                return
            }
            if now - lastPing >= timing.ping, pacer.admit(.ping, now: now) {
                lastPing = now
                try await transport.ping()
                return
            }
            if let inFlight = reportInFlight, now >= inFlight.deadline { reportInFlight = nil } // resent below
            if status == .live, profile.supportsReports, reportInFlight == nil, now >= retryAfter,
               let report = reports.first, pacer.admit(.report, now: now) {
                reportInFlight = (report.requestID, now + timing.acknowledgement)
                try await transport.send(.report(requestID: report.requestID, strokeIDs: report.strokeIDs,
                                                 reason: report.reason, blockAuthor: report.blockAuthor))
                return
            }
            guard status == .live, attempt == nil, now >= retryAfter,
                  let operation = journalState.operations.min(by: { $0.ordinal < $1.ordinal }) else { return }
            let kind: RequestPacer.Kind
            switch operation.payload { case .create: kind = .create; case .delete: kind = .delete }
            guard pacer.admit(kind, now: now) else { return }
            let marked: JournalOperation
            do { marked = try await journal.markMayHaveBeenSent(operation.id) }
            catch DrawingDataError.invalidTransition { await refreshJournal(); return } // undo won before send
            catch {
                guard token == epoch else { return }
                blocked = true; status = .blocked; issue = .storage; publish()
                await reconnect(); return
            }
            guard running, token == epoch, connectionID != nil, !reconnectRequested else { return }
            await refreshJournal()
            guard running, token == epoch, connectionID != nil, !reconnectRequested else { return }
            let requestID = UUID().uuidString.lowercased()
            attempt = Attempt(requestID: requestID, operation: marked, deadline: now + timing.acknowledgement)
            try await transport.send(marked.message(requestID: requestID))
        } catch {
            guard running, token == epoch else { return }
            await reconnect()
        }
    }

    /// Manifest contract violations mean this connection's cache can no longer be trusted:
    /// drop the right to cached subscriptions and resync with a fresh connection (full snapshot).
    private func manifestStep(_ body: () throws -> Void) throws {
        do { try body() }
        catch ManifestLoader.Failure.resync {
            reusable = false; manifest = ManifestLoader(); pendingFetch = nil
            throw TransportFailure.network
        }
    }

    private func sendFetch(_ request: ManifestLoader.FetchRequest) async throws {
        Signposts.snapshot.emitEvent("fetch", "batch \(request.batch) ids \(request.strokeIDs.count)")
        guard pacer.admit(.fetch, now: ProcessInfo.processInfo.systemUptime) else { pendingFetch = request; return }
        try await transport.send(request.message)
    }

    private func reconnect() async {
        reconnectRequested = true
        await transport.disconnect()
    }

    private func receive(_ message: ServerMessage, token: UUID) async throws {
        if helloDeadline != nil {
            guard case .hello = message else { throw TransportFailure.malformedMessage }
        }
        switch message {
        case .hello(let spawn):
            guard helloDeadline != nil else { throw TransportFailure.malformedMessage }
            helloDeadline = nil; status = .loading
            // Fresh scope even for identical bounds; keep only bounded stale display until end.
            scene.reconnect()
            if let spawn { await onSpawn(spawn) }
        case .snapshotBegin(let id):
            guard helloDeadline == nil else { throw TransportFailure.malformedMessage }
            try scene.begin(id: id)
        case .snapshotChunk(let id, let strokes):
            if manifest.owns(id) { try manifestStep { try manifest.geometry(id: id, strokes: strokes) } }
            try scene.chunk(id: id, strokes: strokes)
            if id == scene.subscriptionID {
                snapshotChunks += 1
                Signposts.snapshot.emitEvent("chunk", "\(self.snapshotChunks) #\(strokes.count)")
            }
        case .snapshotEnd(let id):
            let current = id == scene.subscriptionID
            if manifest.owns(id) { try manifestStep { try manifest.snapshotEnd(id: id) } }
            try scene.end(id: id)
            if current {
                snapshotDeadline = nil; snapshotTimeouts = 0; status = .live
                reusable = profile.supportsManifest
                if let snapshotInterval { Signposts.snapshot.endInterval("subscription", snapshotInterval, "\(self.snapshotChunks) chunks") }
                snapshotInterval = nil
            }
        case .manifestBegin(let id, let snapshotToken, let strokeCount, let pointCount):
            try manifestStep { try manifest.begin(id: id, token: snapshotToken, strokeCount: strokeCount, pointCount: pointCount) }
        case .manifestChunk(let id, let snapshotToken, let strokeIDs):
            try manifestStep { try manifest.chunk(id: id, token: snapshotToken, strokeIDs: strokeIDs) }
        case .manifestEnd(let id, let snapshotToken):
            let scene = self.scene
            var result: (retained: [SceneStroke], request: ManifestLoader.FetchRequest)?
            try manifestStep { result = try manifest.end(id: id, token: snapshotToken, cached: { scene.cached($0) }) }
            if let result {
                try self.scene.retain(id: id, records: result.retained)
                let counts = manifest.counts
                Signposts.snapshot.emitEvent("manifest", "\(counts.members) members \(counts.missing) missing")
                try await sendFetch(result.request)
            }
        case .fetchEnd(let id, let snapshotToken, let batch):
            var request: ManifestLoader.FetchRequest?
            try manifestStep { request = try manifest.fetchEnd(id: id, token: snapshotToken, batch: batch) }
            if let request { try await sendFetch(request) }
        case .snapshotFallback(let id, let reason):
            guard id == scene.subscriptionID else { return }
            // busy / scene_limit: no partial manifest was sent; load a full snapshot shortly, same socket.
            reusable = false; manifest = ManifestLoader(); pendingFetch = nil
            snapshotDeadline = nil
            resubscribeAt = ProcessInfo.processInfo.systemUptime + 1
            if reason == .sceneLimit { issue = .dense }
            Signposts.snapshot.emitEvent("fallback", "\(reason.rawValue, privacy: .public)")
        case .created(let id, let stroke): try scene.created(id: id, stroke: stroke)
        case .deleted(let id, let strokeID, let sequence): try scene.deleted(id: id, strokeID: strokeID, sequence: sequence)
        case .createAcknowledged(let requestID, let stroke):
            guard let active = attempt, active.requestID == requestID else { return }
            guard case .create(let payload) = active.operation.payload, payload.matchesAcknowledgement(stroke.payload, compact: profile.protocolVersion >= 6), stroke.own else {
                throw TransportFailure.malformedMessage
            }
            // Canonical commit is known before awaiting durable resolution; an overlapping UI command
            // must never observe neither the pending draft nor its confirmed geometry.
            try scene.acknowledged(stroke)
            try await journal.acknowledgeCreate(operationID: active.operation.id, stroke: stroke, compact: profile.protocolVersion >= 6)
            guard token == epoch else { return }
            if attempt?.requestID == requestID { attempt = nil }
            issue = nil
            await refreshJournal()
        case .deleteAcknowledged(let requestID, let strokeID, let sequence, _):
            guard let active = attempt, active.requestID == requestID else { return }
            guard active.operation.payload == .delete(strokeID) else { throw TransportFailure.malformedMessage }
            try scene.remove(strokeID, sequence: sequence)
            try await journal.acknowledgeDelete(operationID: active.operation.id, strokeID: strokeID)
            guard token == epoch else { return }
            if attempt?.requestID == requestID { attempt = nil }
            issue = nil
            await refreshJournal()
        case .reportAcknowledged(let requestID, _):
            guard reportInFlight?.requestID == requestID else { return }
            reportInFlight = nil
            reports.removeAll { $0.requestID == requestID }
        case .error(let requestID, _, let code) where requestID != nil && requestID == reportInFlight?.requestID:
            reportInFlight = nil
            if ["rate_limited", "internal_error"].contains(code) {
                retryAfter = ProcessInfo.processInfo.systemUptime + 1.5
            } else {
                // Gone, own, invalid or banned: nothing to retry; the local hide already happened.
                reports.removeAll { $0.requestID == requestID }
                if code == "banned" { issue = .banned }
            }
        case .error(let requestID, let subscriptionID, let code):
            if let subscriptionID, subscriptionID != scene.subscriptionID { return }
            if let requestID {
                guard let active = attempt, active.requestID == requestID else { return }
                if ["rate_limited", "internal_error"].contains(code) {
                    retryAfter = ProcessInfo.processInfo.systemUptime + 1.5
                } else if ["id_conflict", "validation_failed", "invalid_message", "message_too_large", "forbidden", "stroke_deleted", "not_found", "banned"].contains(code) {
                    if code == "stroke_deleted" || code == "not_found" { try scene.remove(active.operation.payload.strokeID) }
                    try await journal.reject(operationID: active.operation.id, discardUndo: code == "not_found" || code == "stroke_deleted")
                    issue = code == "banned" ? .banned : .rejected
                } else { throw TransportFailure.malformedMessage }
                guard token == epoch else { return }
                attempt = nil; await refreshJournal()
            } else if code == "resync_required" || code == "internal_error" || code == "rate_limited" {
                await reconnect()
            } else { throw TransportFailure.malformedMessage }
        }
        guard token == epoch else { return }
        publishSoon()
    }
}
