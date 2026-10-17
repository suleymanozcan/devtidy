import Foundation

// MARK: - Errors ---------------------------------------------------------------

public enum ProcessTerminationError: Error, Sendable, Equatable {
    case refused(String)             // safety rule tripped before any signal (tag, e.g. "root-is-self-ancestor")
}

public enum DockerError: Error, Sendable, Equatable {
    case notInstalled
    case daemonUnavailable(String)
    case http(status: Int, body: String)
    case decoding(String)
    case timeout
    case commandFailed(exitCode: Int32, stderr: String)
    case invalidArgument(String)
}

public enum CleanupError: Error, Sendable, Equatable {
    case rootRejected(String)
    case planStale
}

// MARK: - Audit ----------------------------------------------------------------

public struct AuditEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case cleanup, terminate, dockerContainer, dockerCompose, dockerPrune }
    public let time: Date
    public let kind: Kind
    public let subject: String            // absolute path / "pid:startSec" / container id / project name
    public let result: String             // "deleted" | "trashed" | "skipped:<reason>" | "failed:<errno text>" | "ok" | …
    public let detail: [String: String]   // rule id, class, mode, bytes, git facts, signals…
    public init(time: Date, kind: Kind, subject: String, result: String, detail: [String: String]) {
        self.time = time; self.kind = kind; self.subject = subject; self.result = result; self.detail = detail
    }
}

public protocol AuditLogging: Sendable {
    /// Appends one JSON line to ~/Library/Logs/DevTidy/cleanup.log. Never throws. A cleanup MUST NOT start if `isWritable()` is false (D12).
    func record(_ event: AuditEvent) async
    /// Appends one line and reports whether it reached the file; the cleaner stops when this is false (D12 / F-5).
    func recordDurably(_ event: AuditEvent) async -> Bool
    func isWritable() async -> Bool
}

public extension AuditLogging {
    /// Fakes and loggers without a failure signal: fire-and-forget `record`, always "durable".
    func recordDurably(_ event: AuditEvent) async -> Bool {
        await record(event)
        return true
    }
}

// MARK: - Tools ----------------------------------------------------------------

public protocol ToolLocating: Sendable {
    /// Absolute path of the docker CLI, discovered without shell PATH: ~/.docker/bin/docker, /usr/local/bin/docker,
    /// /opt/homebrew/bin/docker, /Applications/Docker.app/Contents/Resources/bin/docker. nil = not found.
    func dockerExecutable() -> URL?
    func gitExecutable() -> URL?                       // /usr/bin/git
    /// Resolved Engine socket path (override → DOCKER_HOST → context → ~/.docker/run/docker.sock → /var/run/docker.sock → colima/orbstack).
    /// nil = no usable socket: none exists, or a configured one (override / `$DOCKER_HOST`) is missing or remote. The search
    /// never falls through to another daemon.
    func dockerSocketPath(override: String?) -> String?
    func isDockerDesktopInstalled() -> Bool            // /Applications/Docker.app exists
    /// Minimal environment for children: HOME, USER, PATH=/usr/bin:/bin:/usr/sbin:/sbin:~/.docker/bin (the user-writable
    /// directory last), LC_ALL=C. (Git hardening variables are added by the git caller, not here.)
    func childEnvironment() -> [String: String]
}

// MARK: - Processes (S1) -----------------------------------------------------------

public protocol ProcessScanning: Sendable {
    /// Never throws; unreadable processes are omitted. Stateful (keeps previous cpu ticks per ProcessIdentity).
    func snapshot(_ detail: ScanDetail) async -> ProcessSnapshot
}

public protocol ServerClassifying: Sendable {
    /// Pure function of the snapshot (+ filesystem walk-up via ProjectDetecting). Must not mutate or signal anything.
    func classify(_ snapshot: ProcessSnapshot) async -> ServerScan
}

public protocol ProcessTerminating: Sendable {
    /// Stops the whole tree of `server` (K1–K11). Idempotent: an already-gone server returns `wasAlreadyGone == true`.
    func terminate(_ server: DevServer, policy: TerminationPolicy) async throws -> TerminationReport
}

// MARK: - Projects & caches (S2) -----------------------------------------------------------

