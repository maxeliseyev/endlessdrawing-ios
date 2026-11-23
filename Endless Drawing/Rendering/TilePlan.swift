import Foundation

/// World-aligned raster tiles, ported from the web client (`src/webgl/tile-plan.ts`, `src/tiles.ts`).
/// Pure Double math, no Metal: which tiles a frame needs and where they land in backing pixels.
nonisolated enum TilePlan {
    /// Tile edge in backing pixels.
    static let size = 512
    /// After the last zoom change the scale stays on √2 steps for this long, then becomes exact.
    static let settle: TimeInterval = 0.180
    private static let level = 2.0.squareRoot()

    struct Rect: Equatable, Sendable {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
        func intersects(_ extent: StrokeExtent) -> Bool {
            extent.maxX >= minX && extent.minX <= maxX && extent.maxY >= minY && extent.minY <= maxY
        }
    }

    struct Key: Hashable, Sendable {
        /// Backing pixels per world unit; exact Double equality is intended (same plan, same key).
        let scale: Double
        let tx: Int64
        let ty: Int64
    }

    /// Target pixel = (world − origin) × scale. Shared by tiles and the drawable.
    struct View: Equatable, Sendable {
        var origin: WorldPoint
        var scale: Double
        var width: Int
        var height: Int
    }

    struct Placement: Equatable, Sendable { var x0: Int, y0: Int, x1: Int, y1: Int }

    struct ZoomClock: Equatable, Sendable {
        var zoom: Double?
        var zoomedAt: TimeInterval = -.infinity
    }

    struct Frame: Sendable {
        /// The drawable view with the camera snapped to whole backing pixels (shift ≤ 0.5 px).
        let view: View
        /// Exact backing pixels per world unit for this zoom.
        let exact: Double
        /// Scale tiles are built at: √2 level while zooming, exact once settled.
        let scale: Double
        /// Seconds until the scale becomes exact; nil when already settled.
        let settleIn: TimeInterval?
        /// Visible tiles, nearest to the centre first.
        let needed: [Key]
        let clock: ZoomClock
        fileprivate let visible: Rect
        /// One-tile ring around the visible ones for idle prefetch, nearest first. Computed on demand:
        /// it is only needed once zoom has settled and every visible tile is ready.
        var ring: [Key] { TilePlan.covering(visible, scale: scale, margin: 1) }
    }

    /// Smallest √2 power ≥ zoom, or zoom itself when it already is one.
    static func zoomLevel(_ zoom: Double) -> Double {
        let result = pow(level, (log(zoom) / log(level) - 1e-9).rounded(.up))
        return abs(result - zoom) <= zoom * 1e-9 ? zoom : result
    }

    static func worldSize(scale: Double) -> Double { Double(size) / scale }

    /// World area of a tile plus a two-pixel fringe so edge antialiasing of neighbours is included.
    static func bounds(_ key: Key) -> Rect {
        let world = worldSize(scale: key.scale), fringe = 2 / key.scale
        return Rect(minX: Double(key.tx) * world - fringe, minY: Double(key.ty) * world - fringe,
                    maxX: Double(key.tx + 1) * world + fringe, maxY: Double(key.ty + 1) * world + fringe)
    }

    /// The tile's own render view: its top-left backing pixel is the world tile origin.
    static func view(_ key: Key) -> View {
        let world = worldSize(scale: key.scale)
        return View(origin: WorldPoint(x: Double(key.tx) * world, y: Double(key.ty) * world),
                    scale: key.scale, width: size, height: size)
    }

    /// `pixelsPerPoint` is drawable pixels per UIKit point (not assumed to equal the screen scale).
    static func plan(camera: Camera, viewport: CanvasSize, pixelsPerPoint: Double, width: Int, height: Int,
                     now: TimeInterval, clock: ZoomClock) -> Frame {
        var zoomedAt = clock.zoomedAt
        if let previous = clock.zoom, previous != camera.zoom { zoomedAt = now }
        let exact = camera.zoom * pixelsPerPoint
        let wait = settle - (now - zoomedAt)
        let scale = wait <= 0 ? exact : zoomLevel(camera.zoom) * pixelsPerPoint
        // Integer pixel offset of the world origin: tiles at the exact scale land on whole pixels.
        let ox = (Double(width) / 2 - camera.center.x * exact).rounded()
        let oy = (Double(height) / 2 - camera.center.y * exact).rounded()
        let view = View(origin: WorldPoint(x: -ox / exact, y: -oy / exact), scale: exact, width: width, height: height)
        let visible = Rect(minX: view.origin.x, minY: view.origin.y,
                           maxX: view.origin.x + Double(width) / exact, maxY: view.origin.y + Double(height) / exact)
        return Frame(view: view, exact: exact, scale: scale, settleIn: wait > 0 ? wait : nil,
                     needed: covering(visible, scale: scale, margin: 0),
                     clock: ZoomClock(zoom: camera.zoom, zoomedAt: zoomedAt), visible: visible)
    }

    /// Destination rectangle of a tile in the drawable, in whole backing pixels; shared edges coincide.
    static func placement(_ key: Key, in view: View) -> Placement {
        let world = worldSize(scale: key.scale)
        func pixel(_ tile: Int64, _ origin: Double) -> Int { Int(((Double(tile) * world - origin) * view.scale).rounded()) }
        return Placement(x0: pixel(key.tx, view.origin.x), y0: pixel(key.ty, view.origin.y),
                         x1: pixel(key.tx + 1, view.origin.x), y1: pixel(key.ty + 1, view.origin.y))
    }

    static func covering(_ view: Rect, scale: Double, margin: Int64) -> [Key] {
        let world = worldSize(scale: scale)
        let x0 = Int64((view.minX / world).rounded(.down)) - margin, x1 = Int64((view.maxX / world).rounded(.down)) + margin
        let y0 = Int64((view.minY / world).rounded(.down)) - margin, y1 = Int64((view.maxY / world).rounded(.down)) + margin
        let cx = (view.minX + view.maxX) / 2 / world - 0.5, cy = (view.minY + view.maxY) / 2 / world - 0.5
        // Distance computed once per tile (per-comparison hypot dominated main-thread time on iPad).
        var keys: [(key: Key, distance: Double)] = []
        keys.reserveCapacity(Int((x1 - x0 + 1) * (y1 - y0 + 1)))
        for ty in y0...y1 {
            let dy = Double(ty) - cy
            for tx in x0...x1 {
                let dx = Double(tx) - cx
                keys.append((Key(scale: scale, tx: tx, ty: ty), dx * dx + dy * dy))
            }
        }
        keys.sort { $0.distance < $1.distance }
        return keys.map(\.key)
    }
}

