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

    /// v3+/v4: visible-first and cached fetches arrive out of seq order; each member still exactly once.
    @Test func unorderedSnapshotAcceptsAnySeqOrderButRejectsRepeatedMembers() throws {
        let a = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 9)
        let b = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 3)
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "v4", bounds: region, unordered: true); try scene.begin(id: "v4")
        try scene.chunk(id: "v4", strokes: [a]); try scene.chunk(id: "v4", strokes: [b])
        #expect(throws: SceneFailure.inconsistent) { try scene.chunk(id: "v4", strokes: [a]) }
        try scene.end(id: "v4")
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [3, 9])
        var ordered = SceneStore()
        ordered.subscribe(id: "v2", bounds: region); try ordered.begin(id: "v2")
        try ordered.chunk(id: "v2", strokes: [a])
        #expect(throws: SceneFailure.inconsistent) { try ordered.chunk(id: "v2", strokes: [b]) } // v2 keeps ascending seq
    }

    @Test func retainedCacheRecordsReplaceMembershipAtEndAndTombstonesStillWin() throws {
        let kept = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 1)
        let dropped = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 2)
        let fetched = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 3)
        let deleted = try M2TestSupport.confirmed(M2TestSupport.payload(), sequence: 4)
        let region = try bounds(); var scene = SceneStore()
        scene.subscribe(id: "one", bounds: region, unordered: true); try scene.begin(id: "one")
        try scene.chunk(id: "one", strokes: [kept, dropped, deleted]); try scene.end(id: "one")
        scene.subscribe(id: "two", bounds: region, unordered: true); try scene.begin(id: "two")
        let cachedKept = try #require(scene.cached(kept.payload.id))
        let cachedDeleted = try #require(scene.cached(deleted.payload.id))
        try scene.remove(deleted.payload.id, sequence: 4) // delete known before the manifest completes
        #expect(scene.cached(deleted.payload.id) == nil)
        try scene.retain(id: "two", records: [cachedKept, cachedDeleted])
        #expect(throws: SceneFailure.inconsistent) { try scene.retain(id: "two", records: [cachedKept]) }
        try scene.chunk(id: "two", strokes: [fetched])
        try scene.end(id: "two")
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [1, 3]) // dropped left the manifest, deleted stays gone
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

    // MARK: - Strokes that only left the area (pan)

    private func line(_ sequence: Int64, x: Double, points: Int = 2) throws -> ServerStroke {
        let path = (0..<points).map { WorldPoint(x: x + Double($0 % 2) * 10, y: Double($0 % 50)) }
        let payload = try StrokePayload(id: UUID(), points: path, brush: .round, width: 6, color: "#202020", opacity: 1)
        return try M2TestSupport.confirmed(payload, sequence: sequence, own: false)
    }

    /// Panning keeps strokes that merely left the area (drawn, reusable by the manifest) and still drops
    /// a stroke missing inside the new area, which means it was deleted.
    @Test func panKeepsStrokesThatOnlyLeftTheAreaAndDropsDeletedOnes() throws {
        let a = try line(1, x: -80), b = try line(2, x: 60), c = try line(3, x: 150)
        let first = try bounds(), right = try WireBounds(minX: 0, minY: -100, maxX: 200, maxY: 100)
        var scene = SceneStore()
        scene.subscribe(id: "s1", bounds: first, unordered: true); try scene.begin(id: "s1")
        try scene.chunk(id: "s1", strokes: [a, b]); try scene.end(id: "s1")
        scene.subscribe(id: "s2", bounds: right, unordered: true)
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [1, 2]) // nothing blinks while loading
        try scene.begin(id: "s2"); try scene.chunk(id: "s2", strokes: [c]); try scene.end(id: "s2")
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [1, 3]) // b was deleted inside the area
        #expect(scene.cached(a.payload.id) != nil) // pan back: the manifest reuses it, nothing to download
        scene.subscribe(id: "s3", bounds: first, unordered: true); try scene.begin(id: "s3")
        try scene.end(id: "s3") // authoritative again for the left side: a was deleted meanwhile
        #expect(scene.ordered(hidden: []).map(\.server.sequence) == [3])
    }

    /// Out-of-area strokes are a bounded cache: farthest dropped first, and they yield room to the
    /// current subscription instead of making a dense area fail with `capacity`.
    @Test func outsideCacheIsBoundedAndYieldsToTheCurrentArea() throws {
        let perGroup = SceneStore.maximumOutsidePoints / 2 / 2000
        var sequence: Int64 = 0
        func group(x: Double, count: Int) throws -> [ServerStroke] {
            try (0..<count).map { _ in sequence += 1; return try line(sequence, x: x, points: 2000) }
        }
        let far = try group(x: -9000, count: perGroup), near = try group(x: -500, count: perGroup)
        let middle = try group(x: -3000, count: perGroup)
        var scene = SceneStore()
        let wide = try WireBounds(minX: -10_000, minY: -100, maxX: 10_000, maxY: 100)
        scene.subscribe(id: "wide", bounds: wide, unordered: true); try scene.begin(id: "wide")
        try scene.chunk(id: "wide", strokes: far + near + middle); try scene.end(id: "wide")
        let area = try WireBounds(minX: 0, minY: -100, maxX: 1000, maxY: 100)
        scene.subscribe(id: "pan", bounds: area, unordered: true); try scene.begin(id: "pan")
        try scene.end(id: "pan")
        let kept = Set(scene.ordered(hidden: []).map(\.server.payload.id))
        #expect(kept.count == 2 * perGroup)
        #expect(!far.contains { kept.contains($0.payload.id) })
        // A dense new area needs more than the room left: kept strokes give way, no capacity failure.
        let dense = try group(x: 500, count: (SceneStore.maximumPoints - SceneStore.maximumOutsidePoints) / 2000 + 1)
        scene.subscribe(id: "dense", bounds: area, unordered: true); try scene.begin(id: "dense")
        try scene.chunk(id: "dense", strokes: dense); try scene.end(id: "dense")
        let after = scene.ordered(hidden: [])
        #expect(after.count < dense.count + 2 * perGroup)
        #expect(Set(dense.map(\.payload.id)).isSubset(of: Set(after.map(\.server.payload.id))))
    }
}
