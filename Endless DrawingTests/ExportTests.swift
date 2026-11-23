import Foundation
import Testing
@testable import Endless_Drawing

struct ExportTests {
    private let tagA = "aaaaaaaaaaaaaaaaaaaaaa" // 22 chars, a valid v5+ author tag
    private let tagB = "bbbbbbbbbbbbbbbbbbbbbb"

    private func scene(_ id: UUID, seq: Int64, own: Bool, author: String?,
                       points: [WorldPoint] = [WorldPoint(x: 0, y: 0), WorldPoint(x: 10, y: 0)],
                       brush: BrushKind = .round, width: Double = 4) throws -> SceneStroke {
        let payload = try StrokePayload(id: id, points: points, brush: brush, width: width, color: "#202020", opacity: 1)
        let server = try ServerStroke(payload: payload, sequence: seq, own: own, author: author)
        return SceneStroke(server)
    }

    private func drawable(_ id: UUID, points: [WorldPoint], brush: BrushKind = .round, width: Double = 4) -> LocalStroke {
        LocalStroke(id: id, points: points,
                    style: BrushStyle(brush: brush, width: width, opacity: 1, color: InkColor.palette[0]))
    }

    private func orderedFixture() throws -> (mine: SceneStroke, a1: SceneStroke, b1: SceneStroke, a2: SceneStroke,
                                             ordered: [SceneStroke], pending: LocalStroke) {
        let mine = try scene(UUID(), seq: 3, own: true, author: "mmmmmmmmmmmmmmmmmmmmmm")
        let a1 = try scene(UUID(), seq: 1, own: false, author: tagA)
        let b1 = try scene(UUID(), seq: 2, own: false, author: tagB)
        let a2 = try scene(UUID(), seq: 4, own: false, author: tagA)
        let pending = drawable(UUID(), points: [WorldPoint(x: 1, y: 1)])
        return (mine, a1, b1, a2, [a1, b1, mine, a2], pending)
    }

    @Test func selectionStartsWithMineAndTogglesMineOrAnotherAuthor() {
        #expect(ExportSelection.defaultSelection == ExportSelection(own: true, authors: []))
        var selection = Export.toggleAuthor(.defaultSelection, own: false, author: tagA)
        #expect(selection == ExportSelection(own: true, authors: [tagA]))
        selection = Export.toggleAuthor(selection, own: false, author: tagB)
        selection = Export.toggleAuthor(selection, own: true, author: nil)
        #expect(selection == ExportSelection(own: false, authors: [tagA, tagB]))
        selection = Export.toggleAuthor(selection, own: false, author: tagA)
        #expect(selection == ExportSelection(own: false, authors: [tagB]))
        #expect(Export.isEmptySelection(Export.toggleAuthor(selection, own: false, author: tagB)))
    }

    @Test func cannotPickAnAuthorWithoutAV5Tag() throws {
        let untagged = try scene(UUID(), seq: 9, own: false, author: nil)
        #expect(Export.toggleAuthor(.defaultSelection, own: false, author: nil) == .defaultSelection)
        let selected = Export.selectStrokes(confirmed: [untagged], pending: [], selection: .defaultSelection) { _ in false }
        #expect(selected.isEmpty)
    }

    @Test func keepsOnlyTheChosenAuthorsInCanvasOrderWithPendingOnTop() throws {
        let f = try orderedFixture()
        let noHide: (SceneStroke) -> Bool = { _ in false }

        let mine = Export.selectStrokes(confirmed: f.ordered, pending: [f.pending], selection: .defaultSelection, isHidden: noHide)
        #expect(mine.map(\.id) == [f.mine.server.payload.id, f.pending.id])

        let authorsOnly = Export.selectStrokes(confirmed: f.ordered, pending: [f.pending],
                                               selection: ExportSelection(own: false, authors: [tagA]), isHidden: noHide)
        #expect(authorsOnly.map(\.id) == [f.a1.server.payload.id, f.a2.server.payload.id])

        let mixed = Export.selectStrokes(confirmed: f.ordered, pending: [f.pending],
                                         selection: ExportSelection(own: true, authors: [tagA]), isHidden: noHide)
        #expect(mixed.map(\.id) == [f.a1.server.payload.id, f.mine.server.payload.id, f.a2.server.payload.id, f.pending.id])

        let none = Export.selectStrokes(confirmed: f.ordered, pending: [f.pending],
                                        selection: ExportSelection(own: false, authors: []), isHidden: noHide)
        #expect(none.isEmpty)
    }