/// Uniform world grid over stroke extents: which strokes a tile must draw, without scanning the scene.
nonisolated struct StrokeIndex {
    static let cell = 1024.0
    private var cells: [SIMD2<Int64>: Set<UUID>] = [:]
    private var extents: [UUID: StrokeExtent] = [:]

    var count: Int { extents.count }

    mutating func insert(_ id: UUID, extent: StrokeExtent) {
        remove(id)
        extents[id] = extent
        for cell in Self.cells(minX: extent.minX, minY: extent.minY, maxX: extent.maxX, maxY: extent.maxY) {
            cells[cell, default: []].insert(id)
        }
    }

    mutating func remove(_ id: UUID) {
        guard let extent = extents.removeValue(forKey: id) else { return }
        for cell in Self.cells(minX: extent.minX, minY: extent.minY, maxX: extent.maxX, maxY: extent.maxY) {
            cells[cell]?.remove(id)
            if cells[cell]?.isEmpty == true { cells[cell] = nil }
        }
    }

    mutating func removeAll() { cells.removeAll(); extents.removeAll() }

    /// Strokes whose extent intersects `rect` (unordered).
    func query(_ rect: TilePlan.Rect) -> [UUID] {
        var found: Set<UUID> = []
        for cell in Self.cells(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY) {
            for id in cells[cell] ?? [] where !found.contains(id) {
                if let extent = extents[id], rect.intersects(extent) { found.insert(id) }
            }
        }
        return Array(found)
    }

    private static func cells(minX: Double, minY: Double, maxX: Double, maxY: Double) -> [SIMD2<Int64>] {
        let x0 = Int64((minX / cell).rounded(.down)), x1 = Int64((maxX / cell).rounded(.down))
        let y0 = Int64((minY / cell).rounded(.down)), y1 = Int64((maxY / cell).rounded(.down))
        var result: [SIMD2<Int64>] = []
        result.reserveCapacity(Int((x1 - x0 + 1) * (y1 - y0 + 1)))
        for y in y0...y1 { for x in x0...x1 { result.append(SIMD2(x, y)) } }
        return result
    }
}
