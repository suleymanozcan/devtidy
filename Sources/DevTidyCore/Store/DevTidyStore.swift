import Foundation
import Observation
import os

public enum BuildsScanState: Equatable, Sendable {
    case idle
    case scanning(directories: Int)
    case finished(BuildsScanSummary)
    case failed(String)
}

/// Popover tabs. Kept in the store so polling can follow what the user is looking at (§6.2).
public enum DevTidyTab: String, CaseIterable, Sendable {
    case servers, docker, builds
}

/// The single UI state holder (§6.1). It only *assigns* results; every filesystem / process / socket call happens
/// inside the injected services, which are `nonisolated` (or actors) and therefore run off the main actor.
@MainActor @Observable
public final class DevTidyStore {
    // MARK: Observable state

    public private(set) var serverScan: ServerScan = .empty
    public private(set) var serverIdle: [ProcessIdentity: IdleState] = [:]
    public private(set) var dockerSnapshot: DockerSnapshot = .unknown
    public private(set) var containerIdle: [String: IdleState] = [:]
    public private(set) var buildCache: BuildCacheSummary?
    /// Why the last build-cache measurement failed; cleared by a success. The Docker tab shows it with a retry.
    public private(set) var buildCacheFailure: String?
    /// True only while a build-cache measurement request is in flight.
    public private(set) var isMeasuringBuildCache = false
    public private(set) var buildReports: [ProjectCacheReport] = []        // not-running first, then known bytes desc
    public private(set) var buildsScan: BuildsScanState = .idle
    public private(set) var runningProjectRoots: Set<String> = []          // from servers + running containers' working dirs
    public private(set) var orphanedDerivedData: [CacheEntry] = []
    public private(set) var busyKeys: Set<String> = []                     // "server:<pid>", "container:<id>", "compose:<name>", "prune"
    public var cleanup: CleanupFlow?                                        // non-nil ⇒ sheet visible
    public private(set) var cleanupProgress: [CleanupOutcome] = []         // outcomes streamed while `.executing`
    /// Class C (dependencies) needs an explicit "Anladım"; reset whenever a new review starts.
    public var acknowledgedDependencies = false
    /// Set while an orphaned-DerivedData plan is under review: Xcode is running (notice only, never a blocker).
    public private(set) var xcodeRunning = false
    public private(set) var lastBuildCachePrune: BuildCachePruneResult?
    /// Identity of every project that has a running server, by project root: resolved off the main actor, in the same tick as
    /// the scan it belongs to.
    public private(set) var projectIdentities: [String: ProjectIdentity] = [:]
    /// Page-title state per server. Filled only while the popover shows the Sunucular tab and the setting is on.
    public private(set) var pageTitles: [PageTitleTarget: PageTitleState] = [:]
    public var settings: DevTidySettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    public private(set) var lastError: UserFacingError?
    public var isPopoverVisible = false {
        didSet { if isPopoverVisible != oldValue { visibilityDidChange() } }
    }
    public var selectedTab: DevTidyTab = .servers {
        didSet { if selectedTab != oldValue { tabActivated() } }
    }

    // MARK: Private state

    private let services: DevTidyServices
    private let settingsStore: SettingsStore
    private let logger = Logger(subsystem: "dev.minata.DevTidy", category: "store")
    @ObservationIgnored private var polling: PollingCoordinator?
    @ObservationIgnored private var serverIdleTracker = IdleTracker<ProcessIdentity>()
    @ObservationIgnored private var containerIdleTracker = IdleTracker<String>()
    @ObservationIgnored private var buildsTask: Task<Void, Never>?
    @ObservationIgnored private var buildsGeneration = 0
    @ObservationIgnored private var sizingQueue: SizingQueue?
    @ObservationIgnored private var lastBuildsScanAt: Date?
    @ObservationIgnored private var lastBuildCacheFailureAt: Date?
    // Ordering of results is by when a request was ISSUED (a store-side sequence), never by wall-clock stamps: a clock that
    // steps backwards must not freeze a list, and a slow call that finishes late must not overwrite a newer answer.
    @ObservationIgnored private var processTickSeq = 0
    @ObservationIgnored private var appliedProcessSeq = 0
    @ObservationIgnored private var dockerTickSeq = 0
    @ObservationIgnored private var appliedDockerSeq = 0
    @ObservationIgnored private var appliedStatsSeq = 0
    @ObservationIgnored private var pageTitleTasks: [PageTitleTarget: Task<Void, Never>] = [:]
    /// Per server: when the effects of DevTidy's own title request on that server end. A sample taken before then says nothing
    /// about the user (`applyServerScan`).
    @ObservationIgnored private var probeQuietUntil: [ProcessIdentity: Date] = [:]
    /// When the previous server scan was applied: the start of the window the next CPU sample covers.
    @ObservationIgnored private var lastServerScanAt: Date?
    /// How long after a title request is answered (or abandoned) its effect on the server still counts as the probe's, not the
    /// user's: the compile a Next.js page starts, the file-watch and HMR chatter that follows.
    static let probeAfterglow: TimeInterval = 5
    /// A prune finished while a measurement was in flight: that figure predates it, measure once more when it lands.
    @ObservationIgnored private var remeasureBuildCache = false
    /// Test seam: every poke the store sends to the polling loops (`nil` = all of them), whether or not `start()` was called.
    @ObservationIgnored var onPoke: (@MainActor (PollingCoordinator.Loop?) -> Void)?
    /// Test seam: page-title requests started and not yet applied (or dropped).
    var pendingPageTitleRequests: Int { pageTitleTasks.count }

    // MARK: Init / lifecycle

