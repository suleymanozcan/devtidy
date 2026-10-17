import Foundation
import Testing
@testable import DevTidyCore

@Suite("DockerStatsCalculator")
struct DockerStatsCalculatorTests {
    private func sample(_ json: String) throws -> StatsSample {
        StatsSample(try JSONDecoder().decode(WireStats.self, from: Data(json.utf8)))
    }

    private func counters(_ total: UInt64, _ system: UInt64) -> DockerCPUCounters {
        DockerCPUCounters(total: total, system: system)
    }

    private func measured(_ previous: DockerCPUCounters?, _ current: StatsSample) throws -> Double {
        let value = try #require(DockerStatsCalculator.cpuPercent(previous: previous, current: current))
        return value
    }

    // MARK: CPU%

    @Test func firstSampleHasNoCPU() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 1_000_000_000, system: 100_000_000_000))
        #expect(DockerStatsCalculator.cpuPercent(previous: nil, current: current) == nil)
        #expect(current.counters == counters(1_000_000_000, 100_000_000_000))
    }

    @Test func secondSampleGivesTheHandComputedPercentage() throws {
        // Δcontainer = 0.4e9, Δsystem = 4e9, 4 CPUs ⇒ 0.4/4 × 4 × 100 = 40 %.
        let current = try sample(S3Fixtures.statsJSON(total: 1_400_000_000, system: 104_000_000_000, cpus: 4))
        let percent = try #require(DockerStatsCalculator.cpuPercent(previous: counters(1_000_000_000, 100_000_000_000), current: current))
        #expect(abs(percent - 40.0) < 1e-9)
    }

    @Test func oneCoreFullyBusyOnAFourCoreHostIs100Percent() throws {
        // Δsystem = 4 s of host CPU over 1 s wall on 4 CPUs; the container used 1 s ⇒ 1/4 × 4 × 100 = 100 %.
        let current = try sample(S3Fixtures.statsJSON(total: 11_000_000_000, system: 14_000_000_000, cpus: 4))
        let percent = try #require(DockerStatsCalculator.cpuPercent(previous: counters(10_000_000_000, 10_000_000_000), current: current))
        #expect(abs(percent - 100.0) < 1e-9)
    }

    @Test func percentageCanExceedOneHundred() throws {
        // Δsystem = 4e9 (1 s of wall on 4 CPUs) and the container consumed 4e9 of CPU time: all 4 cores busy ⇒ 400 %.
        let current = try sample(S3Fixtures.statsJSON(total: 4_000_000_000, system: 8_000_000_000, cpus: 4))
        let percent = try #require(DockerStatsCalculator.cpuPercent(previous: counters(0, 4_000_000_000), current: current))
        #expect(abs(percent - 400.0) < 1e-9)
    }

    @Test func idleContainerIsAGenuineZero() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 5_000, system: 20_000_000_000))
        #expect(DockerStatsCalculator.cpuPercent(previous: counters(5_000, 10_000_000_000), current: current) == 0)
    }

    @Test func cpuCountFallsBackToPerCPUThenToOne() throws {
        let previous = counters(0, 0)
        let perCPU = try sample(S3Fixtures.statsJSON(total: 400_000_000, system: 4_000_000_000, cpus: nil, perCPU: [100, 100]))
        #expect(abs(try measured(previous, perCPU) - 20.0) < 1e-9)  // ×2

        let none = try sample(S3Fixtures.statsJSON(total: 400_000_000, system: 4_000_000_000, cpus: nil))
        #expect(abs(try measured(previous, none) - 10.0) < 1e-9)    // ×1

        let zero = try sample(S3Fixtures.statsJSON(total: 400_000_000, system: 4_000_000_000, cpus: 0, perCPU: []))
        #expect(DockerStatsCalculator.cpuCount(zero) == 1)
    }

    @Test func counterResetGivesNil() throws {
        // Container restarted: its cumulative usage went backwards.
        let restarted = try sample(S3Fixtures.statsJSON(total: 500, system: 104_000_000_000))
        #expect(DockerStatsCalculator.cpuPercent(previous: counters(1_000_000_000, 100_000_000_000), current: restarted) == nil)
        // The host counter went backwards (daemon restart).
        let hostReset = try sample(S3Fixtures.statsJSON(total: 2_000_000_000, system: 1_000))
        #expect(DockerStatsCalculator.cpuPercent(previous: counters(1_000_000_000, 100_000_000_000), current: hostReset) == nil)
    }

    @Test func zeroSystemDeltaGivesNil() throws {
        let same = try sample(S3Fixtures.statsJSON(total: 2_000_000_000, system: 100_000_000_000))
        #expect(DockerStatsCalculator.cpuPercent(previous: counters(1_000_000_000, 100_000_000_000), current: same) == nil)
    }

    // MARK: Minimum window

    @Test func windowsBelowOneHundredMillisecondsPerCPUAreTooShort() throws {
        let previous = counters(1_000_000_000, 100_000_000_000)
        // 4 CPUs ⇒ the minimum host-CPU delta is 4 × 100 ms = 4e8 ns.
        let below = try sample(S3Fixtures.statsJSON(total: 1_100_000_000, system: 100_399_999_999, cpus: 4))
        let exactly = try sample(S3Fixtures.statsJSON(total: 1_100_000_000, system: 100_400_000_000, cpus: 4))
        #expect(DockerStatsCalculator.isWindowTooShort(previous: previous, current: below))
        #expect(!DockerStatsCalculator.isWindowTooShort(previous: previous, current: exactly))
        // No delta at all is too short as well (two samples inside one host clock tick).
        let same = try sample(S3Fixtures.statsJSON(total: 1_000_000_000, system: 100_000_000_000, cpus: 4))
        #expect(DockerStatsCalculator.isWindowTooShort(previous: previous, current: same))
    }

    @Test func tooShortNeverAppliesToFirstSamplesResetsOrMissingCounters() throws {
        let first = try sample(S3Fixtures.statsJSON(total: 5, system: 6))
        #expect(!DockerStatsCalculator.isWindowTooShort(previous: nil, current: first))
        let restarted = try sample(S3Fixtures.statsJSON(total: 500, system: 100_000_000_001))
        #expect(!DockerStatsCalculator.isWindowTooShort(previous: counters(1_000_000_000, 100_000_000_000), current: restarted))
        let hostReset = try sample(S3Fixtures.statsJSON(total: 2_000_000_000, system: 1_000))
        #expect(!DockerStatsCalculator.isWindowTooShort(previous: counters(1_000_000_000, 100_000_000_000), current: hostReset))
        let empty = try sample("{}")
        #expect(!DockerStatsCalculator.isWindowTooShort(previous: counters(1, 1), current: empty))
    }

    @Test func absurdCPUCountsCannotOverflowTheMinimumWindow() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 10, system: 11, cpus: Int.max))
        #expect(DockerStatsCalculator.isWindowTooShort(previous: counters(5, 10), current: current))      // saturates, no trap
    }

    @Test func missingCountersGiveNil() throws {
        let noSystem = try sample(#"{"cpu_stats":{"cpu_usage":{"total_usage":10}},"memory_stats":{"usage":1}}"#)
        #expect(noSystem.counters == nil)
        #expect(DockerStatsCalculator.cpuPercent(previous: counters(1, 1), current: noSystem) == nil)
        let empty = try sample("{}")
        #expect(empty.counters == nil)
        #expect(DockerStatsCalculator.cpuPercent(previous: counters(1, 1), current: empty) == nil)
    }

    // MARK: Memory

    @Test func memoryMinusInactiveFileOnCgroupV2() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 1, system: 1, usage: 1_000_000, inactiveFile: 200_000, limit: 6_210_576_384))
        #expect(DockerStatsCalculator.memoryBytes(current) == 800_000)
        #expect(current.memoryLimit == 6_210_576_384)
        let stats = DockerStatsCalculator.stats(previous: nil, current: current)
        #expect(stats == DockerContainerStats(cpuPercent: nil, memoryBytes: 800_000, memoryLimitBytes: 6_210_576_384))
    }

    @Test func memoryMinusTotalInactiveFileOnCgroupV1() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 1, system: 1, usage: 1_000_000, totalInactiveFile: 300_000))
        #expect(DockerStatsCalculator.memoryBytes(current) == 700_000)
    }

    @Test func inactiveFileWinsOverTotalInactiveFile() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 1, system: 1, usage: 1_000_000, inactiveFile: 100_000, totalInactiveFile: 900_000))
        #expect(DockerStatsCalculator.memoryBytes(current) == 900_000)
    }

    @Test func memorySaturatesAtZero() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 1, system: 1, usage: 100, inactiveFile: 5_000))
        #expect(DockerStatsCalculator.memoryBytes(current) == 0)
    }

    @Test func memoryWithoutDetailStatsIsRawUsage() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 1, system: 1, usage: 4_096))
        #expect(DockerStatsCalculator.memoryBytes(current) == 4_096)
    }

    @Test func missingMemoryIsNil() throws {
        let current = try sample(#"{"cpu_stats":{"cpu_usage":{"total_usage":10},"system_cpu_usage":20}}"#)
        #expect(DockerStatsCalculator.memoryBytes(current) == nil)
        #expect(current.memoryLimit == nil)
    }

    @Test func combinedStats() throws {
        let current = try sample(S3Fixtures.statsJSON(total: 1_400_000_000, system: 104_000_000_000, usage: 70_020_000, inactiveFile: 20_000, limit: 6_210_576_384))
        let stats = DockerStatsCalculator.stats(previous: counters(1_000_000_000, 100_000_000_000), current: current)
        let cpu = try #require(stats.cpuPercent)
        #expect(abs(cpu - 40.0) < 1e-9)
        #expect(stats.memoryBytes == 70_000_000)
        #expect(stats.memoryLimitBytes == 6_210_576_384)
    }
}
