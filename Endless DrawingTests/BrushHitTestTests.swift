import Foundation
import Testing
@testable import Endless_Drawing

struct BrushHitTestTests {
    private func stroke(_ points: [WorldPoint], _ brush: BrushKind, width: Double = 6) -> LocalStroke {
        LocalStroke(id: UUID(), points: points,
                    style: BrushStyle(brush: brush, width: width, opacity: 1, color: InkColor.palette[0]))
    }

    @Test func roundHitsCentreLineAndRespectsTolerance() {
        let s = stroke([WorldPoint(x: 0, y: 0), WorldPoint(x: 10, y: 0)], .round) // half width 3
        #expect(BrushHitTest.roundContains(WorldPoint(x: 5, y: 2), in: s, tolerance: 0))
        #expect(!BrushHitTest.roundContains(WorldPoint(x: 5, y: 4), in: s, tolerance: 0))
        #expect(BrushHitTest.roundContains(WorldPoint(x: 5, y: 4), in: s, tolerance: 2))
    }

    @Test func roundSinglePointIsACircle() {
        let s = stroke([WorldPoint(x: 0, y: 0)], .round)
        #expect(BrushHitTest.roundContains(WorldPoint(x: 3, y: 0), in: s, tolerance: 0))
        #expect(!BrushHitTest.roundContains(WorldPoint(x: 3.1, y: 0), in: s, tolerance: 0))
    }

    @Test func squareHitsARotatedRectangleNotACircle() {
        // Diagonal segment: the swept square is a rotated rectangle, so a point 4.24 away on the
        // perpendicular is outside even though a round brush would reach 3 only.
        let s = stroke([WorldPoint(x: 0, y: 0), WorldPoint(x: 10, y: 10)], .square)
        #expect(!BrushHitTest.squareContains(WorldPoint(x: 8, y: 2), in: s, tolerance: 0))
        #expect(BrushHitTest.squareContains(WorldPoint(x: 5, y: 5), in: s, tolerance: 0))
        #expect(BrushHitTest.squareContains(WorldPoint(x: 5, y: 7), in: s, tolerance: 0)) // 1.41 ≤ 3
    }

    @Test func squareSinglePointIsAxisAligned() {
        let s = stroke([WorldPoint(x: 0, y: 0)], .square)
        #expect(BrushHitTest.squareContains(WorldPoint(x: 3, y: 3), in: s, tolerance: 0))
        #expect(!BrushHitTest.squareContains(WorldPoint(x: 4, y: 0), in: s, tolerance: 0))
        #expect(!BrushHitTest.squareContains(WorldPoint(x: 3, y: 3.1), in: s, tolerance: 0))
    }

    @Test func chiselHitsTheSweptNib() {
        let s = stroke([WorldPoint(x: 0, y: 0), WorldPoint(x: 10, y: 0)], .chisel)
        #expect(BrushHitTest.chiselContains(WorldPoint(x: 5, y: 0), in: s, tolerance: 0))
        // The −45° nib is long: near the centre line the swept hull reaches well above/below it.
        #expect(BrushHitTest.chiselContains(WorldPoint(x: 5, y: 2), in: s, tolerance: 0))
    }

    @Test func chiselSinglePointIsTheNibHull() {
        let s = stroke([WorldPoint(x: 0, y: 0)], .chisel)
        #expect(BrushHitTest.chiselContains(WorldPoint(x: 0, y: 0), in: s, tolerance: 0))
        #expect(!BrushHitTest.chiselContains(WorldPoint(x: 10, y: 10), in: s, tolerance: 0))
    }

    @Test func spraySharesTheRenderersDeterministicParticles() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let s = LocalStroke(id: id, points: [WorldPoint(x: 0, y: 0)],
                            style: BrushStyle(brush: .spray, width: 8, opacity: 1, color: InkColor.palette[0]))
        let prepared = try #require(BrushGeometry.prepare(s))
        let circles = prepared.circles
        #expect(!circles.isEmpty)
        // Every particle the renderer draws is also a hit, and a point far away is not.
        for circle in circles {
            let center = WorldPoint(x: Double(circle.center.x), y: Double(circle.center.y))
            #expect(BrushHitTest.sprayContains(center, in: s, tolerance: 0))
        }
        #expect(!BrushHitTest.sprayContains(WorldPoint(x: 1000, y: 1000), in: s, tolerance: 0))
    }
}

struct EraseSelectionTests {
    private func scene(_ id: UUID, points: [WorldPoint], seq: Int64, own: Bool,
                       brush: BrushKind = .round, width: Double = 6) throws -> SceneStroke {
        let payload = try StrokePayload(id: id, points: points, brush: brush, width: width, color: "#202020", opacity: 1)
        let server = try ServerStroke(payload: payload, sequence: seq, own: own,
                                      author: own ? nil : "abcdefghijklmnopqrstuv")
        return SceneStroke(server)
    }

    @Test func newestPendingDraftWinsOverConfirmed() throws {
        let point = WorldPoint(x: 1, y: 1)
        let draftID = UUID()
        let pending = [LocalStroke(id: draftID, points: [point],
                                   style: BrushStyle(brush: .round, width: 6, opacity: 1, color: InkColor.palette[0]))]
        let ownID = UUID()
        let confirmed = [try scene(ownID, points: [point], seq: 9, own: true)]
        let target = EraseSelection.target(at: point, tolerance: 0, pending: pending, confirmed: confirmed, hidden: [])
        #expect(target == draftID)
    }

    @Test func highestSeqOwnStrokeWins() throws {
        let point = WorldPoint(x: 1, y: 1)
        let lowID = UUID(), highID = UUID()
        let confirmed = [try scene(lowID, points: [point], seq: 5, own: true),
                         try scene(highID, points: [point], seq: 10, own: true)]
        let target = EraseSelection.target(at: point, tolerance: 0, pending: [], confirmed: confirmed, hidden: [])
        #expect(target == highID)
    }

    @Test func foreignAndHiddenStrokesAreNeverSelected() throws {
        let point = WorldPoint(x: 1, y: 1)
        let foreignID = UUID(), hiddenID = UUID()
        let confirmed = [try scene(foreignID, points: [point], seq: 20, own: false),
                         try scene(hiddenID, points: [point], seq: 30, own: true)]
        #expect(EraseSelection.target(at: point, tolerance: 0, pending: [], confirmed: confirmed, hidden: [hiddenID]) == nil)
    }

    @Test func extentPreFilterRejectsFarPoints() throws {
        let farID = UUID()
        let confirmed = [try scene(farID, points: [WorldPoint(x: 0, y: 0)], seq: 1, own: true)]
        #expect(EraseSelection.target(at: WorldPoint(x: 1000, y: 1000), tolerance: 0,
                                      pending: [], confirmed: confirmed, hidden: []) == nil)
    }
}
