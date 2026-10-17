import Foundation
import Testing
@testable import DevTidyCore

// Fakes and builders for the Store slice. Everything is prefixed `S4`; nothing here touches the real machine:
// no processes are signalled, no Docker call is made, no file outside memory is read or written.

// MARK: - Plumbing -------------------------------------------------------------------

final class S4Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult
    func with<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    var snapshot: Value { with { $0 } }
}

/// Ordered record of the calls the fakes receive, shared between all fakes of one rig.
final class S4Log: @unchecked Sendable {
    private let items = S4Locked<[String]>([])
    func add(_ entry: String) { items.with { $0.append(entry) } }
    var events: [String] { items.snapshot }
    /// Only the events starting with one of `prefixes`, in order.
    func events(prefixed prefixes: String...) -> [String] {
        events.filter { e in prefixes.contains { e.hasPrefix($0) } }
    }
    func count(prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }
}

final class S4Clock: @unchecked Sendable {
    private let current: S4Locked<Date>
    init(_ start: Date = S4.t0) { current = S4Locked(start) }
    var now: Date { current.snapshot }
    func advance(_ seconds: TimeInterval) { current.with { $0 = $0.addingTimeInterval(seconds) } }
    func set(_ date: Date) { current.with { $0 = date } }
}

/// A latch a fake awaits until the test opens it: a "slow call" that stays slow for exactly as long as the test wants, with no
/// timer, so the interleavings under test cannot depend on how loaded the machine is.
final class S4Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

final class S4MemoryStorage: SettingsStorage, @unchecked Sendable {
    private let data = S4Locked<Data?>(nil)
    init(initial: Data? = nil) { data.with { $0 = initial } }
    func read() -> Data? { data.snapshot }
    func write(_ new: Data) { data.with { $0 = new } }
    var stored: Data? { data.snapshot }
}

