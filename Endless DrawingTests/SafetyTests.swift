import Foundation
import Testing
@testable import Endless_Drawing

/// App Review 1.2 client side: protocol v5, local hiding, report hit testing, terms and reports in the model.
@MainActor
struct SafetyTests {
    private let id = "87a122fa-7537-4b88-9b77-b45d24a29714"
    private let tag = "AbCdEfGhIjKlMnOpQr_-12"

    private func created(author: String?) -> [String: FixtureValue] {
        var stroke: [String: FixtureValue] = ["id": .string(id), "points": .array([.array([.integer(0), .integer(0)])]),
            "brush": .string("round"), "width": .integer(6), "color": .string("#202020"), "opacity": .integer(1),
            "seq": .integer(3), "own": .bool(false)]
        if let author { stroke["author"] = .string(author) }
        return ["type": .string("stroke.created"), "subscription_id": .string("s"), "stroke": .object(stroke)]
    }

    @Test func v5StrokesCarryAValidatedAuthorTagThatEarlierProfilesRefuse() throws {
        let v5 = SessionCodec(profile: .messagePackV5), v4 = SessionCodec(profile: .messagePackV4)
        guard case .created(_, let stroke) = try v5.decode(.binary(BoundedMessagePack.encode(created(author: tag)))) else {
            Issue.record("Expected created"); return
        }
        #expect(stroke.author == tag)
        #expect(throws: TransportFailure.malformedMessage) { try v5.decode(.binary(BoundedMessagePack.encode(created(author: nil)))) }
        #expect(throws: TransportFailure.malformedMessage) { try v5.decode(.binary(BoundedMessagePack.encode(created(author: "short")))) }
        #expect(throws: TransportFailure.malformedMessage) { try v4.decode(.binary(BoundedMessagePack.encode(created(author: tag)))) }
        guard case .created(_, let old) = try v4.decode(.binary(BoundedMessagePack.encode(created(author: nil)))) else {
            Issue.record("Expected created"); return
        }
        #expect(old.author == nil)
    }

