import Foundation
import Testing
@testable import DevTidyCore

@MainActor
struct DevTidyStoreTests {
    private let projectRoot = S4.home + "/developer/proj"
    private var project: Project { S4.project(projectRoot) }

    private func summaryOfZeroReports() -> BuildsScanSummary {
        BuildsScanSummary(directoriesVisited: 10, reportCount: 0, truncated: false, permissionDeniedRoots: [], seconds: 0.1)
    }

    // MARK: Summary and idle

    @Test func summaryMath() async {
        let rig = S4Rig()
        let a = S4.project(S4.home + "/developer/a")
        rig.classifier.state.with {
            $0.servers = [S4.server(pid: 10, project: a, cpu: 50, mem: 100 * S4.mb),
                          S4.server(pid: 11, project: a, port: 3001, cpu: 50, mem: 50 * S4.mb)]
        }
        rig.docker.state.with {
            $0.snapshot = S4.dockerSnapshot(standalone: [S4.container("web", cpu: 40, mem: 10 * S4.mb),
                                                         S4.container("db", cpu: 40, mem: 20 * S4.mb),
                                                         S4.container("old", state: .exited)])
        }
        await rig.store.refreshNow()
        #expect(rig.store.summary == MenuBarSummary(runningServers: 2, runningContainers: 2,
                                                     totalMemoryBytes: 180 * S4.mb, flaggedIdleCount: 0))
    }

    @Test func serverIdleTransitionsAndFlaggedCount() async {
        let rig = S4Rig()
        let started = S4.t0.addingTimeInterval(-7_200)
        let quiet = S4.server(pid: 10, project: project, cpu: 0, started: started)
        rig.classifier.state.with { $0.servers = [quiet] }

        await rig.store.refreshNow()
        // Silent for 2 h by uptime alone, not yet observed that long.
        #expect(rig.store.serverIdle[quiet.id] == .probablyIdle)
        #expect(rig.store.summary.flaggedIdleCount == 1)

        rig.clock.advance(31 * 60)
        await rig.store.refreshNow()
        #expect(rig.store.serverIdle[quiet.id] == .idle)
        #expect(rig.store.summary.flaggedIdleCount == 1)

        // CPU wakes up: active again, unflagged.
        let busy = S4.server(pid: 10, project: project, cpu: 25, started: started)
        #expect(busy.id == quiet.id)
        rig.classifier.state.with { $0.servers = [busy] }
        await rig.store.refreshNow()
        #expect(rig.store.serverIdle[busy.id] == .active)
        #expect(rig.store.summary.flaggedIdleCount == 0)
    }

    @Test func serverWithConnectionsIsActiveEvenAtZeroCPU() async {
        let rig = S4Rig()
        let server = S4.server(pid: 10, project: project, cpu: 0, connections: 2, started: S4.t0.addingTimeInterval(-7_200))
        rig.classifier.state.with { $0.servers = [server] }
        await rig.store.refreshNow()
        #expect(rig.store.serverIdle[server.id] == .active)
    }

    @Test func serverWithoutCPUSampleIsActiveOnlyWithConnections() async {
        let rig = S4Rig()
        let started = S4.t0.addingTimeInterval(-7_200)
        let silent = S4.server(pid: 10, project: project, cpu: nil, connections: 0, started: started)
        let connected = S4.server(pid: 11, project: project, port: 3001, cpu: nil, connections: 1, started: started)
        rig.classifier.state.with { $0.servers = [silent, connected] }
        await rig.store.refreshNow()
        #expect(rig.store.serverIdle[silent.id] == .probablyIdle)
        #expect(rig.store.serverIdle[connected.id] == .active)
    }

    @Test func containerWithUnknownCPUIsNotFlagged() async {
        let rig = S4Rig()
        let old = S4.container("old", cpu: nil, started: S4.t0.addingTimeInterval(-18_000))
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [old]) }
        await rig.store.refreshNow()
        #expect(rig.store.containerIdle[old.id] == nil)
        #expect(rig.store.summary.flaggedIdleCount == 0)
        #expect(rig.store.idleContainers.isEmpty)
    }

    @Test func stopIdleContainersStopsOnlyIdleOnes() async {
        let rig = S4Rig()
        let idleA = S4.container("idle-a", cpu: 0, started: S4.t0.addingTimeInterval(-60))
        let busy = S4.container("busy", cpu: 50, started: S4.t0.addingTimeInterval(-7_200))
        let probable = S4.container("probable", cpu: 0, started: S4.t0.addingTimeInterval(-10_800))

        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [idleA, busy]) }
        await rig.store.refreshNow()                                   // t0: idle-a first seen
        rig.clock.advance(10 * 60)
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [idleA, busy, probable]) }
        await rig.store.refreshNow()                                   // t0+10m: probable appears (old, silent)
        rig.clock.advance(6 * 60)
        await rig.store.refreshNow()                                   // t0+16m: idle-a observed 16 min quiet

        #expect(rig.store.containerIdle[idleA.id] == .idle)
        #expect(rig.store.containerIdle[probable.id] == .probablyIdle)
        #expect(rig.store.containerIdle[busy.id] == .active)
        #expect(rig.store.idleContainers.map(\.name) == ["idle-a"])
        #expect(rig.store.summary.flaggedIdleCount == 2)               // idle + probably idle both flagged in the menu bar

        let stopped = await rig.store.stopIdleContainers(ids: Set(rig.store.idleContainers.map(\.id)))
        #expect(stopped == 1)
        #expect(rig.docker.state.snapshot.actions == ["stop:\(idleA.id)"])
        #expect(rig.store.busyKeys.isEmpty)
    }

    @Test func runningProjectRootsComeFromServersAndComposeWorkingDirs() async {
        let rig = S4Rig()
        rig.classifier.state.with { $0.servers = [S4.server(pid: 10, project: project)] }
        let compose = S4.container("php", composeProject: "tunahan", workingDir: "/tmp/s4home/developer/tunahan")
        let stopped = S4.container("old", state: .exited, composeProject: "old", workingDir: "/tmp/s4home/developer/old")
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [compose, stopped]) }
        await rig.store.refreshNow()
        #expect(rig.store.runningProjectRoots == [projectRoot, "/tmp/s4home/developer/tunahan"])
    }

    // MARK: Stop

    @Test func stopSuccessTerminatesAndRefreshes() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        rig.classifier.state.with { $0.servers = [server] }
        await rig.store.refreshNow()
        rig.classifier.state.with { $0.servers = [] }                  // the server is gone after the stop

        await rig.store.stop(server)
        #expect(rig.log.events(prefixed: "terminate:") == ["terminate:50"])
        #expect(rig.store.lastError == nil)
        #expect(rig.store.busyKeys.isEmpty)
        #expect(rig.store.serverScan.servers.isEmpty)                  // process list refreshed right after the stop
    }

    @Test func stopWithSurvivorsReportsThePIDs() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        rig.terminator.state.with { $0.survivors = [1234, 1235] }
        await rig.store.stop(server)
        #expect(rig.store.lastError?.message == "Süreç kapanmadı: PID 1234, 1235")
        #expect(rig.store.busyKeys.isEmpty)
        rig.store.dismissError()
        #expect(rig.store.lastError == nil)
    }

    @Test func stopErrorsMapToTurkishUserFacingErrors() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        rig.terminator.state.with { $0.error = .refused("root-is-self-ancestor") }
        await rig.store.stop(server)
        #expect(rig.store.lastError?.title == "Sunucu durdurulamadı")
        #expect(rig.store.lastError?.message.contains("root-is-self-ancestor") == true)
    }

    // MARK: Docker actions

    @Test func dockerActionFailureIsShortenedAndSurfaced() async {
        let rig = S4Rig()
        let project = ComposeProject(name: "tunahan", workingDir: nil, containers: [S4.container("php", composeProject: "tunahan")])
        rig.docker.state.with { $0.failure = .commandFailed(exitCode: 1, stderr: String(repeating: "x", count: 500)) }
        await rig.store.perform(.down, on: project)
        let message = rig.store.lastError?.message ?? ""
        #expect(message.count == 301)
        #expect(message.hasSuffix("…"))
        #expect(message.hasPrefix("docker çıkış kodu 1: "))
        #expect(rig.docker.state.snapshot.actions == ["compose-down:tunahan"])
        #expect(rig.store.busyKeys.isEmpty)
    }

    @Test func containerActionRefreshesTheListAndClearsBusy() async {
        let rig = S4Rig()
        let web = S4.container("web", state: .exited)
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: [web]) }
        await rig.store.perform(.start, on: web)
        #expect(rig.docker.state.snapshot.actions == ["start:\(web.id)"])
        #expect(rig.store.lastError == nil)
        #expect(rig.store.dockerSnapshot.allContainers.count == 1)
        #expect(rig.store.busyKeys.isEmpty)
    }

    @Test func pruneRefreshesTheBuildCacheSummary() async {
        let rig = S4Rig()
        rig.docker.state.with {
            $0.snapshot = S4.dockerSnapshot()
            $0.buildCache = BuildCacheSummary(totalBytes: 100, reclaimableBytes: 80, privateReclaimableBytes: 60,
                                              recordCount: 3, activeCount: 0, measuredAt: S4.t0)
        }
        await rig.store.refreshNow()
        await rig.store.pruneBuildCache(.olderThan(hours: 168))
        #expect(rig.docker.state.snapshot.pruneModes == [.olderThan(hours: 168)])
        #expect(rig.store.buildCache?.totalBytes == 100)
        #expect(rig.store.lastBuildCachePrune == BuildCachePruneResult(reclaimedBytes: 5_000))
        #expect(rig.store.busyKeys.isEmpty)
    }

    @Test func buildCacheIsNotMeasuredWhileDockerIsDown() async {
        let rig = S4Rig()
        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(status: .notRunning) }
        await rig.store.refreshNow()
        await rig.store.refreshBuildCache()
        #expect(rig.store.buildCache == nil)
        #expect(rig.log.count(prefix: "docker-buildcache") == 0)
    }

    // MARK: Cleanup: nothing happens without an explicit confirmation

    private func readyForReview(_ rig: S4Rig, entries: [CacheEntry], blockers: [ActivityBlocker] = []) async {
        rig.cleaner.state.with { $0.plans = [S4.plan(root: projectRoot, project: project, entries: entries, blockers: blockers)] }
        await rig.store.beginClean(projectRoot: projectRoot)
    }

    @Test func beginCleanOnlyPlansAndNeverExecutes() async {
        let rig = S4Rig()
        let next = S4.entry("next.cache", packageDir: projectRoot)
        await readyForReview(rig, entries: [next])
        guard case .review(let plan, let selections, let stopFirst)? = rig.store.cleanup else {
            Issue.record("expected .review, got \(String(describing: rig.store.cleanup))"); return
        }
        #expect(plan.entries == [next])
        #expect(selections[next.id] == CleanupSelection(entryID: next.id, mode: .permanent))
        #expect(stopFirst == nil)
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
        #expect(rig.log.events(prefixed: "execute:", "terminate:").isEmpty)

        rig.store.dismissCleanup()
        #expect(rig.store.cleanup == nil)
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
    }

    @Test func planningFailureShowsTurkishMessage() async {
        let rig = S4Rig()
        rig.cleaner.state.with { $0.plans = [nil] }
        await rig.store.beginClean(projectRoot: projectRoot)
        guard case .failed(let error)? = rig.store.cleanup else { Issue.record("expected .failed"); return }
        #expect(error.message == "Bu proje için temizlenecek önbellek yok")
    }

    @Test func confirmWithNothingSelectedDoesNothing() async {
        let rig = S4Rig()
        let next = S4.entry("next.cache", packageDir: projectRoot)
        await readyForReview(rig, entries: [next])
        rig.store.setSelected(next.id, false)
        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
        guard case .review? = rig.store.cleanup else { Issue.record("sheet must stay in review"); return }
    }

    @Test func confirmOutsideReviewDoesNothing() async {
        let rig = S4Rig()
        await rig.store.confirmCleanup()                                // no flow at all
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
        rig.cleaner.state.with { $0.plans = [nil] }
        await rig.store.beginClean(projectRoot: projectRoot)            // .failed
        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
    }

    @Test func confirmExecutesExactlyTheSelectedEntriesWithTheirModes() async {
        let rig = S4Rig()
        let next = S4.entry("next.cache", packageDir: projectRoot)
        let build = S4.entry("vite.cache", packageDir: projectRoot, display: "node_modules/.vite", safety: .conditional, selected: true)
        let other = S4.entry("turbo.cache", packageDir: projectRoot, display: ".turbo")
        await readyForReview(rig, entries: [next, build, other])
        rig.store.setSelected(other.id, false)
        await rig.store.confirmCleanup()

        let executed = rig.cleaner.state.snapshot.executed
        #expect(executed.count == 1)
        #expect(executed.first?.selections == [CleanupSelection(entryID: next.id, mode: .permanent),
                                               CleanupSelection(entryID: build.id, mode: .trash)])
        guard case .finished(let result, let terminated)? = rig.store.cleanup else { Issue.record("expected .finished"); return }
        #expect(terminated == nil)
        #expect(result.outcomes.map(\.entryID) == [next.id, build.id])
        #expect(result.freedBytes == 1_000_000)
        #expect(result.trashedBytes == 1_000_000)
        #expect(rig.store.cleanupProgress.count <= 2)
    }

    @Test func hardBlockerThatIsNotBeingStoppedPreventsExecution() async {
        let rig = S4Rig()
        let next = S4.entry("next.cache", packageDir: projectRoot)
        await readyForReview(rig, entries: [next], blockers: [S4.blocker("node (PID 77)", pid: 77)])
        #expect(CleanupRules.unresolvedBlockers(plan: rig.currentPlan(), selections: rig.currentSelections(), stopFirst: nil).count == 1)
        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
        #expect(rig.store.lastError?.message.contains("node (PID 77)") == true)
    }

    @Test func softBlockerOnlyBlocksNonAlwaysClasses() async {
        let rig = S4Rig()
        let soft = S4.blocker("db", kind: .container, severity: .soft)
        let next = S4.entry("next.cache", packageDir: projectRoot)
        await readyForReview(rig, entries: [next], blockers: [soft])
        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.count == 1)         // class A proceeds with a warning

        let rig2 = S4Rig()
        let cond = S4.entry("vite.cache", packageDir: projectRoot, display: ".vite", safety: .conditional, selected: true)
        await readyForReview(rig2, entries: [cond], blockers: [soft])
        await rig2.store.confirmCleanup()
        #expect(rig2.cleaner.state.snapshot.executed.isEmpty)           // class B is blocked by any blocker
    }

    @Test func dependenciesAreNeverPreselectedAndNeedAcknowledgement() async {
        let rig = S4Rig()
        rig.store.settings.includeDependencies = true
        let deps = S4.entry("node.modules", packageDir: projectRoot, display: "node_modules", safety: .optIn,
                            selected: true, reinstall: "npm ci")
        await readyForReview(rig, entries: [deps])
        guard case .review(_, let initial, _)? = rig.store.cleanup else { Issue.record("expected .review"); return }
        #expect(initial.isEmpty)                                         // even though defaultSelected was true

        rig.store.setSelected(deps.id, true)
        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)             // no "Anladım" yet
        rig.store.acknowledgedDependencies = true
        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.count == 1)
        #expect(rig.cleaner.state.snapshot.executed.first?.selections.first?.mode == .permanent)
        #expect(rig.cleaner.state.snapshot.executed.first?.selections.first?.acknowledgedDependencies == true)
    }

    @Test func conditionalModeFollowsTheSettingWhileReviewing() async {
        let rig = S4Rig()
        let cond = S4.entry("vite.cache", packageDir: projectRoot, display: ".vite", safety: .conditional, selected: true)
        let always = S4.entry("next.cache", packageDir: projectRoot)
        await readyForReview(rig, entries: [cond, always])
        func modes() -> [String: DeleteMode] {
            guard case .review(_, let selections, _)? = rig.store.cleanup else { return [:] }
            return selections.mapValues(\.mode)
        }
        #expect(modes() == [cond.id: .trash, always.id: .permanent])
        rig.store.settings.deleteConditionalPermanently = true
        #expect(modes() == [cond.id: .permanent, always.id: .permanent])
        rig.store.settings.deleteConditionalPermanently = false
        #expect(modes() == [cond.id: .trash, always.id: .permanent])
        rig.store.setMode(always.id, .trash)
        #expect(modes()[always.id] == .trash)
    }

    @Test func includeDependenciesChangesTheOptionsPassedToTheServices() async {
        let rig = S4Rig()
        let next = S4.entry("next.cache", packageDir: projectRoot)
        rig.cleaner.state.with { $0.plans = [S4.plan(root: projectRoot, project: project, entries: [next])] }
        rig.catalog.state.with { $0.scripts = [[.finished(summaryOfZeroReports())]] }

        await rig.store.beginClean(projectRoot: projectRoot)
        await rig.store.scanBuilds()
        #expect(rig.cleaner.state.snapshot.planOptions.last?.includeDependencies == false)
        #expect(rig.catalog.state.snapshot.scanOptions.last?.catalog.includeDependencies == false)
        #expect(rig.catalog.state.snapshot.scanOptions.last?.roots == [S4.home + "/developer"])
        #expect(rig.catalog.state.snapshot.scanOptions.last?.maxDepth == 4)

        rig.store.settings.includeDependencies = true
        rig.store.settings.buildsMaxDepth = 6
        await rig.store.beginClean(projectRoot: projectRoot)
        await rig.store.scanBuilds()
        #expect(rig.cleaner.state.snapshot.planOptions.last?.includeDependencies == true)
        #expect(rig.catalog.state.snapshot.scanOptions.last?.catalog.includeDependencies == true)
        #expect(rig.catalog.state.snapshot.scanOptions.last?.maxDepth == 6)
    }

    // MARK: Stop + clean (R16)

    private func stopAndCleanRig(survivors: [Int32] = [], freshBlockers: [ActivityBlocker] = []) -> (S4Rig, DevServer, CacheEntry) {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        let next = S4.entry("next.cache", packageDir: projectRoot)
        let first = S4.plan(root: projectRoot, project: project, entries: [next],
                            blockers: [S4.blocker("node (PID 50)", pid: 50)])
        let fresh = S4.plan(root: projectRoot, project: project, entries: [next], blockers: freshBlockers)
        rig.cleaner.state.with { $0.plans = [first, fresh] }
        rig.terminator.state.with { $0.survivors = survivors }
        return (rig, server, next)
    }

    @Test func stopAndCleanPlansFirstAndTouchesNothingUntilConfirmed() async {
        let (rig, server, next) = stopAndCleanRig()
        await rig.store.beginStopAndClean(server)
        guard case .review(_, let selections, let stopFirst)? = rig.store.cleanup else { Issue.record("expected .review"); return }
        #expect(stopFirst?.id == server.id)
        #expect(selections.keys.contains(next.id))
        #expect(rig.log.events(prefixed: "plan:", "terminate:", "execute:") == ["plan:\(projectRoot)"])
    }

    @Test func stopAndCleanCallOrderIsPlanTerminateFreshPlanExecute() async {
        let (rig, server, next) = stopAndCleanRig()
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()

        #expect(rig.log.events(prefixed: "plan:", "terminate:", "execute:") == [
            "plan:\(projectRoot)", "terminate:50", "plan:\(projectRoot)", "execute:\(next.id)",
        ])
        guard case .finished(let result, let terminated)? = rig.store.cleanup else {
            Issue.record("expected .finished, got \(String(describing: rig.store.cleanup))"); return
        }
        #expect(terminated?.survivors.isEmpty == true)
        #expect(result.outcomes.count == 1)
        #expect(rig.store.busyKeys.isEmpty)
        // After the cleanup the process list and the project's builds row are refreshed.
        #expect(rig.log.events.contains("report:\(projectRoot)"))
    }

    @Test func stopAndCleanAbortsWhenTheServerSurvives() async {
        let (rig, server, _) = stopAndCleanRig(survivors: [50])
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()
        guard case .failed(let error)? = rig.store.cleanup else { Issue.record("expected .failed"); return }
        #expect(error.message.contains("temizlik yapılmadı"))
        #expect(rig.log.events(prefixed: "execute:").isEmpty)
        #expect(rig.log.count(prefix: "plan:") == 1)                     // no fresh re-plan after a failed stop
        #expect(rig.store.busyKeys.isEmpty)
    }

    @Test func stopAndCleanAbortsWhenTerminationThrows() async {
        let (rig, server, _) = stopAndCleanRig()
        rig.terminator.state.with { $0.error = .refused("root-is-self-ancestor") }
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()
        guard case .failed? = rig.store.cleanup else { Issue.record("expected .failed"); return }
        #expect(rig.log.events(prefixed: "execute:").isEmpty)
    }

    @Test func stopAndCleanAbortsWhenABlockerReappearsInTheFreshPlan() async {
        let (rig, server, _) = stopAndCleanRig(freshBlockers: [S4.blocker("python (PID 999)", pid: 999)])
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()
        guard case .failed(let error)? = rig.store.cleanup else { Issue.record("expected .failed"); return }
        #expect(error.message.contains("python (PID 999)"))
        #expect(rig.log.events(prefixed: "terminate:") == ["terminate:50"])
        #expect(rig.log.events(prefixed: "execute:").isEmpty)
    }

    @Test func freshPlanIsIntersectedWithTheUsersSelection() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: project)
        let next = S4.entry("next.cache", packageDir: projectRoot)
        let turbo = S4.entry("turbo.cache", packageDir: projectRoot, display: ".turbo")
        let appeared = S4.entry("vite.cache", packageDir: projectRoot, display: ".vite")
        let first = S4.plan(root: projectRoot, project: project, entries: [next, turbo], blockers: [S4.blocker("node (PID 50)", pid: 50)])
        // The fresh plan has a new entry the user never saw, and lost `turbo`.
        let fresh = S4.plan(root: projectRoot, project: project, entries: [next, appeared])
        rig.cleaner.state.with { $0.plans = [first, fresh] }
        await rig.store.beginStopAndClean(server)
        await rig.store.confirmCleanup()
        let executed = rig.cleaner.state.snapshot.executed
        #expect(executed.count == 1)
        #expect(executed.first?.plan.entries.map(\.id) == [next.id])
        #expect(executed.first?.selections.map(\.entryID) == [next.id])
    }

    @Test func stopAndCleanRefusesProjectlessServers() async {
        let rig = S4Rig()
        let server = S4.server(pid: 50, project: nil)
        await rig.store.beginStopAndClean(server)
        #expect(rig.store.cleanup == nil)
        #expect(rig.store.lastError != nil)
        #expect(rig.log.events(prefixed: "plan:").isEmpty)
    }

    @Test func dismissingWhilePlanningDropsTheLatePlan() async {
        let rig = S4Rig()
        let next = S4.entry("next.cache", packageDir: projectRoot)
        let gate = S4Gate()                                              // the plan stays "slow" until the test says so
        rig.cleaner.state.with {
            $0.planGate = gate
            $0.plans = [S4.plan(root: projectRoot, project: project, entries: [next])]
        }
        let planning = Task { await rig.store.beginClean(projectRoot: projectRoot) }
        let started = await s4Eventually {
            if case .planning? = rig.store.cleanup { return true }
            return false
        }
        #expect(started)
        rig.store.dismissCleanup()
        #expect(rig.store.cleanup == nil)
        gate.open()
        await planning.value
        #expect(rig.store.cleanup == nil)                                // the plan that arrived late was dropped
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)
    }

    // MARK: Builds

    private func buildsFixture() -> (S4Rig, [ProjectCacheReport]) {
        let rig = S4Rig()
        let names = ["a", "b", "c"]
        let reports = names.map { name -> ProjectCacheReport in
            let project = S4.project(S4.home + "/developer/" + name)
            return S4.report(project, entries: [S4.entry("next.cache", packageDir: project.root, size: nil)])
        }
        let sizes: [String: Int64] = ["a": 10, "b": 500, "c": 300]
        rig.catalog.state.with {
            for (name, report) in zip(names, reports) {
                $0.sizes[report.entries[0].id] = SizeResult(bytes: sizes[name] ?? 0, isPartial: false, itemCount: nil)
            }
            $0.scripts = [S4.scanScript(reports, visited: 9)]
        }
        return (rig, reports)
    }

    @Test func buildsAreSizedAndOrderedNotRunningFirstThenBySizeDescending() async {
        let (rig, reports) = buildsFixture()
        // "b" (the biggest) has a running server, so it sorts last.
        rig.classifier.state.with { $0.servers = [S4.server(pid: 9, project: reports[1].project)] }
        await rig.store.refreshNow()
        await rig.store.scanBuilds()

        #expect(rig.store.buildReports.map(\.project.name) == ["c", "a", "b"])
        #expect(rig.store.buildReports.map(\.knownBytes) == [300, 10, 500])
        #expect(rig.store.isRunning(rig.store.buildReports[2]))
        #expect(!rig.store.isRunning(rig.store.buildReports[0]))
        guard case .finished(let summary) = rig.store.buildsScan else { Issue.record("expected .finished"); return }
        #expect(summary.reportCount == 3)
    }

    @Test func ordersFollowTheRunningSetWhenItChanges() async {
        let (rig, reports) = buildsFixture()
        await rig.store.scanBuilds()
        #expect(rig.store.buildReports.map(\.project.name) == ["b", "c", "a"])
        rig.classifier.state.with { $0.servers = [S4.server(pid: 9, project: reports[1].project)] }
        await rig.store.refreshNow()
        #expect(rig.store.buildReports.map(\.project.name) == ["c", "a", "b"])
    }

    @Test func sizingNeverRunsMoreThanFourMeasurementsAtOnce() async {
        let rig = S4Rig()
        var reports: [ProjectCacheReport] = []
        for n in 0..<3 {
            let project = S4.project(S4.home + "/developer/p\(n)")
            let entries = (0..<4).map { S4.entry("rule\($0)", packageDir: project.root, display: "d\($0)", size: nil) }
            reports.append(S4.report(project, entries: entries))
        }
        let gate = S4Gate()                                              // every measurement is held until the test opens it
        rig.catalog.state.with {
            $0.sizeGate = gate
            $0.scripts = [S4.scanScript(reports, visited: 3)]
        }
        let scan = Task { await rig.store.scanBuilds() }
        // 12 measurements are queued; with the limit at four, exactly four are in flight while the gate is closed.
        #expect(await s4Eventually { rig.catalog.state.snapshot.current == 4 })
        #expect(rig.catalog.state.snapshot.sizeCalls == 4)
        gate.open()
        await scan.value
        let observed = rig.catalog.state.snapshot
        #expect(observed.sizeCalls == 12)
        #expect(observed.maxConcurrent == 4)
        #expect(rig.store.buildReports.allSatisfy { $0.entries.allSatisfy { $0.sizeBytes == 1_000 } })
    }

    @Test func dependenciesAreOnlySizedWhenOptedIn() async {
        let rig = S4Rig()
        let project = S4.project(S4.home + "/developer/p")
        let deps = S4.entry("node.modules", packageDir: project.root, display: "node_modules", safety: .optIn, size: nil)
        let next = S4.entry("next.cache", packageDir: project.root, size: nil)
        rig.catalog.state.with {
            $0.scripts = [[.report(S4.report(project, entries: [next, deps])),
                           .finished(BuildsScanSummary(directoriesVisited: 1, reportCount: 1, truncated: false, permissionDeniedRoots: [], seconds: 0))]]
        }
        await rig.store.scanBuilds()
        #expect(rig.catalog.state.snapshot.sizeCalls == 1)
        #expect(rig.store.buildReports.first?.entries.first(where: { $0.safety == .optIn })?.sizeBytes == nil)

        rig.store.settings.includeDependencies = true
        await rig.store.scanBuilds()
        #expect(rig.catalog.state.snapshot.sizeCalls == 3)               // 1 earlier + next + deps
    }

    @Test func aNewerScanCancelsTheOlderOne() async {
        let rig = S4Rig()
        rig.catalog.state.with {
            $0.hangingScanCalls = [0]
            $0.scripts = [[.progress(directoriesVisited: 1)], [.finished(BuildsScanSummary(directoriesVisited: 5, reportCount: 0, truncated: false,
                                                                                         permissionDeniedRoots: [], seconds: 0))]]
        }
        let first = Task { await rig.store.scanBuilds() }
        let started = await s4Eventually { rig.catalog.state.snapshot.scanOptions.count == 1 }
        #expect(started)
        #expect(rig.catalog.state.snapshot.terminatedCalls.isEmpty)       // the first stream is still hanging

        await rig.store.scanBuilds()
        _ = await first.value
        #expect(rig.catalog.state.snapshot.terminatedCalls.contains(0))   // …and was terminated by the newer scan
        guard case .finished(let summary) = rig.store.buildsScan else { Issue.record("expected the newer scan to win"); return }
        #expect(summary.directoriesVisited == 5)
    }

    @Test func permissionDeniedRootsAndTruncationReachTheUI() async {
        let rig = S4Rig()
        let summary = BuildsScanSummary(directoriesVisited: 25_000, reportCount: 0, truncated: true,
                                        permissionDeniedRoots: [S4.home + "/Desktop"], seconds: 15)
        rig.catalog.state.with { $0.scripts = [[.finished(summary)]] }
        await rig.store.scanBuilds()
        #expect(rig.store.buildsScan == .finished(summary))
        #expect(rig.store.buildReports.isEmpty)
    }

    @Test func scanThatEndsWithoutFinishedEventFails() async {
        let rig = S4Rig()
        rig.catalog.state.with { $0.scripts = [[.progress(directoriesVisited: 3)]] }
        await rig.store.scanBuilds()
        #expect(rig.store.buildsScan == .failed("Tarama tamamlanamadı"))
    }

    @Test func firstVisitOfTheBuildsTabStartsAScan() async {
        let rig = S4Rig()
        rig.catalog.state.with { $0.scripts = [[.finished(summaryOfZeroReports())]] }
        rig.store.isPopoverVisible = true
        #expect(rig.catalog.state.snapshot.scanOptions.isEmpty)           // servers tab: nothing to do
        rig.store.selectedTab = .builds
        let scanned = await s4Eventually { rig.catalog.state.snapshot.scanOptions.count == 1 }
        #expect(scanned)
        _ = await s4Eventually { rig.store.buildsScan == .finished(summaryOfZeroReports()) }
        // Visiting again does not rescan.
        rig.store.selectedTab = .servers
        rig.store.selectedTab = .builds
        for _ in 0..<20 { await Task.yield() }                            // let anything the revisit spawned run
        #expect(rig.catalog.state.snapshot.scanOptions.count == 1)
    }

    @Test func dockerTabMeasuresTheBuildCacheWhenItOpens() async {
        let rig = S4Rig()
        rig.docker.state.with {
            $0.snapshot = S4.dockerSnapshot()
            $0.buildCache = BuildCacheSummary(totalBytes: 4_200, reclaimableBytes: 5_900, privateReclaimableBytes: 100,
                                              recordCount: 2, activeCount: 0, measuredAt: S4.t0)
        }
        await rig.store.refreshNow()
        rig.store.isPopoverVisible = true
        rig.store.selectedTab = .docker
        let measured = await s4Eventually { rig.store.buildCache != nil }
        #expect(measured)
    }

    // MARK: Orphaned DerivedData

    @Test func orphanedDerivedDataFlow() async {
        let rig = S4Rig()
        let derivedData = S4.home + "/Library/Developer/Xcode/DerivedData"
        let orphan = S4.entry("xcode.deriveddata", packageDir: derivedData, display: "Foo-abcdefghijklmnopqrstuvwxyzab", size: nil,
                              instance: "Foo-abcdefghijklmnopqrstuvwxyzab")
        rig.catalog.state.with {
            $0.orphans = [orphan]
            $0.sizes[orphan.id] = SizeResult(bytes: 700, isPartial: false, itemCount: nil)
            $0.scripts = [[.finished(summaryOfZeroReports())]]
        }
        await rig.store.scanBuilds()
        #expect(rig.store.orphanedDerivedData.map(\.id) == [orphan.id])
        #expect(rig.store.orphanedDerivedData.first?.sizeBytes == 700)

        let sized = orphan.withSize(SizeResult(bytes: 700, isPartial: false, itemCount: nil))
        rig.cleaner.state.with { $0.orphanPlan = S4.plan(root: derivedData, project: nil, entries: [sized]) }
        rig.scanner.state.with { $0.nodes = [S4.node(300, name: "Xcode", exe: "/Applications/Xcode.app/Contents/MacOS/Xcode")] }

        await rig.store.beginCleanOrphanedDerivedData()
        guard case .review(let plan, let selections, let stopFirst)? = rig.store.cleanup else {
            Issue.record("expected .review, got \(String(describing: rig.store.cleanup))"); return
        }
        #expect(plan.project == nil)
        #expect(stopFirst == nil)
        #expect(rig.store.xcodeRunning)
        #expect(selections[orphan.id] != nil)
        #expect(rig.cleaner.state.snapshot.executed.isEmpty)

        await rig.store.confirmCleanup()
        #expect(rig.cleaner.state.snapshot.executed.count == 1)
        guard case .finished? = rig.store.cleanup else { Issue.record("expected .finished"); return }
        #expect(rig.log.count(prefix: "orphans") >= 2)                    // listed again after the cleanup
        rig.store.dismissCleanup()
        #expect(rig.store.xcodeRunning == false)
    }

    @Test func noOrphansShowsAMessage() async {
        let rig = S4Rig()
        await rig.store.beginCleanOrphanedDerivedData()
        guard case .failed(let error)? = rig.store.cleanup else { Issue.record("expected .failed"); return }
        #expect(error.message == "Sahipsiz DerivedData bulunamadı")
    }

    // MARK: Settings and policy

    @Test func settingsChangesArePersisted() async {
        let rig = S4Rig()
        rig.store.settings.menuBarShowsMemory = false
        rig.store.settings.serverIdleMinutes = 45
        let stored = rig.storage.stored.flatMap { try? JSONDecoder().decode(DevTidySettings.self, from: $0) }
        #expect(stored?.menuBarShowsMemory == false)
        #expect(stored?.serverIdleMinutes == 45)
    }

    @Test func idleThresholdsComeFromSettings() async {
        var settings = DevTidySettings()
        settings.serverIdleMinutes = 5
        let rig = S4Rig(settings: settings)
        let server = S4.server(pid: 10, project: project, cpu: 0, started: S4.t0.addingTimeInterval(-600))
        rig.classifier.state.with { $0.servers = [server] }
        await rig.store.refreshNow()
        #expect(rig.store.serverIdle[server.id] == .probablyIdle)         // 10 min old, window is 5 min
    }

    @Test func policyFollowsStoreState() async {
        let rig = S4Rig()
        #expect(rig.store.currentPolicy().popoverVisible == false)
        #expect(rig.store.currentPolicy().dockerReachable == true)
        rig.store.isPopoverVisible = true
        #expect(rig.store.currentPolicy().popoverVisible == true)

        rig.docker.state.with { $0.snapshot = S4.dockerSnapshot(status: .notRunning) }
        await rig.store.refreshNow()
        #expect(rig.store.currentPolicy().dockerReachable == false)
        #expect(rig.store.currentPolicy().dockerStatsInterval == nil)

        rig.docker.state.with {
            $0.snapshot = S4.dockerSnapshot(standalone: [S4.container("web"), S4.container("db", state: .exited)])
        }
        await rig.store.refreshNow()
        #expect(rig.store.currentPolicy().dockerReachable == true)
        #expect(rig.store.currentPolicy().runningContainerCount == 1)
        #expect(rig.store.currentPolicy().dockerStatsInterval == .seconds(10))
    }

    @Test func startAndShutdownAreIdempotent() async {
        let rig = S4Rig()
        rig.store.start()
        rig.store.start()
        let ticked = await s4Eventually { rig.log.count(prefix: "scan:") >= 1 && rig.log.count(prefix: "docker-snapshot:") >= 1 }
        #expect(ticked)
        rig.store.shutdown()
        rig.store.shutdown()
    }
}