/// Polls `condition` until it holds. `seconds` only bounds a HANG (a condition that can never come true fails after it instead of
/// blocking the suite); it is deliberately far above any real wait, so a loaded machine cannot turn a correct run into a failure.
@MainActor
func s4Eventually(seconds: Double = 30, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - Builders -------------------------------------------------------------------

enum S4 {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let home = "/tmp/s4home"
    static let mb: UInt64 = 1_048_576

    static func identity(_ pid: Int32, started: Date = t0.addingTimeInterval(-3_600)) -> ProcessIdentity {
        let t = started.timeIntervalSince1970
        return ProcessIdentity(pid: pid, startSeconds: Int64(t), startMicroseconds: 0)
    }

    static func node(_ pid: Int32, ppid: Int32 = 1, pgid: Int32? = nil, name: String = "node",
                     args: [String] = [], exe: String? = nil, cwd: String? = nil, cpu: Double? = nil, mem: UInt64 = 0,
                     uid: UInt32 = 501, started: Date = t0.addingTimeInterval(-3_600)) -> ProcessNode {
        ProcessNode(identity: identity(pid, started: started), parentPID: ppid, pgid: pgid ?? pid, uid: uid,
                    name: name, executablePath: exe, arguments: args, workingDirectory: cwd, hasControllingTTY: false,
                    memoryBytes: mem, cpuTimeNanoseconds: 0, cpuPercent: cpu)
    }

    static func snapshot(takenAt: Date = t0, selfPID: Int32 = 4242, nodes: [ProcessNode],
                         listeners: [Int32: [ListeningPort]] = [:]) -> ProcessSnapshot {
        ProcessSnapshot(takenAt: takenAt, selfPID: selfPID,
                        nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.pid, $0) }), listeners: listeners)
    }

    static func project(_ root: String, name: String? = nil, group: String? = nil) -> Project {
        Project(root: root, name: name ?? (root as NSString).lastPathComponent, groupName: group,
                kinds: [.node], repoRoot: root)
    }

    /// A bare identity (folder only) unless a repo / branch / manifest is given.
    static func identity(_ root: String, repoRoot: String? = nil, pathInRepo: String? = nil, head: GitHead? = nil,
                         manifest: ProjectManifest? = nil, workspace: String? = nil) -> ProjectIdentity {
        ProjectIdentity(path: root, folderName: (root as NSString).lastPathComponent, repoRoot: repoRoot,
                        repoName: repoRoot.map { ($0 as NSString).lastPathComponent }, pathInRepo: pathInRepo,
                        workspaceName: workspace, head: head, manifest: manifest)
    }

    static func port(_ port: UInt16, owner: Int32, scope: BindScope = .loopback, established: Int = 0) -> ListeningPort {
        ListeningPort(port: port, ownerPID: owner, scope: scope, establishedConnections: established)
    }

    static func server(pid: Int32, project: Project?, port: UInt16 = 3000, cpu: Double? = 0, connections: Int = 0,
                       mem: UInt64 = 100 * mb, started: Date = t0.addingTimeInterval(-3_600),
                       extraMembers: [ProcessNode] = [], extraPorts: [UInt16] = [], arguments: [String] = [],
                       scope: BindScope = .loopback) -> DevServer {
        let root = node(pid, name: "node", args: arguments, cwd: project?.root, cpu: cpu, mem: mem, started: started)
        return DevServer(root: root, members: [root] + extraMembers,
                         ports: ([port] + extraPorts).map {
                             S4.port($0, owner: pid, scope: $0 == port ? scope : .loopback, established: $0 == port ? connections : 0)
                         }, mainPort: port,
                         project: project, kind: .next, confidence: project == nil ? .low : .high,
                         command: "next dev -p \(port)", cpuPercent: cpu, memoryBytes: mem,
                         establishedConnections: connections,
                         hints: ServerHints(orphaned: false, noControllingTTY: true, lanExposed: false, noConnections: connections == 0),
                         groupKillEligible: true)
    }

    static func container(_ name: String, state: ContainerState = .running, cpu: Double? = 0, mem: UInt64? = 10 * mb,
                          started: Date? = t0.addingTimeInterval(-60), composeProject: String? = nil,
                          workingDir: String? = nil, mounts: [String] = []) -> DockerContainer {
        let hex = name.utf8.map { String(format: "%02x", $0) }.joined()
        let id = String((hex + String(repeating: "0", count: 64)).prefix(64))
        return DockerContainer(id: String(id), shortID: String(id.prefix(12)), name: name, image: "img:\(name)", state: state,
                               statusText: "Up", createdAt: t0.addingTimeInterval(-7_200), startedAt: state == .running ? started : nil,
                               composeProject: composeProject, composeService: composeProject == nil ? nil : name,
                               composeWorkingDir: workingDir, publishedPorts: [], bindMountSources: mounts, health: nil,
                               cpuPercent: state == .running ? cpu : nil, memoryBytes: state == .running ? mem : nil,
                               memoryLimitBytes: nil)
    }

    static func dockerSnapshot(takenAt: Date = t0, status: DockerStatus? = nil, standalone: [DockerContainer] = [],
                               projects: [ComposeProject] = [], statsAt: Date? = nil) -> DockerSnapshot {
        DockerSnapshot(status: status ?? .running(DockerEngineInfo(version: "1", apiVersion: "1")),
                       projects: projects, standalone: standalone, takenAt: takenAt, statsAt: statsAt)
    }

    static func entry(_ ruleID: String, packageDir: String, display: String = ".next", safety: CacheSafety = .always,
                      size: Int64? = 1_000_000, selected: Bool? = nil, mode: DeleteMode? = nil,
                      reinstall: String? = nil, instance: String? = nil) -> CacheEntry {
        CacheEntry(id: "\(ruleID)@\(packageDir)", ruleID: ruleID, packageDir: packageDir, instance: instance, displayPath: display,
                   title: "Test \(ruleID)", safety: safety, isContentsOnly: false,
                   defaultSelected: selected ?? (safety == .always),
                   defaultMode: mode ?? (safety == .conditional ? .trash : .permanent),
                   sizeBytes: size, sizeIsPartial: false, itemCount: nil,
                   qualifiedBecause: ["git tarafından yok sayılıyor"], notes: [], reinstallCommand: reinstall)
    }

    static func blocker(_ label: String, pid: Int32? = nil, kind: ActivityBlocker.Kind = .process,
                        severity: ActivityBlocker.Severity = .hard) -> ActivityBlocker {
        ActivityBlocker(kind: kind, severity: severity, label: label, pid: pid, containerID: nil)
    }

    static func plan(root: String, project: Project? = nil, entries: [CacheEntry], blockers: [ActivityBlocker] = [],
                     id: UUID = UUID()) -> CleanupPlan {
        CleanupPlan(id: id, rootPath: root, project: project, entries: entries, blockers: blockers, createdAt: t0)
    }

    static func report(_ project: Project, entries: [CacheEntry]) -> ProjectCacheReport {
        ProjectCacheReport(project: project, entries: entries, scannedAt: t0)
    }

    /// `.report` for every report, then `.finished` — what a healthy `CacheCataloging.scan` emits.
    static func scanScript(_ reports: [ProjectCacheReport], visited: Int = 10) -> [BuildsScanEvent] {
        let events: [BuildsScanEvent] = reports.map { BuildsScanEvent.report($0) }
        let summary = BuildsScanSummary(directoriesVisited: visited, reportCount: reports.count, truncated: false,
                                        permissionDeniedRoots: [], seconds: 0.1)
        return events + [BuildsScanEvent.finished(summary)]
    }

    static func termination(for server: DevServer, survivors: [Int32] = [], gone: Bool = false) -> TerminationReport {
        TerminationReport(root: server.root.identity, terminated: survivors.isEmpty ? server.members.map(\.pid) : [],
                          forced: [], survivors: survivors, skipped: [], usedGroupSignal: true, wasAlreadyGone: gone)
    }
}

