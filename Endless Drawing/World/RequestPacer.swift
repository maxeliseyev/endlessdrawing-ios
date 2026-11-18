import Foundation

/// Conservative rolling monotonic windows, including control traffic in the total budget.
nonisolated struct RequestPacer {
    enum Kind: Sendable { case hello, subscribe, create, delete, ping, fetch }
    private var frames: [(Kind, TimeInterval)] = []
    mutating func admit(_ kind: Kind, now: TimeInterval) -> Bool {
        frames.removeAll { now - $0.1 >= 1.1 }
        guard frames.count < 80 else { return false }
        let limit: Int
        // fetch counts toward the total but is not a new subscribe; ≤21 batches per snapshot.
        switch kind { case .create, .subscribe: limit = 5; case .delete, .fetch: limit = 20; default: limit = 80 }
        guard frames.filter({ $0.0 == kind }).count < limit else { return false }
        if kind == .subscribe, let previous = frames.last(where: { $0.0 == .subscribe }), now - previous.1 < 0.30 { return false }
        frames.append((kind, now)); return true
    }
}
