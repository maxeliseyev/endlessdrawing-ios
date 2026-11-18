import Foundation
import Testing
@testable import Endless_Drawing

/// Opt-in only, hard restricted to loopback. Use an isolated disposable backend database.
struct LocalBackendTests {
    private static var enabled: Bool { ProcessInfo.processInfo.environment["ENDLESS_LOCAL_BACKEND_WS"] != nil }
    private func environment() throws -> DrawingEnvironment {
        let raw = ProcessInfo.processInfo.environment["ENDLESS_LOCAL_BACKEND_WS"] ?? ""
        guard let url = URL(string: raw), url.scheme == "ws", url.host == "127.0.0.1" else {
            throw DrawingDataError.invalidEnvironment
        }
        return try DrawingEnvironment(namespace: .development, socketURL: url, origin: "http://localhost:5173")
    }
    private func secret() throws -> SessionSecret {
        try SessionSecret(bytes: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }
    private func wait(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<800 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Isolated backend did not reach expected state"); throw TransportFailure.timedOut
    }

    @Test(.enabled(if: Self.enabled && ProcessInfo.processInfo.environment["ENDLESS_EXPECT_JSON_ROLLBACK"] != "1"), .timeLimit(.minutes(1)))
    func binaryWorldSessionAndLegacyObserverShareAllBrushesOwnershipIdempotencyAndUndo() async throws {
        let environment = try environment()
        let observer = WebSocketTransport(environment: environment, policy: .legacyJSONV1)
        let author = WebSocketTransport(environment: environment)
        let duplicate = WebSocketTransport(environment: environment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("real-backend-\(UUID())")
        let journal = try await OperationJournal.open(environment: environment, identityID: UUID(),
            storage: JournalFileStorage(url: directory.appendingPathComponent("operations.json")))
        let owner = await journal.snapshot().identityID
        let identity = DrawingIdentity(id: owner, secret: try secret())
        let world = WorldSession(transport: author, identity: identity, journal: journal, initial: await journal.snapshot())
        defer {
            Task {
                await world.stop(); await observer.disconnect(); await duplicate.disconnect()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let observerConnection = try await observer.connect()
        #expect(observerConnection.profile == .legacyJSONV1)
        try await observer.send(.hello(secret()))
        var incoming = observerConnection.messages.makeAsyncIterator()
        #expect(try await incoming.next() == .hello(spawn: nil)) // disposable DB starts empty
        let region = try CanvasRegion(camera: Camera(), viewport: CanvasSize(width: 1024, height: 768))
        try await observer.send(.subscribe(id: "legacy-view", bounds: region.subscription))
        #expect(try await incoming.next() == .snapshotBegin(id: "legacy-view"))
        #expect(try await incoming.next() == .snapshotEnd(id: "legacy-view"))
        await world.update(region: region); await world.start()
        try await wait { await world.snapshot().status == .live }
        let payloads = try [BrushKind.round, .square, .chisel, .spray].map {
            try StrokePayload(id: UUID(), points: [WorldPoint(x: 12.125, y: -8.0625), WorldPoint(x: 40.25, y: 22.5)],
                              brush: $0, width: 6.25, color: "#abCDef", opacity: 0.5)
        }
        var sequences: [UUID: Int64] = [:]
        for (index, payload) in payloads.enumerated() {
            _ = try await world.enqueue(payload.drawable)
            guard case .created(let scope, let record) = try await incoming.next() else {
                Issue.record("Expected a mixed-profile creation event"); return
            }
            #expect(scope == "legacy-view" && record.payload == payload && !record.own)
            sequences[payload.id] = record.sequence
            try await wait { await journal.snapshot().undo.count == index + 1 }
        }
        #expect(await world.snapshot().confirmed.allSatisfy { $0.server.own })
        let retryConnection = try await duplicate.connect()
        #expect(retryConnection.profile.isMessagePack) // v2/v3/v4 depending on the local backend gates
        try await duplicate.send(.hello(identity.secret))
        var retried = retryConnection.messages.makeAsyncIterator()
        guard case .hello = try await retried.next() else { Issue.record("Missing retry hello"); return }
        try await duplicate.send(.create(requestID: "retry-other-connection", stroke: payloads[0]))
        guard case .createAcknowledged(let requestID, let record) = try await retried.next() else {
            Issue.record("Expected idempotent create ack"); return
        }
        #expect(requestID == "retry-other-connection" && record.own && record.sequence == sequences[payloads[0].id])
        try await observer.send(.delete(requestID: "not-the-owner", strokeID: payloads[0].id))
        guard case .error(let requestID, _, let code) = try await incoming.next() else { Issue.record("Expected ownership rejection"); return }
        #expect(requestID == "not-the-owner" && code == "forbidden")
        for (index, payload) in payloads.reversed().enumerated() {
            _ = try await world.undo()
            guard case .deleted(let scope, let id, let sequence) = try await incoming.next() else {
                Issue.record("Expected mixed-profile deletion event"); return
            }
            #expect(scope == "legacy-view" && id == payload.id && sequence == sequences[id])
            try await wait { await journal.snapshot().undo.count == payloads.count - index - 1 }
        }
        #expect(await journal.snapshot().operations.isEmpty)
        #expect(await world.snapshot().confirmed.isEmpty)
        print("Isolated backend/Postgres PASS: all four brushes, Binary/legacy coexistence, ownership, idempotent retry and server undo.")
    }

    @Test(.enabled(if: Self.enabled && ProcessInfo.processInfo.environment["ENDLESS_EXPECT_JSON_ROLLBACK"] == "1"), .timeLimit(.minutes(1)))
    func serverFlagRollsNegotiatedNativeClientBackToExplicitJSON() async throws {
        let transport = WebSocketTransport(environment: try environment())
        defer { Task { await transport.disconnect() } }
        let connection = try await transport.connect()
        #expect(connection.profile == .jsonV1)
        try await transport.send(.hello(secret()))
        var incoming = connection.messages.makeAsyncIterator()
        guard case .hello = try await incoming.next() else { Issue.record("Expected JSON hello.ack"); return }
        print("Isolated backend JSON rollback PASS (no legacy retry)."); await transport.disconnect()
    }
}