    @Test func reportsEncodeOnlyOnV5AndTheirAckOnlyDecodesThere() throws {
        let a = UUID(), b = UUID()
        let report = ClientMessage.report(requestID: "r", strokeIDs: [a, b], reason: .hate, blockAuthor: true)
        guard case .binary(let bytes) = try SessionCodec(profile: .messagePackV5).encode(report) else { Issue.record("binary"); return }
        struct Wire: Decodable { let type: String; let request_id: String; let stroke_ids: [String]; let reason: String; let block_author: Bool }
        let wire = try BoundedMessagePack.decode(Wire.self, from: bytes)
        #expect(wire.type == "stroke.report" && wire.stroke_ids == [a, b].map { $0.uuidString.lowercased() })
        #expect(wire.reason == "hate" && wire.block_author)
        #expect(throws: TransportFailure.malformedMessage) { try SessionCodec(profile: .messagePackV4).encode(report) }
        #expect(throws: TransportFailure.malformedMessage) {
            try SessionCodec(profile: .messagePackV5).encode(.report(requestID: "r", strokeIDs: [a, a], reason: .spam, blockAuthor: false))
        }
        #expect(throws: TransportFailure.malformedMessage) {
            try SessionCodec(profile: .messagePackV5).encode(.report(requestID: "r", strokeIDs: [], reason: .spam, blockAuthor: false))
        }
        let ack: [String: FixtureValue] = ["type": .string("ack"), "request_id": .string("r"), "operation": .string("stroke.report"),
                                           "report_id": .string(id)]
        #expect(try SessionCodec(profile: .messagePackV5).decode(.binary(BoundedMessagePack.encode(ack)))
                == .reportAcknowledged(requestID: "r", reportID: UUID(uuidString: id)!))
        #expect(throws: TransportFailure.malformedMessage) { try SessionCodec(profile: .messagePackV4).decode(.binary(BoundedMessagePack.encode(ack))) }
    }

    @Test func hiddenContentHidesByStrokeOrAuthorStaysBoundedAndRoundTrips() {
        let (a, b) = (UUID(), UUID())
        var hidden = HiddenContent()
        hidden.hide(strokes: [a, a], authors: [tag])
        #expect(hidden.hides(a, author: nil) && hidden.hides(b, author: tag) && !hidden.hides(b, author: nil))
        #expect(hidden.strokes == [a])
        let restored = HiddenContent(storedStrokes: hidden.storedStrokes + ["junk"], storedAuthors: hidden.authors + ["bad"])
        #expect(restored == hidden)
        var many = HiddenContent()
        many.hide(strokes: (0...HiddenContent.maximumStrokes).map { _ in UUID() }, authors: [])
        #expect(many.strokes.count == HiddenContent.maximumStrokes)
    }

    @Test func hitTestPicksTheTopmostOtherStrokeNearTheLine() throws {
        func record(_ seq: Int64, own: Bool, y: Double) throws -> SceneStroke {
            let payload = try StrokePayload(id: UUID(), points: [WorldPoint(x: -50, y: y), WorldPoint(x: 50, y: y)], brush: .round,
                                            width: 10, color: "#202020", opacity: 1)
            return SceneStroke(try ServerStroke(payload: payload, sequence: seq, own: own))
        }
        #expect(StrokeHitTest.distance(from: WorldPoint(x: 0, y: 7), to: [WorldPoint(x: -1, y: 0), WorldPoint(x: 1, y: 0)]) == 7)
        let low = try record(1, own: false, y: 0), high = try record(2, own: false, y: 2), mine = try record(3, own: true, y: 1)
        let all = [low, high, mine]
        #expect(StrokeHitTest.topmost(at: WorldPoint(x: 0, y: 1), slop: 2, in: all) { $0.server.own }?.server.sequence == 2)
        #expect(StrokeHitTest.topmost(at: WorldPoint(x: 0, y: 40), slop: 2, in: all) { $0.server.own } == nil)
        #expect(StrokeHitTest.topmost(at: WorldPoint(x: 0, y: -6), slop: 2, in: all) { $0.server.own }?.server.sequence == 1)
    }

    @Test func termsAreAskedOncePerVersionInTheLiveAppOnly() throws {
        let name = "SafetyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CanvasModel().termsAccepted) // tests and previews never block drawing
        let model = CanvasModel(defaults: defaults)
        #expect(!model.termsAccepted)
        model.termsPrompt = true
        model.acceptTerms()
        #expect(model.termsAccepted && !model.termsPrompt)
        #expect(CanvasModel(defaults: defaults).termsAccepted)
        defaults.set("terms.v0", forKey: "acceptedTerms")
        #expect(!CanvasModel(defaults: defaults).termsAccepted) // a new terms version asks again
    }

    @Test func submittingAReportHidesLocallyBlocksTheAuthorAndPersists() throws {
        let name = "SafetyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CanvasModel(defaults: defaults)
        var changes = 0
        model.onHiddenChanged = { changes += 1 }
        let extent = StrokeExtent(LocalStroke(id: UUID(), points: [.zero], style: BrushStyle()))
        let (a, b) = (UUID(), UUID())
        model.startReporting()
        model.toggleReport(ReportTarget(id: a, author: tag, extent: extent))
        model.toggleReport(ReportTarget(id: b, author: nil, extent: extent))
        model.toggleReport(ReportTarget(id: b, author: nil, extent: extent)) // second tap deselects
        #expect(model.reportSelection.map(\.id) == [a])
        model.submitReport(reason: .sexual, blockAuthor: true)
        #expect(!model.reporting && model.reportSelection.isEmpty && model.notice != nil)
        #expect(model.hiddenContent.hides(a, author: nil) && model.hiddenContent.hides(UUID(), author: tag))
        #expect(changes == 1)
        #expect(CanvasModel(defaults: defaults).hiddenContent == model.hiddenContent)
        model.showHiddenContent()
        #expect(model.hiddenContent.isEmpty && CanvasModel(defaults: defaults).hiddenContent.isEmpty)
    }
}