// MARK: - Service fakes ---------------------------------------------------------------

final class S4Scanner: ProcessScanning, @unchecked Sendable {
    struct State { var nodes: [ProcessNode] = []; var listeners: [Int32: [ListeningPort]] = [:]; var selfPID: Int32 = 4242 }
    let state = S4Locked(State())
    let log: S4Log
    let clock: S4Clock
    init(log: S4Log, clock: S4Clock) { self.log = log; self.clock = clock }

    func snapshot(_ detail: ScanDetail) async -> ProcessSnapshot {
        log.add("scan:\(detail)")
        let s = state.snapshot
        return S4.snapshot(takenAt: clock.now, selfPID: s.selfPID, nodes: s.nodes, listeners: s.listeners)
    }
}

final class S4Classifier: ServerClassifying, @unchecked Sendable {
    struct State {
        var servers: [DevServer] = []
        var others: [OtherListener] = []
        var gates: [S4Gate] = []                        // consumed one per classify() call (FIFO); empty ⇒ the call is not held
    }
    let state = S4Locked(State())
    let log: S4Log
    let clock: S4Clock
    init(log: S4Log, clock: S4Clock) { self.log = log; self.clock = clock }

    func classify(_ snapshot: ProcessSnapshot) async -> ServerScan {
        // The answer is decided when the call starts; a held call returns it late.
        let (s, gate): (State, S4Gate?) = state.with { st in (st, st.gates.isEmpty ? nil : st.gates.removeFirst()) }
        log.add("classify")
        await gate?.wait()
        return ServerScan(takenAt: snapshot.takenAt, servers: s.servers, others: s.others)
    }
}

final class S4Terminator: ProcessTerminating, @unchecked Sendable {
    struct State {
        var survivors: [Int32] = []
        var error: ProcessTerminationError?
        var gate: S4Gate?                               // terminate() waits here until the test opens it
    }
    let state = S4Locked(State())
    let log: S4Log
    init(log: S4Log) { self.log = log }

    func terminate(_ server: DevServer, policy: TerminationPolicy) async throws -> TerminationReport {
        log.add("terminate:\(server.root.pid)")
        let s = state.snapshot
        await s.gate?.wait()
        if let error = s.error { throw error }
        return S4.termination(for: server, survivors: s.survivors)
    }
}

final class S4Catalog: CacheCataloging, @unchecked Sendable {
    struct State {
        var scripts: [[BuildsScanEvent]] = []           // one script per scan() call; the last one repeats
        var hangingScanCalls: Set<Int> = []              // 0-based call numbers whose stream never finishes
        var scanOptions: [BuildsScanOptions] = []
        var reportOptions: [CatalogOptions] = []
        var reportsByRoot: [String: ProjectCacheReport] = [:]
        var sizes: [String: SizeResult] = [:]            // by entry id
        var orphans: [CacheEntry] = []
        var terminatedCalls: Set<Int> = []              // scan() call numbers whose stream was terminated/finished
        var sizeGate: S4Gate?                            // every size() call waits here until the test opens it
        var current = 0
        var maxConcurrent = 0
        var sizeCalls = 0
    }
    let state = S4Locked(State())
    let log: S4Log
    init(log: S4Log) { self.log = log }

    func report(forProjectAt path: String, options: CatalogOptions) async -> ProjectCacheReport? {
        log.add("report:\(path)")
        return state.with { s in s.reportOptions.append(options); return s.reportsByRoot[path] }
    }

    func scan(_ options: BuildsScanOptions) -> AsyncStream<BuildsScanEvent> {
        let (call, script, hang): (Int, [BuildsScanEvent], Bool) = state.with { s in
            let call = s.scanOptions.count
            s.scanOptions.append(options)
            let script = s.scripts.isEmpty ? [] : s.scripts[min(call, s.scripts.count - 1)]
            return (call, script, s.hangingScanCalls.contains(call))
        }
        log.add("scan-builds:\(call)")
        let state = self.state
        return AsyncStream { continuation in
            continuation.onTermination = { _ in state.with { s in _ = s.terminatedCalls.insert(call) } }
            for event in script { continuation.yield(event) }
            if !hang { continuation.finish() }
        }
    }

