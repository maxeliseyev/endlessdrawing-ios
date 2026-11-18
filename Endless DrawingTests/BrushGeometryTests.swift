import Foundation
import Testing
@testable import Endless_Drawing

private final class BrushFixtureBundle: NSObject {}

struct BrushGeometryTests {
    private struct Fixture: Decodable {
        let version: Int
        let sourceSHA256: [String: String]
        let cases: [Sample]
        struct Sample: Decodable {
            let name: String, id: UUID, brush: BrushKind, width: Double
            let points: [[Double]], triangles: [Float], circles: [Float]
        }
    }

    @Test func allAdditionalBrushesMatchPinnedWebGeometryIncludingSmallSpray() throws {
        let url = try #require(Bundle(for: BrushFixtureBundle.self).url(forResource: "brush-geometry", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.version == 1)
        #expect(fixture.sourceSHA256.count == 2)
        for sample in fixture.cases {
            var style = BrushStyle(); style.brush = sample.brush; style.width = sample.width
            let stroke = LocalStroke(id: sample.id, points: sample.points.map { WorldPoint(x: $0[0], y: $0[1]) }, style: style)
            let result = try #require(BrushGeometry.prepare(stroke))
            let values = result.triangles.flatMap { [$0.x, $0.y] } + result.circles.flatMap { [$0.center.x, $0.center.y, $0.radius] }
            let expected = sample.triangles + sample.circles
            #expect(values.count == expected.count, "\(sample.name)")
            for (value, reference) in zip(values, expected) { #expect(abs(value - reference) <= 0.00001, "\(sample.name)") }
        }
    }

    @Test func maximumSprayIsBoundedAndDoesNotUseLegacyParticleSize() throws {
        var style = BrushStyle(); style.brush = .spray; style.width = 64
        let stroke = LocalStroke(id: UUID(), points: [.zero, WorldPoint(x: 100_000, y: 0)], style: style)
        let result = try #require(BrushGeometry.prepare(stroke))
        #expect(result.circles.count <= 98_304)
        #expect(result.circles.count >= 98_256)
        #expect(result.circles.allSatisfy { $0.radius == 0.5 })
        #expect(result.triangles.isEmpty)
    }

    @Test func effectBrushPredictionHandoffUsesMeasuredGeometryOnly() throws {
        for brush in [BrushKind.square, .chisel, .spray] {
            var style = BrushStyle(); style.brush = brush
            let stroke = LocalStroke(id: UUID(), points: [.zero, WorldPoint(x: 10, y: 5), WorldPoint(x: 30, y: 20)], style: style)
            let preview = try #require(BrushGeometry.prepare(stroke, realPointCount: 2))
            let measured = try #require(BrushGeometry.prepare(LocalStroke(id: stroke.id, points: Array(stroke.points.prefix(2)), style: style)))
            #expect(preview.triangles == measured.triangles)
            #expect(preview.circles.map(\.center) == measured.circles.map(\.center))
            #expect(preview.realCircleCount == preview.circles.count)
            #expect(preview.realTriangleCount == preview.triangles.count)
        }
    }
}
