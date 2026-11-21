import MetalKit
import Testing
@testable import Endless_Drawing

@Suite(.serialized)
@MainActor
struct GeometryCacheTests {
    private func geometry(bytes: Int, id: UUID = UUID()) throws -> MetalRenderer.GPUStroke {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let buffer = try #require(device.makeBuffer(length: bytes, options: .storageModeShared))
        let stroke = LocalStroke(id: id, points: [.zero], style: BrushStyle())
        return MetalRenderer.GPUStroke(id: id, origin: .zero, style: stroke.style, extent: StrokeExtent(stroke),
                                      triangles: buffer, triangleCount: 0, circles: nil, circleCount: 0,
                                      realTriangleCount: 0, realCircleCount: 0)
    }

    @Test func requiredGeometryMayExceedPrefetchTargetWithoutDroppingVisibleInk() throws {
        var cache = GeometryCache()
        let visible = try geometry(bytes: 48), next = try geometry(bytes: 48)
        cache[visible.id] = visible
        let evicted = cache.reserve(GeometryCache.cost(next), for: next.id, budget: 64, required: true, canEvict: { _ in false })
        #expect(evicted == [])
        cache[next.id] = next
        #expect(cache.bytes == 96 && cache[visible.id] != nil && cache[next.id] != nil)
        let draft = try geometry(bytes: 80)
        #expect(cache.reserve(80, for: draft.id, budget: 64, required: true, canEvict: { _ in false }) == [])
        cache[draft.id] = draft
        #expect(cache.bytes == 176) // a finalized local draft is not rejected at the old cutoff
    }

    @Test func optionalPrefetchDefersWithoutEvictingAndVisibleGeometryEvictsOnlyOptionalEntries() throws {
        var cache = GeometryCache()
        let visible = try geometry(bytes: 32), far = try geometry(bytes: 32), next = try geometry(bytes: 32)
        cache[visible.id] = visible; cache[far.id] = far
        #expect(cache.reserve(32, for: next.id, budget: 64, required: false, canEvict: { _ in true }) == nil)
        #expect(cache.bytes == 64 && cache[far.id] != nil && cache[visible.id] != nil)
        #expect(cache.reserve(32, for: next.id, budget: 64, required: true, canEvict: { $0 == far.id }) == [far.id])
        cache[next.id] = next
        #expect(cache.bytes == 64 && cache[far.id] == nil && cache[visible.id] != nil)
        // The canonical scene can request the evicted record on a later pan.
        #expect(cache.reserve(32, for: far.id, budget: 64, required: true, canEvict: { $0 == next.id }) == [next.id])
        cache[far.id] = far
        #expect(cache.bytes == 64 && cache[far.id] != nil)
    }

    @Test func replacementAndRemovalKeepExactByteAccounting() throws {
        var cache = GeometryCache()
        let original = try geometry(bytes: 48)
        cache[original.id] = original
        let replacement = try geometry(bytes: 64, id: original.id)
        #expect(cache.reserve(64, for: original.id, budget: 64, required: false, canEvict: { _ in true }) == [])
        cache[original.id] = replacement
        #expect(cache.bytes == 64)
        cache.retain { _ in false }
        #expect(cache.bytes == 0 && cache.ids.isEmpty)
    }

    /// Production regression: the previous controller showed "too dense" and disabled the Pencil at
    /// 64 MiB. These visible spray strokes use 72 MiB, but only 96 canonical points and valid GPU buffers.
    @Test(.timeLimit(.minutes(1))) func sharedCanvasFinishesVisibleGeometryAbove64MiBWithoutAnAlertOrDrawingLock() async throws {
        let environment = try M2TestSupport.environment()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await OperationJournal.open(environment: environment, identityID: UUID(),
            storage: JournalFileStorage(url: directory.appendingPathComponent("journal.json")))
        let initial = await journal.snapshot()
        let identity = DrawingIdentity(id: initial.identityID, secret: try SessionSecret(bytes: Data(repeating: 1, count: 32)))
        let world = WorldSession(transport: WebSocketTransport(environment: environment), identity: identity,
                                 journal: journal, initial: initial)
        // Never shown in a window: no network activation and no continuous display link.
        let model = CanvasModel(environment: environment, session: world)
        let controller = CanvasViewController(model: model)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        var records = try (1...48).map { sequence in
            let payload = try StrokePayload(id: UUID(), points: [WorldPoint(x: -16_384, y: 0), WorldPoint(x: 16_384, y: 0)],
                                            brush: .spray, width: 64, color: "#202020", opacity: 1)
            return SceneStroke(try ServerStroke(payload: payload, sequence: Int64(sequence), own: false))
        }
        // A visible corner is farther from the centre than an optional stroke just beyond the side.
        // A full prefetch cache must not stop the queue before this required corner is uploaded.
        for (index, point) in [WorldPoint(x: 500, y: 350), WorldPoint(x: 520, y: 0)].enumerated() {
            let payload = try StrokePayload(id: UUID(), points: [point], brush: .round, width: 6, color: "#202020", opacity: 1)
            records.append(SceneStroke(try ServerStroke(payload: payload, sequence: Int64(49 + index), own: false)))
        }
        model.onWorld?(WorldRenderState(revision: 1, status: .live, issue: nil, confirmed: records, pending: [],
                                        hidden: [], pendingCount: 0, canUndo: false))
        for _ in 0..<1000 {
            if controller.pendingGeometryCount == 1 || model.failure != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.failure == nil)
        #expect(model.canDraw)
        #expect(controller.pendingGeometryCount == 1) // only the optional offscreen stroke is deferred
        #expect(controller.geometryBytes > 64 * 1024 * 1024)
    }
}