// MARK: - CleanupRules ---------------------------------------------------------------

struct CleanupRulesTests {
    private let root = "/tmp/s4home/developer/proj"

    @Test func blockersBeingStoppedAreResolvedOthersAreNot() {
        let server = S4.server(pid: 50, project: S4.project(root),
                               extraMembers: [S4.node(51, ppid: 50), S4.node(52, ppid: 50)])
        let entry = S4.entry("next.cache", packageDir: root)
        let plan = S4.plan(root: root, entries: [entry], blockers: [
            S4.blocker("node (PID 50)", pid: 50), S4.blocker("npm (PID 51)", pid: 51, severity: .soft),
            S4.blocker("python (PID 99)", pid: 99), S4.blocker("db", kind: .container, severity: .soft),
        ])
        let selections = [entry.id: CleanupSelection(entryID: entry.id, mode: .permanent)]
        let unresolved = CleanupRules.unresolvedBlockers(plan: plan, selections: selections, stopFirst: server)
        #expect(unresolved.map(\.label) == ["python (PID 99)"])                     // the container is soft ⇒ not blocking class A
        #expect(CleanupRules.isBeingStopped(plan.blockers[0], stopFirst: server))
        #expect(!CleanupRules.isBeingStopped(plan.blockers[2], stopFirst: server))
        #expect(!CleanupRules.isBeingStopped(plan.blockers[0], stopFirst: nil))
        #expect(!CleanupRules.isBeingStopped(plan.blockers[3], stopFirst: server))   // containers are never "being stopped"
    }

