import Foundation

// MARK: - Policy -----------------------------------------------------------------

/// Pure cadence table (§6.2). Every interval is re-read on each loop iteration, so visibility / power-state
/// changes apply at once.
///
/// | Loop            | Popover open               | Popover closed             | Low Power Mode |
/// |-----------------|----------------------------|----------------------------|----------------|
/// | processes       | 2 s                        | 10 s                       | ×2             |
/// | docker list     | 3 s                        | 30 s                       | ×2             |
/// | docker stats    | 10 s (≥ 1 running only)    | 120 s (≥ 1 running only)   | ×2             |
///
/// Docker `.notRunning` / `.notInstalled` replaces the list interval by a 15 s (open) / 60 s (closed) back-off
/// (Low Power Mode still doubles it). Builds scan and build-cache summary have their own staleness windows below.
struct PollingPolicy: Equatable, Sendable {
    var popoverVisible: Bool
    var lowPowerMode: Bool
    /// False when the last Docker status was `.notRunning` / `.notInstalled`.
    var dockerReachable: Bool
    var runningContainerCount: Int

    init(popoverVisible: Bool = false, lowPowerMode: Bool = false, dockerReachable: Bool = true, runningContainerCount: Int = 0) {
        self.popoverVisible = popoverVisible
        self.lowPowerMode = lowPowerMode
        self.dockerReachable = dockerReachable
        self.runningContainerCount = runningContainerCount
    }

    /// Auto-refresh windows while the popover is open (§6.2: "auto at most every 30 min" / "≤ every 5 min").
    static let buildsAutoRefresh: TimeInterval = 30 * 60
    static let buildCacheRefresh: TimeInterval = 5 * 60

    private var multiplier: Double { lowPowerMode ? 2 : 1 }

    var processInterval: Duration {
        .seconds((popoverVisible ? 2 : 10) * multiplier)
    }

    var dockerListInterval: Duration {
        let base: Double
        if dockerReachable {
            base = popoverVisible ? 3 : 30
        } else {
            base = popoverVisible ? 15 : 60
        }
        return .seconds(base * multiplier)
    }

    /// nil = the stats loop is disabled (no running container, or Docker is down).
    var dockerStatsInterval: Duration? {
        guard dockerReachable, runningContainerCount > 0 else { return nil }
        return .seconds((popoverVisible ? 10 : 120) * multiplier)
    }
}

// MARK: - Loop gate --------------------------------------------------------------

/// A cancellable, pokeable sleep. `poke()` ends the current sleep early (or makes the next one return at once
/// if the loop is busy working). Confined to the main actor together with its loop. The sleep itself is injectable so
/// tests drive it with a virtual clock.
@MainActor
final class LoopGate {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    nonisolated static let systemSleeper: Sleeper = { try await Task.sleep(for: $0) }

    private let sleeper: Sleeper
    private var timer: Task<Void, Never>?
    private var pendingPoke = false

    init(sleeper: @escaping Sleeper = LoopGate.systemSleeper) {
        self.sleeper = sleeper
    }

    func poke() {
        if let timer {
            timer.cancel()
        } else {
            pendingPoke = true
        }
    }

    /// Returns when `interval` elapsed, `poke()` was called, or the calling task was cancelled.
    func sleep(for interval: Duration) async {
        if pendingPoke { pendingPoke = false; return }
        if Task.isCancelled { return }
        let sleeper = self.sleeper
        let timer = Task<Void, Never> { _ = try? await sleeper(interval) }
        self.timer = timer
        await withTaskCancellationHandler {
            await timer.value
        } onCancel: {
            timer.cancel()
        }
        self.timer = nil
    }
}

// MARK: - Coordinator ------------------------------------------------------------

/// Owns the independent polling loops. One sequential loop per service ⇒ a slow service never stacks calls.
/// The coordinator holds no state about *what* is polled; the store hands it closures and a policy provider.
@MainActor
final class PollingCoordinator {
    enum Loop: CaseIterable, Sendable { case processes, dockerList, dockerStats, housekeeping }

