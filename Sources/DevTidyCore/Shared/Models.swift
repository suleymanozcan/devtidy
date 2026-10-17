import Foundation

// MARK: - Processes ---------------------------------------------------------

/// pid + start time. The PID-reuse guard: two nodes are "the same process" only if the whole identity matches.
public struct ProcessIdentity: Hashable, Sendable, Codable {
    public let pid: Int32
    public let startSeconds: Int64        // proc_bsdinfo.pbi_start_tvsec
    public let startMicroseconds: Int64   // proc_bsdinfo.pbi_start_tvusec
    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int64) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
    public var startDate: Date {
        Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000)
    }
}

public struct ProcessNode: Identifiable, Hashable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let pgid: Int32
    public let uid: UInt32
    /// Kernel comm (`pbi_comm`, ≤ 16 chars) — NOT argv[0]; `next-server` keeps comm "node" (ENV G4).
    public let name: String
    /// proc_pidpath. nil = not fetched / not permitted.
    public let executablePath: String?
    /// argv from KERN_PROCARGS2. nil = not fetched; [] = fetched but empty/unreadable.
    public let arguments: [String]?
    /// PROC_PIDVNODEPATHINFO cdir. nil = not fetched.
    public let workingDirectory: String?
    public let hasControllingTTY: Bool
    /// ri_phys_footprint (Activity Monitor "Memory"); falls back to pti_resident_size if rusage fails.
    public let memoryBytes: UInt64
    /// Cumulative user+system CPU time in nanoseconds (mach ticks converted with mach_timebase_info).
    public let cpuTimeNanoseconds: UInt64
    /// Percent of ONE core over the interval since the previous snapshot of this identity; nil on first sight.
    public let cpuPercent: Double?
    public var id: ProcessIdentity { identity }
    public var pid: Int32 { identity.pid }
}

public enum BindScope: String, Sendable, Codable {
    case loopback        // 127.0.0.0/8, ::1
    case allInterfaces   // 0.0.0.0, ::
    case other
}

public struct ListeningPort: Hashable, Sendable, Identifiable {
    public let port: UInt16
    public let ownerPID: Int32
    public let scope: BindScope
    /// ESTABLISHED sockets owned by the same process whose local port == `port` (server-side accepted sockets).
    public let establishedConnections: Int
    public var id: String { "\(ownerPID):\(port)" }
    public var isEphemeral: Bool { port >= 49_152 }
    /// Node and workerd inspectors: 9229 plus the next two ports an inspector falls back to when the previous one is taken
    /// (several Vite + Cloudflare servers at once land on 9230 / 9231).
    public static let inspectorPorts: ClosedRange<UInt16> = 9_229...9_231
    public var isInspector: Bool { Self.inspectorPorts.contains(port) }
}

public enum ScanDetail: Sendable {
    /// All own-uid processes: identity/ppid/pgid/uid/name/memory/cpu. exe+argv+cwd only for listener owners and their ancestors (≤ 12 hops).
    case standard
    /// `.standard` + cwd for EVERY own-uid process (used by `ActivityChecking`).
    case full
}

public struct ProcessSnapshot: Sendable {
    public let takenAt: Date
    public let selfPID: Int32
    /// Own-uid processes only (ENV G3). DevTidy itself is included (callers exclude via `selfPID`).
    public let nodes: [Int32: ProcessNode]
    /// Own-uid listening TCP sockets, deduplicated by (pid, port).
    public let listeners: [Int32: [ListeningPort]]
    private let children: [Int32: [Int32]]

    public init(takenAt: Date, selfPID: Int32, nodes: [Int32: ProcessNode], listeners: [Int32: [ListeningPort]]) {
        self.takenAt = takenAt; self.selfPID = selfPID; self.nodes = nodes; self.listeners = listeners
        var c: [Int32: [Int32]] = [:]
        for n in nodes.values where n.parentPID != n.identity.pid { c[n.parentPID, default: []].append(n.identity.pid) }
        for k in Array(c.keys) { c[k]?.sort() }
        self.children = c
    }

    public func childPIDs(of pid: Int32) -> [Int32] { children[pid] ?? [] }

