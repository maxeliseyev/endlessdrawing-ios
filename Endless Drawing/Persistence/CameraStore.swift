import Foundation

/// Small environment-scoped preference, never an owner credential or copy of the world.
actor CameraStore {
    private let storage: any JournalStorage
    init(storage: any JournalStorage) { self.storage = storage }

    func load() throws -> Camera? {
        guard let data = try storage.read(maximumBytes: 4096) else { return nil }
        let value = try JSONDecoder().decode(Record.self, from: data)
        guard value.version == 1, value.center.isValid, value.zoom.isFinite,
              (Camera.minimumZoom...Camera.maximumZoom).contains(value.zoom) else { return nil }
        var camera = Camera()
        camera.pan(screenDelta: WorldPoint(x: -value.center.x, y: -value.center.y))
        camera.zoom(to: value.zoom, anchor: WorldPoint(x: 0.5, y: 0.5), viewport: CanvasSize(width: 1, height: 1))
        return camera
    }

    func save(_ camera: Camera) throws {
        try storage.writeAtomically(JSONEncoder().encode(Record(version: 1, center: camera.center, zoom: camera.zoom)))
    }
    private nonisolated struct Record: Codable { let version: Int; let center: WorldPoint; let zoom: Double }
}
