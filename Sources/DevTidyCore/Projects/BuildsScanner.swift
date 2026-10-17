import Foundation
import Darwin

/// Caps the number of git questions of one builds scan (≤ 300). Beyond the budget every answer is `.failed`
/// (fail-closed: those entries are simply not offered) and `exceeded` is set so the scan reports `truncated`.
final class BudgetedGit: GitProbing, @unchecked Sendable {
    private let base: any GitProbing
    private let limit: Int
    private let lock = NSLock()
    private var used = 0
    private var over = false

    init(base: any GitProbing, limit: Int) {
        self.base = base
        self.limit = limit
    }

    var exceeded: Bool { lock.withLock { over } }

    private func charge() -> Bool {
        lock.withLock {
            if used >= limit { over = true; return false }
            used += 1
            return true
        }
    }

    func toplevel(of directory: String) async -> GitRepoState {
        charge() ? await base.toplevel(of: directory) : .failed("git sınırı doldu")
    }

    func trackedPaths(inParent parent: String, paths: [String]) async -> GitListOutcome {
        charge() ? await base.trackedPaths(inParent: parent, paths: paths) : .failed("git sınırı doldu")
    }

    func untrackedNotIgnoredPaths(inParent parent: String, paths: [String]) async -> GitListOutcome {
        charge() ? await base.untrackedNotIgnoredPaths(inParent: parent, paths: paths) : .failed("git sınırı doldu")
    }

    func ignoredPaths(inParent parent: String, paths: [String]) async -> GitBatchIgnoreOutcome {
        charge() ? await base.ignoredPaths(inParent: parent, paths: paths) : .failed("git sınırı doldu")
    }
}

/// Bounded, symlink-safe directory walk feeding `CacheCatalog.scan` (design §5.6).
struct BuildsScanner: Sendable {
    let engine: CatalogEngine
    let git: any GitProbing
    let policy: PathPolicy
    let now: @Sendable () -> Date
    /// Test seam: called once per visited directory (a fake visit counter proves cancellation stops the walk).
    var onVisit: (@Sendable () -> Void)?
    /// Monotonic seconds; replaceable in tests.
    var clock: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    static let gitBudget = 300
    static let concurrency = 4
    static let progressInterval = 200