    /// Nearest ancestor first. Stops at a missing node (launchd / other uid), a cycle, or `maxHops`.
    public func ancestors(of pid: Int32, maxHops: Int = 12) -> [ProcessNode] {
        var out: [ProcessNode] = []
        var seen: Set<Int32> = [pid]
        var cur = nodes[pid]?.parentPID ?? 0
        while out.count < maxHops, cur > 0, !seen.contains(cur), let n = nodes[cur] {
            out.append(n); seen.insert(cur); cur = n.parentPID
        }
        return out
    }

    /// Breadth-first, excludes `pid` itself, deterministic order (ascending pid per level).
    public func descendants(of pid: Int32) -> [ProcessNode] {
        var out: [ProcessNode] = []
        var queue = childPIDs(of: pid)
        var seen: Set<Int32> = [pid]
        var i = 0
        while i < queue.count {
            let p = queue[i]; i += 1
            guard seen.insert(p).inserted, let n = nodes[p] else { continue }
            out.append(n)
            queue.append(contentsOf: childPIDs(of: p))
        }
        return out
    }

    public func groupMembers(_ pgid: Int32) -> [ProcessNode] {
        nodes.values.filter { $0.pgid == pgid }.sorted { $0.identity.pid < $1.identity.pid }
    }

    /// Returns the node only if pid AND start time match.
    public func node(matching id: ProcessIdentity) -> ProcessNode? {
        guard let n = nodes[id.pid], n.identity == id else { return nil }
        return n
    }
}

// MARK: - Projects -----------------------------------------------------------

public enum ProjectKind: String, Sendable, Codable, CaseIterable {
    case next, vite, nuxt, svelteKit, astro, remix, reactRouter, gatsby, angular, parcel
    case expo, reactNative, cloudflareWorkers, node
    case laravel, php, python, ruby, java, rust, go
    case swiftPackage, xcode, gradle, flutter, godot
    case unknown
}

public struct Project: Identifiable, Hashable, Sendable, Codable {
    /// Canonical (realpath) project root: the nearest marker dir (servers) or the git/ceiling root (cleanup, CAT §2).
    public let root: String
    /// Last path component of `root`.
    public let name: String
    /// Parent folder name, used only for grouping labels (e.g. "rentacarsaas" for rentacarsaas/backoffice).
    public let groupName: String?
    public let kinds: [ProjectKind]            // most specific first; never empty (`[.unknown]`)
    public let repoRoot: String?               // canonical git toplevel if any
    public var id: String { root }
}

/// Result of the R1/R2 gate + package-dir resolution (CAT §2). nil from `projectContext` ⇒ refuse any cache offer.
public struct ProjectContext: Sendable {
    public let project: Project
    /// repoRoot if (depthBelow(home) >= 2 && under home) else the start path itself — the "ceiling" of CAT §2.
    public let ceiling: String
    /// [start, parent, …, ceiling], max 8, canonical.
    public let packageDirs: [String]
}

// MARK: - Servers ------------------------------------------------------------

public enum Confidence: Int, Sendable, Codable, Comparable {
    case low = 0, medium, high
    public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
}

public struct ServerHints: Hashable, Sendable {
    public let orphaned: Bool          // tree root ppid == 1
    public let noControllingTTY: Bool  // tree root has no tty
    public let lanExposed: Bool        // any port bound allInterfaces
    public let noConnections: Bool     // establishedConnections == 0
}

/// A listener process folded into a `DevServer` (the primary one plus every nested-root listener merged into it).
public struct ServerListener: Hashable, Sendable {
    public let pid: Int32
    public let name: String                 // kernel comm
    public let project: Project?
    public let ports: [ListeningPort]       // ascending
}

