import Testing
@testable import Endless_Drawing

struct CameraTests {
    private let viewport = CanvasSize(width: 1024, height: 768)

    @Test func roundTripAndZoomAnchor() {
        var camera = Camera()
        let anchor = WorldPoint(x: 153.5, y: 617.25)
        let fixed = camera.worldPoint(at: anchor, viewport: viewport)
        camera.zoom(to: 3.75, anchor: anchor, viewport: viewport)
        let result = camera.screenPoint(at: fixed, viewport: viewport)
        #expect(abs(result.x - anchor.x) < 1e-9)
        #expect(abs(result.y - anchor.y) < 1e-9)
        #expect(camera.worldPoint(at: result, viewport: viewport) == fixed)
    }

    @Test func panFollowsFingerAtAnyZoom() {
        var camera = Camera()
        camera.zoom(to: 4, anchor: WorldPoint(x: 512, y: 384), viewport: viewport)
        camera.pan(screenDelta: WorldPoint(x: 40, y: -20))
        #expect(camera.center == WorldPoint(x: -10, y: 5))
    }

    @Test func clampsZoomAndWorldAndRejectsInvalidInput() {
        var camera = Camera()
        camera.zoom(to: 100, anchor: .zero, viewport: viewport)
        #expect(camera.zoom == 4)
        camera.zoom(to: 0, anchor: .zero, viewport: viewport)
        #expect(camera.zoom == 0.16)
        camera.pan(screenDelta: WorldPoint(x: -1e20, y: 1e20))
        #expect(camera.center == WorldPoint(x: 1e9, y: -1e9))
        let before = camera
        camera.zoom(to: .nan, anchor: .zero, viewport: viewport)
        camera.pan(screenDelta: WorldPoint(x: .infinity, y: 0))
        #expect(camera == before)
    }

    @Test func pinchKeepsInitialWorldPointUnderMovingMidpoint() {
        let start = Camera()
        var result = start
        let initial = WorldPoint(x: 200, y: 300)
        let midpoint = WorldPoint(x: 280, y: 350)
        result.pinch(from: start, initialMidpoint: initial, midpoint: midpoint, ratio: 2, viewport: viewport)
        let fixed = start.worldPoint(at: initial, viewport: viewport)
        #expect(result.screenPoint(at: fixed, viewport: viewport) == midpoint)
        result.pinch(from: start, initialMidpoint: initial, midpoint: midpoint, ratio: 0, viewport: viewport)
        #expect(result.zoom == Camera.minimumZoom)
    }
}