    @Test func nothingSelectedMeansNothingBlocks() {
        let entry = S4.entry("next.cache", packageDir: root)
        let plan = S4.plan(root: root, entries: [entry], blockers: [S4.blocker("node (PID 1)", pid: 1)])
        #expect(CleanupRules.unresolvedBlockers(plan: plan, selections: [:], stopFirst: nil).isEmpty)
    }

    @Test func softBlockerBlocksOnlyWhenAConditionalOrDependencyEntryIsSelected() {
        let a = S4.entry("next.cache", packageDir: root)
        let b = S4.entry("vite.cache", packageDir: root, display: ".vite", safety: .conditional)
        let plan = S4.plan(root: root, entries: [a, b], blockers: [S4.blocker("db", kind: .container, severity: .soft)])
        let onlyA = [a.id: CleanupSelection(entryID: a.id, mode: .permanent)]
        let both = onlyA.merging([b.id: CleanupSelection(entryID: b.id, mode: .trash)]) { $1 }
        #expect(CleanupRules.unresolvedBlockers(plan: plan, selections: onlyA, stopFirst: nil).isEmpty)
        #expect(CleanupRules.unresolvedBlockers(plan: plan, selections: both, stopFirst: nil).count == 1)
    }

    @Test func totalsSplitPermanentFromTrash() {
        let a = S4.entry("a", packageDir: root, size: 100)
        let b = S4.entry("b", packageDir: root, display: "b", safety: .conditional, size: 208)
        let c = S4.entry("c", packageDir: root, display: "c", size: 50)
        let plan = S4.plan(root: root, entries: [a, b, c])
        let selections = [a.id: CleanupSelection(entryID: a.id, mode: .permanent),
                          b.id: CleanupSelection(entryID: b.id, mode: .trash)]
        let totals = CleanupRules.totals(plan: plan, selections: selections)
        #expect(totals.permanent == 100)
        #expect(totals.trash == 208)
        #expect(totals.hasPartial == false)
    }

