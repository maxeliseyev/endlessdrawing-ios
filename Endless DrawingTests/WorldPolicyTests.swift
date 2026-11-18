import Foundation
import Testing
@testable import Endless_Drawing

struct WorldPolicyTests {
    @Test func rollingBudgetsIncludeControlFramesAndDoNotResetOnChunkTraffic() {
        func check(_ budget: inout RequestPacer, _ kind: RequestPacer.Kind, _ time: Double, _ expected: Bool) {
            let permitted = budget.admit(kind, now: time)
            #expect(permitted == expected)
        }
        var budget = RequestPacer()
        for _ in 0..<5 { check(&budget, .create, 0, true) }
        check(&budget, .create, 1.09, false)
        check(&budget, .create, 1.1, true)
        for _ in 0..<20 { check(&budget, .delete, 1.1, true) }
        check(&budget, .delete, 1.1, false)
        check(&budget, .subscribe, 1.1, true)
        check(&budget, .subscribe, 1.39, false)
        check(&budget, .subscribe, 1.41, true)
        var frames = RequestPacer()
        for _ in 0..<80 { check(&frames, .ping, 0, true) }
        check(&frames, .hello, 0, false)
        check(&frames, .hello, 1.1, true)
    }

    @Test func cameraPreferenceRestoresEightPercentAndWorldEdgeWithoutTouchingJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("camera-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JournalFileStorage(url: directory.appendingPathComponent("camera.json"))
        let store = CameraStore(storage: storage)
        #expect(try await store.load() == nil)
        var camera = Camera()
        camera.pan(screenDelta: WorldPoint(x: -1e9, y: 1e9))
        camera.zoom(to: 0.08, anchor: WorldPoint(x: 512, y: 384), viewport: CanvasSize(width: 1024, height: 768))
        try await store.save(camera)
        #expect(try await CameraStore(storage: storage).load() == camera)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("operations.json").path))
    }
}
