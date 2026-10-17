import Foundation
import Testing
@testable import DevTidyCore

/// Regression tests for the review / QA findings that live in `DevTidyStore` and its polling. Every test runs against the
/// fakes of `S4Support`: no process is signalled, no Docker call is made, nothing outside memory is touched.
@MainActor
struct DevTidyStoreRegressionTests {
    private let projectRoot = S4.home + "/developer/proj"
    private var project: Project { S4.project(projectRoot) }

    private func buildCacheSummary() -> BuildCacheSummary {
        BuildCacheSummary(totalBytes: 4_200, reclaimableBytes: 5_900, privateReclaimableBytes: 100,
                          recordCount: 2, activeCount: 0, measuredAt: S4.t0)
    }

    private func finishedScan() -> BuildsScanSummary {
        BuildsScanSummary(directoriesVisited: 5, reportCount: 0, truncated: false, permissionDeniedRoots: [], seconds: 0)
    }

    // MARK: P1-1 stale Docker snapshots

    @Test func aSlowSnapshotNeverResurrectsAStoppedContainer() async {
        let rig = S4Rig()
        let running = S4.container("web", cpu: 0)
        let stopped = S4.container("web", state: .exited)
        // The slow stats pass starts first and still reads "web" as running; its stats are stamped later than the list below.
        let gate = S4Gate()
        rig.docker.state.with {
            $0.snapshot = S4.dockerSnapshot(standalone: [running], statsAt: S4.t0.addingTimeInterval(5))
            $0.snapshotGates = [gate]
        }
        let slow = Task { await rig.store.dockerStatsTick() }
        #expect(await s4Eventually { rig.log.count(prefix: "docker-snapshot:") == 1 })

        // The user stops it; the list read after the action finishes first.
        rig.clock.advance(1)
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [stopped], statsAt: S4.t0) }
        await rig.store.dockerListTick()
        #expect(rig.store.dockerSnapshot.allContainers.map(\.state) == [.exited])

        gate.open()
        await slow.value
        #expect(rig.store.dockerSnapshot.allContainers.map(\.state) == [.exited])
        #expect(rig.store.summary.runningContainers == 0)
        #expect(rig.store.idleContainers.isEmpty)
    }

    @Test func aSlowSnapshotStillContributesItsFresherStats() async {
        let rig = S4Rig()
        let sampled = S4.container("db", cpu: 40, mem: 7 * S4.mb)
        let gate = S4Gate()
        rig.docker.state.with {
            $0.snapshot = S4.dockerSnapshot(standalone: [sampled], statsAt: S4.t0.addingTimeInterval(5))
            $0.snapshotGates = [gate]
        }
        let slow = Task { await rig.store.dockerStatsTick() }
        #expect(await s4Eventually { rig.log.count(prefix: "docker-snapshot:") == 1 })

        rig.clock.advance(1)
        let db = S4.container("db", cpu: nil, mem: nil)
        let cache = S4.container("cache", cpu: nil, mem: nil)           // only the newer list knows this one
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [db, cache], statsAt: nil) }
        await rig.store.dockerListTick()
        #expect(rig.store.dockerSnapshot.allContainers.first { $0.name == "db" }?.cpuPercent == nil)

        gate.open()
        await slow.value
        let shown = rig.store.dockerSnapshot.allContainers
        #expect(shown.map(\.name) == ["db", "cache"])                    // the newer list stays
        #expect(shown.first { $0.name == "db" }?.cpuPercent == 40)       // the older pass's samples are taken
        #expect(shown.first { $0.name == "db" }?.memoryBytes == 7 * S4.mb)
        #expect(shown.first { $0.name == "cache" }?.cpuPercent == nil)
    }

    // MARK: P1-2 / F-4 "Boştakileri Durdur" acts on what the card listed

    @Test func stopIdleContainersStopsOnlyTheConfirmedIDsThatAreStillIdle() async {
        let rig = S4Rig()
        let a = S4.container("idle-a", cpu: 0, started: S4.t0.addingTimeInterval(-60))
        let b = S4.container("idle-b", cpu: 0, started: S4.t0.addingTimeInterval(-60))
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [a, b]) }
        await rig.store.refreshNow()                                      // t0: a and b first seen

        rig.clock.advance(10 * 60)
        let c = S4.container("idle-c", cpu: 0, started: S4.t0.addingTimeInterval(10 * 60 - 60))
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [a, b, c]) }
        await rig.store.refreshNow()                                      // t0+10m: c appears
        rig.clock.advance(6 * 60)
        await rig.store.refreshNow()                                      // t0+16m: a and b quiet for 16 min, c for 6

        // The card is armed now: it lists a and b.
        #expect(rig.store.idleContainers.map(\.name) == ["idle-a", "idle-b"])
        let armed = Set(rig.store.idleContainers.map(\.id))

        // While it is open b wakes up and c crosses the threshold.
        rig.clock.advance(10 * 60)
        let busyB = S4.container("idle-b", cpu: 50, started: S4.t0.addingTimeInterval(-60))
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [a, busyB, c]) }
        await rig.store.refreshNow()
        #expect(rig.store.idleContainers.map(\.name) == ["idle-a", "idle-c"])

        let stopped = await rig.store.stopIdleContainers(ids: armed)
        #expect(stopped == 1)
        #expect(rig.docker.state.snapshot.actions == ["stop:\(a.id)"])   // not b (active again), not c (never listed)
        #expect(rig.store.busyKeys.isEmpty)
    }

    // MARK: P1-3 build-cache measurement failures

    @Test func aBuildCacheFailureIsVisibleAndASuccessClearsIt() async {
        let rig = S4Rig()
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot() }       // no build cache configured ⇒ the fake times out
        await rig.store.refreshNow()
        await rig.store.refreshBuildCache()
        #expect(rig.store.buildCache == nil)
        #expect(rig.store.buildCacheFailure?.isEmpty == false)
        #expect(!rig.store.isMeasuringBuildCache)                         // never stuck on "ölçülüyor…"

        rig.docker.state.with { $0.buildCache = buildCacheSummary() }
        await rig.store.refreshBuildCache()                               // the retry button
        #expect(rig.store.buildCacheFailure == nil)
        #expect(rig.store.buildCache?.totalBytes == 4_200)
    }

    @Test func measuringIsTrueOnlyWhileTheRequestIsInFlight() async {
        let rig = S4Rig()
        let gate = S4Gate()
        rig.docker.state.with {
            $0.buildCache = buildCacheSummary()
            $0.buildCacheGate = gate
        }
        #expect(!rig.store.isMeasuringBuildCache)
        let measuring = Task { await rig.store.refreshBuildCache() }
        #expect(await s4Eventually { rig.store.isMeasuringBuildCache })
        #expect(rig.store.buildCacheFailure == nil)
        await rig.store.refreshBuildCache()                                // single-flight: returns at once
        #expect(rig.log.count(prefix: "docker-buildcache") == 1)
        gate.open()
        await measuring.value
        #expect(!rig.store.isMeasuringBuildCache)
        #expect(rig.store.buildCache != nil)
    }

    @Test func aFailedMeasurementIsNotRetriedOnEveryHousekeepingTick() async {
        let rig = S4Rig()                                                  // no build cache configured ⇒ every measurement fails
        rig.store.isPopoverVisible = true
        rig.store.selectedTab = .docker                                    // measures once on activation
        #expect(await s4Eventually { rig.store.buildCacheFailure != nil })
        #expect(rig.log.count(prefix: "docker-buildcache") == 1)

        await rig.store.housekeepingTick()
        #expect(rig.log.count(prefix: "docker-buildcache") == 1)           // inside the window: left to the retry button
        rig.clock.advance(6 * 60)
        await rig.store.housekeepingTick()
        #expect(rig.log.count(prefix: "docker-buildcache") == 2)
    }

    @Test func anUnsupportedDockerConfigurationBacksOffLikeADockerThatIsDown() async {
        let rig = S4Rig()
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(status: .unsupported("Uzak Docker bağlamı desteklenmiyor")) }
        await rig.store.refreshNow()
        #expect(rig.store.currentPolicy().dockerReachable == false)
        await rig.store.refreshBuildCache()
        #expect(rig.log.count(prefix: "docker-buildcache") == 0)
    }

    // MARK: P1-4 scan settings change mid-scan

    @Test func changingScanRootsDuringAScanRestartsItWithTheNewRoots() async {
        let rig = S4Rig()
        let done = finishedScan()
        rig.catalog.state.with {
            $0.hangingScanCalls = [0]
            $0.scripts = [[.progress(directoriesVisited: 1)], [.finished(done)]]
        }
        rig.store.isPopoverVisible = true
        rig.store.selectedTab = .builds
        #expect(await s4Eventually { rig.store.buildsScan == .scanning(directories: 1) })

        let newRoot = S4.home + "/work"
        rig.store.settings.scanRoots = [newRoot]
        #expect(await s4Eventually { rig.store.buildsScan == .finished(done) })

        let calls = rig.catalog.state.snapshot
        #expect(calls.scanOptions.count == 2)
        #expect(calls.scanOptions.last?.roots == [newRoot])
        #expect(calls.terminatedCalls.contains(0))                         // the old scan was cancelled, not left running
    }

    @Test func changingScanSettingsDropsRowsThatBelongToTheOldSettings() async {
        let rig = S4Rig()
        let report = S4.report(S4.project(S4.home + "/developer/a"),
                               entries: [S4.entry("next.cache", packageDir: S4.home + "/developer/a", size: nil)])
        rig.catalog.state.with { $0.scripts = [S4.scanScript([report])] }
        await rig.store.scanBuilds()
        #expect(!rig.store.buildReports.isEmpty)

        rig.store.settings.buildsMaxDepth = 6                              // popover closed: nothing rescans yet
        #expect(rig.store.buildReports.isEmpty)
        #expect(rig.store.buildsScan == .idle)
    }

    // MARK: P2-13 zero-size entries

    @Test func entriesThatMeasureZeroAreDroppedAndEmptyProjectsDisappear() async {
        let rig = S4Rig()
        let one = S4.project(S4.home + "/developer/one")
        let two = S4.project(S4.home + "/developer/two")
        let keep = S4.entry("next.cache", packageDir: one.root, size: nil)
        let empty = S4.entry("vite.cache", packageDir: one.root, display: ".vite", size: nil)
        let onlyEmpty = S4.entry("next.cache", packageDir: two.root, size: nil)
        rig.catalog.state.with {
            $0.sizes[keep.id] = SizeResult(bytes: 500, isPartial: false, itemCount: nil)
            $0.sizes[empty.id] = SizeResult(bytes: 0, isPartial: false, itemCount: nil)
            $0.sizes[onlyEmpty.id] = SizeResult(bytes: 0, isPartial: false, itemCount: nil)
            $0.scripts = [S4.scanScript([S4.report(one, entries: [keep, empty]), S4.report(two, entries: [onlyEmpty])])]
        }
        await rig.store.scanBuilds()
        #expect(rig.store.buildReports.map(\.project.name) == ["one"])
        #expect(rig.store.buildReports.first?.entries.map(\.id) == [keep.id])
    }

    // MARK: P2-16 Xcode notice

    @Test func theXcodeNoticeAppearsForAnyPlanThatContainsDerivedData() async {
        let rig = S4Rig()
        rig.scanner.state.with { $0.nodes = [S4.node(300, name: "Xcode", exe: "/Applications/Xcode.app/Contents/MacOS/Xcode")] }
        let derived = S4.entry("xcode.deriveddata", packageDir: S4.home + "/Library/Developer/Xcode/DerivedData",
                               display: "Foo-abc", instance: "Foo-abc")
        let next = S4.entry("next.cache", packageDir: projectRoot)
        rig.cleaner.state.with { $0.plans = [S4.plan(root: projectRoot, project: project, entries: [next, derived])] }
        await rig.store.beginClean(projectRoot: projectRoot)
        #expect(rig.store.xcodeRunning)

        rig.store.dismissCleanup()
        #expect(!rig.store.xcodeRunning)

        // A plan without DerivedData never even asks for the process list.
        let scansBefore = rig.log.count(prefix: "scan:")
        rig.cleaner.state.with { $0.plans = [S4.plan(root: projectRoot, project: project, entries: [next])] }
        await rig.store.beginClean(projectRoot: projectRoot)
        #expect(!rig.store.xcodeRunning)
        #expect(rig.log.count(prefix: "scan:") == scansBefore)
    }

    // MARK: Expired plans (CleanupError.planStale)
    //
    // That nothing is deleted for an expired plan is `CacheCleanerSafetyTests`' job (the real cleaner throws before touching
    // anything). The store's part is the state and the message.

    @Test func anExpiredPlanIsShownAsAFailedSheetWithTheTurkishMessage() async {
        let rig = S4Rig()
        let next = S4.entry("next.cache", packageDir: projectRoot)
        rig.cleaner.state.with {
            $0.plans = [S4.plan(root: projectRoot, project: project, entries: [next])]
            $0.executeError = .planStale
        }
        await rig.store.beginClean(projectRoot: projectRoot)
        await rig.store.confirmCleanup()
        guard case .failed(let error)? = rig.store.cleanup else {
            Issue.record("expected .failed, got \(String(describing: rig.store.cleanup))"); return
        }
        #expect(error.message == "Plan eskidi, yeniden planlayın.")
    }

    @Test func anExpiredPlanAfterAStopSaysTheServerWasStopped() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        let next = S4.entry("next.cache", packageDir: projectRoot)
        let first = S4.plan(root: projectRoot, project: project, entries: [next], blockers: [S4.blocker("node (PID 50)", pid: 50)])
        let fresh = S4.plan(root: projectRoot, project: project, entries: [next])
        rig.cleaner.state.with {
            $0.plans = [first, fresh]
            $0.executeError = .planStale
        }
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()
        guard case .failed(let error)? = rig.store.cleanup else { Issue.record("expected .failed"); return }
        #expect(error.message.contains("Sunucu durduruldu"))
        #expect(error.message.contains("Plan eskidi"))
        #expect(rig.log.events(prefixed: "terminate:") == ["terminate:50"])
        #expect(rig.store.busyKeys.isEmpty)
    }

    // MARK: P2-10 quitting mid-action

    @Test func quittingIsRefusedWhileAStopIsInFlight() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        let gate = S4Gate()
        rig.terminator.state.with { $0.gate = gate }
        #expect(rig.store.canQuit)
        let stopping = Task { await rig.store.stop(server) }
        #expect(await s4Eventually { !rig.store.canQuit })
        gate.open()
        await stopping.value
        #expect(rig.store.canQuit)
    }

    // MARK: P2-N1 the store wakes the parked loops

    @Test func aFirstRunningContainerPokesTheStatsLoopExactlyOnce() async {
        let rig = S4Rig()
        let pokes = S4Locked<[PollingCoordinator.Loop?]>([])
        rig.store.onPoke = { loop in pokes.with { $0.append(loop) } }
        func statsPokes() -> Int { pokes.snapshot.filter { $0 == .dockerStats }.count }

        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [S4.container("db", state: .exited)]) }
        await rig.store.dockerListTick()
        #expect(statsPokes() == 0)                                         // nothing running: the loop stays parked

        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [S4.container("db")]) }
        await rig.store.dockerListTick()
        #expect(statsPokes() == 1)                                         // 0 → 1 running

        await rig.store.dockerListTick()
        #expect(statsPokes() == 1)                                         // 1 → 1: no second wake-up
    }

    @Test func becomingVisibleAndChangingSettingsPokeEveryLoop() async {
        let rig = S4Rig()
        let pokes = S4Locked<[PollingCoordinator.Loop?]>([])
        rig.store.onPoke = { loop in pokes.with { $0.append(loop) } }
        func allLoopPokes() -> Int { pokes.snapshot.filter { $0 == nil }.count }

        rig.store.isPopoverVisible = true
        #expect(allLoopPokes() == 1)
        rig.store.isPopoverVisible = false
        #expect(allLoopPokes() == 1)                                       // hiding wakes nothing
        rig.store.settings.menuBarShowsMemory = false
        #expect(allLoopPokes() == 2)
    }

    // MARK: P3-4 a prune that lands during a measurement

    private func summary(total: Int64) -> BuildCacheSummary {
        BuildCacheSummary(totalBytes: total, reclaimableBytes: total, privateReclaimableBytes: 0,
                          recordCount: 1, activeCount: 0, measuredAt: S4.t0)
    }

    @Test func aPruneThatFinishesDuringAMeasurementStillGetsItsOwnMeasurement() async {
        let rig = S4Rig()
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot() }
        await rig.store.refreshNow()
        let gate = S4Gate()
        rig.docker.state.with { $0.buildCache = summary(total: 9_000); $0.buildCacheGate = gate }
        let measuring = Task { await rig.store.refreshBuildCache() }
        #expect(await s4Eventually { rig.log.count(prefix: "docker-buildcache") == 1 })   // the pre-prune figure was read

        rig.docker.state.with { $0.buildCache = summary(total: 100) }                       // what the prune left behind
        await rig.store.pruneBuildCache(.allUnused)
        #expect(rig.log.count(prefix: "docker-buildcache") == 1)                            // still the one in flight

        gate.open()
        await measuring.value
        #expect(rig.log.count(prefix: "docker-buildcache") == 2)                            // …followed by a fresh one
        #expect(rig.store.buildCache?.totalBytes == 100)
        #expect(!rig.store.isMeasuringBuildCache)
    }

    // MARK: P3-5 the row is busy for the action, not for the list read behind it

    @Test func aContainerRowIsNotBusyWhileTheFollowUpListIsQueued() async {
        let rig = S4Rig()
        let web = S4.container("web", state: .exited)
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [web]) }
        await rig.store.refreshNow()
        let gate = S4Gate()
        rig.docker.state.with { $0.snapshotGates = [gate] }                  // the daemon hangs on the next list read
        let acting = Task { await rig.store.perform(.start, on: web) }
        #expect(await s4Eventually { rig.log.count(prefix: "docker-snapshot:") == 2 })
        #expect(rig.store.busyKeys.isEmpty)
        gate.open()
        await acting.value
        #expect(rig.store.busyKeys.isEmpty)
    }

    @Test func aComposeRowIsNotBusyWhileTheFollowUpListIsQueued() async {
        let rig = S4Rig()
        let compose = ComposeProject(name: "tunahan", workingDir: nil, containers: [S4.container("php", composeProject: "tunahan")])
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(projects: [compose]) }
        await rig.store.refreshNow()
        let gate = S4Gate()
        rig.docker.state.with { $0.snapshotGates = [gate] }
        let acting = Task { await rig.store.perform(.stop, on: compose) }
        #expect(await s4Eventually { rig.log.count(prefix: "docker-snapshot:") == 2 })
        #expect(rig.store.busyKeys.isEmpty)
        gate.open()
        await acting.value
    }

    // MARK: P3-6 ordering never depends on wall-clock stamps

    @Test func aSlowerEarlierServerTickNeverOverwritesALaterOne() async {
        let rig = S4Rig()
        let gate = S4Gate()
        rig.classifier.state.with { $0.servers = [S4.server(pid: 10, project: project)]; $0.gates = [gate] }
        let slow = Task { await rig.store.processTick() }
        #expect(await s4Eventually { rig.log.count(prefix: "classify") == 1 })             // it already saw the server

        rig.classifier.state.with { $0.servers = [] }                                       // a later tick: the server is gone
        await rig.store.processTick()
        #expect(rig.store.serverScan.servers.isEmpty)

        gate.open()
        await slow.value
        #expect(rig.store.serverScan.servers.isEmpty)
    }

    @Test func aClockStepBackwardsDoesNotFreezeTheLists() async {
        let rig = S4Rig()
        rig.clock.set(S4.t0.addingTimeInterval(100))
        rig.classifier.state.with { $0.servers = [S4.server(pid: 10, project: project)] }
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [S4.container("web")]) }
        await rig.store.refreshNow()
        #expect(rig.store.serverScan.servers.count == 1)
        #expect(rig.store.dockerSnapshot.allContainers.count == 1)

        rig.clock.set(S4.t0)                                                                // the system clock stepped back
        rig.classifier.state.with { $0.servers = [] }
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot() }
        await rig.store.refreshNow()
        #expect(rig.store.serverScan.servers.isEmpty)
        #expect(rig.store.dockerSnapshot.allContainers.isEmpty)
    }

    // MARK: P3-10 stop + clean deletes what was reviewed

    @Test func aStopAndCleanOnlyTouchesThePathsTheUserReviewed() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        let reviewed = S4.entry("python.pycache", packageDir: projectRoot, display: "a/__pycache__, b/__pycache__")
        let afterStop = S4.entry("python.pycache", packageDir: projectRoot,
                                 display: "a/__pycache__, b/__pycache__, c/__pycache__")   // `c` appeared meanwhile
        rig.cleaner.state.with {
            $0.plans = [S4.plan(root: projectRoot, project: project, entries: [reviewed]),
                        S4.plan(root: projectRoot, project: project, entries: [afterStop])]
        }
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()
        let executed = rig.cleaner.state.snapshot.executed
        #expect(executed.count == 1)
        #expect(executed.first?.plan.entries.map(\.displayPath) == ["a/__pycache__, b/__pycache__"])
    }

    @Test func aStopAndCleanWithOnlyNewPathsDeletesNothing() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        let reviewed = S4.entry("python.pycache", packageDir: projectRoot, display: "a/__pycache__")
        let afterStop = S4.entry("python.pycache", packageDir: projectRoot, display: "c/__pycache__")
        rig.cleaner.state.with {
            $0.plans = [S4.plan(root: projectRoot, project: project, entries: [reviewed]),
                        S4.plan(root: projectRoot, project: project, entries: [afterStop])]
        }
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
        #expect(rig.log.events(prefixed: "terminate:") == ["terminate:50"])
    }

    @Test func theDockerUnverifiedNoticeIsNotCalledRunning() async {
        let rig = S4Rig()
        let vite = S4.entry("vite.cache", packageDir: projectRoot, display: ".vite", safety: .conditional, selected: true)
        let unverified = S4.blocker(LiveActivityChecker.dockerUnverifiedLabel, kind: .container, severity: .soft)
        rig.cleaner.state.with { $0.plans = [S4.plan(root: projectRoot, project: project, entries: [vite], blockers: [unverified])] }
        await rig.store.beginClean(projectRoot: projectRoot)
        await rig.store.confirmCleanup()
        #expect(rig.store.lastError?.message == "Docker durumu doğrulanamadı; Docker yanıt verince yeniden deneyin.")

        let running = S4.blocker("node (PID 77)", pid: 77)
        rig.cleaner.state.with { $0.plans = [S4.plan(root: projectRoot, project: project, entries: [vite], blockers: [running, unverified])] }
        rig.store.dismissCleanup()
        await rig.store.beginClean(projectRoot: projectRoot)
        await rig.store.confirmCleanup()
        #expect(rig.store.lastError?.message
                == "Şunlar çalıştığı için temizlenemez: node (PID 77) Docker durumu doğrulanamadı; Docker yanıt verince yeniden deneyin.")
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
    }
}

