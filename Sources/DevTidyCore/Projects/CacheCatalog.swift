import Foundation
import Darwin

// MARK: - Engine (shared by `report` and the builds scan) ----------------------------------

struct CatalogEngine: Sendable {
    let git: any GitProbing
    let derived: DerivedDataLocator
    let policy: PathPolicy

    /// A new evaluator — and therefore a new per-scan manifest/listing cache — for every operation, so a detection never
    /// reads a stale directory listing or manifest.
    func makeEvaluator() -> CacheEvaluator { CacheEvaluator(git: git, policy: policy) }
    var evaluator: CacheEvaluator { makeEvaluator() }

    /// Rules offered to the user: class C only with `includeDependencies`; global DerivedData is handled separately.
    func eligibleRules(_ options: CatalogOptions) -> [CacheRule] {
        CatalogData.rules.filter { rule in
            if case .discovered(.derivedDataChildren) = rule.kind { return false }
            return rule.safety != .optIn || options.includeDependencies
        }
    }

    /// Every packageDir of `ctx` × every eligible rule (+ DerivedData folders whose workspace is inside the ceiling).
    func projectEntries(ctx: ProjectContext, options: CatalogOptions,
                        derivedChildren: [DerivedDataLocator.Child]? = nil) async -> [CacheEntry] {
        var byID: [String: CacheEntry] = [:]
        let evaluator = makeEvaluator()
        let rules = eligibleRules(options)
        for dir in ctx.packageDirs {
            for rule in rules {
                if Task.isCancelled { return Self.sorted(byID.values) }
                for e in await evaluator.entries(rule: rule, packageDir: dir, ctx: ctx) { byID[e.id] = e }
            }
        }
        if options.includeDerivedData {
            for e in derivedEntries(matching: ctx.ceiling, children: derivedChildren) { byID[e.id] = e }
        }
        return Self.sorted(byID.values)
    }

    /// Builds-scan evaluation: all eligible rules at `candidate` (the caller shares one `evaluator` per scan).
    func scanEntries(candidate: String, ctx: ProjectContext, options: CatalogOptions, evaluator: CacheEvaluator) async -> [CacheEntry] {
        var out: [CacheEntry] = []
        for rule in eligibleRules(options) {
            if Task.isCancelled { break }
            out += await evaluator.entries(rule: rule, packageDir: candidate, ctx: ctx)
        }
        return out
    }

    /// At the ceiling only rules that may be hoisted (`ancestorOK`, root-level `node_modules`) are evaluated; once per ceiling.
    func ceilingEntries(ctx: ProjectContext, options: CatalogOptions, evaluator: CacheEvaluator) async -> [CacheEntry] {
        var out: [CacheEntry] = []
        for rule in eligibleRules(options) where rule.detect.ancestorOK || rule.id == "node.modules" {
            if Task.isCancelled { break }
            out += await evaluator.entries(rule: rule, packageDir: ctx.ceiling, ctx: ctx)
        }
        return out
    }

    func derivedEntries(matching root: String, children: [DerivedDataLocator.Child]?) -> [CacheEntry] {
        let all = children ?? derived.children()
        return all.filter { PathPolicy.isInsideOrEqual($0.workspacePath, root: root) }.map { derived.entry(for: $0, orphaned: false) }
    }

    /// Deterministic order: safety class, rule id, package dir, instance.
    static func sorted<S: Sequence>(_ entries: S) -> [CacheEntry] where S.Element == CacheEntry {
        entries.sorted {
            if $0.safety != $1.safety { return $0.safety < $1.safety }
            if $0.ruleID != $1.ruleID { return $0.ruleID < $1.ruleID }
            if $0.packageDir != $1.packageDir { return $0.packageDir < $1.packageDir }
            return ($0.instance ?? "") < ($1.instance ?? "")
        }
    }
}

// MARK: - Catalog actor ---------------------------------------------------------------------

