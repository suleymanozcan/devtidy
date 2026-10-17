import Foundation

/// The two cumulative counters CPU% is differenced over (previous poll vs. this poll).
struct DockerCPUCounters: Equatable, Sendable {
    let total: UInt64      // cpu_stats.cpu_usage.total_usage (ns of CPU time)
    let system: UInt64     // cpu_stats.system_cpu_usage (ns of host CPU time, summed over CPUs)
}

/// One `GET /containers/<id>/stats?stream=false&one-shot=true` reading. One-shot responses carry no usable `precpu_stats`
/// (ENV §7.9: `precpu_stats.cpu_usage.total_usage == 0`), so CPU% always needs the previous poll's counters.
struct StatsSample: Equatable, Sendable {
    let cpuTotal: UInt64?
    let systemCPU: UInt64?
    let onlineCPUs: Int?
    let perCPUCount: Int?
    let memoryUsage: UInt64?
    /// `inactive_file` (cgroup v2) preferred over `total_inactive_file` (cgroup v1).
    let inactiveFile: UInt64?
    let memoryLimit: UInt64?

    /// nil unless both counters are present.
    var counters: DockerCPUCounters? {
        guard let total = cpuTotal, let system = systemCPU else { return nil }
        return DockerCPUCounters(total: total, system: system)
    }
}

extension StatsSample {
    init(_ wire: WireStats) {
        self.init(
            cpuTotal: wire.cpuStats?.cpuUsage?.totalUsage,
            systemCPU: wire.cpuStats?.systemCPUUsage,
            onlineCPUs: wire.cpuStats?.onlineCPUs,
            perCPUCount: wire.cpuStats?.cpuUsage?.perCPUUsage?.count,
            memoryUsage: wire.memoryStats?.usage,
            inactiveFile: wire.memoryStats?.stats?.inactiveFile ?? wire.memoryStats?.stats?.totalInactiveFile,
            memoryLimit: wire.memoryStats?.limit
        )
    }
}

/// What the client keeps per running container between polls (`lastStats`).
struct DockerContainerStats: Equatable, Sendable {
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let memoryLimitBytes: UInt64?
}

enum DockerStatsCalculator {
    /// `Δcontainer / Δsystem × cpuCount × 100` (the `docker stats` formula): percent of ONE core, may exceed 100.
    /// nil without a previous sample, when either counter went backwards (container restarted), when the container
    /// counters are absent, or when the system delta is not positive. A zero container delta is a real 0 %.
    static func cpuPercent(previous: DockerCPUCounters?, current: StatsSample) -> Double? {
        guard let previous, let now = current.counters else { return nil }
        guard now.total >= previous.total, now.system > previous.system else { return nil }
        let containerDelta = Double(now.total - previous.total)
        let systemDelta = Double(now.system - previous.system)
        return containerDelta / systemDelta * Double(cpuCount(current)) * 100.0
    }

    /// Shortest host-CPU window a percentage is computed over: 100 ms of wall time on every CPU (`system_cpu_usage` is host CPU
    /// time summed over CPUs, in ns).
    static let minimumWindowNanosecondsPerCPU: UInt64 = 100_000_000

    /// True when both samples carry counters, nothing went backwards, and the host-CPU delta is below the minimum window. Two
    /// refreshes that land back to back would otherwise be differenced over a few milliseconds: a spiky (or, at zero delta,
    /// blank) CPU% that also resets the idle clock. Resets (counters going backwards) are not "too short"; `cpuPercent`
    /// reports those as nil so the baseline restarts.
    static func isWindowTooShort(previous: DockerCPUCounters?, current: StatsSample) -> Bool {
        guard let previous, let now = current.counters else { return false }
        guard now.total >= previous.total, now.system >= previous.system else { return false }
        let (minimum, overflow) = UInt64(cpuCount(current)).multipliedReportingOverflow(by: minimumWindowNanosecondsPerCPU)
        return now.system - previous.system < (overflow ? UInt64.max : minimum)
    }

    /// `online_cpus`, else the length of `percpu_usage`, else 1.
    static func cpuCount(_ sample: StatsSample) -> Int {
        if let online = sample.onlineCPUs, online > 0 { return online }
        if let perCPU = sample.perCPUCount, perCPU > 0 { return perCPU }
        return 1
    }

    /// `usage − inactive_file` (page cache is reclaimable and not what `docker stats` reports), saturating at 0.
    static func memoryBytes(_ sample: StatsSample) -> UInt64? {
        guard let usage = sample.memoryUsage else { return nil }
        let inactive = sample.inactiveFile ?? 0
        return usage > inactive ? usage - inactive : 0
    }

    static func stats(previous: DockerCPUCounters?, current: StatsSample) -> DockerContainerStats {
        DockerContainerStats(cpuPercent: cpuPercent(previous: previous, current: current),
                             memoryBytes: memoryBytes(current),
                             memoryLimitBytes: current.memoryLimit)
    }
}
