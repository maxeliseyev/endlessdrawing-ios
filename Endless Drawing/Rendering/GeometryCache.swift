import Foundation
import Metal

/// GPU geometry by stroke id; the running byte total avoids re-summing the scene on each admission.
/// The budget is a soft target for optional prefetch, never permission to reject visible ink or a draft.
@MainActor
struct GeometryCache {
    private(set) var bytes = 0
    private var entries: [UUID: MetalRenderer.GPUStroke] = [:]

    subscript(id: UUID) -> MetalRenderer.GPUStroke? {
        get { entries[id] }
        set {
            if let old = entries[id] { bytes -= Self.cost(old) }
            entries[id] = newValue
            if let newValue { bytes += Self.cost(newValue) }
        }
    }

    var ids: [UUID] { Array(entries.keys) }

    mutating func retain(_ keep: (UUID) -> Bool) {
        for id in ids where !keep(id) { self[id] = nil }
    }

    /// Nil defers optional prefetch without changing the cache. Required geometry always proceeds,
    /// after evicting optional entries where possible. The caller performs the actual Metal allocation
    /// and records evicted ids as missing; canonical scene membership is never changed here.
    mutating func reserve(_ byteCount: Int, for id: UUID, budget: Int, required: Bool,
                          canEvict: (UUID) -> Bool) -> [UUID]? {
        var excess = bytes - (self[id].map(Self.cost) ?? 0) + byteCount - budget
        guard excess > 0 else { return [] }
        guard required else { return nil }
        var evicted: [UUID] = []
        for victim in ids where victim != id && canEvict(victim) {
            guard let stroke = self[victim] else { continue }
            excess -= Self.cost(stroke)
            self[victim] = nil
            evicted.append(victim)
            if excess <= 0 { break }
        }
        return evicted
    }

    static func cost(_ stroke: MetalRenderer.GPUStroke) -> Int {
        (stroke.triangles?.length ?? 0) + (stroke.circles?.length ?? 0)
    }
}