// MARK: - A parked loop wakes when poked (P2-4) ------------------------------------------------
//
// Coordinator only; that the STORE sends those pokes is covered above. Each test asserts the effect of a poke, not an absence
// of ticks, so none of them depends on how long anything takes.

@MainActor
struct PollingParkingTests {
    @Test func aDisabledStatsLoopTicksOnceItsPolicyEnablesItAndItIsPoked() async {
        let policy = S4Locked(PollingPolicy(popoverVisible: false, runningContainerCount: 0))
        let stats = S4Locked(0)
        let coordinator = PollingCoordinator(work: PollingCoordinator.Work(
            policy: { policy.snapshot },
            processTick: {},
            dockerListTick: {},
            dockerStatsTick: { stats.with { $0 += 1 } },
            housekeepingTick: {}))
        coordinator.start()
        policy.with { $0.runningContainerCount = 2 }
        coordinator.poke(.dockerStats)
        #expect(await s4Eventually { stats.snapshot >= 1 })
        coordinator.stop()
    }

    @Test func housekeepingRunsOnceThePopoverIsOpenAndPoked() async {
        let policy = S4Locked(PollingPolicy(popoverVisible: false))
        let housekeeping = S4Locked(0)
        let coordinator = PollingCoordinator(work: PollingCoordinator.Work(
            policy: { policy.snapshot },
            processTick: {},
            dockerListTick: {},
            dockerStatsTick: {},
            housekeepingTick: { housekeeping.with { $0 += 1 } }))
        coordinator.start()
        policy.with { $0.popoverVisible = true }
        coordinator.pokeAll()
        #expect(await s4Eventually { housekeeping.snapshot >= 1 })
        coordinator.stop()
    }
}
