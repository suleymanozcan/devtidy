import Foundation
import Testing
@testable import DevTidyCore

/// The store decides WHEN a page title may be asked for: lazily, only while the popover shows the Sunucular tab, only with the
/// setting on, once per server identity, never for a server that is flagged idle, and never in a way that DevTidy's own idle
/// detection mistakes for the user. The request itself is the fetcher's job (`PageTitleFetcherTests`); here it is a fake that
/// only counts calls.
@MainActor
struct DevTidyStorePageTitleTests {
    private let root = S4.home + "/developer/client"
    private var project: Project { S4.project(root) }

    private func makeRig(fetching: Bool = true) -> S4Rig {
        var settings = DevTidySettings()
        settings.fetchPageTitles = fetching
        return S4Rig(settings: settings)
    }

    /// A server that started a minute ago. The default test server has run for an hour without CPU, which the idle tracker flags
    /// as "probably idle", and a flagged server is not asked (see `aServerFlaggedIdleIsNotAskedUntilItIsActiveAgain`).
    private func fresh(_ pid: Int32 = 10, port: UInt16 = 5182, cpu: Double? = 0, connections: Int = 0, scope: BindScope = .loopback,
                       binds: Set<BindAddress>? = nil, arguments: [String] = [],
                       started: Date = S4.t0.addingTimeInterval(-60)) -> DevServer {
        S4.server(pid: pid, project: project, port: port, cpu: cpu, connections: connections, started: started,
                  arguments: arguments, scope: scope, binds: binds)
    }

    /// Waits until every request the store started has been applied or dropped (the end state is decided by then), plus a few
    /// turns for anything else scheduled on the main actor.
    private func settle(_ rig: S4Rig) async {
        _ = await s4Eventually { rig.store.pendingPageTitleRequests == 0 }
        for _ in 0..<10 { await Task.yield() }
    }

    // MARK: Lazy: only while the Sunucular tab is visible

    @Test func nothingIsAskedWhileThePopoverIsClosedAndEverythingOnceItOpens() async {
        let rig = makeRig()
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 0)
        #expect(rig.store.pageTitle(for: server) == nil)

