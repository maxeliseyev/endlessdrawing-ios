import CryptoKit
import Foundation
import MessagePack
import Testing
@testable import Endless_Drawing

struct CompactProtocolTests {
    private let codec = SessionCodec(profile: .messagePackV6)
    private let id = UUID(uuidString: "87a122fa-7537-4b88-9b77-b45d24a29714")!
    private func stroke(_ path: [FixtureValue]) -> [String: FixtureValue] {
        ["id": .string(id.uuidString.lowercased()), "path": .array(path), "brush": .string("round"),
         "width": .integer(4), "color": .string("#E46C60"), "opacity": .integer(1),
         "seq": .integer(42), "own": .bool(true), "author": .string("AAAAAAAAAAAAAAAAAAAAAA")]
    }
    private func created(_ stroke: [String: FixtureValue]) -> [String: FixtureValue] {
        ["type": .string("stroke.created"), "subscription_id": .string("s"), "stroke": .object(stroke)]
    }
    private func packet(_ value: [String: FixtureValue]) throws -> WebSocketPacket {
        // Trusted test server output; the client encoder deliberately keeps its 2000-element cap.
        .binary(try MessagePackTestServer.encode(value))
    }

    @Test func deltaPointsDecodeAcrossSnapshotFetchLiveAndAcknowledgement() throws {
        let value = stroke([160, -40, 1, 1, 127, -32].map { .integer($0) })
        let expected = [WorldPoint(x: 10, y: -2.5), WorldPoint(x: 10.0625, y: -2.4375), WorldPoint(x: 18, y: -4.4375)]
        guard case .created(_, let live) = try codec.decode(packet(created(value))) else { Issue.record("created"); return }
        #expect(live.payload.points == expected && live.author == "AAAAAAAAAAAAAAAAAAAAAA")
        let ack: [String: FixtureValue] = ["type": .string("ack"), "operation": .string("stroke.create"),
                                           "request_id": .string("r"), "stroke": .object(value)]
        guard case .createAcknowledged(_, let acknowledged) = try codec.decode(packet(ack)) else { Issue.record("ack"); return }
        #expect(acknowledged == live)
        let chunk: [String: FixtureValue] = ["type": .string("viewport.snapshot.chunk"), "subscription_id": .string("s"),
                                             "strokes": .array([.object(value)])]
        guard case .snapshotChunk(_, let records) = try codec.decode(packet(chunk)) else { Issue.record("chunk"); return }
        #expect(records == [live])
    }

    @Test func serverArrayLimitAndPointBudgetDoNotChangeClientLimits() throws {
        let full = stroke(Array(repeating: .integer(1), count: 4000))
        guard case .created(_, let record) = try codec.decode(packet(created(full))) else { Issue.record("created"); return }
        #expect(record.payload.points.count == 2000)
        #expect(record.payload.points.last == WorldPoint(x: 125, y: 125))
        for count in [4, 5] {
            let chunk: [String: FixtureValue] = ["type": .string("viewport.snapshot.chunk"), "subscription_id": .string("s"),
                "strokes": .array(Array(repeating: .object(full), count: count))]
            if count == 4 { _ = try codec.decode(packet(chunk)) }
            else { #expect(throws: TransportFailure.malformedMessage) { try codec.decode(packet(chunk)) } }
        }
        #expect(throws: TransportFailure.malformedMessage) { try BoundedMessagePack.encode(["path": Array(repeating: 0, count: 4000)]) }
    }

    @Test func rejectsWrongProfileShapeFloatTagsAndInvalidCoordinates() throws {
        let invalid: [[FixtureValue]] = [[], [.integer(0)], [.integer(0), .integer(0), .integer(1)],
            [.double(1), .integer(0)], [.bool(true), .integer(0)], [.integer(16_000_000_001), .integer(0)],
            [.integer(16_000_000_000), .integer(0), .integer(1), .integer(0)],
            [.integer(WireLimits.maximumSequence), .integer(0)], Array(repeating: .integer(0), count: 4002)]
        for path in invalid {
            #expect(throws: TransportFailure.malformedMessage) { try codec.decode(packet(created(stroke(path)))) }
        }
        // The library may coerce integral floats to Int64; preflight must reject their wire tag.
        guard case .binary(var floatPath) = try packet(created(stroke([.integer(1), .integer(0)]))),
              let pathHeader = floatPath.range(of: Data([0xa4, 0x70, 0x61, 0x74, 0x68, 0x92])) else {
            Issue.record("Missing path fixture header"); return
        }
        floatPath.replaceSubrange(pathHeader.upperBound..<(pathHeader.upperBound + 1),
                                  with: [0xcb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0])
        #expect(throws: TransportFailure.malformedMessage) { try codec.decode(.binary(floatPath)) }
        var old = stroke([.integer(0), .integer(0)])
        old["points"] = .array([.array([.integer(0), .integer(0)])])
        #expect(throws: TransportFailure.malformedMessage) { try codec.decode(packet(created(old))) }
        old.removeValue(forKey: "path")
        #expect(throws: TransportFailure.malformedMessage) { try codec.decode(packet(created(old))) }
        _ = try SessionCodec(profile: .messagePackV5).decode(packet(created(old)))
        #expect(throws: TransportFailure.malformedMessage) {
            try SessionCodec(profile: .messagePackV5).decode(packet(created(stroke([.integer(0), .integer(0)]))))
        }
        let edge = stroke([.integer(16_000_000_000), .integer(-16_000_000_000), .integer(-1), .integer(1)])
        guard case .created(_, let record) = try codec.decode(packet(created(edge))) else { Issue.record("created"); return }
        #expect(record.payload.points.last == WorldPoint(x: 1e9 - 1 / 16, y: -1e9 + 1 / 16))
    }

