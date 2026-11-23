import Testing
@testable import Endless_Drawing

struct CanvasCoordinatesTests {
    private let viewport = CanvasSize(width: 1024, height: 768)

    @Test func formatsWholeWorldUnitsLikeTheWeb() {
        // Mirrors tests/unit/coordinates.test.ts in the web client.
        #expect(coordinateText(x: 0, y: -0) == "x: 0  y: 0")
        #expect(coordinateText(x: -0.49, y: 0.49) == "x: 0  y: 0")
        #expect(coordinateText(x: -0.5, y: 0.5) == "x: −1  y: 1")
        #expect(coordinateText(x: -1240.2, y: 579.8) == "x: −1240  y: 580")
        #expect(coordinateText(x: -1_000_000_000, y: 1_000_000_000) == "x: −1000000000  y: 1000000000")
    }

    @Test func usesCameraCenterIndependentlyOfZoom() {
        let anchor = WorldPoint(x: viewport.width / 2, y: viewport.height / 2) // viewport centre
        for zoom in [0.08, 0.16, 1.0, 4.0] {
            var camera = Camera()
            camera.zoom(to: zoom, anchor: anchor, viewport: viewport) // keeps centre at (0,0)
            camera.pan(screenDelta: WorldPoint(x: 1240 * zoom, y: -580 * zoom))
            #expect(coordinateText(x: camera.center.x, y: camera.center.y) == "x: −1240  y: 580")
        }
    }

    @Test func subPixelMovesKeepTheSameRoundedText() {
        // The label is only refreshed when the rounded value changes, so a sub-pixel pan is a no-op.
        #expect(coordinateText(x: 10.0, y: -20.0) == coordinateText(x: 10.49, y: -20.49))
        #expect(coordinateText(x: 10.0, y: -20.0) != coordinateText(x: 10.5, y: -20.5))
    }

    @Test func panPinchAndRestoredCameraShareOneCoordinateSystem() {
        // Pan and pinch change the screen but never the world origin convention: the centre produced by
        // the gestures is the world point the label reports.
        let anchor = WorldPoint(x: 512, y: 384) // viewport centre
        var camera = Camera()
        camera.pan(screenDelta: WorldPoint(x: -200, y: 100)) // centre → (200, −100)
        camera.zoom(to: 2, anchor: anchor, viewport: viewport) // zooming at the centre keeps it
        #expect(coordinateText(x: camera.center.x, y: camera.center.y) == "x: 200  y: −100")

        // CameraStore round-trips the exact same centre, so the label is stable after relaunch.
        var restored = Camera()
        restored.pan(screenDelta: WorldPoint(x: -camera.center.x, y: -camera.center.y))
        restored.zoom(to: camera.zoom, anchor: WorldPoint(x: 0.5, y: 0.5), viewport: CanvasSize(width: 1, height: 1))
        #expect(abs(restored.center.x - camera.center.x) < 1e-9)
        #expect(abs(restored.center.y - camera.center.y) < 1e-9)
        #expect(coordinateText(x: restored.center.x, y: restored.center.y) == "x: 200  y: −100")
    }
}