public struct DevServer: Identifiable, Hashable, Sendable {
    /// Tree root: the process DevTidy starts signalling from (see `TreeRootResolver`).
    public let root: ProcessNode
    /// root first, then BFS descendants.
    public let members: [ProcessNode]
    /// All listeners of all members; `mainPort` first, then ascending.
    public let ports: [ListeningPort]
    public let mainPort: UInt16?
    public let project: Project?
    public let kind: ProjectKind
    public let confidence: Confidence
    /// Display command, e.g. "next dev -p 3000" (parent argv is used when the listener's argv was rewritten, ENV G4).
    public let command: String
    /// Sum over members; nil when every member's cpuPercent is nil.
    public let cpuPercent: Double?
    public let memoryBytes: UInt64
    public let establishedConnections: Int
    public let hints: ServerHints
    /// True iff `kill(-pgid)` is allowed for this tree (K5). Re-verified by the terminator at signal time.
    public let groupKillEligible: Bool
    /// Every candidate listener merged into this server, primary first (several when nested tree roots were merged).
    public var listeners: [ServerListener] = []
    /// Roots of browser / app-bundle subtrees below `root`: not in `members`, never signalled.
    public var sparedRoots: [ProcessNode] = []
    public var id: ProcessIdentity { root.identity }
    public func uptime(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(root.identity.startDate)) }
    /// Ports shown as chips: not ephemeral (≥ 49152), not an inspector (9229–9231, or a port that a member's argv declares via
    /// `--inspect[-brk|-wait][=[host:]port]`, `--inspect-port`, `--inspector-port`). `mainPort` is never hidden.
    public var displayPorts: [ListeningPort] {
        let declared = declaredInspectorPorts
        return ports.filter { port in
            port.port == mainPort || (!port.isEphemeral && !port.isInspector && !declared.contains(port.port))
        }
    }
    public var internalPortCount: Int { ports.count - displayPorts.count }

    /// Inspector ports named in the argv of any member. Empty when no member has `arguments`.
    public var declaredInspectorPorts: Set<UInt16> {
        var out = Set<UInt16>()
        for member in members {
            if let arguments = member.arguments { out.formUnion(InspectorFlags.ports(in: arguments)) }
        }
        return out
    }
}

/// Parses inspector flags out of an argv. Node: `--inspect`, `--inspect-brk`, `--inspect-wait` (value only with `=`),
/// `--inspect-port` (`=` or the next argument); wrangler / workerd: `--inspector-port`. A value is `port` or `host:port`
/// (`[::1]:9229` included). A flag without a value means the default port (9229, already covered by `isInspector`).
enum InspectorFlags {
    static func ports(in arguments: [String]) -> Set<UInt16> {
        var out = Set<UInt16>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--inspect") else { continue }
            let name: Substring
            var value: Substring?
            if let equals = argument.firstIndex(of: "=") {
                name = argument[..<equals]
                value = argument[argument.index(after: equals)...]
            } else {
                name = Substring(argument)
            }
            switch name {
            case "--inspect", "--inspect-brk", "--inspect-wait":
                break
            case "--inspect-port", "--inspector-port":
                if value == nil, index < arguments.count, !arguments[index].hasPrefix("-") {
                    value = Substring(arguments[index])
                    index += 1
                }
            default:
                continue
            }
            if let value, let declared = parsePort(value) { out.insert(declared) }
        }
        return out
    }

    private static func parsePort(_ value: Substring) -> UInt16? {
        let digits = value.split(separator: ":", omittingEmptySubsequences: false).last ?? value
        guard let port = UInt16(digits), port > 0 else { return nil }
        return port
    }
}

public enum OtherListenerReason: String, Sendable { case tool, app, system, unknown }

public struct OtherListener: Identifiable, Hashable, Sendable {
    public let node: ProcessNode
    public let ports: [ListeningPort]
    public let reason: OtherListenerReason
    public var id: ProcessIdentity { node.identity }
}

public struct ServerScan: Sendable {
    public let takenAt: Date
    public let servers: [DevServer]
    public let others: [OtherListener]
    public static let empty = ServerScan(takenAt: .distantPast, servers: [], others: [])
}

public struct TerminationPolicy: Sendable {
    public var graceSeconds: Double = 5        // SIGTERM → wait
    public var killWaitSeconds: Double = 2     // SIGKILL → wait
    public var pollMilliseconds: Int = 100
    public init() {}
}

public struct SignalSkip: Sendable, Hashable {
    public let pid: Int32
    /// machine tag: "identity-changed", "not-owned", "protected", "protected-role" (a terminal / IDE / agent below the root),
    /// "outside-tree", "gone", "eperm"
    public let reason: String
}

public struct TerminationReport: Sendable {
    public let root: ProcessIdentity
    public let terminated: [Int32]             // exited after SIGTERM
    public let forced: [Int32]                 // needed SIGKILL
    public let survivors: [Int32]              // still alive after the SIGKILL wait
    public let skipped: [SignalSkip]
    public let usedGroupSignal: Bool
    public let wasAlreadyGone: Bool
}

// MARK: - Caches -------------------------------------------------------------