    @Test func roundedAckCommitsJournalUndoWithoutChangingFullPrecisionUplink() async throws {
        let draft = try StrokePayload(id: id, points: [WorldPoint(x: 0.03125, y: -0.03125), WorldPoint(x: 0.099, y: -0.099)],
                                      brush: .round, width: 4, color: "#E46C60", opacity: 1)
        let decoded = try codec.decode(packet(created(stroke([.integer(1), .integer(-1), .integer(1), .integer(-1)]))))
        guard case .created(_, let acknowledged) = decoded else { Issue.record("created"); return }
        #expect(draft != acknowledged.payload)
        #expect(draft.matchesAcknowledgement(acknowledged.payload, compact: true))
        #expect(!draft.matchesAcknowledgement(acknowledged.payload, compact: false))
        let wrong = try StrokePayload(id: id, points: [.zero, .zero], brush: .round, width: 4, color: "#E46C60", opacity: 1)
        #expect(!draft.matchesAcknowledgement(wrong, compact: true))
        guard case .binary(let uplink) = try codec.encode(.create(requestID: "r", stroke: draft)) else { Issue.record("binary"); return }
        struct Create: Decodable { let stroke: StrokePayload }
        #expect(try BoundedMessagePack.decode(Create.self, from: uplink).stroke == draft)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compact-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await OperationJournal.open(environment: M2TestSupport.environment(), identityID: UUID(),
            storage: JournalFileStorage(url: directory.appendingPathComponent("journal.json")))
        _ = try await journal.enqueueCreate(draft)
        _ = try await journal.markMayHaveBeenSent(id)
        #expect(try await journal.acknowledgeCreate(operationID: id, stroke: acknowledged, compact: true))
        #expect(await journal.snapshot().operations.isEmpty)
        #expect(await journal.snapshot().undo.map(\.strokeID) == [id])
    }

    @Test func sharedBackendFixturesPinBothEncodersAndKeepDomainGuards() throws {
        final class BundleToken: NSObject {}
        let bundle = Bundle(for: BundleToken.self)
        func data(_ name: String) throws -> Data {
            guard let url = bundle.url(forResource: "ws-v6." + name, withExtension: nil, subdirectory: "ws-v6")
                ?? bundle.url(forResource: "ws-v6." + name, withExtension: nil) else { throw DrawingDataError.invalidMessage }
            return try Data(contentsOf: url)
        }
        let hashes = try JSONDecoder().decode([String: String].self, from: data("sha256.json"))
        for (name, hash) in hashes {
            #expect(try SHA256.hash(data: data(name)).map { String(format: "%02x", $0) }.joined() == hash)
        }
        let samples = try JSONDecoder().decode([V2Fixtures.Sample].self, from: data("corpus.json"))
        for sample in samples { for encoder in ["ts", "rust"] {
            let bytes = try data("\(sample.name).\(encoder).msgpack")
            #expect(try BoundedMessagePack.decode(FixtureValue.self, from: bytes, protocolVersion: 6) == sample.value)
            if sample.name == "snapshot-compact" {
                // Codec-only fixture intentionally crosses world/span boundaries.
                #expect(throws: TransportFailure.malformedMessage) { try codec.decode(.binary(bytes)) }
            } else { _ = try codec.decode(.binary(bytes)) }
        } }
    }
}

// Only fixture generation bypasses the client array cap, never production encoding.
private enum MessagePackTestServer {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try MessagePackEncoder().encode(value)
    }
}