public protocol ProjectDetecting: Sendable {
    /// Server association (ENV §3 rule 4): nearest marker dir walking up from `path`, stopping BEFORE $HOME.
    /// Synchronous. A cold lookup lists up to 12 directories and parses manifests; answers are cached per path (≈ 30 s), so a
    /// process tick that sees the same servers again is cheap. Callers are already off the main actor.
    func project(containing path: String) -> Project?
    /// Cleanup gate (CAT §2, R1/R2): nil = refuse any cache offer for this path.
    func projectContext(for path: String) async -> ProjectContext?
}

public protocol ProjectIdentifying: Sendable {
    /// Who a project is: folder, repo, branch, workspace root and manifest name (see `ProjectIdentity`). Synchronous and cheap:
    /// a handful of bounded (≤ 256 KB) regular-file reads and `lstat`s, never a spawned process. Answers are cached per root
    /// (≈ 30 s). Callers are already off the main actor.
    func identity(ofProjectAt root: String) -> ProjectIdentity
}

public protocol PageTitleFetching: Sendable {
    /// The page `<title>` of a server, fetched with ONE `GET /` to its own loopback address the first time it is asked for
    /// (a failure is retried once, after `PageTitleFetcher.retryDelay`); later calls return the cached state without any I/O.
    /// Never throws.
    func title(for target: PageTitleTarget) async -> PageTitleState
}

public protocol CacheCataloging: Sendable {
    /// Evaluates the catalog for one project (full git gating, NO running-process check, entries unsized).
    func report(forProjectAt path: String, options: CatalogOptions) async -> ProjectCacheReport?
    /// Walks roots (bounded; terminating the stream cancels the walk); emits unsized reports.
    func scan(_ options: BuildsScanOptions) -> AsyncStream<BuildsScanEvent>
    /// Lazy, cached sizing (key: path + dir mtime, TTL 10 min). Honors Task cancellation.
    func size(of entry: CacheEntry) async -> SizeResult
    /// DerivedData folders whose WorkspacePath no longer exists (CAT §5.1 step 4). Unsized.
    func orphanedDerivedData() async -> [CacheEntry]
}

public protocol ActivityChecking: Sendable {
    /// R15/R17: who is using `root` right now? Fresh scan every call (never cached). Empty = free.
    func blockers(for root: String) async -> [ActivityBlocker]
}

public protocol CacheCleaning: Sendable {
    /// Builds a sized plan + current blockers. nil when the root is rejected (R1/R2) or nothing is offered.
    func makePlan(forProjectAt path: String, options: CatalogOptions) async -> CleanupPlan?
    /// Plan for `catalog.orphanedDerivedData()` (sized, no project, rootPath = DerivedData root). nil when none.
    func makeOrphanedDerivedDataPlan() async -> CleanupPlan?
    /// Re-derives every target from (ruleID, packageDir, instance), re-runs ALL gates (R3–R12, R15), then deletes/trashes.
    /// Entries not in `selections` are skipped with `.notSelected`. Throws BEFORE touching anything:
    /// `CleanupError.planStale` (plan older than 30 min, project root no longer its own ceiling, or an orphan plan for another
    /// DerivedData location) and `CleanupError.rootRejected(plan.rootPath)` (a project plan's root is no longer an acceptable
    /// project root). Class C is refused inside the cleaner unless `plan.includesDependencies` AND the selection has
    /// `acknowledgedDependencies` (skipped as `.notInCatalog` / `.notSelected`). Otherwise never throws, each target has its own outcome.
    func execute(_ plan: CleanupPlan, selections: [CleanupSelection],
                 progress: (@Sendable (CleanupOutcome) -> Void)?) async throws -> CleanupResult
}

// MARK: - Docker (S3) -----------------------------------------------------------

public protocol DockerControlling: Sendable {
    /// Never throws. Daemon down ⇒ status .notRunning/.notInstalled with empty lists.
    /// `.reuse` returns the last sampled cpu/mem; `.refresh` samples one-shot stats for running containers (~50 ms each, 4-way).
    func snapshot(stats: StatsRefresh) async -> DockerSnapshot
    func perform(_ action: ContainerAction, on containerID: String) async throws
    func perform(_ action: ComposeAction, projectName: String) async throws
    func buildCacheSummary() async throws -> BuildCacheSummary
    func pruneBuildCache(_ mode: BuildCachePruneMode) async throws -> BuildCachePruneResult
}