public enum CacheSafety: Int, Sendable, Codable, Comparable {
    case always = 0        // class A
    case conditional = 1   // class B
    case optIn = 2         // class C (dependencies)
    public static func < (a: CacheSafety, b: CacheSafety) -> Bool { a.rawValue < b.rawValue }
}

public enum DeleteMode: String, Sendable, Codable { case permanent, trash }

/// One row in the cleanup sheet / Builds tab. `ruleID` + `packageDir` (+ `instance`) fully identify the target;
/// the cleaner NEVER trusts `displayPath` (R3).
public struct CacheEntry: Identifiable, Hashable, Sendable {
    public let id: String                 // "\(ruleID)@\(packageDir)" + (instance.map { "#" + $0 } ?? "")
    public let ruleID: String             // catalog id, e.g. "next.cache"; "xcode.deriveddata" for global DerivedData
    public let packageDir: String         // canonical dir the rule was evaluated in (DerivedData root for global entries)
    public let instance: String?          // DerivedData folder name; nil otherwise
    /// Relative to `packageDir`, display only: one path (".next"), or several joined by `displaySeparator` for multi-directory
    /// rules (".nx/cache, .nx/workspace-data") and discovered rules (up to 200 EXACT relative paths; `itemCount` = all matches
    /// and may exceed the listed count). The cleaner removes only the listed targets.
    public let displayPath: String
    public let title: String              // Turkish, e.g. "Next.js önbelleği"
    public let safety: CacheSafety
    public let isContentsOnly: Bool
    public let defaultSelected: Bool
    public let defaultMode: DeleteMode    // A: permanent, B: trash, C: permanent, DerivedData: permanent
    public let sizeBytes: Int64?          // nil = not sized yet (lazy)
    public let sizeIsPartial: Bool
    public let itemCount: Int?            // e.g. number of __pycache__ dirs
    public let qualifiedBecause: [String] // Turkish facts: "git tarafından yok sayılıyor", "izlenen dosya: 0"
    public let notes: [String]            // Turkish consequences: "yeniden kurulum ağ gerektirir"
    public let reinstallCommand: String?  // class C only
    public func withSize(_ r: SizeResult) -> CacheEntry {
        CacheEntry(id: id, ruleID: ruleID, packageDir: packageDir, instance: instance, displayPath: displayPath, title: title,
                   safety: safety, isContentsOnly: isContentsOnly, defaultSelected: defaultSelected, defaultMode: defaultMode,
                   sizeBytes: r.bytes, sizeIsPartial: r.isPartial, itemCount: r.itemCount ?? itemCount,
                   qualifiedBecause: qualifiedBecause, notes: notes, reinstallCommand: reinstallCommand)
    }

    /// The same entry narrowed to `path`'s targets. Callers only pass a subset of the paths already listed (never a widening).
    func withDisplayPath(_ path: String) -> CacheEntry {
        CacheEntry(id: id, ruleID: ruleID, packageDir: packageDir, instance: instance, displayPath: path, title: title,
                   safety: safety, isContentsOnly: isContentsOnly, defaultSelected: defaultSelected, defaultMode: defaultMode,
                   sizeBytes: sizeBytes, sizeIsPartial: sizeIsPartial, itemCount: itemCount,
                   qualifiedBecause: qualifiedBecause, notes: notes, reinstallCommand: reinstallCommand)
    }

    /// Joins the relative paths of a multi-directory rule in `displayPath`. Catalog path components never contain it.
    static let displaySeparator = ", "

    /// The absolute paths the confirmation sheet shows for this entry, one per target. Display only: the cleaner re-derives
    /// every target from `(ruleID, packageDir, instance)`.
    public var targetPaths: [String] {
        if let instance { return [packageDir + "/" + instance] }
        return displayPath.components(separatedBy: Self.displaySeparator).map { packageDir + "/" + $0 }
    }
}

public struct SizeResult: Sendable, Equatable {
    public let bytes: Int64               // allocated bytes (st_blocks*512), hard links counted once (R21)
    public let isPartial: Bool            // walk hit an error or a cost bound ⇒ "≥"
    public let itemCount: Int?
}

