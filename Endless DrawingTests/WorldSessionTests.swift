import Foundation
import Testing
@testable import Endless_Drawing

actor WorldPeer: CanvasTransport {
    enum Mode: Sendable { case normal, loseFirstAck, delayFirstAck, rateLimitOnce, silentHello, silentSnapshot, fallbackFirstCached, loseFirstDeleteAck }
    struct CreateAttempt: Sendable { let requestID: String; let payload: StrokePayload }
    struct Subscription: Sendable { let id: String; let bounds: WireBounds; let visible: WireBounds?; let cached: Bool }
    private let mode: Mode
    private let profile: TransportProfile
    private var subscriptionLog: [Subscription] = []
    private var fetchedIDs: [UUID] = []
    private var fallbacks = 0
    private var output: AsyncThrowingStream<ServerMessage, any Error>.Continuation?
    private var records: [UUID: ServerStroke] = [:]
    private var deleted: Set<UUID> = []
    private var scope: String?
    private var attempts: [CreateAttempt] = []
    private var delayed: ServerMessage?
    private var sequence: Int64 = 0
    private var connectionCount = 0
    private var allowed = true
    private var manifestToken: UUID?
    struct ReportAttempt: Sendable { let requestID: String; let strokeIDs: [UUID]; let reason: ReportReason; let blockAuthor: Bool }
    private var reportLog: [ReportAttempt] = []
    /// nil: acknowledge reports; otherwise answer them with this error code.
    private var reportError: String?
    /// nil: handle deletes normally; otherwise answer them with this error code.
    private var deleteError: String?
    private var deleteAckLost = false
    private var bannedCreates = false
    func reports() -> [ReportAttempt] { reportLog }
    func failReports(_ code: String?) { reportError = code }
    func failDeletes(_ code: String?) { deleteError = code }
    func banCreates() { bannedCreates = true }

    init(mode: Mode = .normal, profile: TransportProfile = .messagePackV2) { self.mode = mode; self.profile = profile }
    func subscriptions() -> [Subscription] { subscriptionLog }
    func fetched() -> [UUID] { fetchedIDs }
    func dropConnection() { output?.finish(throwing: TransportFailure.network); output = nil }
    /// A stroke someone else drew while this client was not subscribed there (no live event delivered).
    func injectRemote(_ payload: StrokePayload) throws {
        sequence += 1; records[payload.id] = try ServerStroke(payload: payload, sequence: sequence, own: false)
    }
    /// Server membership: strokes whose extent meets the bounds; v4 sends the visible class first.
    private func members(_ bounds: WireBounds, visible: WireBounds?) -> [ServerStroke] {
        let inside = records.values.filter { StrokeExtent($0.payload.drawable).intersects(bounds) }.sorted { $0.sequence < $1.sequence }
        guard let visible else { return inside }
        let first = inside.filter { StrokeExtent($0.payload.drawable).intersects(visible) }
        return first + inside.filter { !StrokeExtent($0.payload.drawable).intersects(visible) }
    }
    func allow(_ value: Bool) { allowed = value }
    func creates() -> [CreateAttempt] { attempts }
    func connects() -> Int { connectionCount }
    func count() -> Int { records.count }
    func releaseAck() { if let delayed { output?.yield(delayed); self.delayed = nil } }

    func connect() throws -> WebSocketTransport.Connection {
        connectionCount += 1
        guard allowed else { throw TransportFailure.network }
        let (stream, continuation) = AsyncThrowingStream<ServerMessage, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        output = continuation; scope = nil
        return .init(id: UUID(), profile: profile, messages: stream)
    }
    func disconnect() { output?.finish(); output = nil }
    func ping() {}
    func send(_ message: ClientMessage) throws {
        switch message {
        case .hello:
            if mode != .silentHello { output?.yield(.hello(spawn: nil)) }
        case .subscribeCached(let id, let bounds, let visible):
            precondition(profile.supportsManifest && (visible != nil) == profile.requiresVisibleBounds)
            subscriptionLog.append(Subscription(id: id, bounds: bounds, visible: visible, cached: true))
            scope = id
            output?.yield(.snapshotBegin(id: id))
            if mode == .fallbackFirstCached && fallbacks == 0 {
                fallbacks += 1; output?.yield(.snapshotFallback(id: id, reason: .busy)); return
            }
            let ids = members(bounds, visible: visible)
            let token = UUID()
            manifestToken = token
            output?.yield(.manifestBegin(id: id, token: token, strokeCount: ids.count,
                                         pointCount: ids.reduce(0) { $0 + $1.payload.points.count }))
            if !ids.isEmpty { output?.yield(.manifestChunk(id: id, token: token, strokeIDs: ids.map(\.payload.id))) }
            output?.yield(.manifestEnd(id: id, token: token))
        case .fetch(let id, let token, let batch, let strokeIDs, let final):
            precondition(token == manifestToken && id == scope)
            fetchedIDs += strokeIDs
            let strokes = strokeIDs.compactMap { records[$0] }
            if !strokes.isEmpty { output?.yield(.snapshotChunk(id: id, strokes: strokes)) }
            output?.yield(final ? .snapshotEnd(id: id) : .fetchEnd(id: id, token: token, batch: batch))
        case .subscribe(let id, let bounds, let visible):
            precondition((visible != nil) == profile.requiresVisibleBounds)
            subscriptionLog.append(Subscription(id: id, bounds: bounds, visible: visible, cached: false))
            if mode == .silentSnapshot { return }
            scope = id
            output?.yield(.snapshotBegin(id: id))
            if profile.supportsManifest {
                let strokes = members(bounds, visible: visible)
                if !strokes.isEmpty { output?.yield(.snapshotChunk(id: id, strokes: strokes)) }
            } else {
                output?.yield(.snapshotChunk(id: id, strokes: records.values.sorted { $0.sequence < $1.sequence }))
            }
            output?.yield(.snapshotEnd(id: id))
        case .report(let requestID, let strokeIDs, let reason, let blockAuthor):
            precondition(profile.supportsReports)
            reportLog.append(ReportAttempt(requestID: requestID, strokeIDs: strokeIDs, reason: reason, blockAuthor: blockAuthor))
            if let reportError { output?.yield(.error(requestID: requestID, subscriptionID: nil, code: reportError)) }
            else { output?.yield(.reportAcknowledged(requestID: requestID, reportID: UUID())) }
        case .create(let requestID, let payload):
            attempts.append(CreateAttempt(requestID: requestID, payload: payload))
            if bannedCreates { output?.yield(.error(requestID: requestID, subscriptionID: nil, code: "banned")); return }
            if mode == .rateLimitOnce && attempts.count == 1 {
                output?.yield(.error(requestID: requestID, subscriptionID: nil, code: "rate_limited")); return
            }
            if deleted.contains(payload.id) {
                output?.yield(.error(requestID: requestID, subscriptionID: nil, code: "stroke_deleted")); return
            }
            let record: ServerStroke
            if let previous = records[payload.id] { record = previous }
            else {
                sequence += 1; record = try M2TestSupport.confirmed(payload, sequence: sequence)
                records[payload.id] = record
                if let scope { output?.yield(.created(id: scope, stroke: record)) }
            }
            let acknowledgement = ServerMessage.createAcknowledged(requestID: requestID, stroke: record)
            if mode == .loseFirstAck && attempts.count == 1 { return }
            if mode == .delayFirstAck && attempts.count == 1 { delayed = acknowledgement; return }
            output?.yield(acknowledgement)
        case .delete(let requestID, let strokeID):
            if let deleteError {
                output?.yield(.error(requestID: requestID, subscriptionID: nil, code: deleteError)); return
            }
            guard let record = records.removeValue(forKey: strokeID) else {
                output?.yield(.error(requestID: requestID, subscriptionID: nil, code: "not_found")); return
            }
            deleted.insert(strokeID)
            if mode == .loseFirstDeleteAck && !deleteAckLost {
                deleteAckLost = true; return // applied server-side, ack lost: the client must retry
            }
            output?.yield(.deleteAcknowledged(requestID: requestID, strokeID: strokeID, sequence: record.sequence, alreadyDeleted: false))
            if let scope { output?.yield(.deleted(id: scope, strokeID: strokeID, sequence: record.sequence)) }
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct WorldSessionTests {
    private struct Harness {
        let directory: URL, peer: WorldPeer, journal: OperationJournal, world: WorldSession
    }
    private func make(_ mode: WorldPeer.Mode = .normal, timing: WorldTiming = WorldTiming(),
                      profile: TransportProfile = .messagePackV2) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("world-tests-\(UUID())")
        let environment = try M2TestSupport.environment(), owner = UUID()
        let journal = try await OperationJournal.open(environment: environment, identityID: owner,
            storage: JournalFileStorage(url: directory.appendingPathComponent("operations.json")))
        let identity = DrawingIdentity(id: owner, secret: try SessionSecret(bytes: Data(repeating: 7, count: 32)))
        let peer = WorldPeer(mode: mode, profile: profile)
        let world = WorldSession(transport: peer, identity: identity, journal: journal, initial: await journal.snapshot(), timing: timing)
        try await world.update(region: CanvasRegion(camera: Camera(), viewport: CanvasSize(width: 1024, height: 768)))
        return Harness(directory: directory, peer: peer, journal: journal, world: world)
    }
    private func wait(_ predicate: @Sendable () async throws -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < limit {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("World FSM did not reach the expected state")
        throw TransportFailure.timedOut
    }
    private func cleanup(_ harness: Harness) async {
        await harness.world.stop(); try? FileManager.default.removeItem(at: harness.directory)
    }

    @Test func createEventBeforeAckDeduplicatesAndUndoDeletesOnlyOwnJournalAction() async throws {
        let h = try await make(); defer { Task { await cleanup(h) } }
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        let payload = try M2TestSupport.payload(brush: .chisel)
        _ = try await h.world.enqueue(payload.drawable)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        let state = await h.world.snapshot()
        #expect(state.confirmed.map(\.server.payload.id) == [payload.id])
        #expect(state.pending.isEmpty)
        _ = try await h.world.undo()
        try await wait {
            let empty = await h.journal.snapshot().operations.isEmpty
            let count = await h.peer.count()
            return empty && count == 0
        }
        #expect(await h.world.snapshot().confirmed.isEmpty)
        #expect(await h.journal.snapshot().undo.isEmpty)
    }

    @Test func lostAckTimesOutAndRetriesSameImmutableUUIDWithNewRequestIDAndSingleUndo() async throws {
        let h = try await make(.loseFirstAck, timing: WorldTiming(acknowledgement: 0.2))
        defer { Task { await cleanup(h) } }
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        let payload = try M2TestSupport.payload(brush: .spray)
        _ = try await h.world.enqueue(payload.drawable)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        let attempts = await h.peer.creates()
        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { $0.payload == payload })
        #expect(attempts[0].requestID != attempts[1].requestID)
        #expect(await h.peer.count() == 1)
        #expect(await h.peer.connects() >= 2)
        #expect(await h.journal.snapshot().undo.map(\.strokeID) == [payload.id])
    }

    @Test func undoAfterPossibleSendHidesThenCompensatesAfterAck() async throws {
        let h = try await make(.delayFirstAck); defer { Task { await cleanup(h) } }
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        let payload = try M2TestSupport.payload()
        _ = try await h.world.enqueue(payload.drawable)
        try await wait { await h.peer.creates().count == 1 }
        _ = try await h.world.undo()
        #expect(await h.world.snapshot().hidden.contains(payload.id))
        #expect(await h.world.snapshot().confirmed.isEmpty)
        await h.peer.releaseAck()
        try await wait {
            let empty = await h.journal.snapshot().operations.isEmpty
            let count = await h.peer.count()
            return empty && count == 0
        }
        #expect(await h.journal.snapshot().undo.isEmpty)
    }

    @Test func offlineDraftPersistsBeforeAnySendAndUnsentUndoNeedsNoMutation() async throws {
        let h = try await make(); defer { Task { await cleanup(h) } }
        await h.peer.allow(false); await h.world.start()
        let payload = try M2TestSupport.payload()
        _ = try await h.world.enqueue(payload.drawable)
        #expect(await h.journal.snapshot().operations.first?.mayHaveBeenSent == false)
        #expect(await h.peer.creates().isEmpty)
        _ = try await h.world.undo()
        #expect(await h.journal.snapshot().operations.isEmpty)
        await h.peer.allow(true)
        try await wait { await h.world.snapshot().status == .live }
        #expect(await h.peer.count() == 0)
    }

    @Test func deleteCancelsUnsentCreateWithoutAnyMutation() async throws {
        let h = try await make(); defer { Task { await cleanup(h) } }
        await h.peer.allow(false); await h.world.start()
        let payload = try M2TestSupport.payload()
        _ = try await h.world.enqueue(payload.drawable)
        #expect(await h.journal.snapshot().operations.first?.mayHaveBeenSent == false)
        _ = try await h.world.delete(strokeID: payload.id)
        #expect(await h.journal.snapshot().operations.isEmpty)
        #expect(await h.world.snapshot().pending.isEmpty)
        await h.peer.allow(true)
        try await wait { await h.world.snapshot().status == .live }
        #expect(await h.peer.count() == 0)
    }

    @Test func deleteRemovesOwnConfirmedStrokeAndItsUndoEntry() async throws {
        let h = try await make(); defer { Task { await cleanup(h) } }
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        let payload = try M2TestSupport.payload()
        _ = try await h.world.enqueue(payload.drawable)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        _ = try await h.world.delete(strokeID: payload.id)
        try await wait {
            let empty = await h.journal.snapshot().operations.isEmpty
            let count = await h.peer.count()
            return empty && count == 0
        }
        #expect(await h.world.snapshot().confirmed.isEmpty)
        #expect(await h.journal.snapshot().undo.isEmpty)
    }

    @Test func deleteSurvivesLostAckAndCompletesOnRetry() async throws {
        let h = try await make(.loseFirstDeleteAck, timing: WorldTiming(acknowledgement: 0.2))
        defer { Task { await cleanup(h) } }
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        let payload = try M2TestSupport.payload()
        _ = try await h.world.enqueue(payload.drawable)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        _ = try await h.world.delete(strokeID: payload.id)
        try await wait { await h.journal.snapshot().operations.isEmpty }
        #expect(await h.peer.count() == 0)
        #expect(await h.journal.snapshot().undo.isEmpty)
    }

    @Test func deleteRejectedRestoresTheStrokeAndItsUndoEntry() async throws {
        let h = try await make(); defer { Task { await cleanup(h) } }
        await h.peer.failDeletes("forbidden")
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        let payload = try M2TestSupport.payload()
        _ = try await h.world.enqueue(payload.drawable)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        _ = try await h.world.delete(strokeID: payload.id)
        try await wait { await h.journal.snapshot().operations.isEmpty }
        let state = await h.world.snapshot()
        #expect(state.confirmed.map(\.server.payload.id) == [payload.id])
        #expect(state.hidden.isEmpty)
        #expect(await h.journal.snapshot().undo.map(\.strokeID) == [payload.id])
    }

    @Test func deleteNotFoundIsSuccessAndDropsTheUndoEntry() async throws {
        let h = try await make(); defer { Task { await cleanup(h) } }
        await h.peer.failDeletes("not_found")
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        let payload = try M2TestSupport.payload()
        _ = try await h.world.enqueue(payload.drawable)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        _ = try await h.world.delete(strokeID: payload.id)
        try await wait { await h.journal.snapshot().operations.isEmpty }
        #expect(await h.world.snapshot().confirmed.isEmpty)
        #expect(await h.journal.snapshot().undo.isEmpty)
    }

    @Test func rateLimitRetainsOperationUntilDelayedRetry() async throws {
        let h = try await make(.rateLimitOnce); defer { Task { await cleanup(h) } }
        await h.world.start(); try await wait { await h.world.snapshot().status == .live }
        _ = try await h.world.enqueue(M2TestSupport.payload().drawable)
        try await wait { await h.peer.creates().count == 1 }
        #expect(await h.journal.snapshot().operations.count == 1)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        #expect(await h.peer.creates().count == 2)
    }

    @Test func repeatedSnapshotTimeoutsPauseUntilRegionChangesInsteadOfResyncingForever() async throws {
        let h = try await make(.silentSnapshot, timing: WorldTiming(snapshot: 0.1))
        defer { Task { await cleanup(h) } }
        await h.world.start()
        try await wait { await h.world.snapshot().status == .dense }
        let count = await h.peer.connects()
        try await Task.sleep(for: .milliseconds(250))
        #expect(await h.peer.connects() == count)
        var camera = Camera(); camera.zoom(to: 2, anchor: .zero, viewport: CanvasSize(width: 1024, height: 768))
        try await h.world.update(region: CanvasRegion(camera: camera, viewport: CanvasSize(width: 1024, height: 768)))
        try await wait { await h.peer.connects() > count }
    }

    @Test func missingHelloAckReconnectsAndStopInvalidatesOldGeneration() async throws {
        let h = try await make(.silentHello, timing: WorldTiming(hello: 0.1))
        defer { Task { await cleanup(h) } }
        await h.world.start()
        try await wait { await h.peer.connects() >= 2 }
        await h.world.stop()
        let count = await h.peer.connects()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.peer.connects() == count)
        #expect(await h.world.snapshot().status == .stopped)
    }

    // MARK: - v4 visible-first and v3 manifest reuse

    private func payload(x: Double) throws -> StrokePayload {
        try StrokePayload(id: UUID(), points: [WorldPoint(x: x, y: 0), WorldPoint(x: x + 10, y: 5)], brush: .round,
                          width: 4, color: "#202020", opacity: 1)
    }

    /// Visible window [688, 1712] leaves the first 3×3 subscription ([-1536, 1536]) but the origin stays inside.
    private func panRight(_ world: WorldSession) async throws {
        var camera = Camera(); camera.pan(screenDelta: WorldPoint(x: -1200, y: 0))
        await world.update(region: try CanvasRegion(camera: camera, viewport: CanvasSize(width: 1024, height: 768)))
    }

    @Test func v4FirstSubscriptionIsFullWithVisibleHintThenPanReusesCachedRecords() async throws {
        let h = try await make(profile: .messagePackV4)
        defer { Task { await cleanup(h) } }
        let near = try payload(x: 0), far = try payload(x: 1400)
        try await h.peer.injectRemote(near)
        await h.world.start()
        try await wait { let state = await h.world.snapshot(); return state.status == .live && state.confirmed.count == 1 }
        let first = try #require(await h.peer.subscriptions().first)
        #expect(!first.cached)
        let visible = try #require(first.visible)
        #expect(first.bounds.contains(visible) && visible != first.bounds)
        try await h.peer.injectRemote(far) // appeared while we were not subscribed there
        try await panRight(h.world)
        try await wait { let count = await h.peer.subscriptions().count; let live = await h.world.snapshot().status == .live; return count == 2 && live }
        let second = try #require(await h.peer.subscriptions().last)
        #expect(second.cached && second.visible != nil)
        #expect(await h.peer.fetched() == [far.id]) // the known stroke is reused, not downloaded again
        try await wait { Set(await h.world.snapshot().confirmed.map(\.server.payload.id)) == [near.id, far.id] }
    }

    @Test func fallbackBusyLoadsAFullSnapshotOnTheSameConnection() async throws {
        let h = try await make(.fallbackFirstCached, profile: .messagePackV4)
        defer { Task { await cleanup(h) } }
        let near = try payload(x: 0)
        try await h.peer.injectRemote(near)
        await h.world.start()
        try await wait { await h.world.snapshot().status == .live }
        try await panRight(h.world)
        try await wait { let count = await h.peer.subscriptions().count; let live = await h.world.snapshot().status == .live; return count == 3 && live }
        let log = await h.peer.subscriptions()
        #expect(log.map(\.cached) == [false, true, false]) // cached → busy fallback → full after the pause
        #expect(await h.peer.connects() == 1)
        #expect(await h.world.snapshot().confirmed.map(\.server.payload.id) == [near.id])
    }

    @Test func reconnectAlwaysStartsWithAFullSnapshot() async throws {
        let h = try await make(profile: .messagePackV4)
        defer { Task { await cleanup(h) } }
        try await h.peer.injectRemote(try payload(x: 0))
        await h.world.start()
        try await wait { await h.world.snapshot().status == .live }
        await h.peer.dropConnection()
        try await wait { let connects = await h.peer.connects(); let count = await h.peer.subscriptions().count; return connects >= 2 && count >= 2 }
        #expect(await h.peer.subscriptions().map(\.cached) == [false, false])
        try await wait { await h.world.snapshot().status == .live }
    }

    @Test func ownDrawingDuringCachedSubscriptionIsNeitherLostNorDuplicated() async throws {
        let h = try await make(profile: .messagePackV4)
        defer { Task { await cleanup(h) } }
        await h.world.start()
        try await wait { await h.world.snapshot().status == .live }
        let mine = try payload(x: 20)
        _ = try await h.world.enqueue(mine.drawable)
        try await wait { await h.journal.snapshot().undo.count == 1 }
        try await panRight(h.world)
        try await wait { let count = await h.peer.subscriptions().count; let live = await h.world.snapshot().status == .live; return count == 2 && live }
        #expect(await h.peer.fetched().isEmpty) // own acked stroke is reused from the connection cache
        let state = await h.world.snapshot()
        #expect(state.confirmed.map(\.server.payload.id) == [mine.id] && state.pending.isEmpty && state.canUndo)
    }

    // MARK: - v5 reports (App Review 1.2)

    @Test func v5ReportIsSentOnceLiveAndAcknowledged() async throws {
        let h = try await make(profile: .messagePackV5)
        defer { Task { await cleanup(h) } }
        let (a, b) = (UUID(), UUID())
        #expect(await h.world.report(strokeIDs: [a, b, a], reason: .hate, blockAuthor: true)) // queued before connecting
        await h.world.start()
        try await wait { await h.peer.reports().count == 1 }
        let sent = try #require(await h.peer.reports().first)
        #expect(sent.strokeIDs == [a, b] && sent.reason == .hate && sent.blockAuthor)
        try await wait { await h.world.queuedReports == 0 }
    }

    @Test func reportsWaitForAV5ConnectionAndBannedDropsThem() async throws {
        let old = try await make(profile: .messagePackV4)
        defer { Task { await cleanup(old) } }
        await old.world.report(strokeIDs: [UUID()], reason: .spam, blockAuthor: false)
        await old.world.start()
        try await wait { await old.world.snapshot().status == .live }
        try await Task.sleep(for: .milliseconds(200))
        let queued = await old.world.queuedReports
        #expect(await old.peer.reports().isEmpty)
        #expect(queued == 1)

        let h = try await make(profile: .messagePackV5)
        defer { Task { await cleanup(h) } }
        await h.peer.failReports("banned")
        await h.world.report(strokeIDs: [UUID()], reason: .other, blockAuthor: false)
        await h.world.start()
        try await wait { await h.world.snapshot().issue == .banned }
        #expect(await h.world.queuedReports == 0)
        #expect(await h.peer.reports().count == 1) // not retried
    }

    @Test func bannedCreateIsRejectedAndReported() async throws {
        let h = try await make(profile: .messagePackV5)
        defer { Task { await cleanup(h) } }
        await h.peer.banCreates()
        await h.world.start()
        try await wait { await h.world.snapshot().status == .live }
        _ = try await h.world.enqueue(try payload(x: 0).drawable)
        try await wait { let state = await h.world.snapshot(); return state.issue == .banned && state.pendingCount == 0 }
    }
}