    func size(of entry: CacheEntry) async -> SizeResult {
        let gate: S4Gate? = state.with { s in
            s.sizeCalls += 1
            s.current += 1
            s.maxConcurrent = max(s.maxConcurrent, s.current)
            return s.sizeGate
        }
        await gate?.wait()
        return state.with { s in
            s.current -= 1
            return s.sizes[entry.id] ?? SizeResult(bytes: entry.sizeBytes ?? 1_000, isPartial: false, itemCount: nil)
        }
    }

    func orphanedDerivedData() async -> [CacheEntry] {
        log.add("orphans")
        return state.snapshot.orphans
    }
}

final class S4Cleaner: CacheCleaning, @unchecked Sendable {
    struct State {
        var plans: [CleanupPlan?] = []                   // consumed per makePlan call; the last one repeats
        var orphanPlan: CleanupPlan?
        var planOptions: [CatalogOptions] = []
        var planCalls = 0
        var planGate: S4Gate?                            // makePlan() waits here until the test opens it
        var executed: [(plan: CleanupPlan, selections: [CleanupSelection])] = []
        var outcomeFor: (@Sendable (CacheEntry, CleanupSelection) -> CleanupStatus)?
        var executeError: CleanupError?                  // thrown by execute() before anything is touched
    }
    let state = S4Locked(State())
    let log: S4Log
    let clock: S4Clock
    init(log: S4Log, clock: S4Clock) { self.log = log; self.clock = clock }

    func makePlan(forProjectAt path: String, options: CatalogOptions) async -> CleanupPlan? {
        log.add("plan:\(path)")
        await state.snapshot.planGate?.wait()
        return state.with { s in
            s.planOptions.append(options)
            let index = min(s.planCalls, max(0, s.plans.count - 1))
            s.planCalls += 1
            return s.plans.isEmpty ? nil : s.plans[index]
        }
    }

    func makeOrphanedDerivedDataPlan() async -> CleanupPlan? {
        log.add("plan-orphans")
        return state.snapshot.orphanPlan
    }

    func execute(_ plan: CleanupPlan, selections: [CleanupSelection],
                 progress: (@Sendable (CleanupOutcome) -> Void)?) async throws -> CleanupResult {
        if let error = state.snapshot.executeError { throw error }
        log.add("execute:" + selections.map(\.entryID).joined(separator: ","))
        let producer = state.with { s -> (@Sendable (CacheEntry, CleanupSelection) -> CleanupStatus)? in
            s.executed.append((plan, selections)); return s.outcomeFor
        }
        var outcomes: [CleanupOutcome] = []
        for selection in selections {
            guard let entry = plan.entries.first(where: { $0.id == selection.entryID }) else { continue }
            let status = producer?(entry, selection)
                ?? (selection.mode == .trash ? .movedToTrash(bytes: entry.sizeBytes ?? 0) : .deleted(bytes: entry.sizeBytes ?? 0))
            let outcome = CleanupOutcome(entryID: entry.id, path: entry.packageDir + "/" + entry.displayPath, status: status)
            progress?(outcome)
            outcomes.append(outcome)
        }
        return CleanupResult(planID: plan.id, outcomes: outcomes, finishedAt: clock.now)
    }
}

final class S4Docker: DockerControlling, @unchecked Sendable {
    struct State {
        var snapshot = DockerSnapshot.unknown
        var actions: [String] = []
        var failure: DockerError?
        var buildCache: BuildCacheSummary?
        var pruneModes: [BuildCachePruneMode] = []
        var snapshotGates: [S4Gate] = []                // consumed one per snapshot() call (FIFO); empty ⇒ the call is not held
        var buildCacheGate: S4Gate?                     // the build-cache call waits here until the test opens it
    }
    let state = S4Locked(State())
    let log: S4Log
    let clock: S4Clock
    init(log: S4Log, clock: S4Clock) { self.log = log; self.clock = clock }

    func snapshot(stats: StatsRefresh) async -> DockerSnapshot {
        // Like the real client: the list is read when the call STARTS (`takenAt`), a slow call returns it late. The state is
        // captured before the call is logged, so a test that waits for the log entry can already change the state.
        let takenAt = clock.now
        let (s, gate): (DockerSnapshot, S4Gate?) = state.with { st in
            (st.snapshot, st.snapshotGates.isEmpty ? nil : st.snapshotGates.removeFirst())
        }
        log.add("docker-snapshot:\(stats)")
        await gate?.wait()
        return DockerSnapshot(status: s.status, projects: s.projects, standalone: s.standalone,
                              takenAt: takenAt, statsAt: s.statsAt)
    }