public struct ProjectCacheReport: Identifiable, Sendable {
    public let project: Project
    public let entries: [CacheEntry]
    public let scannedAt: Date
    public var id: String { project.root }
    public var knownBytes: Int64 { entries.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
}

public struct ActivityBlocker: Hashable, Sendable {
    public enum Kind: String, Sendable { case process, listener, container }
    public enum Severity: String, Sendable { case soft, hard }
    public let kind: Kind
    public let severity: Severity
    public let label: String              // "node (PID 9422)", "tunahan-php-1"
    public let pid: Int32?
    public let containerID: String?
    /// Single source of truth for R15: class A is stopped only by `.hard` blockers; class B/C by any blocker.
    /// Container bind-mount blockers are always emitted as `.soft`.
    public func blocks(_ safety: CacheSafety) -> Bool { severity == .hard || safety != .always }
}

public struct CleanupPlan: Identifiable, Sendable {
    public let id: UUID
    public let rootPath: String           // ceiling for project plans; DerivedData root for the orphan plan
    public let project: Project?
    public let entries: [CacheEntry]      // sized
    public let blockers: [ActivityBlocker]
    public let createdAt: Date
    /// True when the plan was built with class C (dependencies) enabled; the cleaner refuses class C entries otherwise.
    public var includesDependencies: Bool = false
}

/// UI → cleaner. Carries only an entry id + mode, never a path (R3).
public struct CleanupSelection: Hashable, Sendable {
    public let entryID: String
    public let mode: DeleteMode
    /// The user's "Anladım" for class C (dependencies); the cleaner refuses a class C selection without it.
    public let acknowledgedDependencies: Bool
    public init(entryID: String, mode: DeleteMode, acknowledgedDependencies: Bool = false) {
        self.entryID = entryID; self.mode = mode; self.acknowledgedDependencies = acknowledgedDependencies
    }
}

public enum SkipReason: String, Sendable {
    case rootRejected, notFound, symlink, nameMismatch, outsideRoot, crossesDevice, immutable
    case trackedByGit, notIgnoredByGit, hasUntrackedFiles, gitUnavailable
    case blockedByActivity, identityChanged, notInCatalog, notSelected, emptyAlready
    /// A nested repository / worktree was found below the target by the pre-walk.
    case containsRepository
    /// The nested-repository pre-walk hit a bound or an unreadable directory, so "no repository inside" is not proven.
    case scanIncomplete
    /// The package's own manifest names the target as publish output.
    case packageOutput
}

public enum CleanupStatus: Sendable, Equatable {
    case deleted(bytes: Int64)
    case movedToTrash(bytes: Int64)
    case skipped(SkipReason)
    case failed(String)                    // errno text; never a fallback to permanent after a Trash failure (R19)
}

public struct CleanupOutcome: Identifiable, Sendable {
    public let entryID: String
    public let path: String                // absolute path actually touched (result list / audit)
    public let status: CleanupStatus
    public var id: String { entryID }
}

public struct CleanupResult: Sendable {
    public let planID: UUID
    public let outcomes: [CleanupOutcome]
    public let finishedAt: Date
    public var freedBytes: Int64 {
        outcomes.reduce(Int64(0)) { acc, o in if case .deleted(let b) = o.status { return acc + b }; return acc }
    }
    public var trashedBytes: Int64 {
        outcomes.reduce(Int64(0)) { acc, o in if case .movedToTrash(let b) = o.status { return acc + b }; return acc }
    }
}

public struct CatalogOptions: Sendable {
    public var includeDependencies: Bool = false     // class C (node_modules, vendor, Pods): opt-in
    public var includeDerivedData: Bool = true
    public init() {}
}

public struct BuildsScanOptions: Sendable {
    public var roots: [String]
    public var maxDepth: Int = 4
    public var maxDirectories: Int = 25_000
    public var maxSeconds: Double = 15
    public var catalog = CatalogOptions()
    public init(roots: [String]) { self.roots = roots }
}

public struct BuildsScanSummary: Sendable, Equatable {
    public let directoriesVisited: Int
    public let reportCount: Int
    public let truncated: Bool                // a cost bound was hit
    public let permissionDeniedRoots: [String]
    public let seconds: Double
}

public enum BuildsScanEvent: Sendable {
    case progress(directoriesVisited: Int)
    case report(ProjectCacheReport)           // entries unsized (sizeBytes == nil)
    case finished(BuildsScanSummary)
}

// MARK: - Docker ------------------------------------------------------------

public struct DockerEngineInfo: Sendable, Equatable {
    public let version: String
    public let apiVersion: String
}

public enum DockerStatus: Sendable, Equatable {
    case unknown                         // before first poll
    case notInstalled                    // no CLI, no Docker.app, no socket
    case notRunning                      // socket missing / connection refused
    case running(DockerEngineInfo)
    case failed(String)                  // reachable but unusable (HTTP 5xx, bad JSON); retrying can help
    case unsupported(String)             // a configuration DevTidy refuses to use (remote / ssh context, bad override); retrying cannot help
}

public enum ContainerState: String, Sendable {
    case created, running, paused, restarting, removing, exited, dead, unknown
}

public enum ContainerHealth: String, Sendable { case healthy, unhealthy, starting }

public struct PublishedPort: Hashable, Sendable {
    public let hostIP: String?            // "127.0.0.1", "0.0.0.0", "::" or nil
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let proto: String              // "tcp" | "udp"
}

public struct DockerContainer: Identifiable, Hashable, Sendable {
    public let id: String                 // full 64-hex id
    public let shortID: String            // first 12
    public let name: String               // without leading "/"
    public let image: String
    public let state: ContainerState
    public let statusText: String         // daemon's English text, tooltip only
    public let createdAt: Date
    public let startedAt: Date?           // from inspect, running containers only; cached by (id, state)
    public let composeProject: String?    // label com.docker.compose.project
    public let composeService: String?
    public let composeWorkingDir: String? // label com.docker.compose.project.working_dir (host path)
    public let publishedPorts: [PublishedPort]
    public let bindMountSources: [String] // host paths, "/host_mnt" prefix stripped
    public let health: ContainerHealth?   // nil for non-running containers (stale, ENV G8) and for "none"
    public let cpuPercent: Double?        // % of ONE core (can exceed 100); nil until two samples exist
    public let memoryBytes: UInt64?       // usage − inactive_file
    public let memoryLimitBytes: UInt64?
    public func uptime(at now: Date) -> TimeInterval? { startedAt.map { max(0, now.timeIntervalSince($0)) } }
    public var isRunning: Bool { state == .running }

