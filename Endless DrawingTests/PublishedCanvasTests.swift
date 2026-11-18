import Foundation
import Testing
@testable import Endless_Drawing

/// Manual read-only acceptance. Never enabled by ordinary tests or implicit application startup.
struct PublishedCanvasTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENDLESS_NATIVE_READ_SMOKE"] == "1"), .timeLimit(.minutes(1)))
    func nativeURLSessionReadsPublishedV2SnapshotWithoutMutatingWorld() async throws {
        let transport = WebSocketTransport(environment: .live)
        defer { Task { await transport.disconnect() } }
        let connection = try await transport.connect()
        #expect(connection.profile == .messagePackV2)
        let secret = try SessionSecret(bytes: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        try await transport.send(.hello(secret))
        var messages = connection.messages.makeAsyncIterator()
        let welcome = try #require(try await messages.next())
        guard case .hello(let hint) = welcome else { Issue.record("Expected hello.ack"); return }
        let center = hint ?? .zero
        let x = max(-Camera.worldLimit, min(Camera.worldLimit - 1000, center.x - 500))
        let y = max(-Camera.worldLimit, min(Camera.worldLimit - 1000, center.y - 500))
        let bounds = try WireBounds(minX: x, minY: y, maxX: x + 1000, maxY: y + 1000)
        let id = UUID().uuidString.lowercased()
        try await transport.send(.subscribe(id: id, bounds: bounds))
        var began = false, strokes = 0, points = 0, lastSequence: Int64 = 0
        while let message = try await messages.next() {
            switch message {
            case .snapshotBegin(let scope): #expect(scope == id); began = true
            case .snapshotChunk(let scope, let values):
                #expect(began && scope == id)
                for value in values { #expect(value.sequence > lastSequence); lastSequence = value.sequence }
                strokes += values.count; points += values.reduce(0) { $0 + $1.payload.points.count }
                #expect(strokes <= 20_000 && points <= 1_000_000)
            case .snapshotEnd(let scope):
                #expect(began && scope == id)
                print("Published native read-only v2 PASS: \(strokes) strokes, \(points) points. No mutations sent.")
                await transport.disconnect()
                return
            default: Issue.record("Unexpected message during read-only snapshot"); return
            }
        }
        Issue.record("Connection ended before snapshot.end")
    }
}
