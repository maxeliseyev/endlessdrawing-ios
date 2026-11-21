import Foundation
import Testing
@testable import Endless_Drawing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct WebSocketTransportTests {
    private func environment(_ port: UInt16) throws -> DrawingEnvironment {
        try DrawingEnvironment(namespace: .development, socketURL: URL(string: "ws://127.0.0.1:\(port)/ws")!, origin: "http://localhost:5173")
    }
    private func secret() throws -> SessionSecret { try SessionSecret(bytes: Data(repeating: 1, count: 32)) }

    @Test func binaryAndJSONFallbackUseRealUpgradeOriginAndOrderedMessages() async throws {
        for mode in [LocalWebSocketServer.Mode.binary, .jsonFallback, .legacy] {
            let server = try LocalWebSocketServer(mode: mode)
            let port = try await server.start()
            let policy: TransportPolicy = mode == .legacy ? .legacyJSONV1 : .negotiated
            let transport = WebSocketTransport(environment: try environment(port), policy: policy)
            defer { Task { await transport.disconnect(); await server.stop() } }
            let connection = try await transport.connect()
            let expected: TransportProfile = mode == .binary ? .messagePackV2 : (mode == .legacy ? .legacyJSONV1 : .jsonV1)
            #expect(connection.profile == expected)
            let handshake = await server.handshake()
            #expect(handshake.origin == "http://localhost:5173")
            #expect(handshake.offers == policy.offeredProtocols)
            #expect(handshake.cookie == nil)
            try await transport.send(.hello(secret()))
            var messages = connection.messages.makeAsyncIterator()
            #expect(try await messages.next() == .hello(spawn: nil))
            try await transport.send(.subscribe(id: "view-1", bounds: WireBounds(minX: -100, minY: -100, maxX: 100, maxY: 100)))
            #expect(try await messages.next() == .snapshotBegin(id: "view-1"))
            #expect(try await messages.next() == .snapshotEnd(id: "view-1"))
            try await transport.ping()
            await transport.disconnect()
            #expect(try await messages.next() == nil)
            await server.stop()
        }
    }

    @Test func missingSelectedProfileDoesNotOpenLegacyRetry() async throws {
        let server = try LocalWebSocketServer(mode: .missingProtocol)
        let port = try await server.start()
        let transport = WebSocketTransport(environment: try environment(port))
        defer { Task { await transport.disconnect(); await server.stop() } }
        do {
            _ = try await transport.connect()
            Issue.record("An empty negotiated profile must not succeed")
        } catch let failure as TransportFailure {
            // Foundation may reject the upgrade before didOpen; both outcomes must stay closed.
            #expect(failure == .unexpectedProfile || failure == .network)
        }
        #expect(await server.handshake().requests == 1)
        await transport.disconnect()
        await server.stop()
    }

    @Test func invalidVersionAndWrongFrameTypeFailWithoutPublishingMessage() async throws {
        for mode in [LocalWebSocketServer.Mode.wrongVersion, .wrongFrame] {
            let server = try LocalWebSocketServer(mode: mode)
            let port = try await server.start()
            let transport = WebSocketTransport(environment: try environment(port))
            defer { Task { await transport.disconnect(); await server.stop() } }
            let connection = try await transport.connect()
            try await transport.send(.hello(secret()))
            var messages = connection.messages.makeAsyncIterator()
            do {
                _ = try await messages.next()
                Issue.record("Invalid frame must terminate the stream")
            } catch let failure as TransportFailure {
                #expect(failure == (mode == .wrongVersion ? .incompatibleVersion : .wrongMessageType))
            }
            await transport.disconnect()
            await server.stop()
        }
    }

    @Test func SDKReceiveCeilingReportsOversizeRatherThanGenericNetworkFailure() async throws {
        let server = try LocalWebSocketServer(mode: .oversized)
        let port = try await server.start()
        let transport = WebSocketTransport(environment: try environment(port))
        defer { Task { await transport.disconnect(); await server.stop() } }
        let connection = try await transport.connect()
        try await transport.send(.hello(secret()))
        var messages = connection.messages.makeAsyncIterator()
        await #expect(throws: TransportFailure.messageTooLarge) { try await messages.next() }
        await transport.disconnect()
        await server.stop()
    }

    @Test func receiveBackpressureClosesInsteadOfSilentlyDroppingEvents() async throws {
        let server = try LocalWebSocketServer(mode: .flood)
        let port = try await server.start()
        let transport = WebSocketTransport(environment: try environment(port))
        defer { Task { await transport.disconnect(); await server.stop() } }
        let connection = try await transport.connect()
        try await transport.send(.hello(secret()))
        // Keep the consumer stalled until the receive budget closes this generation.
        for _ in 0..<200 {
            if await !transport.isConnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.isConnected == false)
        do {
            for try await _ in connection.messages {}
            Issue.record("Overflow must be observable")
        } catch let failure as TransportFailure { #expect(failure == .queueFull) }
        await transport.disconnect()
        await server.stop()
    }

    @Test func cancelledConnectionCannotCloseItsReplacementAndDisconnectedSendFails() async throws {
        let server = try LocalWebSocketServer(mode: .binary)
        let port = try await server.start()
        let transport = WebSocketTransport(environment: try environment(port))
        defer { Task { await transport.disconnect(); await server.stop() } }
        let hello = try ClientMessage.hello(secret())
        await #expect(throws: TransportFailure.notConnected) { try await transport.send(hello) }
        let first = Task { try await transport.connect() }
        // Require a real first Upgrade, rather than only cancelling a task before it ever starts.
        for _ in 0..<200 {
            if await server.handshake().requests > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.handshake().requests == 1)
        first.cancel()
        _ = try? await first.value
        let replacement = try await transport.connect()
        try await transport.send(hello)
        var messages = replacement.messages.makeAsyncIterator()
        #expect(try await messages.next() == .hello(spawn: nil))
        #expect(await server.handshake().requests == 2)
        try await transport.ping()
        await transport.disconnect()
        await #expect(throws: TransportFailure.notConnected) { try await transport.send(hello) }
        await server.stop()
    }

    @Test func pingReplyResumesOnlyOnceWhenURLSessionCallsBackTwice() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let reply = PingReply(continuation)
            #expect(reply.complete(nil))
            #expect(!reply.complete(URLError(.cancelled)))
            #expect(!reply.complete(nil))
        }
        await #expect(throws: TransportFailure.network) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let reply = PingReply(continuation)
                #expect(reply.complete(URLError(.networkConnectionLost)))
                #expect(!reply.complete(URLError(.cancelled)))
            }
        }
    }

    @Test func disconnectWhilePongIsPendingFailsThePingWithoutTrapping() async throws {
        let server = try LocalWebSocketServer(mode: .silentPong)
        let port = try await server.start()
        let transport = WebSocketTransport(environment: try environment(port))
        defer { Task { await transport.disconnect(); await server.stop() } }
        let connection = try await transport.connect()
        try await transport.send(.hello(secret()))
        var messages = connection.messages.makeAsyncIterator()
        #expect(try await messages.next() == .hello(spawn: nil))
        let ping = Task { try await transport.ping() }
        try await Task.sleep(for: .milliseconds(100)) // the ping frame is out; no pong will come
        await transport.disconnect()
        await #expect(throws: TransportFailure.notConnected) { try await ping.value }
        try await Task.sleep(for: .milliseconds(300)) // late URLSession ping callbacks must be harmless
        await server.stop()
    }

    @Test func connectionLostWhilePongIsPendingFailsThePingWithoutTrapping() async throws {
        let server = try LocalWebSocketServer(mode: .dropOnPing)
        let port = try await server.start()
        let transport = WebSocketTransport(environment: try environment(port))
        defer { Task { await transport.disconnect(); await server.stop() } }
        let connection = try await transport.connect()
        try await transport.send(.hello(secret()))
        var messages = connection.messages.makeAsyncIterator()
        #expect(try await messages.next() == .hello(spawn: nil))
        await #expect(throws: TransportFailure.network) { try await transport.ping() }
        await #expect(throws: TransportFailure.network) { try await messages.next() }
        try await Task.sleep(for: .milliseconds(300))
        await transport.disconnect()
        await server.stop()
    }
}