    struct Work {
        var policy: @MainActor () -> PollingPolicy
        var processTick: @MainActor () async -> Void
        var dockerListTick: @MainActor () async -> Void
        var dockerStatsTick: @MainActor () async -> Void
        /// Builds auto-refresh / build-cache summary refresh (popover open only; staleness decided by the store).
        var housekeepingTick: @MainActor () async -> Void
    }

    /// Housekeeping wakes on this cadence while the popover is open; closed, it parks until it is woken.
    static let housekeepingInterval: Duration = .seconds(60)
    /// A loop with nothing to do sleeps this long unless woken, so an idle app takes no timer wakeups. This is only the
    /// last-resort bound: the real wake-ups are the explicit pokes (popover visibility, scan settings) and
    /// `wakeParkedLoops()`, which re-derives them from the policy after every tick of the two loops that never park.
    static let parkedInterval: Duration = .seconds(300)

    private let work: Work
    private var tasks: [Loop: Task<Void, Never>] = [:]
    private let gates: [Loop: LoopGate]
    /// Loops currently asleep because the policy gives them nothing to do (`parkedInterval`, interruptible by a poke).
    private var parked: Set<Loop> = []

    init(work: Work, sleeper: @escaping LoopGate.Sleeper = LoopGate.systemSleeper) {
        self.work = work
        self.gates = Dictionary(uniqueKeysWithValues: Loop.allCases.map { ($0, LoopGate(sleeper: sleeper)) })
    }

    var isRunning: Bool { !tasks.isEmpty }

    func start() {
        guard tasks.isEmpty else { return }
        for loop in Loop.allCases {
            tasks[loop] = Task { [weak self] in await self?.run(loop) }
        }
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func poke(_ loop: Loop) { gates[loop]?.poke() }

    func pokeAll() { for loop in Loop.allCases { poke(loop) } }

    private func run(_ loop: Loop) async {
        guard let gate = gates[loop] else { return }
        while !Task.isCancelled {
            let policy = work.policy()
            switch loop {
            case .processes:
                await work.processTick()
                wakeParkedLoops()
                await gate.sleep(for: work.policy().processInterval)
            case .dockerList:
                await work.dockerListTick()
                wakeParkedLoops()
                await gate.sleep(for: work.policy().dockerListInterval)
            case .dockerStats:
                if policy.dockerStatsInterval != nil {
                    await work.dockerStatsTick()
                }
                await rest(loop, gate: gate, interval: work.policy().dockerStatsInterval)
            case .housekeeping:
                if policy.popoverVisible { await work.housekeepingTick() }
                await rest(loop, gate: gate, interval: work.policy().popoverVisible ? Self.housekeepingInterval : nil)
            }
        }
    }

    /// `nil` = nothing to do: the loop parks until a poke, `wakeParkedLoops()` or `parkedInterval`.
    private func rest(_ loop: Loop, gate: LoopGate, interval: Duration?) async {
        guard let interval else {
            parked.insert(loop)
            defer { parked.remove(loop) }
            await gate.sleep(for: Self.parkedInterval)
            return
        }
        await gate.sleep(for: interval)
    }

    /// Wakes a parked loop whose policy now gives it work. Runs after every tick of the processes and Docker-list loops,
    /// which never park, so a lost or missing poke (a new container discovered, the popover opened) delays the wake-up by at
    /// most one of their intervals instead of stranding the loop for as long as it is parked.
    private func wakeParkedLoops() {
        guard !parked.isEmpty else { return }
        let policy = work.policy()
        if parked.contains(.dockerStats), policy.dockerStatsInterval != nil { poke(.dockerStats) }
        if parked.contains(.housekeeping), policy.popoverVisible { poke(.housekeeping) }
    }
}
