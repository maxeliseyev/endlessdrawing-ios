import MetalKit
import Testing
@testable import Endless_Drawing

/// Fault injection only; all mutable storage state is under lock.
private final class SwitchableJournalStorage: JournalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failing = false
    func failWrites(_ value: Bool) { lock.withLock { failing = value } }
    func read(maximumBytes: Int) -> Data? { lock.withLock { data } }
    func writeAtomically(_ data: Data) throws {
        try lock.withLock {
            if failing { throw CocoaError(.fileWriteNoPermission) }
            self.data = data
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct SharedCanvasTests {
    private func frame(_ renderer: MetalRenderer) throws -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
        desc.storageMode = .shared; desc.usage = [.renderTarget, .shaderRead]
        let texture = try #require(renderer.device.makeTexture(descriptor: desc))
        let command = try #require(renderer.queue.makeCommandBuffer())
        try renderer.encode(to: texture, viewport: CanvasSize(width: 128, height: 128), command: command)
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 128 * 4,
            from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0) }
        return pixels
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Shared canvas did not reach expected state"); throw TransportFailure.timedOut
    }
    private func make(storage: any JournalStorage, mode: WorldPeer.Mode) async throws
        -> (CanvasModel, CanvasViewController, WorldPeer, OperationJournal, UIWindow) {
        let environment = try M2TestSupport.environment(), id = UUID()
        let journal = try await OperationJournal.open(environment: environment, identityID: id, storage: storage)
        let peer = WorldPeer(mode: mode)
        let identity = DrawingIdentity(id: id, secret: try SessionSecret(bytes: Data(repeating: 9, count: 32)))
        let world = WorldSession(transport: peer, identity: identity, journal: journal, initial: await journal.snapshot())
        let model = CanvasModel(environment: environment, session: world)
        let controller = CanvasViewController(model: model)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await wait { model.worldState?.status == .live }
        return (model, controller, peer, journal, window)
    }

    @Test func pencilHandoffStaysVisibleThroughPersistEventAckAndServerUndo() async throws {
        let storage = SwitchableJournalStorage()
        let (model, controller, peer, journal, window) = try await make(storage: storage, mode: .delayFirstAck)
        defer { window.isHidden = true; model.deactivate() }
        let surface = try #require(controller.view as? MTKView)
        let renderer = try #require(surface.delegate as? MetalRenderer)
        var style = BrushStyle(); style.width = 12; style.opacity = 0.5
        let stroke = LocalStroke(id: UUID(), points: [WorldPoint(x: -40, y: 0), .zero], style: style)
        let preview = LocalStroke(id: stroke.id, points: stroke.points + [WorldPoint(x: 40, y: 0)], style: style)
        renderer.preview = try renderer.upload(#require(BrushGeometry.prepare(preview, realPointCount: 2)))
        controller.complete(stroke)
        #expect((renderer.strokes + renderer.overlay).filter { $0.id == stroke.id }.count == 1)
        let lifted = try frame(renderer)
        #expect(lifted[(64 * 128 + 44) * 4] < 255)
        #expect(lifted[(64 * 128 + 90) * 4] == 255) // predictions removed, real ink never cleared
        try await wait { await peer.creates().count == 1 }
        #expect(await journal.snapshot().operations.first?.mayHaveBeenSent == true)
        #expect(await journal.snapshot().undo.isEmpty)
        await peer.releaseAck()
        try await wait { model.worldState?.pendingCount == 0 }
        #expect(await journal.snapshot().undo.map(\.strokeID) == [stroke.id])
        #expect((renderer.strokes + renderer.overlay).filter { $0.id == stroke.id }.count == 1)
        #expect(try frame(renderer)[(64 * 128 + 44) * 4] < 255)
        model.command?(.undo)
        try await wait {
            let count = await peer.count()
            return count == 0 && model.worldState?.pendingCount == 0
        }
        #expect(try frame(renderer).allSatisfy { $0 == 255 })
    }

    @Test func failedDiskWriteKeepsVisibleRAMDraftAndRetryPersistsBeforeSending() async throws {
        let storage = SwitchableJournalStorage()
        let (model, controller, peer, journal, window) = try await make(storage: storage, mode: .normal)
        defer { window.isHidden = true; model.deactivate() }
        let renderer = try #require((controller.view as? MTKView)?.delegate as? MetalRenderer)
        storage.failWrites(true)
        let stroke = LocalStroke(id: UUID(), points: [.zero], style: BrushStyle())
        controller.complete(stroke)
        try await wait { model.failure != nil && (renderer.strokes + renderer.overlay).contains { $0.id == stroke.id } }
        #expect(await peer.creates().isEmpty)
        #expect(await journal.snapshot().operations.isEmpty)
        #expect(try frame(renderer).contains { $0 < 255 })
        storage.failWrites(false)
        model.failure = nil; model.command?(.retry)
        try await wait { await journal.snapshot().undo.count == 1 }
        #expect(await peer.creates().first?.payload.id == stroke.id)
        #expect((renderer.strokes + renderer.overlay).filter { $0.id == stroke.id }.count == 1)
    }
}