    /// The same container carrying `sample`'s cpu / memory figures (ignored when the sample has none).
    func withStats(of sample: DockerContainer) -> DockerContainer {
        guard sample.cpuPercent != nil || sample.memoryBytes != nil else { return self }
        return DockerContainer(id: id, shortID: shortID, name: name, image: image, state: state, statusText: statusText,
                               createdAt: createdAt, startedAt: startedAt, composeProject: composeProject,
                               composeService: composeService, composeWorkingDir: composeWorkingDir,
                               publishedPorts: publishedPorts, bindMountSources: bindMountSources, health: health,
                               cpuPercent: sample.cpuPercent, memoryBytes: sample.memoryBytes,
                               memoryLimitBytes: sample.memoryLimitBytes)
    }
}

public struct ComposeProject: Identifiable, Sendable {
    public let name: String
    public let workingDir: String?
    public let containers: [DockerContainer]      // sorted by service, then name
    public var id: String { name }
    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var memoryBytes: UInt64 { containers.reduce(0) { $0 + ($1.memoryBytes ?? 0) } }
}

public struct DockerSnapshot: Sendable {
    public let status: DockerStatus
    public let projects: [ComposeProject]
    public let standalone: [DockerContainer]
    public let takenAt: Date
    public let statsAt: Date?                     // when cpu/mem values were last sampled
    public var allContainers: [DockerContainer] { projects.flatMap(\.containers) + standalone }
    public static let unknown = DockerSnapshot(status: .unknown, projects: [], standalone: [], takenAt: .distantPast, statsAt: nil)

