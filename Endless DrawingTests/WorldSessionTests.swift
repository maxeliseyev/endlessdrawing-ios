import Foundation
import Testing
@testable import Endless_Drawing

actor WorldPeer: CanvasTransport {
    enum Mode: Sendable { case normal, loseFirstAck, delayFirstAck, rateLimitOnce, silentHello, silentSnapshot }
    struct CreateAttempt: Sendable { let requestID: String; let payload: StrokePayload }
    private let mode: Mode
    private var output: AsyncThrowingStream<ServerMessage, any Error>.Continuation?
    private var records: [UUID: ServerStroke] = [:]
    private var deleted: Set<UUID> = []
    private var scope: String?
    private var attempts: [CreateAttempt] = []
    private var delayed: ServerMessage?
    private var sequence: Int64 = 0
    private var connectionCount = 0
    private var allowed = true

    init(mode: Mode = .normal) { self.mode = mode }
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
        return .init(id: UUID(), profile: .messagePackV2, messages: stream)
    }
    func disconnect() { output?.finish(); output = nil }
    func ping() {}
    func send(_ message: ClientMessage) throws {
        switch message {
        case .hello:
            if mode != .silentHello { output?.yield(.hello(spawn: nil)) }
        case .subscribe(let id, _):
            if mode == .silentSnapshot { return }
            scope = id
            output?.yield(.snapshotBegin(id: id))
            output?.yield(.snapshotChunk(id: id, strokes: records.values.sorted { $0.sequence < $1.sequence }))
            output?.yield(.snapshotEnd(id: id))
        case .create(let requestID, let payload):
            attempts.append(CreateAttempt(requestID: requestID, payload: payload))
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
            guard let record = records.removeValue(forKey: strokeID) else {
                output?.yield(.error(requestID: requestID, subscriptionID: nil, code: "not_found")); return
            }
            deleted.insert(strokeID)
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
    private func make(_ mode: WorldPeer.Mode = .normal, timing: WorldTiming = WorldTiming()) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("world-tests-\(UUID())")
        let environment = try M2TestSupport.environment(), owner = UUID()
        let journal = try await OperationJournal.open(environment: environment, identityID: owner,
            storage: JournalFileStorage(url: directory.appendingPathComponent("operations.json")))
        let identity = DrawingIdentity(id: owner, secret: try SessionSecret(bytes: Data(repeating: 7, count: 32)))
        let peer = WorldPeer(mode: mode)
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
}
