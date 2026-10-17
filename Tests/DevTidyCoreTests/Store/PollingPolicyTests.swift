import Foundation
import Testing
@testable import DevTidyCore

struct PollingPolicyTests {
    @Test func popoverClosedCadence() {
        let p = PollingPolicy(popoverVisible: false, lowPowerMode: false, dockerReachable: true, runningContainerCount: 3)
        #expect(p.processInterval == .seconds(10))
        #expect(p.dockerListInterval == .seconds(30))
        #expect(p.dockerStatsInterval == .seconds(120))
    }

    @Test func popoverOpenCadence() {
        let p = PollingPolicy(popoverVisible: true, lowPowerMode: false, dockerReachable: true, runningContainerCount: 3)
        #expect(p.processInterval == .seconds(2))
        #expect(p.dockerListInterval == .seconds(3))
        #expect(p.dockerStatsInterval == .seconds(10))
    }

    @Test func lowPowerModeDoublesEveryInterval() {
        let closed = PollingPolicy(popoverVisible: false, lowPowerMode: true, dockerReachable: true, runningContainerCount: 1)
        #expect(closed.processInterval == .seconds(20))
        #expect(closed.dockerListInterval == .seconds(60))
        #expect(closed.dockerStatsInterval == .seconds(240))
        let open = PollingPolicy(popoverVisible: true, lowPowerMode: true, dockerReachable: true, runningContainerCount: 1)
        #expect(open.processInterval == .seconds(4))
        #expect(open.dockerListInterval == .seconds(6))
        #expect(open.dockerStatsInterval == .seconds(20))
    }

    @Test func dockerDownBacksOffTo15SecondsOpenAnd60Closed() {
        let open = PollingPolicy(popoverVisible: true, lowPowerMode: false, dockerReachable: false, runningContainerCount: 0)
        #expect(open.dockerListInterval == .seconds(15))
        let closed = PollingPolicy(popoverVisible: false, lowPowerMode: false, dockerReachable: false, runningContainerCount: 0)
        #expect(closed.dockerListInterval == .seconds(60))
        // The process loop is unaffected by Docker being down.
        #expect(open.processInterval == .seconds(2))
        #expect(closed.processInterval == .seconds(10))
        // Low Power Mode still only ever slows things down.
        let lowPower = PollingPolicy(popoverVisible: false, lowPowerMode: true, dockerReachable: false, runningContainerCount: 0)
        #expect(lowPower.dockerListInterval == .seconds(120))
    }

    @Test func statsLoopIsDisabledWithoutRunningContainers() {
        for visible in [true, false] {
            let none = PollingPolicy(popoverVisible: visible, lowPowerMode: false, dockerReachable: true, runningContainerCount: 0)
            #expect(none.dockerStatsInterval == nil)
            let one = PollingPolicy(popoverVisible: visible, lowPowerMode: false, dockerReachable: true, runningContainerCount: 1)
            #expect(one.dockerStatsInterval != nil)
        }
    }

    @Test func statsLoopIsDisabledWhileDockerIsDownEvenWithStaleContainerCount() {
        let p = PollingPolicy(popoverVisible: true, lowPowerMode: false, dockerReachable: false, runningContainerCount: 4)
        #expect(p.dockerStatsInterval == nil)
    }
}

/// A sleep clock the test advances by hand. It is injected where production code would call `Task.sleep`, so nothing here
/// depends on how long anything really takes: a sleeper waits until `advance(by:)` reaches its deadline, or until it is
/// cancelled (which ends it at once, like the real thing).
final class VirtualSleepClock: @unchecked Sendable {
    private struct Waiter {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var nextID = 0
    private var started = 0
    private var waiters: [Int: Waiter] = [:]

    /// The injectable sleep.
    var sleeper: LoopGate.Sleeper {
        { [self] duration in try await self.sleep(for: duration) }
    }

    /// Sleepers currently waiting.
    var pendingCount: Int { lock.withLock { waiters.count } }
    /// Deadlines of the waiting sleepers (virtual time since the clock was created), ascending.
    var pendingDeadlines: [Duration] { lock.withLock { waiters.values.map(\.deadline).sorted() } }
    /// How many sleeps were ever started.
    var startedCount: Int { lock.withLock { started } }
    var now: Duration { lock.withLock { elapsed } }

    /// Moves virtual time forward and completes every sleeper that is due, earliest deadline first.
    func advance(by duration: Duration) {
        let due: [Waiter] = lock.withLock {
            elapsed += duration
            let ready = waiters.filter { $0.value.deadline <= elapsed }
            for key in ready.keys { waiters[key] = nil }
            return ready.values.sorted { $0.deadline < $1.deadline }
        }
        for waiter in due { waiter.continuation.resume() }
    }