        rig.store.isPopoverVisible = true
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        #expect(rig.store.pageTitle(for: server) == "Page 5182")
        #expect(rig.pageTitles.calls == 1)
    }

    @Test func otherTabsNeverStartARequest() async {
        let rig = makeRig()
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        rig.store.selectedTab = .docker
        await rig.store.processTick()
        rig.store.selectedTab = .builds
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 0)

        rig.store.selectedTab = .servers
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        #expect(rig.pageTitles.calls == 1)
    }

    @Test func aServerThatAppearsWhileAnotherTabIsOpenIsAskedWhenTheTabComesBack() async {
        let rig = makeRig()
        let first = fresh(10, port: 5182)
        let second = fresh(11, port: 5184)
        rig.classifier.state.with { $0.servers = [first] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: first) != nil })

        rig.store.selectedTab = .docker
        rig.classifier.state.with { $0.servers = [first, second] }
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 1)

        rig.store.selectedTab = .servers
        #expect(await s4Eventually { rig.store.pageTitle(for: second) != nil })
        #expect(rig.pageTitles.state.snapshot.targets.map(\.port) == [5182, 5184])        // the first is not asked again
    }

    @Test func nothingIsAskedWhileTheCleanupSheetReplacesTheTabs() async {
        let rig = makeRig()
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        rig.store.cleanup = .failed(DevTidyStore.makeError("Temizlik yapılamadı", "x"))      // the sheet is up; the tab is still .servers
        for _ in 0..<3 { await rig.store.processTick() }
        await settle(rig)
        #expect(rig.pageTitles.calls == 0)

        rig.store.dismissCleanup()
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        #expect(rig.pageTitles.calls == 1)
    }

    // MARK: The setting

    @Test func withTheSettingOffNothingIsEverAsked() async {
        let rig = makeRig(fetching: false)
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        for _ in 0..<3 { await rig.store.processTick() }
        await settle(rig)
        #expect(rig.pageTitles.calls == 0)
        #expect(rig.store.pageTitleStatus(for: server) == .disabled)
        #expect(rig.store.presentation(for: server).titleSource == .folderName)
    }

    @Test func switchingTheSettingOffHidesTitlesAndSwitchingItOnAsksAgain() async {
        let rig = makeRig()
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        #expect(rig.store.presentation(for: server).title == "Page 5182")

        rig.store.settings.fetchPageTitles = false
        #expect(rig.store.pageTitle(for: server) == nil)
        #expect(rig.store.pageTitles.isEmpty)
        #expect(rig.store.presentation(for: server).titleSource == .folderName)
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 1)                                                // off: no further request

        // Back on: the store holds no title any more, so it asks the fetcher again (the fake answers again; the real fetcher
        // answers from its cache without a request).
        rig.store.settings.fetchPageTitles = true
        #expect(await s4Eventually { rig.store.pageTitle(for: server) == "Page 5182" })
        #expect(rig.pageTitles.calls == 2)
    }

    @Test func theSettingIsPersistedAndSurvivesAnOldSettingsBlob() throws {
        let rig = makeRig()
        rig.store.settings.fetchPageTitles = false
        let stored = try #require(rig.storage.stored.flatMap { try? JSONDecoder().decode(DevTidySettings.self, from: $0) })
        #expect(stored.fetchPageTitles == false)

        // A blob written before the setting existed: every other value is kept, the new one defaults to ON.
        let old = Data("""
        {"scanRoots":["/tmp/a"],"buildsMaxDepth":5,"serverIdleMinutes":45,"menuBarShowsMemory":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(DevTidySettings.self, from: old)
        #expect(decoded.fetchPageTitles == true)
        #expect(decoded.scanRoots == ["/tmp/a"])
        #expect(decoded.buildsMaxDepth == 5)
        #expect(decoded.serverIdleMinutes == 45)
        #expect(decoded.menuBarShowsMemory == false)
        #expect(decoded.containerIdleMinutes == DevTidySettings().containerIdleMinutes)

        let loaded = SettingsStore(storage: S4MemoryStorage(initial: old), homeDirectory: S4.home).load()
        #expect(loaded.fetchPageTitles == true)
        #expect(loaded.serverIdleMinutes == 45)
    }

    @Test func theSettingIsOnByDefault() {
        #expect(DevTidySettings().fetchPageTitles == true)
        #expect(SettingsStore(storage: S4MemoryStorage(), homeDirectory: S4.home).load().fetchPageTitles == true)
    }

    @Test func aTitleThatArrivesAfterTheSettingWasSwitchedOffIsDropped() async {
        let rig = makeRig()
        let gate = S4Gate()
        rig.pageTitles.state.with { $0.gates = [gate] }
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.pageTitles.calls == 1 })

        rig.store.settings.fetchPageTitles = false
        gate.open()
        await settle(rig)
        #expect(rig.store.pageTitles.isEmpty)
        #expect(rig.store.pageTitle(for: server) == nil)
    }

    // MARK: Once per server identity

    @Test func oneAskPerServerIdentityAcrossManyTicks() async {
        let rig = makeRig()
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        for _ in 0..<5 { await rig.store.processTick() }
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        for _ in 0..<5 { await rig.store.processTick() }
        await settle(rig)
        #expect(rig.pageTitles.calls == 1)
    }

    @Test func aRequestInFlightIsNotStartedASecondTime() async {
        let rig = makeRig()
        let gate = S4Gate()
        rig.pageTitles.state.with { $0.gates = [gate] }
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        for _ in 0..<4 { await rig.store.processTick() }
        #expect(await s4Eventually { rig.pageTitles.calls == 1 })
        gate.open()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        #expect(rig.pageTitles.calls == 1)
    }

    @Test func aRestartedServerIsANewIdentityAndAskedAgain() async {
        let rig = makeRig()
        let before = fresh(started: S4.t0.addingTimeInterval(-120))
        let after = fresh(started: S4.t0.addingTimeInterval(-60))
        rig.store.isPopoverVisible = true
        rig.classifier.state.with { $0.servers = [before] }
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: before) != nil })
        rig.classifier.state.with { $0.servers = [after] }
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: after) != nil })
        #expect(rig.pageTitles.calls == 2)
    }

    @Test func aServerThatWentAwayDropsItsTitle() async {
        let rig = makeRig()
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        rig.classifier.state.with { $0.servers = [] }
        await rig.store.processTick()
        #expect(rig.store.pageTitles.isEmpty)
    }

    // MARK: Which listeners are asked

    @Test func inspectorsNonLoopbackBindsAndDeclaredInspectorPortsAreSkipped() async {
        let rig = makeRig()
        let inspectorOnly = fresh(20, port: 9230)
        let lanAddress = fresh(21, port: 3001, scope: .other)
        let declaredInspector = fresh(22, port: 9300, arguments: ["node", "--inspect-port=9300"])
        let normal = fresh(23, port: 3002, scope: .allInterfaces)
        rig.classifier.state.with { $0.servers = [inspectorOnly, lanAddress, declaredInspector, normal] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: normal) != nil })
        await settle(rig)
        #expect(rig.pageTitles.state.snapshot.targets.map(\.server.pid) == [23])
        #expect(rig.store.pageTitleStatus(for: inspectorOnly) == .notApplicable)
        #expect(rig.store.pageTitleStatus(for: lanAddress) == .notApplicable)
        #expect(rig.store.pageTitleStatus(for: declaredInspector) == .notApplicable)
    }

    @Test func otherListenersAreNeverAsked() async {
        let rig = makeRig()
        let node = S4.node(30, name: "Spotify")
        rig.classifier.state.with {
            $0.others = [OtherListener(node: node, ports: [S4.port(57621, owner: 30)], reason: .app)]
        }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 0)
    }

    // MARK: A port that another process shares

    /// `com.docker.backend`'s socket for a published container port: the classifier lists it nowhere, the scan's listener table
    /// still has it.
    private func docker(_ port: UInt16, on bind: BindAddress) -> [Int32: [ListeningPort]] {
        [19_200: [S4.port(port, owner: 19_200, binds: [bind])]]
    }

    @Test func aServerOnIPv6LoopbackIsAskedOnIPv6WhileDockerHoldsTheSamePortOnIPv4() async {
        let rig = makeRig()
        let redalert = fresh(39_467, port: 5173, binds: [.ipv6Loopback])
        rig.classifier.state.with { $0.servers = [redalert] }
        rig.scanner.state.with { $0.listeners = docker(5173, on: .ipv4(127, 0, 0, 1)) }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: redalert) != nil })
        #expect(rig.pageTitles.state.snapshot.targets.map(\.addresses) == [[.ipv6]])
    }

    @Test func aServerWhoseEveryAddressAnotherProcessTakesIsNotAskedAndSaysWhy() async {
        let rig = makeRig()
        let server = fresh(39_467, port: 5173, binds: [.ipv4Wildcard])
        rig.classifier.state.with { $0.servers = [server] }
        rig.scanner.state.with { $0.listeners = docker(5173, on: .ipv4(127, 0, 0, 1)) }
        rig.store.isPopoverVisible = true
        for _ in 0..<2 { await rig.store.processTick() }
        await settle(rig)
        #expect(rig.pageTitles.calls == 0)
        #expect(rig.store.pageTitleStatus(for: server) == .portShared)
        #expect(rig.store.pageTitle(for: server) == nil)

        // The container goes away: the server's own address is free again and is asked.
        rig.scanner.state.with { $0.listeners = [:] }
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        #expect(rig.pageTitles.state.snapshot.targets.map(\.addresses) == [[.ipv4(127, 0, 0, 1)]])
        #expect(rig.store.pageTitleStatus(for: server) == .title("Page 5173"))
    }

    @Test func aTitleReadThroughOtherAddressesIsNotReusedWhenTheAddressesChange() async {
        let rig = makeRig()
        let server = fresh(39_467, port: 5173, binds: [.ipv4(127, 0, 0, 1), .ipv6Loopback])
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) != nil })
        #expect(rig.pageTitles.state.snapshot.targets.map(\.addresses) == [[.ipv4(127, 0, 0, 1), .ipv6]])

        // A container now publishes the port on IPv4: what was read before may have been the container's page.
        rig.scanner.state.with { $0.listeners = docker(5173, on: .ipv4(127, 0, 0, 1)) }
        rig.pageTitles.state.with { $0.fallback = { _ in .title("Own page") } }
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) == "Own page" })
        #expect(rig.pageTitles.state.snapshot.targets.map(\.addresses) == [[.ipv4(127, 0, 0, 1), .ipv6], [.ipv6]])
        #expect(rig.store.pageTitles.count == 1)                                          // the old target's title is gone
    }

    // MARK: Failure and the single retry

    @Test func aFailureIsAskedAgainOnlyOnceItsRetryIsDue() async {
        let rig = makeRig()
        let due = S4.t0.addingTimeInterval(60)
        rig.pageTitles.state.with { $0.fallback = { _ in .failed(retryAt: due) } }
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitleStatus(for: server) == .failed })

        rig.clock.advance(59)
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 1)                                                // not due yet

        rig.pageTitles.state.with { $0.fallback = { _ in .title("Back") } }
        rig.clock.advance(1)
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: server) == "Back" })
        #expect(rig.pageTitles.calls == 2)

        rig.clock.advance(3_600)
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 2)
    }

    @Test func aFinalFailureIsNeverAskedAgain() async {
        let rig = makeRig()
        rig.pageTitles.state.with { $0.fallback = { _ in .failed(retryAt: nil) } }
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitleStatus(for: server) == .failed })
        rig.clock.advance(86_400)
        await rig.store.processTick()
        await settle(rig)
        #expect(rig.pageTitles.calls == 1)
    }

    @Test func theDetailsSayWhyThereIsNoTitle() async {
        let rig = makeRig()
        let server = fresh()
        rig.classifier.state.with { $0.servers = [server] }
        await rig.store.processTick()
        #expect(rig.store.pageTitleStatus(for: server) == .pending)                       // popover closed: not asked yet

        rig.pageTitles.state.with { $0.fallback = { _ in .noTitle } }
        rig.store.isPopoverVisible = true
        #expect(await s4Eventually { rig.store.pageTitleStatus(for: server) == .noTitle })
    }

    // MARK: DevTidy's own probe and DevTidy's own idle detection (the request is not the user working)

    @Test func aServerFlaggedIdleIsNotAskedUntilItIsActiveAgain() async {
        let rig = makeRig()
        // The default test server has run for an hour with no CPU and no connection: "probably idle".
        let sleeper = S4.server(pid: 10, project: project, port: 5182)
        rig.classifier.state.with { $0.servers = [sleeper] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(rig.store.serverIdle[sleeper.id] == .probablyIdle)
        for _ in 0..<3 { await rig.store.processTick() }
        await settle(rig)
        #expect(rig.pageTitles.calls == 0)                                                // a request would wake it
        #expect(rig.store.pageTitleStatus(for: sleeper) == .skippedIdle)
        #expect(rig.store.serverIdle[sleeper.id] == .probablyIdle)                        // and nothing changed its state

        // The user (or the server itself) is working on it again: now it is asked.
        let awake = S4.server(pid: 10, project: project, port: 5182, cpu: 30)
        rig.classifier.state.with { $0.servers = [awake] }
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: awake) != nil })
        #expect(rig.pageTitles.calls == 1)
    }

    @Test func theProbesOwnBurstOfCpuNeverCountsAsActivityAndNeverUnflagsAServer() async {
        // The regression (code review 3, R3-P1-1): a title request on the first scan after the popover opens makes the server
        // compile a page; the next 2 s tick saw "CPU ≫ 1 %", took it for the user's activity and restarted the whole 30-minute
        // idle window, so the servers the app exists to flag lost their badge. Here: the user was last active at t0; the probe
        // happens at t0 + 29 min while the server's CPU is at 40 % for the whole of the probe and a few seconds after it.
        let rig = makeRig()
        let gate = S4Gate()
        let quiet = fresh(cpu: 0)
        let burst = fresh(cpu: 40)                                                         // same identity, other CPU
        let threshold = TimeInterval(rig.store.settings.serverIdleMinutes * 60)
        #expect(threshold == 1_800)

        rig.classifier.state.with { $0.servers = [fresh(cpu: 50)] }                        // t0: really busy
        await rig.store.processTick()
        #expect(rig.store.serverIdle[quiet.id] == .active)

        rig.clock.advance(29 * 60)
        rig.classifier.state.with { $0.servers = [quiet] }                                 // t0 + 29 min: quiet, 1 min to go
        await rig.store.processTick()
        #expect(rig.store.serverIdle[quiet.id] == .active)

        // The popover opens: the probe starts (held by the gate, so it is "running" for as long as the test wants).
        rig.pageTitles.state.with { $0.gates = [gate] }
        rig.store.isPopoverVisible = true
        #expect(await s4Eventually { rig.pageTitles.calls == 1 })

        // While it runs, two ticks see the burst.
        for _ in 0..<2 {
            rig.clock.advance(2)
            rig.classifier.state.with { $0.servers = [burst] }
            await rig.store.processTick()
            #expect(rig.store.serverIdle[quiet.id] == .active)
        }
        gate.open()
        await settle(rig)
        #expect(rig.store.pageTitle(for: quiet) == "Page 5182")

        // The tail of the burst after the answer (a compile that outlives the response) is still the probe's.
        for _ in 0..<2 {
            rig.clock.advance(2)
            rig.classifier.state.with { $0.servers = [burst] }
            await rig.store.processTick()
        }
        // Past the window, quiet again: nothing the probe did is in the idle clock, so the 30 minutes still run from t0.
        rig.clock.advance(2)
        rig.classifier.state.with { $0.servers = [quiet] }
        await rig.store.processTick()
        rig.clock.advance(2)
        await rig.store.processTick()
        #expect(rig.store.serverIdle[quiet.id] == .active)                                 // t0 + 29 min 12 s: not yet 30 min

        rig.clock.set(S4.t0.addingTimeInterval(threshold + 1))
        await rig.store.processTick()
        #expect(rig.store.serverIdle[quiet.id] == .idle)                                   // flagged on time; the probe cost nothing
        #expect(rig.store.summary.flaggedIdleCount == 1)

        // A server that really is busy is seen again by the first sample after the window.
        rig.clock.advance(2)
        rig.classifier.state.with { $0.servers = [burst] }
        await rig.store.processTick()
        #expect(rig.store.serverIdle[quiet.id] == .active)
    }

    @Test func aRealConnectionDuringTheProbeIsNotActivityEither() async {
        // The probe is itself an established connection: `establishedConnections > 0` must not count while it runs.
        let rig = makeRig()
        let gate = S4Gate()
        rig.pageTitles.state.with { $0.gates = [gate] }
        let quiet = fresh(cpu: 0)
        rig.classifier.state.with { $0.servers = [fresh(cpu: 50)] }
        await rig.store.processTick()                                                      // last active at t0
        rig.clock.advance(29 * 60)
        rig.classifier.state.with { $0.servers = [quiet] }
        await rig.store.processTick()
        rig.store.isPopoverVisible = true
        #expect(await s4Eventually { rig.pageTitles.calls == 1 })

        rig.clock.advance(2)
        rig.classifier.state.with { $0.servers = [fresh(cpu: 0, connections: 1)] }
        await rig.store.processTick()
        gate.open()
        await settle(rig)

        rig.clock.set(S4.t0.addingTimeInterval(1_801))
        rig.classifier.state.with { $0.servers = [quiet] }
        await rig.store.processTick()
        #expect(rig.store.serverIdle[quiet.id] == .idle)
    }

    // MARK: Identities

    @Test func identitiesAreResolvedOncePerRootInTheSameTickAsTheScan() async {
        let rig = makeRig()
        let a = S4.server(pid: 10, project: project, port: 5182)
        let b = S4.server(pid: 11, project: project, port: 5184)
        rig.identities.table.with {
            $0[root] = S4.identity(root, repoRoot: S4.home + "/developer", pathInRepo: "client", head: .branch("main"),
                                   manifest: ProjectManifest(name: "@red/client", version: "1.0.0", source: .packageJSON))
        }
        rig.classifier.state.with { $0.servers = [a, b] }
        await rig.store.processTick()
        #expect(rig.log.count(prefix: "identity:") == 1)                                  // two servers, one project root
        #expect(rig.store.identity(for: a)?.head == .branch("main"))
        #expect(rig.store.identity(for: b)?.manifest?.label == "@red/client@1.0.0")
        #expect(rig.store.presentation(for: a).title == "@red/client")
        #expect(rig.store.presentation(for: a).titleSource == .manifestName)
        #expect(rig.store.details(for: a).head == .branch("main"))
    }

    @Test func aServerWithoutAProjectHasNoIdentity() async {
        let rig = makeRig()
        let loose = S4.server(pid: 12, project: nil, port: 4000)
        rig.classifier.state.with { $0.servers = [loose] }
        await rig.store.processTick()
        #expect(rig.store.identity(for: loose) == nil)
        #expect(rig.log.count(prefix: "identity:") == 0)
        #expect(rig.store.presentation(for: loose).titleSource == .processName)
    }

    // MARK: Rows that read the same

    @Test func theStoreTellsTwoRowsWithTheSameTitleApart() async {
        let rig = makeRig()
        rig.pageTitles.state.with { state in
            state.fallback = { target in target.port == 3000 ? PageTitleState.title("Shop") : PageTitleState.title("Kızıl Alarm — Prototip") }
        }
        let rootA = S4.home + "/tmp/redalert-perf/packages/client"
        let rootB = S4.home + "/tmp/redalert-perf-base/packages/client"
        let release = ProjectManifest(name: "@redalert/client", version: "0.1.0", source: .packageJSON)
        rig.identities.table.with {
            $0[rootA] = S4.identity(rootA, repoRoot: S4.home + "/tmp/redalert-perf", pathInRepo: "packages/client",
                                    head: .branch("perf-fx"), manifest: release)
            $0[rootB] = S4.identity(rootB, repoRoot: S4.home + "/tmp/redalert-perf-base", pathInRepo: "packages/client",
                                    head: .branch("main"), manifest: release)
        }
        let a = S4.server(pid: 10, project: S4.project(rootA), port: 5182, started: S4.t0.addingTimeInterval(-60))
        let b = S4.server(pid: 11, project: S4.project(rootB), port: 5184, started: S4.t0.addingTimeInterval(-60))
        let alone = S4.server(pid: 12, project: S4.project(S4.home + "/developer/shop"), port: 3000,
                              started: S4.t0.addingTimeInterval(-60))
        rig.classifier.state.with { $0.servers = [a, b, alone] }
        rig.store.isPopoverVisible = true
        await rig.store.processTick()
        #expect(await s4Eventually { rig.store.pageTitle(for: a) != nil && rig.store.pageTitle(for: b) != nil
            && rig.store.pageTitle(for: alone) != nil })

        // The page titles of a and b are equal, and so is everything else on the row but the port chip.
        #expect(rig.store.presentation(for: a).title == rig.store.presentation(for: b).title)
        let qualifiers = rig.store.rowQualifiers
        #expect(qualifiers[a.id] == "redalert-perf › packages/client (perf-fx) · :5182")
        #expect(qualifiers[b.id] == "redalert-perf-base › packages/client (main) · :5184")
        #expect(qualifiers[alone.id] == nil)
    }
}