    /// Never descended into (hidden dirs are skipped as a class as well).
    static let skipNames: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", ".next", ".nuxt", ".svelte-kit", ".output", ".open-next", ".turbo",
        "dist", "build", "out", "target", "vendor", ".venv", "venv", "env", "Pods", "DerivedData", ".build", ".gradle",
        ".dart_tool", ".cache", "__pycache__", "Library", ".Trash",
    ]
    static let bundleSuffixes = [".app", ".framework", ".xcodeproj", ".xcworkspace", ".playground", ".photoslibrary"]

    init(engine: CatalogEngine, git: any GitProbing, policy: PathPolicy, now: @escaping @Sendable () -> Date,
         onVisit: (@Sendable () -> Void)? = nil) {
        self.engine = engine
        self.git = git
        self.policy = policy
        self.now = now
        self.onVisit = onVisit
    }

    static func shouldDescend(into name: String) -> Bool {
        !name.hasPrefix(".") && !skipNames.contains(name) && !bundleSuffixes.contains(where: { name.hasSuffix($0) })
    }

    private struct Candidate: Sendable {
        let path: String
        let root: String
    }

    private struct GroupOutcome: Sendable {
        let reported: Bool
        let skippedForTime: Bool
    }

    // MARK: Run

    func run(_ options: BuildsScanOptions, emit: @escaping @Sendable (BuildsScanEvent) -> Void) async {
        let start = clock()
        let maxSeconds = options.maxSeconds
        var visited = 0
        var truncated = false
        var denied: [String] = []
        var candidates: [Candidate] = []
        var seenCandidates = Set<String>()
        var seenRoots = Set<String>()
        let maxDepth = min(6, max(2, options.maxDepth))

        // Phase 1: bounded walk collecting candidate directories (a project marker is present).
        rootLoop: for raw in options.roots {
            let root = PathPolicy.canonical(raw)
            guard seenRoots.insert(root).inserted,
                  policy.isUnderHome(root), (policy.depthBelowHome(root) ?? 0) >= 1, !policy.isDenied(root),
                  PathPolicy.isRealDirectory(root), let rootDev = PathPolicy.device(of: root) else { continue }
            var stack: [(path: String, depth: Int)] = [(root, 0)]
            while let cur = stack.popLast() {
                if Task.isCancelled { break rootLoop }
                if visited >= options.maxDirectories || clock() - start >= maxSeconds { truncated = true; break rootLoop }
                let fd = SafeFS.openDirAbsolute(cur.path)
                if fd < 0 {
                    if cur.depth == 0, errno == EPERM || errno == EACCES { denied.append(root) }
                    continue
                }
                visited += 1
                onVisit?()
                if visited % Self.progressInterval == 0 {
                    emit(.progress(directoriesVisited: visited))
                    await Task.yield()
                }
                let listing = SafeFS.enumerate(dirFD: fd)
                close(fd)
                guard let entries = listing else { continue }
                if ProjectMarkers.hasMarker(in: entries.map(\.name)), seenCandidates.insert(cur.path).inserted {
                    candidates.append(Candidate(path: cur.path, root: root))
                }
                guard cur.depth < maxDepth else { continue }
                for e in entries.sorted(by: { $0.name > $1.name }) {
                    guard e.stat.isDirectory, e.stat.dev == rootDev, Self.shouldDescend(into: e.name) else { continue }
                    stack.append((cur.path + "/" + e.name, cur.depth + 1))
                }
            }
        }

        // Phase 2: evaluate the catalog per project (ceiling), 4-way, emitting each report as soon as it is complete.
        let budgeted = BudgetedGit(base: git, limit: Self.gitBudget)
        let scanEngine = CatalogEngine(git: budgeted, derived: engine.derived, policy: policy)
        let evaluator = scanEngine.makeEvaluator()    // ONE per scan: manifests and listings are read at most once
        let groups = Self.group(candidates, policy: policy)
        let derivedChildren: [DerivedDataLocator.Child]? = options.catalog.includeDerivedData ? engine.derived.children() : nil
        var reportCount = 0
        var skippedForTime = false

        if !Task.isCancelled {
            await withTaskGroup(of: GroupOutcome.self) { taskGroup in
                var running = 0
                func tally(_ r: GroupOutcome) {
                    if r.reported { reportCount += 1 }
                    if r.skippedForTime { skippedForTime = true }
                }
                for (ceiling, members) in groups {
                    if running >= Self.concurrency, let r = await taskGroup.next() { tally(r); running -= 1 }
                    taskGroup.addTask {
                        await self.evaluateGroup(ceiling: ceiling, candidates: members, options: options, engine: scanEngine,
                                                 evaluator: evaluator, derivedChildren: derivedChildren, deadline: start + maxSeconds, emit: emit)
                    }
                    running += 1
                }
                for await r in taskGroup { tally(r) }
            }
        }

        let summary = BuildsScanSummary(directoriesVisited: visited, reportCount: reportCount,
                                        truncated: truncated || skippedForTime || budgeted.exceeded,
                                        permissionDeniedRoots: denied, seconds: clock() - start)
        emit(.finished(summary))
    }

    // MARK: Grouping

    /// `ceiling` = nearest ancestor-or-self carrying `.git` inside the scan root (when it passes R1), else the candidate.
    private static func group(_ candidates: [Candidate], policy: PathPolicy) -> [(String, [String])] {
        var byCeiling: [String: [String]] = [:]
        for c in candidates {
            byCeiling[ceiling(for: c.path, root: c.root, policy: policy), default: []].append(c.path)
        }
        return byCeiling.keys.sorted().map { ($0, byCeiling[$0]?.sorted() ?? []) }
    }

    private static func ceiling(for candidate: String, root: String, policy: PathPolicy) -> String {
        var dir = candidate
        while true {
            if SafeFS.lstatAbsolute(dir + "/.git") != nil {
                return policy.passesRootDepthAndDenyGate(dir) ? dir : candidate
            }
            if dir == root { return candidate }
            let parent = PathPolicy.parent(of: dir)
            if parent == dir || !PathPolicy.isInsideOrEqual(parent, root: root) { return candidate }
            dir = parent
        }
    }

    // MARK: One project

    private func evaluateGroup(ceiling: String, candidates: [String], options: BuildsScanOptions, engine: CatalogEngine,
                               evaluator: CacheEvaluator, derivedChildren: [DerivedDataLocator.Child]?, deadline: Double,
                               emit: @Sendable (BuildsScanEvent) -> Void) async -> GroupOutcome {
        if Task.isCancelled { return GroupOutcome(reported: false, skippedForTime: false) }
        if clock() >= deadline { return GroupOutcome(reported: false, skippedForTime: true) }
        guard policy.passesRootDepthAndDenyGate(ceiling), policy.isRealDirectoryOnHomeDevice(ceiling) else {
            return GroupOutcome(reported: false, skippedForTime: false)
        }
        var kinds: [ProjectKind] = []
        for dir in candidates {
            guard let names = SafeFS.listNames(atAbsolutePath: dir) else { continue }
            for k in ProjectKindDetector.kinds(inDirectory: dir, names: names) where k != .unknown && !kinds.contains(k) { kinds.append(k) }
        }
        let hasGit = SafeFS.lstatAbsolute(ceiling + "/.git") != nil
        // `Project.name` / `groupName` are shown on the rows of the Builds tab and in the cleanup sheet: the folder names,
        // cleaned for display like `ProjectDetector` does (Security F3-4). `root` stays the real path.
        let folder = (ceiling as NSString).lastPathComponent
        let project = Project(root: ceiling, name: DisplayText.label(folder.isEmpty ? ceiling : folder),
                              groupName: policy.groupName(forProjectRoot: ceiling).map { DisplayText.label($0) },
                              kinds: kinds.isEmpty ? [.unknown] : kinds, repoRoot: hasGit ? ceiling : nil)

        var byID: [String: CacheEntry] = [:]
        for candidate in candidates {
            if Task.isCancelled { break }
            let ctx = ProjectContext(project: project, ceiling: ceiling,
                                     packageDirs: PathPolicy.packageDirs(start: candidate, ceiling: ceiling))
            for e in await engine.scanEntries(candidate: candidate, ctx: ctx, options: options.catalog, evaluator: evaluator) { byID[e.id] = e }
        }
        if !candidates.contains(ceiling), !Task.isCancelled {
            let ctx = ProjectContext(project: project, ceiling: ceiling, packageDirs: [ceiling])
            for e in await engine.ceilingEntries(ctx: ctx, options: options.catalog, evaluator: evaluator) { byID[e.id] = e }
        }
        if options.catalog.includeDerivedData {
            for e in engine.derivedEntries(matching: ceiling, children: derivedChildren) { byID[e.id] = e }
        }
        guard !byID.isEmpty, !Task.isCancelled else { return GroupOutcome(reported: false, skippedForTime: false) }
        emit(.report(ProjectCacheReport(project: project, entries: CatalogEngine.sorted(byID.values), scannedAt: now())))
        return GroupOutcome(reported: true, skippedForTime: false)
    }
}