    @Test func defaultSelectionsSkipDependenciesAndHonourTheSettingForClassB() {
        let a = S4.entry("a", packageDir: root)
        let b = S4.entry("b", packageDir: root, display: "b", safety: .conditional, selected: true)
        let c = S4.entry("c", packageDir: root, display: "c", safety: .optIn, selected: true)
        let plan = S4.plan(root: root, entries: [a, b, c])
        let trash = CleanupRules.defaultSelections(for: plan, deleteConditionalPermanently: false)
        #expect(Set(trash.keys) == [a.id, b.id])
        #expect(trash[b.id]?.mode == .trash)
        let permanent = CleanupRules.defaultSelections(for: plan, deleteConditionalPermanently: true)
        #expect(permanent[b.id]?.mode == .permanent)
        #expect(permanent[a.id]?.mode == .permanent)
    }

    @Test func orderedSelectionsFollowPlanOrder() {
        let a = S4.entry("a", packageDir: root)
        let b = S4.entry("b", packageDir: root, display: "b")
        let plan = S4.plan(root: root, entries: [a, b])
        let selections = [b.id: CleanupSelection(entryID: b.id, mode: .permanent), a.id: CleanupSelection(entryID: a.id, mode: .trash)]
        #expect(CleanupRules.orderedSelections(plan: plan, selections: selections).map(\.entryID) == [a.id, b.id])
    }
}

// MARK: - Rig helpers used above ---------------------------------------------------------

@MainActor
extension S4Rig {
    func currentPlan() -> CleanupPlan {
        guard case .review(let plan, _, _)? = store.cleanup else { fatalError("not in review") }
        return plan
    }

    func currentSelections() -> [String: CleanupSelection] {
        guard case .review(_, let selections, _)? = store.cleanup else { fatalError("not in review") }
        return selections
    }
}