    /// This snapshot (status, list, `takenAt`) with the cpu / memory samples of `newer`, matched by container id and only for
    /// containers that are running in both. Lets a slow stats pass that started before a newer list still contribute its
    /// fresher numbers without resurrecting its stale container list. `statsAt` follows `newer`.
    func mergingStats(from newer: DockerSnapshot) -> DockerSnapshot {
        var samples: [String: DockerContainer] = [:]
        for container in newer.allContainers where container.isRunning { samples[container.id] = container }
        func merged(_ container: DockerContainer) -> DockerContainer {
            guard container.isRunning, let sample = samples[container.id] else { return container }
            return container.withStats(of: sample)
        }
        let mergedProjects = projects.map {
            ComposeProject(name: $0.name, workingDir: $0.workingDir, containers: $0.containers.map(merged))
        }
        return DockerSnapshot(status: status, projects: mergedProjects, standalone: standalone.map(merged),
                              takenAt: takenAt, statsAt: newer.statsAt)
    }
}

public enum StatsRefresh: Sendable { case reuse, refresh }
public enum ContainerAction: Sendable, Equatable { case start, stop, remove }     // remove: never force, never volumes (X3)
public enum ComposeAction: Sendable, Equatable { case stop, down }                // down: never --volumes, never --rmi (X4)

public struct BuildCacheSummary: Sendable, Equatable {
    public let totalBytes: Int64
    public let reclaimableBytes: Int64            // Σ size of records with InUse != true (shared records included ⇒ "en çok")
    public let privateReclaimableBytes: Int64     // … and Shared != true (ENV: matches `system df` Reclaimable)
    public let recordCount: Int
    public let activeCount: Int
    public let measuredAt: Date
}
public enum BuildCachePruneMode: Sendable, Equatable { case olderThan(hours: Int), allUnused }
public struct BuildCachePruneResult: Sendable, Equatable { public let reclaimedBytes: Int64 }

// MARK: - Idle / UI-facing ---------------------------------------------------

public enum IdleState: String, Sendable, Codable {
    case active, probablyIdle, idle
    public var isFlagged: Bool { self != .active }
}

public struct UserFacingError: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let message: String
}

public struct MenuBarSummary: Sendable, Equatable {
    public let runningServers: Int
    public let runningContainers: Int
    public let totalMemoryBytes: UInt64           // servers + running containers
    public let flaggedIdleCount: Int              // idle + probablyIdle servers and containers
}

// MARK: - Settings -----------------------------------------------------------

public struct DevTidySettings: Codable, Sendable, Equatable {
    public var scanRoots: [String] = []           // empty ⇒ ["~/developer"] expanded by SettingsStore
    public var buildsMaxDepth: Int = 4
    public var includeDependencies: Bool = false  // node_modules etc. OFF by default
    public var deleteConditionalPermanently: Bool = false   // class B: false ⇒ Trash
    public var serverIdleMinutes: Int = 30
    public var containerIdleMinutes: Int = 15
    public var idleCPUPercent: Double = 1.0
    public var showOtherListeners: Bool = false
    public var menuBarShowsMemory: Bool = true
    public var dockerSocketOverride: String? = nil
    /// One `GET /` to the server's own loopback address per server, to read the page `<title>`. Default ON.
    public var fetchPageTitles: Bool = true
    public init() {}

    /// Every key is optional: a settings blob saved by an older version (no `fetchPageTitles`) must keep the user's other
    /// values instead of failing to decode and falling back to the defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanRoots = try c.decodeIfPresent([String].self, forKey: .scanRoots) ?? scanRoots
        buildsMaxDepth = try c.decodeIfPresent(Int.self, forKey: .buildsMaxDepth) ?? buildsMaxDepth
        includeDependencies = try c.decodeIfPresent(Bool.self, forKey: .includeDependencies) ?? includeDependencies
        deleteConditionalPermanently = try c.decodeIfPresent(Bool.self, forKey: .deleteConditionalPermanently)
            ?? deleteConditionalPermanently
        serverIdleMinutes = try c.decodeIfPresent(Int.self, forKey: .serverIdleMinutes) ?? serverIdleMinutes
        containerIdleMinutes = try c.decodeIfPresent(Int.self, forKey: .containerIdleMinutes) ?? containerIdleMinutes
        idleCPUPercent = try c.decodeIfPresent(Double.self, forKey: .idleCPUPercent) ?? idleCPUPercent
        showOtherListeners = try c.decodeIfPresent(Bool.self, forKey: .showOtherListeners) ?? showOtherListeners
        menuBarShowsMemory = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowsMemory) ?? menuBarShowsMemory
        dockerSocketOverride = try c.decodeIfPresent(String.self, forKey: .dockerSocketOverride)
        fetchPageTitles = try c.decodeIfPresent(Bool.self, forKey: .fetchPageTitles) ?? fetchPageTitles
    }
}