    @Test func neverExportsHiddenStrokes() throws {
        let f = try orderedFixture()
        let selected = Export.selectStrokes(confirmed: f.ordered, pending: [],
                                            selection: ExportSelection(own: false, authors: [tagA])) {
            $0.server.payload.id == f.a1.server.payload.id
        }
        #expect(selected.map(\.id) == [f.a2.server.payload.id])
    }

    @Test func frameWrapsBrushExtentWithAtLeastA16UnitMargin() {
        // round width 4: extent pad = 4/2 + 1 = 3
        let frame = Export.frameFor([drawable(UUID(), points: [WorldPoint(x: 0, y: 0), WorldPoint(x: 100, y: 50)])])
        #expect(frame == ExportFrame(minX: -19, minY: -19, maxX: 119, maxY: 69))
        #expect(Export.frameFor([]) == nil)
    }

    @Test func frameGrowsMarginWithTheDrawingAndAccountsForSquareBrushes() throws {
        let big = drawable(UUID(), points: [WorldPoint(x: 0, y: 0), WorldPoint(x: 1000, y: 0)], brush: .square, width: 10)
        let pad = 10 / sqrt(2) + 1
        let margin = (1000 + 2 * pad) * 0.04
        let frame = try #require(Export.frameFor([big]))
        #expect(abs(frame.minX - (-pad - margin)) < 1e-9)
        #expect(abs(frame.maxY - (pad + margin)) < 1e-9)
    }

    @Test func normalizesADraggedFrameAndKeepsAMinimumSize() {
        #expect(Export.normalizeFrame(a: WorldPoint(x: 10, y: 20), b: WorldPoint(x: -10, y: -20))
            == ExportFrame(minX: -10, minY: -20, maxX: 10, maxY: 20))
        #expect(Export.normalizeFrame(a: WorldPoint(x: 5, y: 5), b: WorldPoint(x: 5, y: 6))
            == ExportFrame(minX: 1, minY: 1.5, maxX: 9, maxY: 9.5))
    }

    @Test func keepsStrokesThatTouchTheFrameAndDropsThoseEntirelyOutside() {
        let inside = drawable(UUID(), points: [WorldPoint(x: 0, y: 0)])
        let edge = drawable(UUID(), points: [WorldPoint(x: 52, y: 0)])
        let outside = drawable(UUID(), points: [WorldPoint(x: 100, y: 0)])
        let frame = ExportFrame(minX: -50, minY: -50, maxX: 50, maxY: 50)
        #expect(Export.inFrame([inside, edge, outside], frame: frame).map(\.id) == [inside, edge].map(\.id))
    }

    @Test func exportSizeMultipliesTheFrameByTheChosenScale() {
        #expect(Export.exportSize(frame: ExportFrame(minX: 0, minY: 0, maxX: 300.5, maxY: 200), requested: 2)
            == ExportSize(width: 601, height: 400, scale: 2))
    }

    @Test func exportSizeLowersTheScaleToStayWithinCanvasLimits() {
        let wide = Export.exportSize(frame: ExportFrame(minX: 0, minY: 0, maxX: 30_000, maxY: 100), requested: 4)
        #expect(wide.width <= Export.maximumSide)
        #expect(abs(wide.scale - Double(Export.maximumSide) / 30_000) < 1e-9)
        let square = Export.exportSize(frame: ExportFrame(minX: 0, minY: 0, maxX: 10_000, maxY: 10_000), requested: 4)
        #expect(square.width * square.height <= Export.maximumPixels)
        #expect(square.width == 4096)
    }

    @Test func namesTheFileByTheRoundedFrameCentreWithoutNegativeZero() {
        #expect(Export.exportFileName(frame: ExportFrame(minX: -10.4, minY: -0.8, maxX: 10, maxY: 0))
            == "endless-drawing_0_0.png")
        #expect(Export.exportFileName(frame: ExportFrame(minX: -3002, minY: 10, maxX: -1000, maxY: 20))
            == "endless-drawing_-2001_15.png")
    }
}