    public init(services: DevTidyServices, settingsStore: SettingsStore) {
        self.services = services
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    public var summary: MenuBarSummary {
        let runningContainers = dockerSnapshot.allContainers.filter(\.isRunning)
        let serverMemory = serverScan.servers.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let containerMemory = runningContainers.reduce(UInt64(0)) { $0 + ($1.memoryBytes ?? 0) }
        let flaggedServers = serverScan.servers.filter { serverIdle[$0.id]?.isFlagged == true }.count
        let flaggedContainers = runningContainers.filter { containerIdle[$0.id]?.isFlagged == true }.count
        return MenuBarSummary(runningServers: serverScan.servers.count,
                              runningContainers: runningContainers.count,
                              totalMemoryBytes: serverMemory + containerMemory,
                              flaggedIdleCount: flaggedServers + flaggedContainers)
    }

    /// Running containers whose state is `.idle` (never `.probablyIdle`): the only targets of "Boştakileri Durdur".
    public var idleContainers: [DockerContainer] {
        dockerSnapshot.allContainers.filter { $0.isRunning && containerIdle[$0.id] == .idle }
    }

    /// The Servers tab sections: one per project root (titled `repo › path` from its identity), servers without a project last.
    public var serverGroups: [ServerGroup] { ServerGrouping.groups(of: serverScan.servers, identities: projectIdentities) }

    public func identity(for server: DevServer) -> ProjectIdentity? {
        server.project.flatMap { projectIdentities[$0.root] }
    }

    /// The page title to show: nil while the setting is off, before the fetch ended, and when the page has none.
    public func pageTitle(for server: DevServer) -> String? {
        guard settings.fetchPageTitles, let target = PageTitleTarget.make(for: server, in: serverScan),
              case .title(let title)? = pageTitles[target] else { return nil }
        return title
    }

    public func presentation(for server: DevServer) -> ServerPresentation {
        ServerPresentation(server: server, identity: identity(for: server), pageTitle: pageTitle(for: server))
    }

    public func details(for server: DevServer) -> ServerDetails {
        ServerDetails(server: server, identity: identity(for: server), pageTitle: pageTitle(for: server))
    }

    /// For the servers whose row titles read the same (two checkouts of one repository serving the same page): the text that
    /// tells them apart, `repo › path (branch) · :port`. Servers with a title of their own are not in it.
    public var rowQualifiers: [ProcessIdentity: String] {
        ServerRowQualifier.qualifiers(for: serverScan.servers.map { server in
            ServerRowInfo(server: server, presentation: presentation(for: server), identity: identity(for: server))
        })
    }

    /// What the details can say about the page title of `server`.
    public func pageTitleStatus(for server: DevServer) -> PageTitleStatus {
        guard settings.fetchPageTitles else { return .disabled }
        let target: PageTitleTarget
        switch PageTitleTarget.select(for: server, in: serverScan) {
        case .ask(let selected): target = selected
        case .notApplicable: return .notApplicable
        case .shared: return .portShared
        }
        switch pageTitles[target] {
        case nil: return serverIdle[server.id]?.isFlagged == true ? .skippedIdle : .pending
        case .title(let title)?: return .title(title)
        case .noTitle?: return .noTitle
        case .failed?: return .failed
        }
    }

    /// False while a stop, container action, prune or cleanup is running: quitting then would lose the SIGKILL escalation
    /// or leave a half-deleted cache directory.
    public var canQuit: Bool { busyKeys.isEmpty && cleanup?.isExecuting != true }

    /// Spawns the polling loops. Idempotent.
    public func start() {
        guard polling == nil else { return }
        let work = PollingCoordinator.Work(
            policy: { [weak self] in self?.currentPolicy() ?? PollingPolicy() },
            processTick: { [weak self] in await self?.processTick() },
            dockerListTick: { [weak self] in await self?.dockerListTick() },
            dockerStatsTick: { [weak self] in await self?.dockerStatsTick() },
            housekeepingTick: { [weak self] in await self?.housekeepingTick() })
        let coordinator = PollingCoordinator(work: work)
        polling = coordinator
        coordinator.start()
    }

    public func shutdown() {
        polling?.stop()
        polling = nil
        buildsTask?.cancel()
        sizingQueue?.cancelAll()
    }

    /// One process tick + one Docker list tick, sequentially (≈ 80 ms in total, all off the main actor).
    public func refreshNow() async {
        await processTick()
        await dockerListTick()
    }

    public func url(forPort port: UInt16) -> URL {
        URL(string: "http://localhost:\(port)") ?? URL(fileURLWithPath: "/")
    }

    public func dismissError() { lastError = nil }

    // MARK: Polling ticks

    func currentPolicy() -> PollingPolicy {
        PollingPolicy(popoverVisible: isPopoverVisible,
                      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                      dockerReachable: dockerReachable,
                      runningContainerCount: dockerSnapshot.allContainers.filter(\.isRunning).count)
    }

    func processTick() async {
        processTickSeq += 1
        let seq = processTickSeq
        let snapshot = await services.scanner.snapshot(.standard)
        let scan = await services.classifier.classify(snapshot)
        let roots = Set(scan.servers.compactMap { $0.project?.root })
        let identities = await IdentityResolution.resolve(roots, with: services.identities)
        applyServerScan(scan, identities: identities, seq: seq)
    }

    func dockerListTick() async {
        dockerTickSeq += 1
        let seq = dockerTickSeq
        applyDockerSnapshot(await services.docker.snapshot(stats: .reuse), seq: seq, sampledStats: false)
    }

    func dockerStatsTick() async {
        dockerTickSeq += 1
        let seq = dockerTickSeq
        applyDockerSnapshot(await services.docker.snapshot(stats: .refresh), seq: seq, sampledStats: true)
    }

    /// Popover-open chores with their own staleness windows: builds scan ≤ every 30 min, build-cache summary ≤ every 5 min.
    func housekeepingTick() async {
        guard isPopoverVisible else { return }
        let now = services.now()
        switch selectedTab {
        case .builds:
            if case .finished = buildsScan, let last = lastBuildsScanAt,
               now.timeIntervalSince(last) >= PollingPolicy.buildsAutoRefresh {
                await scanBuilds()
            }
        case .docker:
            await refreshBuildCacheIfStale()
        case .servers:
            break
        }
    }

    private func applyServerScan(_ scan: ServerScan, identities: [String: ProjectIdentity], seq: Int) {
        guard seq > appliedProcessSeq else { return }   // a tick issued after this one already landed
        appliedProcessSeq = seq
        serverScan = scan
        if identities != projectIdentities { projectIdentities = identities }
        let now = services.now()
        let threshold = TimeInterval(settings.serverIdleMinutes) * 60
        // The CPU percentage of this sample covers the time since the previous scan, so a probe whose effects ended before that
        // moment is not in it.
        let windowStart = lastServerScanAt ?? now
        lastServerScanAt = now
        let probing = Set(pageTitleTasks.keys.map(\.server))
        var samples: [ProcessIdentity: IdleSample] = [:]
        for server in scan.servers {
            // §6.3: active = CPU at/above the threshold or an established connection; no CPU yet ⇒ connections decide.
            let cpuActive = server.cpuPercent.map { $0 >= settings.idleCPUPercent } ?? false
            let busy = cpuActive || server.establishedConnections > 0
            // DevTidy's own title request is a connection, and on Next.js a page compile (seconds of CPU): neither is the user working
            // on the server. While a request runs, and until its effects end (`probeAfterglow`), the sample is "no evidence": an
            // active sample would restart the whole idle window and hide a server the app exists to flag. A server that really is
            // busy is seen again by the first sample taken after that.
            let isProbeActivity = probing.contains(server.id) || (probeQuietUntil[server.id].map { $0 > windowStart } ?? false)
            samples[server.id] = IdleSample(isActive: busy && !isProbeActivity, age: server.uptime(at: now))
        }
        let live = Set(scan.servers.map(\.id))
        probeQuietUntil = probeQuietUntil.filter { live.contains($0.key) && $0.value > now }
        serverIdle = serverIdleTracker.update(samples, threshold: threshold, now: now)
        recomputeDerived()
        let targets = Set(scan.servers.compactMap { PageTitleTarget.make(for: $0, in: scan) })
        if pageTitles.keys.contains(where: { !targets.contains($0) }) {
            pageTitles = pageTitles.filter { targets.contains($0.key) }
        }
        refreshPageTitles()
    }

    /// `seq` orders requests by when they were issued. A slow stats pass that started before a newer list (a stop, a start) must
    /// not bring back the container list it saw; its fresher cpu / memory samples are still taken.
    private func applyDockerSnapshot(_ incoming: DockerSnapshot, seq: Int, sampledStats: Bool) {
        let snapshot: DockerSnapshot
        if seq > appliedDockerSeq {
            snapshot = incoming
            appliedDockerSeq = seq
            if sampledStats { appliedStatsSeq = seq }
        } else if sampledStats, seq > appliedStatsSeq {
            snapshot = dockerSnapshot.mergingStats(from: incoming)
            appliedStatsSeq = seq
        } else {
            return
        }

        let previousRunning = dockerSnapshot.allContainers.filter(\.isRunning).count
        let wasEngineRunning = Self.isEngineRunning(dockerSnapshot.status)
        dockerSnapshot = snapshot
        let now = services.now()
        let threshold = TimeInterval(settings.containerIdleMinutes) * 60
        var samples: [String: IdleSample] = [:]
        for container in snapshot.allContainers where container.isRunning {
            // Unknown CPU (first stats pass) is "no evidence", not "idle": leave the container out until a value exists.
            guard let cpu = container.cpuPercent else { continue }
            samples[container.id] = IdleSample(isActive: cpu >= settings.idleCPUPercent,
                                               age: container.uptime(at: now) ?? 0)
        }
        containerIdle = containerIdleTracker.update(samples, threshold: threshold, now: now)
        if !dockerReachable {
            buildCacheFailure = nil
            lastBuildCacheFailureAt = nil
        }
        recomputeDerived()

        // A first running container switches the stats loop on at once instead of after its idle re-check.
        if previousRunning == 0, snapshot.allContainers.contains(where: \.isRunning) {
            poke(.dockerStats)
        }
        // The engine just came up while the Docker tab is showing: measure the build cache now, not on the next housekeeping tick.
        if !wasEngineRunning, Self.isEngineRunning(snapshot.status) { tabActivated() }
    }

    private static func isEngineRunning(_ status: DockerStatus) -> Bool {
        if case .running = status { return true }
        return false
    }

    private func recomputeDerived() {
        var roots = Set<String>()
        for server in serverScan.servers { if let root = server.project?.root { roots.insert(root) } }
        for container in dockerSnapshot.allContainers where container.isRunning {
            if let dir = container.composeWorkingDir { roots.insert(dir) }
        }
        if roots != runningProjectRoots {
            runningProjectRoots = roots
            sortBuildReports()
        }
    }

    // MARK: Settings / visibility

    private func settingsDidChange(from old: DevTidySettings) {
        guard settings != old else { return }
        settingsStore.save(settings)
        if settings.deleteConditionalPermanently != old.deleteConditionalPermanently { remapConditionalModes() }
        let scanChanged = settings.scanRoots != old.scanRoots
            || settings.buildsMaxDepth != old.buildsMaxDepth
            || settings.includeDependencies != old.includeDependencies
        if scanChanged {
            supersedeBuildsScan()
            tabActivated()
        }
        if settings.fetchPageTitles != old.fetchPageTitles {
            if settings.fetchPageTitles {
                refreshPageTitles()
            } else if !pageTitles.isEmpty {
                pageTitles = [:]                       // switched off: nothing derived from a page is shown any more
            }
        }
        pokeAll()
    }

    private func visibilityDidChange() {
        if isPopoverVisible { pokeAll() }
        tabActivated()
    }

    /// First visit of the Builds tab scans; the Docker tab refreshes a stale build-cache summary; the Servers tab reads the
    /// page titles it does not have yet.
    private func tabActivated() {
        guard isPopoverVisible else { return }
        switch selectedTab {
        case .builds:
            if buildsScan == .idle { Task { await scanBuilds() } }
        case .docker:
            Task { await refreshBuildCacheIfStale() }
        case .servers:
            refreshPageTitles()
        }
    }

    private func poke(_ loop: PollingCoordinator.Loop) {
        polling?.poke(loop)
        onPoke?(loop)
    }

    private func pokeAll() {
        polling?.pokeAll()
        onPoke?(nil)
    }

    // MARK: Page titles

    /// One `GET /` per server identity, to the server's own loopback address (see `PageTitleFetcher`). Runs only while the popover
    /// is open on the Sunucular tab (not behind the cleanup sheet) and the setting is on; a server that already has a final answer,
    /// one being fetched and a failure whose retry is not due yet are skipped, so a tick costs no I/O.
    ///
    /// A server flagged idle is not asked either: a request wakes it (a page compile in Next.js, a log line, HMR traffic), and the
    /// servers the app exists to flag are exactly the quiet ones. It is asked once it is active again.
    private func refreshPageTitles() {
        guard settings.fetchPageTitles, isPopoverVisible, selectedTab == .servers, cleanup == nil else { return }
        let now = services.now()
        let fetcher = services.pageTitles
        for server in serverScan.servers {
            guard let target = PageTitleTarget.make(for: server, in: serverScan), pageTitleTasks[target] == nil else { continue }
            if serverIdle[server.id]?.isFlagged == true { continue }
            switch pageTitles[target] {
            case .title?, .noTitle?: continue
            case .failed(let retryAt)?:
                guard let retryAt, now >= retryAt else { continue }
            case nil: break
            }
            pageTitleTasks[target] = Task { [weak self] in
                let state = await fetcher.title(for: target)
                self?.applyPageTitle(state, for: target)
            }
        }
    }

    private func applyPageTitle(_ state: PageTitleState, for target: PageTitleTarget) {
        pageTitleTasks[target] = nil
        // What the request set off in the server may go on for a moment after the answer: not the user's activity either.
        probeQuietUntil[target.server] = services.now().addingTimeInterval(Self.probeAfterglow)
        // The setting was switched off, or the server went away, while the request ran.
        guard settings.fetchPageTitles,
              serverScan.servers.contains(where: { PageTitleTarget.make(for: $0, in: serverScan) == target }) else { return }
        pageTitles[target] = state
    }

    // MARK: Servers

    public func stop(_ server: DevServer) async {
        let key = "server:\(server.root.pid)"
        guard !busyKeys.contains(key) else { return }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        do {
            let report = try await services.terminator.terminate(server, policy: TerminationPolicy())
            if !report.survivors.isEmpty {
                lastError = Self.makeError("Süreç kapanmadı", "Süreç kapanmadı: PID \(Self.pidList(report.survivors))")
            } else if let denied = report.skipped.first(where: { $0.reason == "eperm" }) {
                lastError = Self.makeError("Süreç durdurulamadı", "PID \(denied.pid) için izin verilmedi.")
            }
        } catch {
            lastError = Self.userError(error, title: "Sunucu durdurulamadı")
        }
        await processTick()
        poke(.processes)
    }

    /// Plans only: the server keeps running until the user confirms in the sheet.
    public func beginStopAndClean(_ server: DevServer) async {
        if case .executing? = cleanup { return }   // never replace a flow that is deleting or stopping
        guard let project = server.project else {
            lastError = Self.makeError("Temizlik yapılamadı", "Proje bulunamadı.")
            return
        }
        let root = project.root
        cleanup = .planning(forServer: server.id, projectRoot: root)
        let plan = await services.cleaner.makePlan(forProjectAt: root, options: catalogOptions())
        guard case .planning(let planningServer, let planningRoot)? = cleanup,
              planningServer == server.id, planningRoot == root else { return }   // dismissed meanwhile
        guard let plan else {
            cleanup = .failed(Self.makeError("Temizlik yapılamadı", "Bu proje için temizlenecek önbellek yok"))
            return
        }
        let xcode = await xcodeIsRunning(for: plan)
        guard case .planning(let stillPlanningServer, let stillPlanningRoot)? = cleanup,
              stillPlanningServer == server.id, stillPlanningRoot == root else { return }   // dismissed meanwhile
        beginReview(plan: plan, stopFirst: server, xcodeRunning: xcode)
    }

    // MARK: Docker

    public func perform(_ action: ContainerAction, on container: DockerContainer) async {
        let key = "container:\(container.id)"
        guard !busyKeys.contains(key) else { return }
        busyKeys.insert(key)
        do {
            try await services.docker.perform(action, on: container.id)
        } catch {
            lastError = Self.userError(error, title: "Konteyner işlemi başarısız")
        }
        // The row is busy for the action only: the list read that follows queues behind any in-flight snapshot and, with a
        // hung daemon, would keep the spinner going for as long as that takes.
        busyKeys.remove(key)
        await dockerListTick()
        poke(.dockerList)
    }

    public func perform(_ action: ComposeAction, on project: ComposeProject) async {
        let key = "compose:\(project.name)"
        guard !busyKeys.contains(key) else { return }
        busyKeys.insert(key)
        do {
            try await services.docker.perform(action, projectName: project.name)
        } catch {
            lastError = Self.userError(error, title: "Compose işlemi başarısız")
        }
        busyKeys.remove(key)
        await dockerListTick()
        poke(.dockerList)
    }

    /// Stops the running idle containers among `ids`: the ids listed on the confirmation card when it was armed. A container
    /// that became idle after that, one that is no longer idle and one already being acted on are left alone.
    /// Returns how many were stopped.
    public func stopIdleContainers(ids: Set<String>) async -> Int {
        let targets = idleContainers.filter { ids.contains($0.id) && !busyKeys.contains("container:\($0.id)") }
        guard !targets.isEmpty else { return 0 }
        for container in targets { busyKeys.insert("container:\(container.id)") }
        var stopped = 0
        var failures: [String] = []
        for container in targets {
            do {
                try await services.docker.perform(.stop, on: container.id)
                stopped += 1
            } catch {
                failures.append("\(DisplayText.label(container.name, limit: 80)): \(Self.message(for: error))")
            }
            busyKeys.remove("container:\(container.id)")
        }
        if !failures.isEmpty {
            lastError = Self.makeError("Bazı konteynerler durdurulamadı", failures.joined(separator: "\n"))
        }
        await dockerListTick()
        poke(.dockerList)
        return stopped
    }

    /// Measures the build cache. Single-flight; a failure is kept in `buildCacheFailure` (never a silent "measuring").
    public func refreshBuildCache() async {
        await measureBuildCache(supersedingInFlight: false)
    }

    /// `supersedingInFlight`: the caller changed what is measured (a prune), so a measurement already running reads the old
    /// figure; it measures once more when it finishes instead of the caller's request being swallowed.
    private func measureBuildCache(supersedingInFlight: Bool) async {
        guard dockerReachable else {
            buildCache = nil
            buildCacheFailure = nil
            return
        }
        guard !isMeasuringBuildCache else {
            if supersedingInFlight { remeasureBuildCache = true }
            return
        }
        isMeasuringBuildCache = true
        defer {
            isMeasuringBuildCache = false
            remeasureBuildCache = false
        }
        repeat {
            remeasureBuildCache = false
            do {
                buildCache = try await services.docker.buildCacheSummary()
                buildCacheFailure = nil
                lastBuildCacheFailureAt = nil
            } catch is CancellationError {
                return
            } catch {
                let message = Self.message(for: error)
                logger.error("build cache summary failed: \(message, privacy: .public)")
                buildCacheFailure = message
                lastBuildCacheFailureAt = services.now()
            }
        } while remeasureBuildCache
    }

    private func refreshBuildCacheIfStale() async {
        let now = services.now()
        if let measured = buildCache?.measuredAt, now.timeIntervalSince(measured) < PollingPolicy.buildCacheRefresh { return }
        // A failed measurement is retried by the user (or after the window), not on every housekeeping tick.
        if let failedAt = lastBuildCacheFailureAt, now.timeIntervalSince(failedAt) < PollingPolicy.buildCacheRefresh { return }
        await refreshBuildCache()
    }

    public func pruneBuildCache(_ mode: BuildCachePruneMode) async {
        let key = "prune"
        guard !busyKeys.contains(key) else { return }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        do {
            lastBuildCachePrune = try await services.docker.pruneBuildCache(mode)
        } catch {
            lastError = Self.userError(error, title: "Build önbelleği temizlenemedi")
        }
        await measureBuildCache(supersedingInFlight: true)
    }

    private var dockerReachable: Bool {
        switch dockerSnapshot.status {
        case .notRunning, .notInstalled, .unsupported: false
        default: true
        }
    }

    // MARK: Builds

    private func catalogOptions() -> CatalogOptions {
        var options = CatalogOptions()
        options.includeDependencies = settings.includeDependencies
        return options
    }

    private func buildsOptions() -> BuildsScanOptions {
        var options = BuildsScanOptions(roots: settingsStore.effectiveScanRoots(for: settings))
        options.maxDepth = settings.buildsMaxDepth
        options.catalog = catalogOptions()
        return options
    }

    /// Roots the builds scan will walk (for the Builds tab header).
    public var effectiveScanRoots: [String] { settingsStore.effectiveScanRoots(for: settings) }

    /// A newer scan cancels the older one (and its queued size measurements). Returns when the scan, including
    /// lazy sizing, has finished or was superseded.
    public func scanBuilds() async {
        buildsGeneration += 1
        let generation = buildsGeneration
        buildsTask?.cancel()
        sizingQueue?.cancelAll()
        let task = Task { await self.runBuildsScan(generation: generation) }
        buildsTask = task
        await task.value
        if buildsGeneration == generation { buildsTask = nil }
    }

    /// Settings that change what a scan sees were edited: whatever is running (or shown) belongs to the old settings. Cancel
    /// it, drop its rows and let `tabActivated()` start a fresh scan when the Builds tab is visible.
    private func supersedeBuildsScan() {
        buildsGeneration += 1
        buildsTask?.cancel()
        buildsTask = nil
        sizingQueue?.cancelAll()
        buildsScan = .idle
        buildReports = []
        orphanedDerivedData = []
    }

    private func runBuildsScan(generation: Int) async {
        guard !Task.isCancelled, generation == buildsGeneration else { return }   // superseded before it started
        let options = buildsOptions()
        let queue = SizingQueue(limit: 4)
        sizingQueue = queue
        buildReports = []
        orphanedDerivedData = []
        buildsScan = .scanning(directories: 0)

        var summary: BuildsScanSummary?
        for await event in services.catalog.scan(options) {
            if Task.isCancelled || generation != buildsGeneration { break }
            switch event {
            case .progress(let directories):
                buildsScan = .scanning(directories: directories)
            case .report(let report):
                buildReports.append(report)
                enqueueSizing(for: report, queue: queue, generation: generation)
            case .finished(let result):
                summary = result
            }
        }
        guard !Task.isCancelled, generation == buildsGeneration else { return }

        if let summary {
            buildsScan = .finished(summary)
            lastBuildsScanAt = services.now()
        } else {
            buildsScan = .failed("Tarama tamamlanamadı")
        }
        if options.catalog.includeDerivedData {
            await loadOrphanedDerivedData(queue: queue, generation: generation)
        }
        await queue.waitUntilIdle()
        guard !Task.isCancelled, generation == buildsGeneration else { return }
        sortBuildReports()
    }

    private func enqueueSizing(for report: ProjectCacheReport, queue: SizingQueue, generation: Int) {
        for entry in report.entries where entry.sizeBytes == nil {
            if entry.safety == .optIn && !settings.includeDependencies { continue }
            queue.enqueue { [weak self] in
                guard let self else { return }
                let size = await self.services.catalog.size(of: entry)
                guard !Task.isCancelled, generation == self.buildsGeneration else { return }
                self.applySize(size, toEntry: entry.id, inReport: report.id)
            }
        }
    }

    private func applySize(_ size: SizeResult, toEntry entryID: String, inReport reportID: String) {
        guard let index = buildReports.firstIndex(where: { $0.id == reportID }) else { return }
        let report = buildReports[index]
        // Same rule as the planner (D14): an entry that measures 0 B is not offered, and a project left without entries is
        // not a row ("Temizle…" would only fail with "temizlenecek önbellek yok").
        let entries = report.entries.compactMap { entry -> CacheEntry? in
            guard entry.id == entryID else { return entry }
            return size.bytes == 0 && !size.isPartial ? nil : entry.withSize(size)
        }
        if entries.isEmpty {
            buildReports.remove(at: index)
        } else {
            buildReports[index] = ProjectCacheReport(project: report.project, entries: entries, scannedAt: report.scannedAt)
        }
    }

    private func loadOrphanedDerivedData(queue: SizingQueue, generation: Int) async {
        let orphans = await services.catalog.orphanedDerivedData()
        guard !Task.isCancelled, generation == buildsGeneration else { return }
        orphanedDerivedData = orphans
        for entry in orphans where entry.sizeBytes == nil {
            queue.enqueue { [weak self] in
                guard let self else { return }
                let size = await self.services.catalog.size(of: entry)
                guard !Task.isCancelled, generation == self.buildsGeneration else { return }
                self.orphanedDerivedData = self.orphanedDerivedData.compactMap { orphan in
                    guard orphan.id == entry.id else { return orphan }
                    return size.bytes == 0 && !size.isPartial ? nil : orphan.withSize(size)
                }
            }
        }
    }

    /// Whether a project (by report) overlaps something that is running right now (servers, compose working dirs).
    public func isRunning(_ report: ProjectCacheReport) -> Bool {
        runningProjectRoots.contains { PathRelation.overlaps($0, report.project.root) }
    }

    private func sortBuildReports() {
        let keyed = buildReports.map { (report: $0, running: isRunning($0)) }
        buildReports = keyed.sorted { a, b in
            if a.running != b.running { return !a.running }
            if a.report.knownBytes != b.report.knownBytes { return a.report.knownBytes > b.report.knownBytes }
            return a.report.project.name.localizedStandardCompare(b.report.project.name) == .orderedAscending
        }.map { $0.report }
    }

    /// Re-evaluates one project after a cleanup and replaces / removes its row.
    private func rescanProject(root: String) async {
        let report = await services.catalog.report(forProjectAt: root, options: catalogOptions())
        buildReports.removeAll { $0.project.root == root || $0.project.root == report?.project.root }
        guard let report, !report.entries.isEmpty else { return }
        buildReports.append(report)
        let queue = SizingQueue(limit: 4)
        enqueueSizing(for: report, queue: queue, generation: buildsGeneration)
        await queue.waitUntilIdle()
        sortBuildReports()
    }

    // MARK: Cleanup flow

    /// Plans only; nothing is deleted until `confirmCleanup()`.
    public func beginClean(projectRoot: String) async {
        if case .executing? = cleanup { return }
        cleanup = .planning(forServer: nil, projectRoot: projectRoot)
        let plan = await services.cleaner.makePlan(forProjectAt: projectRoot, options: catalogOptions())
        guard case .planning(nil, let root)? = cleanup, root == projectRoot else { return }   // dismissed meanwhile
        guard let plan else {
            cleanup = .failed(Self.makeError("Temizlik yapılamadı", "Bu proje için temizlenecek önbellek yok"))
            return
        }
        let xcode = await xcodeIsRunning(for: plan)
        guard case .planning(nil, let stillRoot)? = cleanup, stillRoot == projectRoot else { return }   // dismissed meanwhile
        beginReview(plan: plan, stopFirst: nil, xcodeRunning: xcode)
    }

    /// Plans only; nothing is deleted until `confirmCleanup()`.
    public func beginCleanOrphanedDerivedData() async {
        if case .executing? = cleanup { return }
        let derivedDataRoot = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
        cleanup = .planning(forServer: nil, projectRoot: derivedDataRoot)
        let plan = await services.cleaner.makeOrphanedDerivedDataPlan()
        guard case .planning(nil, derivedDataRoot)? = cleanup else { return }   // dismissed meanwhile
        guard let plan else {
            cleanup = .failed(Self.makeError("Temizlik yapılamadı", "Sahipsiz DerivedData bulunamadı"))
            return
        }
        let xcode = await xcodeIsRunning(for: plan)
        guard case .planning(nil, derivedDataRoot)? = cleanup else { return }   // dismissed meanwhile
        beginReview(plan: plan, stopFirst: nil, xcodeRunning: xcode)
    }

    private func beginReview(plan: CleanupPlan, stopFirst: DevServer?, xcodeRunning xcode: Bool) {
        acknowledgedDependencies = false
        cleanupProgress = []
        xcodeRunning = xcode
        let selections = CleanupRules.defaultSelections(for: plan, deleteConditionalPermanently: settings.deleteConditionalPermanently)
        cleanup = .review(plan: plan, selections: selections, stopFirst: stopFirst)
    }

    /// Xcode running is a notice, never a blocker. Only looked up for plans that contain DerivedData folders.
    private func xcodeIsRunning(for plan: CleanupPlan) async -> Bool {
        guard plan.entries.contains(where: { $0.instance != nil }) else { return false }
        let snapshot = await services.scanner.snapshot(.standard)
        return snapshot.nodes.values.contains { node in
            node.name == "Xcode" || node.executablePath?.hasSuffix("/Xcode.app/Contents/MacOS/Xcode") == true
        }
    }

    public func setSelected(_ entryID: String, _ on: Bool) {
        guard case .review(let plan, var selections, let stopFirst)? = cleanup,
              let entry = plan.entries.first(where: { $0.id == entryID }) else { return }
        if on {
            let mode = CleanupRules.defaultMode(for: entry, deleteConditionalPermanently: settings.deleteConditionalPermanently)
            selections[entryID] = CleanupSelection(entryID: entryID, mode: mode)
        } else {
            selections[entryID] = nil
        }
        cleanup = .review(plan: plan, selections: selections, stopFirst: stopFirst)
    }

    public func setMode(_ entryID: String, _ mode: DeleteMode) {
        guard case .review(let plan, var selections, let stopFirst)? = cleanup, selections[entryID] != nil else { return }
        selections[entryID] = CleanupSelection(entryID: entryID, mode: mode)
        cleanup = .review(plan: plan, selections: selections, stopFirst: stopFirst)
    }

    /// Class B follows `settings.deleteConditionalPermanently` for the rows that are currently selected.
    private func remapConditionalModes() {
        guard case .review(let plan, var selections, let stopFirst)? = cleanup else { return }
        for entry in plan.entries where entry.safety == .conditional && selections[entry.id] != nil {
            let mode = CleanupRules.defaultMode(for: entry, deleteConditionalPermanently: settings.deleteConditionalPermanently)
            selections[entry.id] = CleanupSelection(entryID: entry.id, mode: mode)
        }
        cleanup = .review(plan: plan, selections: selections, stopFirst: stopFirst)
    }

    /// The ONLY entry point that deletes or kills. Does nothing unless the sheet is in `.review` with at least one
    /// selected entry, no unresolved blocker, and (for class C) the "Anladım" acknowledgement.
    public func confirmCleanup() async {
        guard case .review(let plan, let selections, let stopFirst)? = cleanup else { return }
        let ordered = CleanupRules.orderedSelections(plan: plan, selections: selections,
                                                     acknowledgedDependencies: acknowledgedDependencies)
        guard !ordered.isEmpty else { return }
        let selectedEntries = plan.entries.filter { selections[$0.id] != nil }
        if selectedEntries.contains(where: { $0.safety == .optIn }) && !acknowledgedDependencies { return }
        let unresolved = CleanupRules.unresolvedBlockers(plan: plan, selections: selections, stopFirst: stopFirst)
        guard unresolved.isEmpty else {
            lastError = Self.makeError("Temizlik yapılamadı",
                                       Self.blockedMessage(unresolved, runningPrefix: "Şunlar çalıştığı için temizlenemez: "))
            return
        }
        if let server = stopFirst {
            await runStopAndClean(plan: plan, selections: selections, server: server,
                                  acknowledgedDependencies: acknowledgedDependencies)
        } else {
            await runClean(plan: plan, ordered: ordered)
        }
    }

    public func dismissCleanup() {
        if case .executing? = cleanup { return }   // a stop or delete is in flight
        cleanup = nil
        cleanupProgress = []
        acknowledgedDependencies = false
        xcodeRunning = false
    }

    private func progressHandler() -> @Sendable (CleanupOutcome) -> Void {
        { [weak self] outcome in
            Task { @MainActor in self?.cleanupProgress.append(outcome) }
        }
    }

    private func runClean(plan: CleanupPlan, ordered: [CleanupSelection]) async {
        cleanup = .executing(planID: plan.id, stoppingServer: false)
        cleanupProgress = []
        let result: CleanupResult
        do {
            result = try await services.cleaner.execute(plan, selections: ordered, progress: progressHandler())
        } catch {
            cleanup = .failed(Self.userError(error, title: "Temizlik yapılamadı"))   // e.g. an expired plan: nothing was touched
            return
        }
        cleanup = .finished(result, terminated: nil)
        await afterCleanup(plan)
    }

    /// R16: stop → require no survivors → fresh re-plan (new blockers, only the user's selected ids) → abort on any
    /// blocker that still blocks a selected entry → execute.
    private func runStopAndClean(plan: CleanupPlan, selections: [String: CleanupSelection], server: DevServer,
                                 acknowledgedDependencies acknowledged: Bool) async {
        cleanup = .executing(planID: plan.id, stoppingServer: true)
        cleanupProgress = []
        let busyKey = "server:\(server.root.pid)"
        busyKeys.insert(busyKey)
        defer { busyKeys.remove(busyKey) }

        let report: TerminationReport
        do {
            report = try await services.terminator.terminate(server, policy: TerminationPolicy())
        } catch {
            cleanup = .failed(Self.userError(error, title: "Sunucu durdurulamadı"))
            await processTick()
            return
        }
        guard report.survivors.isEmpty else {
            cleanup = .failed(Self.makeError("Süreç kapanmadı",
                                             "Süreç kapanmadı, temizlik yapılmadı. PID: \(Self.pidList(report.survivors))"))
            await processTick()
            return
        }
        await processTick()

        guard let root = server.project?.root,
              let fresh = await services.cleaner.makePlan(forProjectAt: root, options: catalogOptions()) else {
            cleanup = .failed(Self.makeError("Temizlik yapılamadı",
                                             "Sunucu durduruldu; bu proje için temizlenecek önbellek kalmadı."))
            return
        }
        // Only what the user reviewed: a path that showed up after the review (a new `__pycache__`) is not deleted unseen.
        let reviewed = Dictionary(plan.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = fresh.entries.compactMap { entry -> CacheEntry? in
            guard selections[entry.id] != nil, let before = reviewed[entry.id] else { return nil }
            return Self.narrowed(entry, toReviewed: before)
        }
        var freshPlan = CleanupPlan(id: fresh.id, rootPath: fresh.rootPath, project: fresh.project,
                                    entries: entries, blockers: fresh.blockers, createdAt: fresh.createdAt)
        freshPlan.includesDependencies = fresh.includesDependencies
        let freshSelections = selections.filter { key, _ in entries.contains { $0.id == key } }

        let remaining = fresh.blockers.filter { blocker in entries.contains { blocker.blocks($0.safety) } }
        guard remaining.isEmpty else {
            cleanup = .failed(Self.makeError("Temizlik iptal edildi",
                                             "Sunucu durduruldu ama temizlik yapılmadı. "
                                             + Self.blockedMessage(remaining, runningPrefix: "Hâlâ çalışıyor: ")))
            return
        }
        let ordered = CleanupRules.orderedSelections(plan: freshPlan, selections: freshSelections,
                                                     acknowledgedDependencies: acknowledged)
        guard !ordered.isEmpty else {
            cleanup = .finished(CleanupResult(planID: fresh.id, outcomes: [], finishedAt: services.now()), terminated: report)
            await afterCleanup(plan)
            return
        }
        let result: CleanupResult
        do {
            result = try await services.cleaner.execute(freshPlan, selections: ordered, progress: progressHandler())
        } catch {
            let detail = Self.message(for: error)
            cleanup = .failed(Self.makeError("Temizlik yapılamadı", "Sunucu durduruldu ama temizlik yapılmadı. " + detail))
            return
        }
        cleanup = .finished(result, terminated: report)
        await afterCleanup(plan)
    }

    private func afterCleanup(_ plan: CleanupPlan) async {
        await refreshNow()
        if let root = plan.project?.root {
            await rescanProject(root: root)
        } else {
            let queue = SizingQueue(limit: 4)
            await loadOrphanedDerivedData(queue: queue, generation: buildsGeneration)
            await queue.waitUntilIdle()
        }
    }

    // MARK: Error text

    nonisolated static func makeError(_ title: String, _ message: String) -> UserFacingError {
        UserFacingError(id: UUID(), title: title, message: shorten(message))
    }

    nonisolated static func userError(_ error: any Error, title: String) -> UserFacingError {
        makeError(title, message(for: error))
    }

    nonisolated static func pidList(_ pids: [Int32]) -> String {
        pids.map { String($0) }.joined(separator: ", ")
    }

    /// "Şunlar çalıştığı için temizlenemez: a, b" for what runs; the Docker-unverified notice is not a running thing and gets its
    /// own sentence.
    nonisolated static func blockedMessage(_ blockers: [ActivityBlocker], runningPrefix: String) -> String {
        var sentences: [String] = []
        let running = blockers.filter { !$0.isDockerUnverified }
        if !running.isEmpty { sentences.append(runningPrefix + running.map(\.label).joined(separator: ", ")) }
        if blockers.contains(where: \.isDockerUnverified) {
            sentences.append("Docker durumu doğrulanamadı; Docker yanıt verince yeniden deneyin.")
        }
        return sentences.joined(separator: " ")
    }

    /// `fresh` restricted to the paths `reviewed` listed; nil when none of them is left. Entries are matched by id first, so the
    /// paths of one rule are the only thing that can differ.
    nonisolated static func narrowed(_ fresh: CacheEntry, toReviewed reviewed: CacheEntry) -> CacheEntry? {
        let allowed = Set(reviewed.displayPath.components(separatedBy: CacheEntry.displaySeparator))
        let paths = fresh.displayPath.components(separatedBy: CacheEntry.displaySeparator)
        let kept = paths.filter { allowed.contains($0) }
        guard !kept.isEmpty else { return nil }
        return kept.count == paths.count ? fresh : fresh.withDisplayPath(kept.joined(separator: CacheEntry.displaySeparator))
    }

    /// stderr / HTTP bodies are cut to 300 scalars before they reach the UI (scalars, not characters: one character can hold
    /// any number of scalars).
    nonisolated static func shorten(_ text: String, limit: Int = 300) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
    }

    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case let e as ProcessTerminationError:
            switch e {
            case .refused(let tag): return "Güvenlik kuralı nedeniyle reddedildi (\(tag))."
            }
        case let e as DockerError:
            return DockerClient.describe(e)
        case let e as CleanupError:
            switch e {
            case .rootRejected(let detail): return "Klasör reddedildi: \(detail)"
            case .planStale: return "Plan eskidi, yeniden planlayın."
            }
        case let e as CommandError:
            switch e {
            case .launchFailed(let detail): return "Komut başlatılamadı: \(detail)"
            }
        default:
            return String(describing: error)
        }
    }
}

/// What `DevTidyStore.pageTitleStatus(for:)` can say.
public enum PageTitleStatus: Equatable, Sendable {
    /// The "Sayfa başlığını oku" setting is off.
    case disabled
    /// The server has no port that may be asked (inspector only, bound to one non-loopback address, no port).
    case notApplicable
    /// Every loopback address that reaches the server's socket is taken by another process on the same port (a Docker container
    /// published on the port too): the answer would not be the server's, so DevTidy does not ask.
    case portShared
    /// Not asked yet (popover on another tab) or the request is running.
    case pending
    case title(String)
    /// The server answered but the page has no usable title.
    case noTitle
    /// The server did not answer.
    case failed
    /// The server is flagged idle: DevTidy does not wake it with a request, and asks once it is active again.
    case skippedIdle
}

/// Identities are read off the main actor: a handful of bounded file reads per project root.
private enum IdentityResolution {
    @concurrent
    static func resolve(_ roots: Set<String>, with resolver: any ProjectIdentifying) async -> [String: ProjectIdentity] {
        var identities: [String: ProjectIdentity] = [:]
        for root in roots { identities[root] = resolver.identity(ofProjectAt: root) }
        return identities
    }
}
