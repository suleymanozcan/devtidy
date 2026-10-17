import Foundation

/// One observation of a resource for idle detection.
struct IdleSample: Sendable, Equatable {
    /// CPU above the threshold, or (servers) at least one established connection.
    let isActive: Bool
    /// Uptime of the resource: lets a freshly launched DevTidy flag something that has been silent for hours (D7).
    let age: TimeInterval
}

/// Three-state idle detection (§6.3). A plain value type mutated only by `DevTidyStore`; the clock is injected via `now`.
struct IdleTracker<Key: Hashable & Sendable>: Sendable {
    private struct Entry: Sendable {
        let firstSeen: Date
        var lastActive: Date?
    }

    private var entries: [Key: Entry] = [:]

    init() {}

    /// Keys absent from `samples` are dropped. Active sample ⇒ `lastActive = now`.
    /// Inactive: `quietSince = lastActive ?? firstSeen`; `now - quietSince >= threshold` ⇒ `.idle`;
    /// else `lastActive == nil && age >= threshold` ⇒ `.probablyIdle` (silent for longer than the window by
    /// uptime alone, not yet observed that long); else `.active`.
    mutating func update(_ samples: [Key: IdleSample], threshold: TimeInterval, now: Date) -> [Key: IdleState] {
        var next: [Key: Entry] = [:]
        next.reserveCapacity(samples.count)
        var states: [Key: IdleState] = [:]
        states.reserveCapacity(samples.count)

        for (key, sample) in samples {
            var entry = entries[key] ?? Entry(firstSeen: now, lastActive: nil)
            if sample.isActive {
                entry.lastActive = now
                states[key] = .active
            } else {
                let quietSince = entry.lastActive ?? entry.firstSeen
                if now.timeIntervalSince(quietSince) >= threshold {
                    states[key] = .idle
                } else if entry.lastActive == nil && sample.age >= threshold {
                    states[key] = .probablyIdle
                } else {
                    states[key] = .active
                }
            }
            next[key] = entry
        }
        entries = next
        return states
    }
}