    private func sleep(for duration: Duration) async throws {
        let id: Int = lock.withLock {
            nextID += 1
            started += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = Waiter(deadline: elapsed + duration, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
struct LoopGateTests {
    @Test func pokeEndsTheSleepEarly() async {
        let clock = VirtualSleepClock()
        let gate = LoopGate(sleeper: clock.sleeper)
        let finished = S4Locked(false)
        let task = Task { await gate.sleep(for: .seconds(30)); finished.with { $0 = true } }
        #expect(await s4Eventually { clock.pendingCount == 1 })
        #expect(finished.snapshot == false)                 // virtual time never moved: only a poke can end this sleep
        gate.poke()
        #expect(await s4Eventually { finished.snapshot })
        await task.value
        #expect(clock.pendingCount == 0)
    }

    @Test func theSleepEndsWhenVirtualTimeReachesTheInterval() async {
        let clock = VirtualSleepClock()
        let gate = LoopGate(sleeper: clock.sleeper)
        let finished = S4Locked(false)
        let task = Task { await gate.sleep(for: .seconds(30)); finished.with { $0 = true } }
        #expect(await s4Eventually { clock.pendingCount == 1 })
        clock.advance(by: .seconds(29))
        #expect(finished.snapshot == false)
        clock.advance(by: .seconds(1))
        #expect(await s4Eventually { finished.snapshot })
        await task.value
    }

    @Test func pokeWhileBusyMakesTheNextSleepReturnImmediately() async {
        let clock = VirtualSleepClock()
        let gate = LoopGate(sleeper: clock.sleeper)
        gate.poke()
        await gate.sleep(for: .seconds(30))
        #expect(clock.startedCount == 0)                    // returned without arming a timer

        // The poke was consumed: the next sleep waits again.
        let task = Task { await gate.sleep(for: .seconds(30)) }
        #expect(await s4Eventually { clock.pendingCount == 1 })
        task.cancel()
        await task.value
    }

    @Test func cancellingTheCallerEndsTheSleep() async {
        let clock = VirtualSleepClock()
        let gate = LoopGate(sleeper: clock.sleeper)
        let finished = S4Locked(false)
        let task = Task { await gate.sleep(for: .seconds(30)); finished.with { $0 = true } }
        #expect(await s4Eventually { clock.pendingCount == 1 })
        task.cancel()
        #expect(await s4Eventually { finished.snapshot })
        await task.value
        #expect(clock.pendingCount == 0)
    }
}

@MainActor
struct PollingCoordinatorTests {
    private final class Counters: @unchecked Sendable {
        let values = S4Locked<[String: Int]>([:])
        func bump(_ key: String) { values.with { $0[key, default: 0] += 1 } }
        func count(_ key: String) -> Int { values.snapshot[key] ?? 0 }
    }

    private func makeCoordinator(counters: Counters, policy: S4Locked<PollingPolicy>,
                                 clock: VirtualSleepClock) -> PollingCoordinator {
        PollingCoordinator(work: PollingCoordinator.Work(
            policy: { policy.snapshot },
            processTick: { counters.bump("process") },
            dockerListTick: { counters.bump("list") },
            dockerStatsTick: { counters.bump("stats") },
            housekeepingTick: { counters.bump("housekeeping") }),
                           sleeper: clock.sleeper)
    }

    /// Waits until the processes and Docker-list loops have ticked `ticks` times and are asleep again (their next deadline is
    /// pending): everything a tick does, including waking a parked loop, has happened by then.
    private func waitForDriverLoops(_ counters: Counters, _ clock: VirtualSleepClock, ticks: Int,
                                    processDeadline: Duration, listDeadline: Duration) async -> Bool {
        await s4Eventually {
            counters.count("process") == ticks && counters.count("list") == ticks
                && clock.pendingDeadlines.contains(processDeadline) && clock.pendingDeadlines.contains(listDeadline)
        }
    }

    @Test func startRunsEveryEnabledLoopOnceAndParksStatsWithoutRunningContainers() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: true, runningContainerCount: 0))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { clock.pendingCount == 4 })
        #expect(counters.count("process") == 1 && counters.count("list") == 1 && counters.count("housekeeping") == 1)
        #expect(counters.count("stats") == 0)
        // What each loop asked to sleep: popover open ⇒ 2 s / 3 s, housekeeping every minute, stats parked.
        #expect(clock.pendingDeadlines == [.seconds(2), .seconds(3), PollingCoordinator.housekeepingInterval,
                                           PollingCoordinator.parkedInterval])
        coordinator.stop()
        #expect(await s4Eventually { clock.pendingCount == 0 })
    }

    @Test func statsLoopRunsWhenContainersAreRunningAndHousekeepingStaysParkedWhileClosed() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: false, runningContainerCount: 2))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { clock.pendingCount == 4 })
        #expect(counters.count("stats") == 1)
        #expect(counters.count("housekeeping") == 0)
        #expect(clock.pendingDeadlines == [.seconds(10), .seconds(30), .seconds(120), PollingCoordinator.parkedInterval])
        coordinator.stop()
        #expect(await s4Eventually { clock.pendingCount == 0 })
    }

    @Test func pokeWakesALoopEarlyAndStopEndsAllLoops() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: false))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { counters.count("process") == 1 && clock.pendingCount == 4 })
        coordinator.poke(.processes)
        #expect(await s4Eventually { counters.count("process") == 2 })
        #expect(clock.now == .zero)                         // woken by the poke, not by time

        coordinator.stop()
        #expect(coordinator.isRunning == false)
        #expect(await s4Eventually { clock.pendingCount == 0 })
        let before = counters.count("process")
        coordinator.poke(.processes)
        clock.advance(by: .seconds(3_600))
        #expect(counters.count("process") == before)         // nothing runs any more
    }

    // MARK: A parked loop is always woken (CodeReview P2-N1)

    @Test func aParkedStatsLoopIsWokenByThePolicyWithoutAnyPoke() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: false, runningContainerCount: 0))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { clock.pendingCount == 4 })
        #expect(counters.count("stats") == 0)                // nothing running: parked

        // What a Docker list tick that finds the first running container does to the policy. Nobody pokes the stats loop.
        policy.with { $0.runningContainerCount = 2 }
        clock.advance(by: .seconds(30))                      // the list loop's next tick; the stats loop's own timer is far away
        #expect(await s4Eventually { counters.count("stats") == 1 })
        #expect(clock.now < PollingCoordinator.parkedInterval)
        coordinator.stop()
    }

    @Test func aParkedHousekeepingLoopIsWokenWhenThePopoverOpensWithoutAnyPoke() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: false, runningContainerCount: 0))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { clock.pendingCount == 4 })
        #expect(counters.count("housekeeping") == 0)

        policy.with { $0.popoverVisible = true }             // visibility changed; `pokeAll()` is lost
        clock.advance(by: .seconds(10))                      // the processes loop's next tick (closed cadence)
        #expect(await s4Eventually { counters.count("housekeeping") == 1 })
        #expect(clock.now < PollingCoordinator.parkedInterval)
        coordinator.stop()
    }

    @Test func parkedLoopsStayParkedWhileThePolicyGivesThemNothingToDo() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: false, runningContainerCount: 0))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { clock.pendingCount == 4 })

        clock.advance(by: .seconds(30))                      // processes tick at 10 s, the list loop at 30 s
        let settled = await waitForDriverLoops(counters, clock, ticks: 2, processDeadline: .seconds(40), listDeadline: .seconds(60))
        #expect(settled)
        // Both parked loops still sleep on their original deadline: nothing woke them.
        #expect(clock.pendingDeadlines.filter { $0 == PollingCoordinator.parkedInterval }.count == 2)
        #expect(counters.count("stats") == 0)
        #expect(counters.count("housekeeping") == 0)
        coordinator.stop()
    }

    @Test func anExplicitPokeStillWakesAParkedLoopAtOnce() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: false, runningContainerCount: 0))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { clock.pendingCount == 4 })

        policy.with { $0.runningContainerCount = 1 }
        coordinator.poke(.dockerStats)
        #expect(await s4Eventually { counters.count("stats") == 1 })
        #expect(clock.now == .zero)                          // immediate: no tick of any other loop was needed
        coordinator.stop()
    }

    @Test func aWokenHousekeepingLoopKeepsItsCadenceWhileThePopoverStaysOpen() async {
        let counters = Counters()
        let clock = VirtualSleepClock()
        let policy = S4Locked(PollingPolicy(popoverVisible: true, runningContainerCount: 0))
        let coordinator = makeCoordinator(counters: counters, policy: policy, clock: clock)
        coordinator.start()
        #expect(await s4Eventually { counters.count("housekeeping") == 1 && clock.pendingCount == 4 })

        clock.advance(by: PollingCoordinator.housekeepingInterval)
        #expect(await s4Eventually { counters.count("housekeeping") == 2 })
        coordinator.stop()
    }
}