public actor CacheCatalog: CacheCataloging {
    let projects: any ProjectDetecting
    let policy: PathPolicy
    let git: any GitProbing
    nonisolated let engine: CatalogEngine
    let now: @Sendable () -> Date

    private struct CachedSize {
        let result: SizeResult
        let signature: [FileStat.MTime?]
        let at: Date
    }
    private var sizeCache: [String: CachedSize] = [:]
    private var lastSizeEviction: Date?
    static let sizeTTL: TimeInterval = 600
    /// Test seam: how many measured sizes are currently cached.
    var cachedSizeCount: Int { sizeCache.count }

    public init(projects: any ProjectDetecting, runner: any CommandRunning, locator: any ToolLocating,
                homeDirectory: String = NSHomeDirectory()) {
        self.init(projects: projects, git: GitProbe(runner: runner, locator: locator), homeDirectory: homeDirectory,
                  derivedDataRoot: nil, customDerivedDataLocation: DerivedDataLocator.readCustomLocation, now: { Date() })
    }

    /// Test seam: fake git, DerivedData root, clock.
    init(projects: any ProjectDetecting, git: any GitProbing, homeDirectory: String, derivedDataRoot: String?,
         customDerivedDataLocation: @escaping @Sendable () -> String? = { nil }, now: @escaping @Sendable () -> Date = { Date() }) {
        let policy = PathPolicy(homeDirectory: homeDirectory)
        self.projects = projects
        self.policy = policy
        self.git = git
        self.now = now
        self.engine = CatalogEngine(
            git: git,
            derived: DerivedDataLocator(policy: policy, rootOverride: derivedDataRoot, customLocation: customDerivedDataLocation),
            policy: policy)
    }

    // MARK: CacheCataloging

    public func report(forProjectAt path: String, options: CatalogOptions) async -> ProjectCacheReport? {
        guard let ctx = await projects.projectContext(for: path) else { return nil }
        let entries = await engine.projectEntries(ctx: ctx, options: options)
        return ProjectCacheReport(project: ctx.project, entries: entries, scannedAt: now())
    }

    public nonisolated func scan(_ options: BuildsScanOptions) -> AsyncStream<BuildsScanEvent> {
        let scanner = BuildsScanner(engine: engine, git: git, policy: policy, now: now)
        // Unbounded: a `.report` row must never be dropped when the consumer is busy (progress events are throttled at the
        // source, every `BuildsScanner.progressInterval` directories).
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await scanner.run(options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func size(of entry: CacheEntry) async -> SizeResult {
        let signature = sizeSignature(of: entry)
        if let hit = sizeCache[entry.id], hit.signature == signature, now().timeIntervalSince(hit.at) < Self.sizeTTL {
            return hit.result
        }
        let measured = await measure(entry)
        if !Task.isCancelled {
            let stamp = now()
            evictExpiredSizes(at: stamp)
            sizeCache[entry.id] = CachedSize(result: measured, signature: signature, at: stamp)
        }
        return measured
    }

    /// Entries of deleted or renamed projects never come back, so everything past its TTL is dropped — but at most once per
    /// half TTL: a builds scan inserts thousands of sizes, and filtering the whole dictionary on every insert is quadratic
    /// (CodeReview P3-9). An expired entry that is still in the dictionary is never served: the hit test above checks the TTL.
    private func evictExpiredSizes(at stamp: Date) {
        if let last = lastSizeEviction {
            let elapsed = stamp.timeIntervalSince(last)
            if elapsed >= 0, elapsed < Self.sizeTTL / 2 { return }      // a clock that stepped back counts as due
        }
        lastSizeEviction = stamp
        sizeCache = sizeCache.filter { stamp.timeIntervalSince($0.value.at) < Self.sizeTTL }
    }

    public func orphanedDerivedData() async -> [CacheEntry] {
        engine.derived.orphanedEntries()
    }

    // MARK: Sizing

    /// Directory mtimes of the measured paths (cache key part: a changed directory invalidates the cached size).
    private func sizeSignature(of entry: CacheEntry) -> [FileStat.MTime?] {
        sizePaths(of: entry).map { SafeFS.lstatAbsolute($0)?.mtime }
    }

    private func sizePaths(of entry: CacheEntry) -> [String] {
        guard let rule = CatalogData.rule(id: entry.ruleID) else { return [] }
        switch rule.kind {
        case .dir:
            return engine.evaluator.literalTargets(rule: rule, packageDir: entry.packageDir, ceiling: entry.packageDir).map(\.path)
        case .dirs:
            // Several possible targets: only the ones the entry listed are measured (and removable).
            let listed = Set(entry.listedRelativePaths)
            return engine.evaluator.literalTargets(rule: rule, packageDir: entry.packageDir, ceiling: entry.packageDir)
                .filter { listed.contains($0.relative) }.map(\.path)
        case .contentsOnly(let comps, _), .file(let comps, _):
            return [entry.packageDir + "/" + comps.joined(separator: "/")]
        case .discovered(let d):
            if d == .derivedDataChildren {
                guard let instance = entry.instance else { return [] }
                return [entry.packageDir + "/" + instance]
            }
            return engine.evaluator.discoveredTargets(rule: rule, packageDir: entry.packageDir, ceiling: entry.packageDir,
                                                      listed: entry.listedRelativePaths).map(\.path)
        }
    }

    private func measure(_ entry: CacheEntry) async -> SizeResult {
        guard let rule = CatalogData.rule(id: entry.ruleID) else {
            return SizeResult(bytes: 0, isPartial: true, itemCount: entry.itemCount)
        }
        var total: Int64 = 0
        var partial = false
        switch rule.kind {
        case .contentsOnly(_, let matcher):
            let dirPath = sizePaths(of: entry).first ?? ""
            let fd = SafeFS.openDirAbsolute(dirPath)
            if fd >= 0 {
                defer { close(fd) }
                for e in SafeFS.enumerate(dirFD: fd) ?? [] where e.stat.isRegularFile && e.name != ".gitignore"
                    && e.name != ".gitkeep" && matcher.matches(e.name) {
                    total += e.stat.blocks * 512
                }
            }
        case .file:
            if let st = SafeFS.lstatAbsolute(sizePaths(of: entry).first ?? ""), st.isRegularFile { total = st.blocks * 512 }
        case .discovered(.derivedDataChildren):
            guard let instance = entry.instance, engine.derived.isValidInstance(instance),
                  entry.packageDir == engine.derived.root() else {
                return SizeResult(bytes: 0, isPartial: true, itemCount: entry.itemCount)
            }
            fallthrough
        case .dir, .dirs, .discovered:
            for path in sizePaths(of: entry) {
                if Task.isCancelled { partial = true; break }
                guard let st = SafeFS.lstatAbsolute(path), st.isDirectory else { continue }   // symlinks are never measured through
                let r = await DirectorySizer.sizeOffActor(of: path)
                total += r.bytes
                partial = partial || r.isPartial
            }
        }
        return SizeResult(bytes: total, isPartial: partial, itemCount: entry.itemCount)
    }
}
