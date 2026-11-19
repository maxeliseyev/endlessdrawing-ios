import CryptoKit
import Foundation
import Testing
@testable import Endless_Drawing

struct SessionCodecTests {
    @Test func negotiatesOfferedV5ThroughV1InPreferenceOrderAndNeverGuesses() throws {
        let policy = TransportPolicy.negotiated
        #expect(policy.offeredProtocols == ["endless-drawing.msgpack.v5", "endless-drawing.msgpack.v4", "endless-drawing.msgpack.v3",
                                            "endless-drawing.msgpack.v2", "endless-drawing.json.v1"])
        #expect(try policy.selected(TransportProfile.safetyProtocol) == .messagePackV5)
        #expect(try policy.selected(TransportProfile.priorityProtocol) == .messagePackV4)
        #expect(try policy.selected(TransportProfile.manifestProtocol) == .messagePackV3)
        #expect(try policy.selected(TransportProfile.messagePackProtocol) == .messagePackV2)
        #expect(try policy.selected(TransportProfile.jsonProtocol) == .jsonV1)
        for value in [nil, "", "endless-drawing.msgpack.v6", "endless-drawing.json.v2", "unoffered-profile"] {
            #expect(throws: TransportFailure.unexpectedProfile) { try policy.selected(value) }
        }
        #expect(TransportPolicy.legacyJSONV1.offeredProtocols.isEmpty)
        #expect(try TransportPolicy.legacyJSONV1.selected(nil) == .legacyJSONV1)
        #expect(throws: TransportFailure.unexpectedProfile) { try TransportPolicy.legacyJSONV1.selected(TransportProfile.jsonProtocol) }
        for profile in [TransportProfile.messagePackV2, .messagePackV3, .messagePackV4, .messagePackV5] {
            #expect(profile.isMessagePack && profile.maximumServerBytes == 256 * 1024)
        }
    }

    @Test func frameTypesAndHelloVersionsMatchTheSelectedProfile() throws {
        let binary = SessionCodec(profile: .messagePackV2)
        let json = SessionCodec(profile: .jsonV1)
        let hello = try SessionSecret(bytes: Data(repeating: 1, count: 32))
        guard case .binary = try binary.encode(.hello(hello)), case .text = try json.encode(.hello(hello)) else {
            Issue.record("Incorrect outbound message type"); return
        }
        let v2Hello = try BoundedMessagePack.encode(["type": FixtureValue.string("hello.ack"), "protocol_version": .integer(2)])
        let v1Hello = try BoundedMessagePack.encode(["type": FixtureValue.string("hello.ack"), "protocol_version": .integer(1)])
        #expect(try binary.decode(.binary(v2Hello)) == .hello(spawn: nil))
        #expect(try json.decode(.text("{\"type\":\"hello.ack\",\"protocol_version\":1}")) == .hello(spawn: nil))
        #expect(throws: TransportFailure.incompatibleVersion) { try binary.decode(.binary(v1Hello)) }
        #expect(throws: TransportFailure.incompatibleVersion) { try json.decode(.text("{\"type\":\"hello.ack\",\"protocol_version\":2}")) }
        #expect(throws: TransportFailure.wrongMessageType) { try binary.decode(.text("{}")) }
        #expect(throws: TransportFailure.wrongMessageType) { try json.decode(.binary(Data([0x80]))) }
    }

    @Test func sharedCorpusHashesAndBothEncodersDecodeWithoutPrecisionLoss() throws {
        let manifest = try JSONDecoder().decode([String: String].self, from: V2Fixtures.data("sha256.json"))
        for (filename, expected) in manifest {
            let data = try V2Fixtures.data(filename)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected, "\(filename)")
        }
        for sample in try V2Fixtures.samples() {
            for encoder in ["ts", "rust"] {
                let data = try V2Fixtures.data("\(sample.name).\(encoder).msgpack")
                let value = try BoundedMessagePack.decode(FixtureValue.self, from: data)
                #expect(value == sample.value, "\(sample.name).\(encoder)")
            }
        }
    }

    @Test func exportsTemporarySwiftOutputForIndependentJSDecoderVerification() throws {
        // Actual-output artifacts, not regeneration or modification of the pinned expected corpus.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ws-v2-swift-interop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sample in try V2Fixtures.samples() {
            let bytes = try BoundedMessagePack.encode(sample.value)
            try bytes.write(to: directory.appendingPathComponent("\(sample.name).swift.msgpack"))
            #expect(try BoundedMessagePack.decode(FixtureValue.self, from: bytes) == sample.value)
        }
    }

    @Test func sharedCorpusIsCodecSemanticNotPermissionToRelaxDomainExtents() throws {
        let codec = SessionCodec(profile: .messagePackV2)
        #expect(try codec.decode(.binary(V2Fixtures.data("welcome.rust.msgpack"))) == .hello(spawn: WorldPoint(x: 999999999.125, y: -999999999.0625)))
        // These fixtures intentionally span ~1e9 units. Preserve codec parity, but the app's 100000 extent guard still applies.
        for name in ["snapshot-chunk", "created", "create-ack"] {
            #expect(throws: TransportFailure.malformedMessage) { try codec.decode(.binary(V2Fixtures.data("\(name).rust.msgpack"))) }
        }
    }

    @Test func validNativeDTOsDecodeMixedIntegerAndDoubleGeometry() throws {
        let values: [String: FixtureValue] = [
            "type": .string("stroke.created"), "subscription_id": .string("v"),
            "stroke": .object(["id": .string("87a122fa-7537-4b88-9b77-b45d24a29714"),
                               "points": .array([.array([.integer(0), .double(-0.25)]), .array([.double(10.125), .integer(-2)])]),
                               "brush": .string("round"), "width": .integer(6), "color": .string("#aabbcc"),
                               "opacity": .double(0.5), "seq": .integer(WireLimits.maximumSequence), "own": .bool(false)])]
        let bytes = try BoundedMessagePack.encode(values)
        let decoded = try SessionCodec(profile: .messagePackV2).decode(.binary(bytes))
        guard case .created(let id, let stroke) = decoded else { Issue.record("Expected created"); return }
        #expect(id == "v" && stroke.sequence == WireLimits.maximumSequence && !stroke.own)
        #expect(stroke.payload.points == [WorldPoint(x: 0, y: -0.25), WorldPoint(x: 10.125, y: -2)])
        #expect(stroke.payload.color == "#AABBCC")
    }

    @Test func actualClientEncodingKeepsDoubleAndUUIDStrings() throws {
        let payload = try StrokePayload(id: UUID(), points: [WorldPoint(x: 999999999.125, y: -999999999.0625)],
                                        brush: .chisel, width: 6.25, color: "#aabbcc", opacity: 0.125)
        let packet = try SessionCodec(profile: .messagePackV2).encode(.create(requestID: "r1", stroke: payload))
        guard case .binary(let bytes) = packet else { Issue.record("Expected binary"); return }
        struct Create: Decodable { let type: String; let request_id: String; let stroke: StrokePayload }
        let decoded = try BoundedMessagePack.decode(Create.self, from: bytes)
        #expect(decoded.type == "stroke.create" && decoded.request_id == "r1")
        #expect(decoded.stroke == payload)
        #expect(bytes.contains(0xcb)) // double tag present; preflight would reject every float32 tag
    }

    @Test func binaryChunkPointBudgetDoesNotTightenJSONCompatibility() throws {
        let points = Array(repeating: WorldPoint.zero, count: 2000)
        let payload = try StrokePayload(id: UUID(), points: points, brush: .round, width: 1, color: "#202020", opacity: 1)
        let stroke = try M2TestSupport.object(payload)
        let jsonObject: [String: Any] = ["type": "viewport.snapshot.chunk", "subscription_id": "v", "strokes": Array(repeating: stroke, count: 5)]
        let jsonBytes = try JSONSerialization.data(withJSONObject: jsonObject)
        let semantic = try JSONDecoder().decode(FixtureValue.self, from: jsonBytes)
        let binaryBytes = try BoundedMessagePack.encode(semantic, maximumBytes: 256 * 1024)
        #expect(throws: TransportFailure.malformedMessage) { try SessionCodec(profile: .messagePackV2).decode(.binary(binaryBytes)) }
        guard case .snapshotChunk = try SessionCodec(profile: .jsonV1).decode(.text(String(decoding: jsonBytes, as: UTF8.self))) else {
            Issue.record("Legacy JSON point budget changed"); return
        }
    }

    @Test func unresolvedJSONAttemptCanRetryAsBinaryWithoutChangingJournalIdentityOrUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codec-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JournalFileStorage(url: directory.appendingPathComponent("journal.json"))
        let environment = try M2TestSupport.environment(), owner = UUID()
        let original = try await OperationJournal.open(environment: environment, identityID: owner, storage: storage)
        let payload = try M2TestSupport.payload()
        try await original.enqueueCreate(payload)
        let first = try await original.markMayHaveBeenSent(payload.id)
        let json = try SessionCodec(profile: .jsonV1).encode(first.message(requestID: "lost-json-ack"))
        let restored = try await OperationJournal.open(environment: environment, identityID: owner, storage: storage)
        let retried = try await restored.markMayHaveBeenSent(payload.id)
        let binary = try SessionCodec(profile: .messagePackV2).encode(retried.message(requestID: "binary-retry"))
        struct Create: Decodable { let stroke: StrokePayload }
        guard case .text(let text) = json, case .binary(let data) = binary else { Issue.record("Wrong encoding"); return }
        #expect(try JSONDecoder().decode(Create.self, from: Data(text.utf8)).stroke == payload)
        #expect(try BoundedMessagePack.decode(Create.self, from: data).stroke == payload)
        #expect(await restored.snapshot().identityID == owner)
        #expect(await restored.snapshot().environment == environment)
        let acknowledged = try M2TestSupport.confirmed(payload)
        #expect(try await restored.acknowledgeCreate(operationID: payload.id, stroke: acknowledged))
        #expect(try await restored.acknowledgeCreate(operationID: payload.id, stroke: acknowledged) == false)
        #expect(await restored.snapshot().undo.map(\.strokeID) == [payload.id])
    }

    @Test func encoderFloat64AdapterPreservesEveryDoubleBitAndAppliesExpandedSizeCap() throws {
        let values = [-0.0, 0.125, 6.25, 999999999.125, -999999999.0625, Double.leastNonzeroMagnitude]
        let bytes = try BoundedMessagePack.encode(["values": values])
        try MessagePackPreflight.validate(bytes) // float32 is still forbidden on input
        let restored = try BoundedMessagePack.decode([String: [Double]].self, from: bytes)
        #expect(restored["values"]?.map(\.bitPattern) == values.map(\.bitPattern))
        #expect(throws: TransportFailure.messageTooLarge) {
            try BoundedMessagePack.encode(["values": Array(repeating: 0.5, count: 2000)], maximumBytes: 12_000)
        }
    }

    @Test func twoThousandPointGeometryRoundTripsAndMeetsPayloadSizeTarget() throws {
        let points = (0..<2000).map { WorldPoint(x: 5000 + sin(Double($0) * 0.03) * 400,
                                                y: -7000 + cos(Double($0) * 0.07) * 300) }
        let payload = try StrokePayload(id: UUID(), points: points, brush: .spray, width: 6.25, color: "#202020", opacity: 0.5)
        let message = ClientMessage.create(requestID: "geometry-size-test", stroke: payload)
        let json = try message.jsonData()
        let binary = try SessionCodec(profile: .messagePackV2).encode(message)
        #expect(Double(binary.byteCount) <= Double(json.count) * 0.60)
        print("Synthetic 2000-point application bytes: JSON=\(json.count), MessagePack=\(binary.byteCount)")
        struct Create: Decodable { let stroke: StrokePayload }
        guard case .binary(let data) = binary else { Issue.record("Expected binary"); return }
        #expect(try BoundedMessagePack.decode(Create.self, from: data).stroke == payload)
    }

    @Test func profileByteLimitsAndCloseCodesAreStable() throws {
        #expect(TransportProfile.messagePackV2.maximumServerBytes == 256 * 1024)
        #expect(TransportProfile.jsonV1.maximumServerBytes == 4 * 1024 * 1024)
        #expect(TransportFailure.malformedMessage.closeCode == 1007)
        #expect(TransportFailure.wrongMessageType.closeCode == 1003)
        #expect(throws: TransportFailure.messageTooLarge) { try MessagePackPreflight.validate(Data(repeating: 0, count: 256 * 1024 + 1)) }
        #expect(throws: TransportFailure.messageTooLarge) { try SessionCodec(profile: .jsonV1).decode(.text(String(repeating: "я", count: 2 * 1024 * 1024 + 1))) }
    }
}
