import CryptoKit
import Foundation
import Testing
@testable import Endless_Drawing

/// Pinned backend v3/v4 corpus (files carry a `ws-vN.` prefix because test resources are bundled flat).
nonisolated enum VersionedFixtures {
    static func data(_ version: Int, _ filename: String) throws -> Data { try V2Fixtures.data("ws-v\(version).\(filename)") }
    static func samples(_ version: Int) throws -> [V2Fixtures.Sample] {
        try JSONDecoder().decode([V2Fixtures.Sample].self, from: data(version, "corpus.json"))
    }
    static func sample(_ version: Int, _ name: String) throws -> FixtureValue {
        try #require(try samples(version).first { $0.name == name }).value
    }
}

struct ManifestProtocolTests {
    private let token = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let a = UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!
    private let b = UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!

    private func bounds(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) throws -> WireBounds {
        try WireBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Native client encoding, decoded as plain MessagePack, must equal the corpus value.
    private func encoded(_ message: ClientMessage, _ profile: TransportProfile) throws -> FixtureValue {
        guard case .binary(let bytes) = try SessionCodec(profile: profile).encode(message) else {
            Issue.record("Expected Binary for \(profile)"); return .object([:])
        }
        return try BoundedMessagePack.decode(FixtureValue.self, from: bytes)
    }

    @Test func pinnedCorpusHashesAndBothEncodersDecode() throws {
        for version in [3, 4] {
            let manifest = try JSONDecoder().decode([String: String].self, from: VersionedFixtures.data(version, "sha256.json"))
            #expect(!manifest.isEmpty)
            for (filename, expected) in manifest {
                let actual = SHA256.hash(data: try VersionedFixtures.data(version, filename)).map { String(format: "%02x", $0) }.joined()
                #expect(actual == expected, "v\(version) \(filename)")
            }
            for sample in try VersionedFixtures.samples(version) {
                for encoder in ["ts", "rust"] {
                    let value = try BoundedMessagePack.decode(FixtureValue.self,
                                                              from: VersionedFixtures.data(version, "\(sample.name).\(encoder).msgpack"))
                    #expect(value == sample.value, "v\(version) \(sample.name).\(encoder)")
                }
            }
        }
    }

    @Test func serverMessagesDecodeFromBothEncodersOnTheirProfiles() throws {
        let v3 = SessionCodec(profile: .messagePackV3), v4 = SessionCodec(profile: .messagePackV4)
        let expectations: [(String, ServerMessage)] = [
            ("welcome", .hello(spawn: nil)),
            ("manifest-begin", .manifestBegin(id: "view-1", token: token, strokeCount: 2, pointCount: 4)),
            ("manifest-chunk", .manifestChunk(id: "view-1", token: token, strokeIDs: [a, b])),
            ("manifest-end", .manifestEnd(id: "view-1", token: token)),
            ("fetch-end", .fetchEnd(id: "view-1", token: token, batch: 0)),
            ("fallback-busy", .snapshotFallback(id: "view-1", reason: .busy)),
            ("fallback-scene_limit", .snapshotFallback(id: "view-1", reason: .sceneLimit)),
        ]
        for encoder in ["ts", "rust"] {
            for (name, expected) in expectations {
                let bytes = try VersionedFixtures.data(3, "\(name).\(encoder).msgpack")
                #expect(try v3.decode(.binary(bytes)) == expected, "\(name).\(encoder)")
                if name != "welcome" { #expect(try v4.decode(.binary(bytes)) == expected, "v4 \(name).\(encoder)") }
                // Manifest messages never exist on a v2 socket; hello versions must match exactly.
                #expect(throws: (any Error).self) { try SessionCodec(profile: .messagePackV2).decode(.binary(bytes)) }
            }
            #expect(try v4.decode(.binary(VersionedFixtures.data(4, "welcome-priority.\(encoder).msgpack"))) == .hello(spawn: nil))
            #expect(throws: TransportFailure.incompatibleVersion) {
                try v3.decode(.binary(VersionedFixtures.data(4, "welcome-priority.\(encoder).msgpack")))
            }
        }
    }

    @Test func clientMessagesMatchTheCorpusExactly() throws {
        let full = try bounds(-1500, -1050, 1500, 1050), visible = try bounds(-500, -350, 500, 350)
        let id4 = "00000000-0000-4000-8000-000000000001"
        #expect(try encoded(.subscribe(id: id4, bounds: full, visible: visible), .messagePackV4) == VersionedFixtures.sample(4, "priority-full"))
        #expect(try encoded(.subscribeCached(id: id4, bounds: full, visible: visible), .messagePackV4)
                == VersionedFixtures.sample(4, "priority-cached"))
        let small = try bounds(-100, -100, 100, 100)
        #expect(try encoded(.subscribeCached(id: "view-1", bounds: small), .messagePackV3) == VersionedFixtures.sample(3, "cached-subscribe"))
        let fetches: [(String, ClientMessage)] = [
            ("fetch-partial", .fetch(subscriptionID: "view-1", token: token, batch: 0, strokeIDs: [b], final: true)),
            ("fetch-more", .fetch(subscriptionID: "view-1", token: token, batch: 0, strokeIDs: [a], final: false)),
            ("fetch-empty", .fetch(subscriptionID: "view-1", token: token, batch: 0, strokeIDs: [], final: true)),
        ]
        for (name, message) in fetches { #expect(try encoded(message, .messagePackV3) == VersionedFixtures.sample(3, name), "\(name)") }
    }

    @Test func profileShapeIsEnforcedBeforeAnythingIsSent() throws {
        let full = try bounds(-1500, -1050, 1500, 1050), visible = try bounds(-500, -350, 500, 350)
        // v4 requires the hint, earlier profiles forbid it; cached/fetch need v3+.
        #expect(throws: TransportFailure.malformedMessage) { try SessionCodec(profile: .messagePackV4).encode(.subscribe(id: "s", bounds: full)) }
        #expect(throws: TransportFailure.malformedMessage) {
            try SessionCodec(profile: .messagePackV3).encode(.subscribe(id: "s", bounds: full, visible: visible))
        }
        #expect(throws: TransportFailure.malformedMessage) { try SessionCodec(profile: .messagePackV2).encode(.subscribeCached(id: "s", bounds: full)) }
        #expect(throws: TransportFailure.malformedMessage) {
            try SessionCodec(profile: .jsonV1).encode(.fetch(subscriptionID: "s", token: UUID(), batch: 0, strokeIDs: [], final: true))
        }
        // The hint must lie inside the subscription; batches are bounded.
        let outside = try bounds(1000, 1000, 2000, 2000)
        #expect(throws: (any Error).self) { try SessionCodec(profile: .messagePackV4).encode(.subscribe(id: "s", bounds: full, visible: outside)) }
        #expect(throws: (any Error).self) {
            try SessionCodec(profile: .messagePackV3).encode(.fetch(subscriptionID: "s", token: UUID(), batch: 21, strokeIDs: [], final: true))
        }
        #expect(full.intersection(outside) == (try bounds(1000, 1000, 1500, 1050)))
        #expect(full.intersection(try bounds(2000, 2000, 3000, 3000)) == nil)
    }

    @Test func manifestCountsAndIdsAreValidatedOnDecode() throws {
        let codec = SessionCodec(profile: .messagePackV3)
        func message(_ map: [String: FixtureValue]) throws -> WebSocketPacket { .binary(try BoundedMessagePack.encode(map)) }
        let base: [String: FixtureValue] = ["type": .string("viewport.manifest.begin"), "subscription_id": .string("s"),
                                            "snapshot_token": .string(token.uuidString.lowercased())]
        func begin(_ count: Int64, _ points: Int64) throws -> WebSocketPacket {
            var map = base; map["stroke_count"] = .integer(count); map["point_count"] = .integer(points); return try message(map)
        }
        #expect(try codec.decode(begin(0, 0)) == .manifestBegin(id: "s", token: token, strokeCount: 0, pointCount: 0))
        for (count, points) in [(Int64(2), Int64(1)), (20_001, 20_001), (1, 2001), (600, 1_000_001)] {
            #expect(throws: TransportFailure.malformedMessage) { try codec.decode(begin(count, points)) }
        }
        var badToken = base; badToken["snapshot_token"] = .string("not-a-uuid"); badToken["stroke_count"] = .integer(0); badToken["point_count"] = .integer(0)
        #expect(throws: TransportFailure.malformedMessage) { try codec.decode(message(badToken)) }
        var tooMany = base; tooMany["type"] = .string("viewport.manifest.chunk")
        tooMany["stroke_ids"] = .array((0..<1001).map { _ in .string(UUID().uuidString.lowercased()) })
        #expect(throws: (any Error).self) { try codec.decode(message(tooMany)) }
        let unknownReason: [String: FixtureValue] = ["type": .string("viewport.snapshot.fallback"), "subscription_id": .string("s"),
                                                     "reason": .string("later")]
        #expect(throws: TransportFailure.malformedMessage) { try codec.decode(message(unknownReason)) }
    }
}
