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
nonisolated enum WorldIssue: Sendable, Equatable { case storage, protocolMismatch, rejected, dense }
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
    private var snapshotInterval: OSSignpostIntervalState?
    private var snapshotChunks = 0
    private let onSpawn: @Sendable (WorldPoint) async -> Void

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

    func update(region: CanvasRegion) {
        self.region = region
        if let suspendedForRegion, suspendedForRegion != region.subscription {
            self.suspendedForRegion = nil; snapshotTimeouts = 0; issue = nil
        }
        publish()
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

    private func refreshJournal() async {
        let snapshot = await journal.versionedSnapshot()
        if snapshot.revision >= journalRevision { journalRevision = snapshot.revision; journalState = snapshot.state }
    }

    @discardableResult private func publish() -> WorldRenderState {
        revision &+= 1
        let value = state(); output?.yield(value); return value
    }

    private func state() -> WorldRenderState {
        let hidden = Set(journalState.operations.compactMap { operation -> UUID? in
            switch operation.payload {
            case .create(let payload): operation.cancelled ? payload.id : nil
            case .delete(let id): id
            }
        })
        let records = region.map { scene.visible(in: $0.rendering, hidden: hidden) } ?? []
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
                connectionID = connection.id; pacer = RequestPacer(); attempt = nil
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
            if let region, (scene.subscriptionID == nil || scene.bounds?.contains(region.visible) != true),
               pacer.admit(.subscribe, now: now) {
                let id = UUID().uuidString.lowercased()
                scene.subscribe(id: id, bounds: region.subscription)
                if let snapshotInterval { Signposts.snapshot.endInterval("subscription", snapshotInterval, "superseded") }
                snapshotInterval = Signposts.snapshot.beginInterval("subscription"); snapshotChunks = 0
                snapshotDeadline = now + timing.snapshot; status = .loading; publish()
                try await transport.send(.subscribe(id: id, bounds: region.subscription))
                return
            }
            if now - lastPing >= timing.ping, pacer.admit(.ping, now: now) {
                lastPing = now
                try await transport.ping()
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
            try scene.chunk(id: id, strokes: strokes)
            if id == scene.subscriptionID {
                snapshotChunks += 1
                Signposts.snapshot.emitEvent("chunk", "\(self.snapshotChunks) #\(strokes.count)")
            }
        case .snapshotEnd(let id):
            let current = id == scene.subscriptionID
            try scene.end(id: id)
            if current {
                snapshotDeadline = nil; snapshotTimeouts = 0; status = .live
                if let snapshotInterval { Signposts.snapshot.endInterval("subscription", snapshotInterval, "\(self.snapshotChunks) chunks") }
                snapshotInterval = nil
            }
        case .created(let id, let stroke): try scene.created(id: id, stroke: stroke)
        case .deleted(let id, let strokeID, let sequence): try scene.deleted(id: id, strokeID: strokeID, sequence: sequence)
        case .createAcknowledged(let requestID, let stroke):
            guard let active = attempt, active.requestID == requestID else { return }
            guard case .create(let payload) = active.operation.payload, payload == stroke.payload, stroke.own else {
                throw TransportFailure.malformedMessage
            }
            // Canonical commit is known before awaiting durable resolution; an overlapping UI command
            // must never observe neither the pending draft nor its confirmed geometry.
            try scene.acknowledged(stroke)
            try await journal.acknowledgeCreate(operationID: active.operation.id, stroke: stroke)
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
        case .error(let requestID, let subscriptionID, let code):
            if let subscriptionID, subscriptionID != scene.subscriptionID { return }
            if let requestID {
                guard let active = attempt, active.requestID == requestID else { return }
                if ["rate_limited", "internal_error"].contains(code) {
                    retryAfter = ProcessInfo.processInfo.systemUptime + 1.5
                } else if ["id_conflict", "validation_failed", "invalid_message", "message_too_large", "forbidden", "stroke_deleted", "not_found"].contains(code) {
                    if code == "stroke_deleted" || code == "not_found" { try scene.remove(active.operation.payload.strokeID) }
                    try await journal.reject(operationID: active.operation.id, discardUndo: code == "not_found" || code == "stroke_deleted")
                    issue = .rejected
                } else { throw TransportFailure.malformedMessage }
                guard token == epoch else { return }
                attempt = nil; await refreshJournal()
            } else if code == "resync_required" || code == "internal_error" || code == "rate_limited" {
                await reconnect()
            } else { throw TransportFailure.malformedMessage }
        }
        guard token == epoch else { return }
        publish()
    }
}
