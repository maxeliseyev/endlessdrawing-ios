import Foundation
import Testing
@testable import Endless_Drawing

private final class TestBundleToken: NSObject {}

struct GeometryTests {
    private struct Fixture: Decodable {
        let version: Int
        let frontendCommit: String
        let cases: [Case]
        struct Case: Decodable {
            let name: String
            let points: [[Double]]
            let width: Double
            let triangles: [Float]
            let circles: [Float]
        }
    }

    @Test func matchesWebRoundGeometryFixtures() throws {
        let url = try #require(Bundle(for: TestBundleToken.self).url(forResource: "round-geometry", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.version == 1)
        #expect(!fixture.frontendCommit.isEmpty)
        for sample in fixture.cases {
            var style = BrushStyle()
            style.width = sample.width
            let points = sample.points.map { WorldPoint(x: $0[0], y: $0[1]) }
            let prepared = try #require(RoundGeometry.prepare(LocalStroke(id: UUID(), points: points, style: style)))
            let triangles = prepared.triangles.flatMap { [$0.x, $0.y] }
            let circles = prepared.circles.flatMap { [$0.center.x, $0.center.y, $0.radius] }
            #expect(triangles.count == sample.triangles.count, "\(sample.name)")
            #expect(circles.count == sample.circles.count, "\(sample.name)")
            for (actual, expected) in zip(triangles + circles, sample.triangles + sample.circles) {
                #expect(abs(actual - expected) <= 0.00001, "\(sample.name): \(actual) vs \(expected)")
            }
        }
    }

    @Test func geometryIsTranslationInvariantAtWorldEdge() throws {
        let style = BrushStyle()
        let local = [WorldPoint.zero, WorldPoint(x: 4, y: 8)]
        let offset = WorldPoint(x: 999_999_990, y: -999_999_990)
        let moved = local.map { WorldPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        let a = try #require(RoundGeometry.prepare(LocalStroke(id: UUID(), points: local, style: style)))
        let b = try #require(RoundGeometry.prepare(LocalStroke(id: UUID(), points: moved, style: style)))
        #expect(a.triangles == b.triangles)
        #expect(a.circles.map(\.center) == b.circles.map(\.center))
        #expect(b.origin == offset)
    }

    @Test func emptyAndInvalidGeometryIsRejected() {
        #expect(RoundGeometry.prepare(LocalStroke(id: UUID(), points: [], style: BrushStyle())) == nil)
        #expect(RoundGeometry.prepare(LocalStroke(id: UUID(), points: [WorldPoint(x: .infinity, y: 0)], style: BrushStyle())) == nil)
    }
}