    func perform(_ action: ContainerAction, on containerID: String) async throws {
        log.add("docker-container:\(action):\(containerID.prefix(4))")
        try state.with { s in
            s.actions.append("\(action):\(containerID)")
            if let failure = s.failure { throw failure }
        }
    }

    func perform(_ action: ComposeAction, projectName: String) async throws {
        log.add("docker-compose:\(action):\(projectName)")
        try state.with { s in
            s.actions.append("compose-\(action):\(projectName)")
            if let failure = s.failure { throw failure }
        }
    }

    func buildCacheSummary() async throws -> BuildCacheSummary {
        // The figure is read when the call STARTS (like a real measurement); a held call returns it late.
        let (summary, gate) = state.with { ($0.buildCache, $0.buildCacheGate) }
        log.add("docker-buildcache")
        await gate?.wait()
        guard let summary else { throw DockerError.timeout }
        return summary
    }

    func pruneBuildCache(_ mode: BuildCachePruneMode) async throws -> BuildCachePruneResult {
        log.add("docker-prune")
        state.with { $0.pruneModes.append(mode) }
        return BuildCachePruneResult(reclaimedBytes: 5_000)
    }
}

struct S4Audit: AuditLogging {
    func record(_ event: AuditEvent) async {}
    func isWritable() async -> Bool { true }
}

/// Resolves identities from a table; a root without an entry gets a plain "folder only" identity. Records every lookup.
final class S4Identities: ProjectIdentifying, @unchecked Sendable {
    let table = S4Locked<[String: ProjectIdentity]>([:])
    let log: S4Log
    init(log: S4Log) { self.log = log }

    func identity(ofProjectAt root: String) -> ProjectIdentity {
        log.add("identity:\(root)")
        return table.snapshot[root] ?? S4.identity(root)
    }
}

/// Answers from a table (default: `.title("Page <port>")`). Records every call; a held call waits for its gate.
final class S4PageTitles: PageTitleFetching, @unchecked Sendable {
    struct State {
        var answers: [PageTitleTarget: PageTitleState] = [:]
        var fallback: (@Sendable (PageTitleTarget) -> PageTitleState) = { .title("Page \($0.port)") }
        var gates: [S4Gate] = []
        var targets: [PageTitleTarget] = []
    }
    let state = S4Locked(State())
    let log: S4Log
    init(log: S4Log) { self.log = log }

    func title(for target: PageTitleTarget) async -> PageTitleState {
        let (answer, gate): (PageTitleState, S4Gate?) = state.with { s in
            s.targets.append(target)
            return (s.answers[target] ?? s.fallback(target), s.gates.isEmpty ? nil : s.gates.removeFirst())
        }
        log.add("title:\(target.server.pid):\(target.port)")
        await gate?.wait()
        return answer
    }

    var calls: Int { state.snapshot.targets.count }
}

// MARK: - Rig ------------------------------------------------------------------------

/// A `DevTidyStore` wired to fakes with an injected clock and in-memory settings.
@MainActor
struct S4Rig {
    let log = S4Log()
    let clock = S4Clock()
    let storage: S4MemoryStorage
    let scanner: S4Scanner
    let classifier: S4Classifier
    let terminator: S4Terminator
    let catalog: S4Catalog
    let cleaner: S4Cleaner
    let docker: S4Docker
    let identities: S4Identities
    let pageTitles: S4PageTitles
    let store: DevTidyStore

    init(settings: DevTidySettings? = nil) {
        var initial: Data?
        if let settings { initial = try? JSONEncoder().encode(settings) }
        storage = S4MemoryStorage(initial: initial)
        scanner = S4Scanner(log: log, clock: clock)
        classifier = S4Classifier(log: log, clock: clock)
        terminator = S4Terminator(log: log)
        catalog = S4Catalog(log: log)
        cleaner = S4Cleaner(log: log, clock: clock)
        docker = S4Docker(log: log, clock: clock)
        identities = S4Identities(log: log)
        pageTitles = S4PageTitles(log: log)
        let clock = self.clock
        let services = DevTidyServices(scanner: scanner, classifier: classifier, terminator: terminator, catalog: catalog,
                                    cleaner: cleaner, docker: docker, identities: identities, pageTitles: pageTitles,
                                    audit: S4Audit(), now: { clock.now })
        store = DevTidyStore(services: services, settingsStore: SettingsStore(storage: storage, homeDirectory: S4.home))
    }
}
