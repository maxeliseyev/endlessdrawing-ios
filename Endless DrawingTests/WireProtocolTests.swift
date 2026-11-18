import Foundation
import Testing
@testable import Endless_Drawing

struct WireProtocolTests {
    private func message(_ object: [String: Any]) throws -> ServerMessage {
        try ServerMessage.decode(JSONSerialization.data(withJSONObject: object))
    }

    @Test func endpointSeparatesIdentitiesAndBuildsExplicitOrigin() throws {
        let environment = try M2TestSupport.environment()
        let request = environment.webSocketRequest()
        #expect(request.value(forHTTPHeaderField: "Origin") == "http://localhost:5173")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.url?.query == nil)
        #expect(environment.identityAccount != (try M2TestSupport.environment(port: 3001)).identityAccount)
        let canonical = try DrawingEnvironment(namespace: .development, socketURL: URL(string: "ws://LOCALHOST:3000/ws")!,
                                               origin: "http://LOCALHOST:5173/")
        #expect(canonical.origin == "http://localhost:5173")
        #expect(try JSONDecoder().decode(DrawingEnvironment.self, from: JSONEncoder().encode(canonical)) == canonical)
    }

    @Test func productionRejectsPlaintextCredentialsQueriesAndInvalidOrigins() throws {
        for url in ["ws://example.com/ws", "wss://user:password@example.com/ws", "wss://example.com/ws?secret=unsafe", "wss://example.com/ws#fragment"] {
            #expect(throws: DrawingDataError.invalidEnvironment) {
                try DrawingEnvironment(namespace: .production, socketURL: URL(string: url)!, origin: "https://example.com")
            }
        }
        for origin in ["http://example.com", "https://user:password@example.com", "https://example.com/admin", "https://example.com?q=1"] {
            #expect(throws: DrawingDataError.invalidEnvironment) {
                try DrawingEnvironment(namespace: .production, socketURL: URL(string: "wss://example.com/ws")!, origin: origin)
            }
        }
    }

    @Test func pointsUseExactlyTwoFiniteWorldCoordinates() throws {
        let point = try JSONDecoder().decode(WorldPoint.self, from: Data("[12.5,-8]".utf8))
        #expect(point == WorldPoint(x: 12.5, y: -8))
        for text in ["[]", "[1]", "[1,2,3]", "[true,2]", "[1000000001,0]", "{\"x\":1,\"y\":2}"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(WorldPoint.self, from: Data(text.utf8)) }
        }
    }

    @Test func everyBrushHasValidatedImmutablePayloadWithoutServerFields() throws {
        for brush in [BrushKind.round, .square, .chisel, .spray] {
            let payload = try M2TestSupport.payload(brush: brush)
            let data = try ClientMessage.create(requestID: "r1", stroke: payload).jsonData()
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let stroke = try #require(object["stroke"] as? [String: Any])
            #expect(stroke["brush"] as? String == brush.rawValue)
            #expect(stroke["color"] as? String == "#ABCDEF")
            #expect(Set(stroke.keys) == Set(["id", "points", "brush", "width", "color", "opacity"]))
            #expect(try JSONDecoder().decode(StrokePayload.self, from: JSONSerialization.data(withJSONObject: stroke)) == payload)
        }
    }

    @Test func invalidPayloadsCannotBeConstructedOrDecoded() throws {
        for width in [0.0, 65, .infinity] {
            #expect(throws: DrawingDataError.invalidMessage) {
                try StrokePayload(id: UUID(), points: [.zero], brush: .round, width: width, color: "#202020", opacity: 1)
            }
        }
        #expect(throws: DrawingDataError.invalidMessage) {
            try StrokePayload(id: UUID(), points: [.zero, WorldPoint(x: 100001, y: 0)], brush: .round,
                              width: 6, color: "#202020", opacity: 1)
        }
        var invalid = try M2TestSupport.object(M2TestSupport.payload())
        invalid["brush"] = "future-unsupported-brush"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StrokePayload.self, from: JSONSerialization.data(withJSONObject: invalid)) }
        invalid["brush"] = "round"; invalid["points"] = []
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StrokePayload.self, from: JSONSerialization.data(withJSONObject: invalid)) }
    }

    @Test func clientMessagesRespectIdentifierByteLimitsAndStableRetryPayload() throws {
        let payload = try M2TestSupport.payload()
        #expect(throws: DrawingDataError.invalidMessage) { try ClientMessage.create(requestID: "", stroke: payload).jsonData() }
        #expect(throws: DrawingDataError.invalidMessage) {
            try ClientMessage.create(requestID: String(repeating: "я", count: 65), stroke: payload).jsonData()
        }
        let first = try ClientMessage.create(requestID: "first", stroke: payload).jsonData()
        let retry = try ClientMessage.create(requestID: "retry", stroke: payload).jsonData()
        let a = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let b = try #require(JSONSerialization.jsonObject(with: retry) as? [String: Any])
        #expect((a["stroke"] as? NSDictionary) == (b["stroke"] as? NSDictionary))
        let secret = try SessionSecret(bytes: Data(repeating: 0, count: 32))
        let hello = try #require(JSONSerialization.jsonObject(with: ClientMessage.hello(secret).jsonData()) as? [String: Any])
        #expect(hello["session_secret"] as? String == secret.base64URLValue)
    }

    @Test func viewportBoundsHaveServerSpanAndWorldLimits() throws {
        let bounds = try WireBounds(minX: -500, minY: -500, maxX: 500, maxY: 500)
        let data = try ClientMessage.subscribe(id: "view-1", bounds: bounds).jsonData()
        #expect(String(decoding: data, as: UTF8.self).contains("min_x"))
        #expect(throws: DrawingDataError.invalidMessage) { try WireBounds(minX: 0, minY: 0, maxX: 30001, maxY: 1) }
        #expect(throws: DrawingDataError.invalidMessage) { try WireBounds(minX: 0, minY: 0, maxX: 0, maxY: 1) }
        #expect(throws: DrawingDataError.invalidMessage) { try WireBounds(minX: 0, minY: 0, maxX: .nan, maxY: 1) }
    }

    @Test func helloValidatesVersionAndOptionalSpawn() throws {
        #expect(try message(["type": "hello.ack", "protocol_version": 1]) == .hello(spawn: nil))
        #expect(try message(["type": "hello.ack", "protocol_version": 1, "spawn": ["x": 5, "y": -10]]) == .hello(spawn: WorldPoint(x: 5, y: -10)))
        #expect(throws: DrawingDataError.unsupportedProtocol) { try message(["type": "hello.ack", "protocol_version": 2]) }
        #expect(throws: DrawingDataError.invalidMessage) {
            try message(["type": "hello.ack", "protocol_version": 1, "spawn": ["x": 1000000001, "y": 0]])
        }
    }

    @Test func snapshotAndLiveFramesDecodeAllFourShapes() throws {
        #expect(try message(["type": "viewport.snapshot.begin", "subscription_id": "v1"]) == .snapshotBegin(id: "v1"))
        #expect(try message(["type": "viewport.snapshot.end", "subscription_id": "v1"]) == .snapshotEnd(id: "v1"))
        let objects = try [BrushKind.round, .square, .chisel, .spray].enumerated().map {
            try M2TestSupport.object(M2TestSupport.payload(brush: $0.element), sequence: Int64($0.offset + 1), own: false)
        }
        let chunk = try message(["type": "viewport.snapshot.chunk", "subscription_id": "v1", "strokes": objects])
        guard case .snapshotChunk(let id, let strokes) = chunk else { Issue.record("Wrong snapshot case"); return }
        #expect(id == "v1" && strokes.count == 4)
        #expect(strokes.map(\.payload.brush) == [.round, .square, .chisel, .spray])
        let event = try message(["type": "stroke.created", "subscription_id": "v1", "stroke": objects[0]])
        #expect(event == .created(id: "v1", stroke: strokes[0]))
    }

    @Test func sequenceLimitsOwnershipAndDeleteAcksAreValidated() throws {
        let payload = try M2TestSupport.payload()
        let object = try M2TestSupport.object(payload)
        let confirmed = try M2TestSupport.confirmed(payload)
        #expect(try message(["type": "ack", "operation": "stroke.create", "request_id": "r1", "stroke": object]) == .createAcknowledged(requestID: "r1", stroke: confirmed))
        var foreign = object; foreign["own"] = false
        #expect(throws: DrawingDataError.invalidMessage) { try message(["type": "ack", "operation": "stroke.create", "request_id": "r1", "stroke": foreign]) }
        #expect(try message(["type": "ack", "operation": "stroke.delete", "request_id": "r2", "stroke_id": payload.id.uuidString,
                             "seq": 1, "already_deleted": true]) == .deleteAcknowledged(requestID: "r2", strokeID: payload.id, sequence: 1, alreadyDeleted: true))
        #expect(try message(["type": "stroke.deleted", "subscription_id": "v1", "stroke_id": payload.id.uuidString, "seq": 1]) == .deleted(id: "v1", strokeID: payload.id, sequence: 1))
        for sequence in [Int64(0), -1, WireLimits.maximumSequence + 1] {
            var invalid = object; invalid["seq"] = sequence
            #expect(throws: DrawingDataError.invalidMessage) { try message(["type": "stroke.created", "subscription_id": "v1", "stroke": invalid]) }
        }
    }

    @Test func limitsMalformedFramesAndSafeErrorPayload() throws {
        let error = try message(["type": "error", "request_id": "r1", "code": "forbidden", "message": "untrusted diagnostics"])
        #expect(error == .error(requestID: "r1", subscriptionID: nil, code: "forbidden"))
        #expect(!String(reflecting: error).contains("untrusted diagnostics"))
        #expect(throws: DrawingDataError.invalidMessage) { try ServerMessage.decode(Data("not-json".utf8)) }
        #expect(throws: DrawingDataError.invalidMessage) { try message(["type": "unknown-message"]) }
        #expect(throws: DrawingDataError.limitExceeded) { try ServerMessage.decode(Data(repeating: 0, count: WireLimits.maximumServerBytes + 1)) }
        #expect(throws: DrawingDataError.limitExceeded) {
            try message(["type": "viewport.snapshot.chunk", "subscription_id": "v1", "strokes": Array(repeating: [:], count: 1001)])
        }
    }
}
