import Testing
@testable import Endless_Drawing

struct InputTests {
    @Test func predictionsNeverEnterCompletedStroke() throws {
        var input = StrokeInput()
        input.begin(at: .zero, timestamp: 1, style: BrushStyle())
        input.appendReal(WorldPoint(x: 10, y: 0), timestamp: 2)
        input.replacePredictions([WorldPoint(x: 100, y: 100)])
        #expect(input.preview?.points.count == 3)
        let completed = input.finish(at: WorldPoint(x: 12, y: 0), timestamp: 3)
        let stroke = try #require(completed)
        #expect(stroke.points == [.zero, WorldPoint(x: 10, y: 0), WorldPoint(x: 12, y: 0)])
        #expect(input.preview == nil)
    }

    @Test func predictionsAreReplacedAndClearedByRealInput() {
        var input = StrokeInput()
        input.begin(at: .zero, timestamp: 1, style: BrushStyle())
        input.replacePredictions([WorldPoint(x: 10, y: 0)])
        input.replacePredictions([WorldPoint(x: 20, y: 0)])
        #expect(input.predictedPoints == [WorldPoint(x: 20, y: 0)])
        input.appendReal(WorldPoint(x: 5, y: 0), timestamp: 2)
        #expect(input.predictedPoints.isEmpty)
        input.cancel()
        #expect(input.finish(at: .zero, timestamp: 3) == nil)
    }

    @Test func duplicateAndStaleSamplesAreIgnored() {
        var input = StrokeInput()
        input.begin(at: .zero, timestamp: 1, style: BrushStyle())
        input.appendReal(.zero, timestamp: 1)
        input.appendReal(WorldPoint(x: 0.25, y: 0), timestamp: 2)
        input.appendReal(WorldPoint(x: 50, y: 0), timestamp: 1)
        #expect(input.realPoints == [.zero])
        let final = input.finish(at: WorldPoint(x: 0.5, y: 0), timestamp: 3)
        #expect(final?.points.last == WorldPoint(x: 0.5, y: 0))
    }

    @Test func decimationRetainsEndpointsWithoutTruncatingTail() throws {
        var input = StrokeInput()
        input.begin(at: .zero, timestamp: 0, style: BrushStyle())
        for index in 1...10_000 { input.appendReal(WorldPoint(x: Double(index), y: 0), timestamp: Double(index)) }
        let completed = input.finish(at: WorldPoint(x: 10_001, y: 0), timestamp: 10_001)
        let stroke = try #require(completed)
        #expect(stroke.points.count <= 2000)
        #expect(stroke.points.first == .zero)
        #expect(stroke.points.last?.x == 10_001)
    }

    @Test func invalidStyleAndCoordinatesCannotStartStroke() {
        var input = StrokeInput()
        input.begin(at: WorldPoint(x: .nan, y: 0), timestamp: 0, style: BrushStyle())
        #expect(input.id == nil)
        var style = BrushStyle()
        style.opacity = 0
        input.begin(at: .zero, timestamp: 0, style: style)
        #expect(input.id == nil)
    }

    @Test func invalidExtentIsRejectedAtCompletion() {
        var input = StrokeInput()
        input.begin(at: .zero, timestamp: 0, style: BrushStyle())
        #expect(input.finish(at: WorldPoint(x: 100_001, y: 0), timestamp: 1) == nil)
    }

    @Test func pinchRemainderIsBlockedUntilAllFingersLift() {
        var navigation = NavigationInput()
        let viewport = CanvasSize(width: 500, height: 500)
        navigation.begin(id: 1, point: WorldPoint(x: 100, y: 100), camera: Camera())
        navigation.begin(id: 2, point: WorldPoint(x: 200, y: 100), camera: Camera())
        #expect(navigation.move(id: 2, point: WorldPoint(x: 300, y: 100), viewport: viewport)?.zoom == 2)
        navigation.end(id: 2)
        #expect(navigation.blocked)
        #expect(navigation.move(id: 1, point: .zero, viewport: viewport) == nil)
        navigation.end(id: 1)
        #expect(!navigation.blocked)
    }

    @Test func thirdFingerDoesNotReplaceActivePinchPair() {
        var navigation = NavigationInput()
        let viewport = CanvasSize(width: 500, height: 500)
        navigation.begin(id: 1, point: WorldPoint(x: 100, y: 100), camera: Camera())
        navigation.begin(id: 2, point: WorldPoint(x: 200, y: 100), camera: Camera())
        navigation.begin(id: 3, point: .zero, camera: Camera())
        let camera = navigation.move(id: 3, point: WorldPoint(x: 400, y: 400), viewport: viewport)
        #expect(camera == Camera())
        navigation.end(id: 3)
        #expect(!navigation.blocked)
        navigation.blockUntilTouchesEnd()
        #expect(navigation.move(id: 1, point: .zero, viewport: viewport) == nil)
    }
}
