import Foundation
import Testing
@testable import Endless_Drawing

struct SceneStoreTests {
    private func bounds() throws -> WireBounds { try WireBounds(minX: -100, minY: -100, maxX: 100, maxY: 100) }

    @Test func progressivelyDisplaysButRemovesMissingOnlyAtEndIncludingEmptySnapshot() throws {
        let a = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 1)
        let b = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 2)
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "one", bounds: region); try scene.begin(id: "one")
        try scene.chunk(id: "one", strokes: [a]); try scene.end(id: "one")
        scene.subscribe(id: "two", bounds: region); try scene.begin(id: "two")
        try scene.chunk(id: "two", strokes: [b])
        #expect(scene.visible(in: region, hidden: []).map(\.server.sequence) == [1, 2])
        try scene.end(id: "two")
        #expect(scene.visible(in: region, hidden: []).map(\.server.sequence) == [2])
        scene.subscribe(id: "empty", bounds: region); try scene.begin(id: "empty")
        #expect(scene.visible(in: region, hidden: []).count == 1)
        try scene.end(id: "empty")
        #expect(scene.visible(in: region, hidden: []).isEmpty)
        #expect(!scene.loading)
    }

    /// The memoized order must observe every mutation path: chunks, end, live events, acks, removal, hiding.
    @Test func orderedSceneTracksEveryMutationAndHidesWithoutResorting() throws {
        let a = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 4)
        let b = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 2)
        let c = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 7)
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "s", bounds: region); try scene.begin(id: "s")
        #expect(scene.ordered(hidden: []).isEmpty)
        try scene.chunk(id: "s", strokes: [b, a])
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [2, 4])
        try scene.end(id: "s")
        try scene.created(id: "s", stroke: c)
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [2, 4, 7])
        #expect(scene.ordered(hidden: [a.payload.id]).map(\.server.sequence) == [2, 7])
        try scene.remove(b.payload.id, sequence: 2)
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [4, 7])
        scene.subscribe(id: "t", bounds: region)
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [4, 7]) // bounded stale display
    }

    @Test func acknowledgementsSurviveSnapshotBoundaryButDeletionWinsAgainstLateChunksAndAcks() throws {
        let stroke = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 3)
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "v", bounds: region); try scene.begin(id: "v")
        try scene.acknowledged(stroke); try scene.end(id: "v")
        #expect(scene.visible(in: region, hidden: []).count == 1)
        scene.subscribe(id: "next", bounds: region); try scene.begin(id: "next")
        try scene.remove(stroke.payload.id, sequence: 3)
        try scene.chunk(id: "next", strokes: [stroke]); try scene.acknowledged(stroke)
        try scene.end(id: "next")
        #expect(scene.visible(in: region, hidden: []).isEmpty)
    }

    @Test func ignoresStaleScopesAndDeduplicatesEventAndAckWithoutInventingUndo() throws {
        let stroke = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 9)
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "v", bounds: region); try scene.begin(id: "v"); try scene.end(id: "v")
        try scene.created(id: "v", stroke: stroke); try scene.acknowledged(stroke)
        try scene.deleted(id: "old", strokeID: stroke.payload.id, sequence: 9)
        try scene.chunk(id: "old", strokes: [stroke]); try scene.end(id: "old")
        #expect(scene.visible(in: region, hidden: []).count == 1)
        #expect(scene.visible(in: region, hidden: [stroke.payload.id]).isEmpty)
    }

    @Test func rejectsChangedImmutablePayloadOrReusedSequenceTransactionally() throws {
        let first = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 1)
        let conflict = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 1)
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "v", bounds: region); try scene.begin(id: "v")
        #expect(throws: SceneFailure.inconsistent) { try scene.chunk(id: "v", strokes: [first, conflict]) }
        #expect(scene.visible(in: region, hidden: []).isEmpty)
        try scene.chunk(id: "v", strokes: [first]); try scene.end(id: "v")
        #expect(throws: SceneFailure.inconsistent) { try scene.remove(first.payload.id, sequence: 2) }
    }

    @Test func scenePointAndTombstoneBudgetsFailWithoutPartialChunkOrSilentEviction() throws {
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "v", bounds: region); try scene.begin(id: "v")
        let points = Array(repeating: WorldPoint.zero, count: 2000)
        let records = try (1...500).map { sequence in
            try ServerStroke(payload: StrokePayload(id: UUID(), points: points, brush: .round, width: 6,
                                                    color: "#202020", opacity: 1), sequence: Int64(sequence), own: false)
        }
        try scene.chunk(id: "v", strokes: records)
        let extra = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 501)
        #expect(throws: SceneFailure.capacity) { try scene.chunk(id: "v", strokes: [extra]) }
        #expect(scene.visible(in: region, hidden: []).count == 500)
        var deleted = SceneStore()
        for _ in 0..<20_000 { try deleted.remove(UUID()) }
        #expect(throws: SceneFailure.capacity) { try deleted.remove(UUID()) }
    }

    @Test func eightPercentPrefetchRespectsServerSpanAndWorldEdges() throws {
        for center in [WorldPoint.zero, WorldPoint(x: 1e9, y: -1e9)] {
            let viewport = CanvasSize(width: 1376, height: 1032)
            var camera = Camera(); camera.pan(screenDelta: WorldPoint(x: -center.x, y: -center.y))
            camera.zoom(to: 0.08, anchor: WorldPoint(x: 688, y: 516), viewport: viewport)
            let region = try CanvasRegion(camera: camera, viewport: viewport)
            #expect(region.subscription.contains(region.visible))
            #expect(region.subscription.maxX - region.subscription.minX <= 30_000)
            #expect(region.subscription.minX >= -1e9 && region.subscription.maxX <= 1e9)
            #expect(region.subscription.minY >= -1e9 && region.subscription.maxY <= 1e9)
        }
    }
}
