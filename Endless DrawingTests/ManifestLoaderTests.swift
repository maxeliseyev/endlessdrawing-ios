import Foundation
import Testing
@testable import Endless_Drawing

struct ManifestLoaderTests {
    private let token = UUID()

    private func record(_ sequence: Int64, points: Int = 2) throws -> SceneStroke {
        let payload = try StrokePayload(id: UUID(), points: (0..<points).map { WorldPoint(x: Double($0), y: 0) },
                                        brush: .round, width: 4, color: "#202020", opacity: 1)
        return SceneStroke(try ServerStroke(payload: payload, sequence: sequence, own: false))
    }

    private func loaded(_ members: [SceneStroke], known: Set<UUID>) throws -> (ManifestLoader, [SceneStroke], ManifestLoader.FetchRequest) {
        var loader = ManifestLoader()
        loader.start(subscriptionID: "s", cached: true)
        try loader.begin(id: "s", token: token, strokeCount: members.count, pointCount: members.reduce(0) { $0 + $1.server.payload.points.count })
        try loader.chunk(id: "s", token: token, strokeIDs: members.map(\.server.payload.id))
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.server.payload.id, $0) })
        let result = try #require(try loader.end(id: "s", token: token, cached: { known.contains($0) ? byID[$0] : nil }))
        return (loader, result.retained, result.request)
    }

    @Test func fullyWarmAreaSendsEmptyFinalFetchAndNoGeometry() throws {
        let members = try (1...3).map { try record($0) }
        var (loader, retained, request) = try loaded(members, known: Set(members.map(\.server.payload.id)))
        #expect(retained.map(\.server.sequence) == [1, 2, 3])
        #expect(request == .init(subscriptionID: "s", token: token, batch: 0, strokeIDs: [], final: true))
        try loader.snapshotEnd(id: "s")
        #expect(!loader.isActive)
    }

    @Test func partialAreaFetchesOnlyMissingInManifestOrder() throws {
        let members = try (1...4).map { try record($0) }
        let known = Set([members[0], members[2]].map(\.server.payload.id))
        var (loader, retained, request) = try loaded(members, known: known)
        #expect(Set(retained.map(\.server.payload.id)) == known)
        #expect(request.strokeIDs == [members[1], members[3]].map(\.server.payload.id) && request.final)
        try loader.geometry(id: "s", strokes: [members[3].server])
        try loader.geometry(id: "s", strokes: [members[1].server])
        try loader.snapshotEnd(id: "s")
    }

    @Test func largeMissingSetIsFetchedInStopAndWaitBatches() throws {
        let members = try (1...2500).map { try record(Int64($0), points: 1) }
        var (loader, _, first) = try loaded(members, known: [])
        #expect(first.batch == 0 && first.strokeIDs.count == 1000 && !first.final)
        #expect(throws: ManifestLoader.Failure.resync) { try loader.fetchEnd(id: "s", token: token, batch: 0) } // batch not complete
        try loader.geometry(id: "s", strokes: members[0..<1000].map(\.server))
        let second = try #require(try loader.fetchEnd(id: "s", token: token, batch: 0))
        #expect(second.batch == 1 && second.strokeIDs.count == 1000 && !second.final)
        try loader.geometry(id: "s", strokes: members[1000..<2000].map(\.server))
        let third = try #require(try loader.fetchEnd(id: "s", token: token, batch: 1))
        #expect(third.batch == 2 && third.strokeIDs.count == 500 && third.final)
        try loader.geometry(id: "s", strokes: members[2000...].map(\.server))
        #expect(throws: ManifestLoader.Failure.resync) { try loader.fetchEnd(id: "s", token: token, batch: 2) } // final ends with snapshot.end
        try loader.snapshotEnd(id: "s")
    }

    @Test func contractViolationsRequireResync() throws {
        let members = try (1...2).map { try record($0) }
        let other = try record(9)
        var (loader, _, _) = try loaded(members, known: [])
        #expect(throws: ManifestLoader.Failure.resync) { try loader.geometry(id: "s", strokes: [other.server]) } // not requested
        (loader, _, _) = try loaded(members, known: [])
        #expect(throws: ManifestLoader.Failure.resync) { try loader.geometry(id: "s", strokes: [members[0].server, members[0].server]) }
        (loader, _, _) = try loaded(members, known: [])
        try loader.geometry(id: "s", strokes: [members[0].server])
        #expect(throws: ManifestLoader.Failure.resync) { try loader.snapshotEnd(id: "s") } // incomplete

        var wrong = ManifestLoader()
        wrong.start(subscriptionID: "s", cached: true)
        try wrong.begin(id: "s", token: token, strokeCount: 1, pointCount: 2)
        #expect(throws: ManifestLoader.Failure.resync) { try wrong.chunk(id: "s", token: UUID(), strokeIDs: [UUID()]) }
        var duplicate = ManifestLoader()
        duplicate.start(subscriptionID: "s", cached: true)
        try duplicate.begin(id: "s", token: token, strokeCount: 2, pointCount: 4)
        let id = UUID()
        #expect(throws: ManifestLoader.Failure.resync) { try duplicate.chunk(id: "s", token: token, strokeIDs: [id, id]) }
        var short = ManifestLoader()
        short.start(subscriptionID: "s", cached: true)
        try short.begin(id: "s", token: token, strokeCount: 2, pointCount: 4)
        try short.chunk(id: "s", token: token, strokeIDs: [UUID()])
        #expect(throws: ManifestLoader.Failure.resync) { _ = try short.end(id: "s", token: token, cached: { _ in nil }) }
        var lying = ManifestLoader() // cached members already exceed the announced point count
        lying.start(subscriptionID: "s", cached: true)
        try lying.begin(id: "s", token: token, strokeCount: 1, pointCount: 1)
        try lying.chunk(id: "s", token: token, strokeIDs: [members[0].server.payload.id])
        #expect(throws: ManifestLoader.Failure.resync) { _ = try lying.end(id: "s", token: token, cached: { _ in members[0] }) }
    }

    @Test func otherSubscriptionsAndFullSnapshotsAreIgnored() throws {
        var loader = ManifestLoader()
        loader.start(subscriptionID: "new", cached: true)
        try loader.begin(id: "old", token: token, strokeCount: 5, pointCount: 5) // stale scope: ignored
        #expect(!loader.owns("old") && loader.owns("new"))
        var full = ManifestLoader()
        full.start(subscriptionID: "x", cached: false)
        #expect(!full.isActive && !full.owns("x"))
    }
}
