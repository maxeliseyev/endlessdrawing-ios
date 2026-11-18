import Foundation
import os

/// Points of Interest for Instruments (architecture §12). Counts and durations only: never payloads,
/// identity, raw frames or user points.
nonisolated enum Signposts {
    static let frame = OSSignposter(subsystem: subsystem, category: "frame")
    static let geometry = OSSignposter(subsystem: subsystem, category: "geometry")
    static let tiles = OSSignposter(subsystem: subsystem, category: "tiles")
    static let snapshot = OSSignposter(subsystem: subsystem, category: "snapshot")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "EndlessDrawing"
}
