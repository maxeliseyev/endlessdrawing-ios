import Foundation
import Testing
@testable import Endless_Drawing

struct TilePlanTests {
    private let viewport = CanvasSize(width: 1210, height: 834)

    @Test func zoomLevelsAreSquareRootTwoStepsAtOrAboveZoom() {
        #expect(TilePlan.zoomLevel(1) == 1)
        #expect(abs(TilePlan.zoomLevel(1.2) - 2.0.squareRoot()) < 1e-12)
        #expect(abs(TilePlan.zoomLevel(0.5) - 0.5) < 1e-12)
        #expect(abs(TilePlan.zoomLevel(0.6) - 1 / 2.0.squareRoot()) < 1e-12)
        for zoom in stride(from: 0.08, through: 4.0, by: 0.037) { #expect(TilePlan.zoomLevel(zoom) >= zoom * (1 - 1e-9)) }
    }

    @Test func settledExactTilesLandOnWholePixelsWithSharedEdges() {
        var camera = Camera()
        camera.pan(screenDelta: WorldPoint(x: -123.37, y: 45.81))
        camera.zoom(to: 1.37, anchor: WorldPoint(x: 300, y: 200), viewport: viewport)
        let frame = TilePlan.plan(camera: camera, viewport: viewport, pixelsPerPoint: 2, width: 2420, height: 1668,
                                  now: 10, clock: TilePlan.ZoomClock(zoom: camera.zoom, zoomedAt: 0))
        #expect(frame.settleIn == nil)
        #expect(frame.scale == frame.exact)
        let placements = frame.needed.map { TilePlan.placement($0, in: frame.view) }
        for p in placements { #expect(p.x1 - p.x0 == TilePlan.size && p.y1 - p.y0 == TilePlan.size) }
        // Every visible pixel is covered and right neighbours start exactly where a tile ends.
        for (key, p) in zip(frame.needed, placements) {
            if let i = frame.needed.firstIndex(of: TilePlan.Key(scale: key.scale, tx: key.tx + 1, ty: key.ty)) {
                #expect(placements[i].x0 == p.x1)
            }
        }
        #expect(placements.map(\.x0).min()! <= 0 && placements.map(\.x1).max()! >= 2420)
        #expect(placements.map(\.y0).min()! <= 0 && placements.map(\.y1).max()! >= 1668)
        // Snapping moves the camera by at most half a backing pixel.
        let snappedCenter = frame.view.origin.x + 1210 / frame.exact
        #expect(abs(snappedCenter - camera.center.x) * frame.exact <= 0.5 + 1e-9)
    }

    @Test func zoomUsesLevelScaleUntilSettledThenExact() {
        var camera = Camera()
        let start = TilePlan.ZoomClock(zoom: 1, zoomedAt: -.infinity)
        camera.zoom(to: 1.2, anchor: .zero, viewport: viewport)
        let zooming = TilePlan.plan(camera: camera, viewport: viewport, pixelsPerPoint: 2, width: 2420, height: 1668,
                                    now: 5, clock: start)
        #expect(abs(zooming.scale - 2.0.squareRoot() * 2) < 1e-12)
        #expect(abs((zooming.settleIn ?? 0) - TilePlan.settle) < 1e-9)
        let later = TilePlan.plan(camera: camera, viewport: viewport, pixelsPerPoint: 2, width: 2420, height: 1668,
                                  now: 5 + TilePlan.settle + 0.001, clock: zooming.clock)
        #expect(later.scale == later.exact && later.settleIn == nil)
        #expect(later.ring.count > later.needed.count)
        #expect(Set(later.needed).isSubset(of: Set(later.ring)))
    }

    @Test func neededTilesAreNearestFirstAndBoundsIncludeFringe() {
        let frame = TilePlan.plan(camera: Camera(), viewport: viewport, pixelsPerPoint: 2, width: 2420, height: 1668,
                                  now: 0, clock: TilePlan.ZoomClock())
        let first = TilePlan.bounds(frame.needed[0])
        #expect(first.minX <= 0 && first.maxX >= 0 && first.minY <= 0 && first.maxY >= 0)
        let key = TilePlan.Key(scale: 2, tx: 3, ty: -2)
        let bounds = TilePlan.bounds(key)
        #expect(bounds.minX == 3 * 256 - 1 && bounds.maxX == 4 * 256 + 1)
        #expect(TilePlan.view(key).origin == WorldPoint(x: 768, y: -512))
    }

    @Test func strokeIndexFindsOnlyIntersectingStrokesAndForgetsRemoved() {
        var style = BrushStyle(); style.width = 10
        let near = LocalStroke(id: UUID(), points: [WorldPoint(x: 10, y: 10)], style: style)
        let far = LocalStroke(id: UUID(), points: [WorldPoint(x: 5000, y: -9000)], style: style)
        let long = LocalStroke(id: UUID(), points: [WorldPoint(x: -3000, y: 0), WorldPoint(x: 3000, y: 0)], style: style)
        var index = StrokeIndex()
        for stroke in [near, far, long] { index.insert(stroke.id, extent: StrokeExtent(stroke)) }
        let rect = TilePlan.Rect(minX: -100, minY: -100, maxX: 100, maxY: 100)
        #expect(Set(index.query(rect)) == [near.id, long.id])
        index.remove(long.id)
        #expect(index.query(rect) == [near.id])
        #expect(index.query(TilePlan.Rect(minX: 4900, minY: -9100, maxX: 5100, maxY: -8900)) == [far.id])
        #expect(index.count == 2)
    }
}
