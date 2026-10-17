import Foundation
import Darwin

// MARK: - Trash --------------------------------------------------------------------------

protocol Trashing: Sendable {
    /// Moves `url` to the Trash and returns where the item landed (`nil` when the system does not report it).
    func trash(_ url: URL) throws -> URL?
}

struct FileManagerTrasher: Trashing {
    func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

// MARK: - Cleaner --------------------------------------------------------------------------

/// Tiered cleaner (design §5.5, R3–R21, D1–D14). Every target is re-derived from `(ruleID, packageDir, instance)`;
/// `displayPath`, UI strings and entry fields other than those three never build a path that reaches a syscall. The one
/// use of `displayPath` is to NARROW the targets of rules with several possible targets (`dirs`, discovered) to the paths
/// the user was shown: it can remove a rule-derived target from the set, never add one.
///
/// Per target, in this order: validate (fd checks, git, hard refusals) → measure → blockers → the last slow step (the
/// nested-repository walk for a directory, the git re-qualification of the children for a contents-only rule) → blockers
/// again → synchronous identity pre-check → audit `intent` line → synchronous identity recheck and unlink/trash. Every
/// `await` precedes the last three steps, so nothing suspends between the final `(dev, ino)` check and the removal
/// (Security F-7), and the slow step that decides "may this be removed" sits directly in front of the one audit append
/// (Security N-2, N-3). The second blocker check follows that slow step because the walk can take seconds and a server
/// started in the meantime must still stop the removal (Security F3-2); the first one stays in front of it so that a
/// blocked target never pays for the walk (CodeReview P3-7).
public actor CacheCleaner: CacheCleaning {
    let catalog: CacheCatalog
    let activity: any ActivityChecking
    let audit: any AuditLogging
    let trasher: any Trashing
    let policy: PathPolicy
    let now: @Sendable () -> Date
    let scanLimits: RepositoryScanner.Limits
    let nestedScan: NestedScan

    /// The nested-repository walk of a directory target. The real one runs off the actor for up to `scanLimits.maxSeconds`;
    /// it is injectable so that a test can hold it open at a known point and change the world while it is "running".
    typealias NestedScan = @Sendable (_ path: String, _ expected: FileIdentity, _ rootDev: dev_t,
                                      _ limits: RepositoryScanner.Limits) async -> NestedRepositoryScan
    static let defaultNestedScan: NestedScan = { path, expected, rootDev, limits in
        await RepositoryScanner.scanOffActor(path: path, expected: expected, rootDev: rootDev, limits: limits)
    }

    /// A plan younger than this reports its own byte figure; an older one is re-measured.
    static let planFreshness: TimeInterval = 600
    /// A plan older than this is refused with `CleanupError.planStale`: the user left the sheet open and must review again.
    static let planMaxAge: TimeInterval = 1800
    static let sizingConcurrency = 4
    static let auditFailureText = "denetim günlüğü yazılamıyor"

    public init(catalog: CacheCatalog, activity: any ActivityChecking, audit: any AuditLogging,
                            homeDirectory: String = NSHomeDirectory()) {
        self.init(catalog: catalog, activity: activity, audit: audit, homeDirectory: homeDirectory, trasher: FileManagerTrasher())
    }

    /// Internal overload for tests.
    init(catalog: CacheCatalog, activity: any ActivityChecking, audit: any AuditLogging, homeDirectory: String,
         trasher: any Trashing, now: @escaping @Sendable () -> Date = { Date() },
         scanLimits: RepositoryScanner.Limits = RepositoryScanner.Limits(),
         nestedScan: @escaping NestedScan = CacheCleaner.defaultNestedScan) {
        self.catalog = catalog
        self.activity = activity
        self.audit = audit
        self.trasher = trasher
        self.policy = PathPolicy(homeDirectory: homeDirectory)
        self.now = now
        self.scanLimits = scanLimits
        self.nestedScan = nestedScan
    }

    // MARK: Planning

    public func makePlan(forProjectAt path: String, options: CatalogOptions) async -> CleanupPlan? {
        guard let report = await catalog.report(forProjectAt: path, options: options) else { return nil }
        let sized = await sizeAll(report.entries)
        guard !sized.isEmpty else { return nil }
        // R17: blockers are evaluated at the ceiling (the project root of the report), so hoisted workspaces are covered.
        let blockers = await activity.blockers(for: report.project.root)
        return CleanupPlan(id: UUID(), rootPath: report.project.root, project: report.project, entries: sized,
                           blockers: blockers, createdAt: now(), includesDependencies: options.includeDependencies)
    }

    public func makeOrphanedDerivedDataPlan() async -> CleanupPlan? {
        let entries = await catalog.orphanedDerivedData()
        let sized = await sizeAll(entries)
        guard !sized.isEmpty else { return nil }
        return CleanupPlan(id: UUID(), rootPath: catalog.engine.derived.root(), project: nil, entries: sized,
                           blockers: [], createdAt: now())
    }

    /// 4-way, order-preserving; zero-size (non-partial) entries are dropped (D14).
    private func sizeAll(_ entries: [CacheEntry]) async -> [CacheEntry] {
        let catalog = self.catalog
        var sized = [CacheEntry?](repeating: nil, count: entries.count)
        await withTaskGroup(of: (Int, CacheEntry).self) { group in
            var next = 0
            var running = 0
            while next < entries.count || running > 0 {
                if next < entries.count, running < Self.sizingConcurrency {
                    let i = next
                    let entry = entries[i]
                    next += 1
                    running += 1
                    group.addTask { (i, entry.withSize(await catalog.size(of: entry))) }
                } else if let (i, e) = await group.next() {
                    sized[i] = e
                    running -= 1
                } else {
                    break
                }
            }
        }
        return sized.compactMap { $0 }.filter { !($0.sizeBytes == 0 && !$0.sizeIsPartial) }
    }

    // MARK: Execution

    /// Per-`execute` bookkeeping, only ever touched from the cleaner actor.
    private final class RunState {
        /// An audit line could not be written: nothing further is touched (D12).
        var auditFailed = false
    }

    public func execute(_ plan: CleanupPlan, selections: [CleanupSelection],
                        progress: (@Sendable (CleanupOutcome) -> Void)?) async throws -> CleanupResult {
        do {
            try await ensureCurrent(plan)
        } catch {
            // I-1: a refused plan touched nothing, but "every attempt is logged" (D12) holds for it too (best effort).
            await auditRefusal(plan, error: error)
            throw error
        }

        var outcomes: [CleanupOutcome] = []
        func emit(_ o: CleanupOutcome) {
            outcomes.append(o)
            progress?(o)
        }
        var selectionByID: [String: CleanupSelection] = [:]
        for s in selections where selectionByID[s.entryID] == nil { selectionByID[s.entryID] = s }

        // 1. Audit preflight (D12): without a writable audit log nothing is touched.
        let writable = await audit.isWritable()
        let run = RunState()
        var handled = Set<String>()

        for entry in plan.entries {
            guard let selection = selectionByID[entry.id] else {
                emit(CleanupOutcome(entryID: entry.id, path: entry.packageDir, status: .skipped(.notSelected)))
                continue
            }
            handled.insert(entry.id)
            guard writable, !run.auditFailed else {
                emit(CleanupOutcome(entryID: entry.id, path: entry.packageDir, status: .failed(Self.auditFailureText)))
                continue
            }
            emit(await process(entry, selection: selection, plan: plan, run: run))
        }

        // Selections that name no entry of this plan (forged / stale ids).
        for selection in selections where !handled.contains(selection.entryID) {
            handled.insert(selection.entryID)
            guard writable, !run.auditFailed else {
                emit(CleanupOutcome(entryID: selection.entryID, path: "", status: .failed(Self.auditFailureText)))
                continue
            }
            let status = CleanupStatus.skipped(.notInCatalog)
            let written = await writeAudit(status: status, subject: selection.entryID, entryID: selection.entryID, ruleID: nil,
                                           safety: nil, mode: selection.mode, packageDir: nil, planID: plan.id, facts: nil, bytes: nil)
            if !written { run.auditFailed = true }
            emit(CleanupOutcome(entryID: selection.entryID, path: "", status: written ? status : .failed(Self.auditFailureText)))
        }
        return CleanupResult(planID: plan.id, outcomes: outcomes, finishedAt: now())
    }

    /// Security F-13: a plan that no longer matches the world is refused before anything is touched.
    /// * older than `planMaxAge` (a forgotten sheet);
    /// * a project plan whose root is no longer an acceptable project root (`rootRejected`) or no longer its own ceiling
    ///   (a repository appeared above it);
    /// * the orphaned-DerivedData plan after the DerivedData location changed.
    private func ensureCurrent(_ plan: CleanupPlan) async throws {
        if now().timeIntervalSince(plan.createdAt) > Self.planMaxAge { throw CleanupError.planStale }
        guard plan.project != nil else {
            guard plan.rootPath == catalog.engine.derived.root() else { throw CleanupError.planStale }
            return
        }
        guard let ctx = await catalog.projects.projectContext(for: plan.rootPath) else {
            throw CleanupError.rootRejected(plan.rootPath)
        }
        guard ctx.ceiling == plan.rootPath else { throw CleanupError.planStale }
    }

    /// One `refused:<reason>` line for a plan `ensureCurrent` turned away (nothing was touched). The result is ignored on
    /// purpose: a log that cannot be written changes nothing about a refusal that already happened.
    private func auditRefusal(_ plan: CleanupPlan, error: Error) async {
        let reason: String
        switch error as? CleanupError {
        case .planStale?: reason = "planStale"
        case .rootRejected?: reason = "rootRejected"
        case nil: reason = "error"
        }
        _ = await audit.recordDurably(AuditEvent(time: now(), kind: .cleanup, subject: plan.rootPath, result: "refused:" + reason,
                                                 detail: ["plan": plan.id.uuidString, "entries": String(plan.entries.count)]))
    }

    // MARK: One entry

    private struct DerivedTarget: Sendable {
        let path: String
        let parent: String
        let name: String
        let relative: String
    }

    private struct Validated: Sendable {
        let target: DerivedTarget
        let identity: FileIdentity
        let facts: GitFacts
        let children: [String]      // contents-only: qualifying children
        let bytes: Int64?           // contents-only: measured at validation

        /// The same target with a smaller child list (re-qualification at act time never widens it).
        func narrowed(to kept: [String], bytes: Int64, facts: GitFacts) -> Validated {
            Validated(target: target, identity: identity, facts: facts, children: kept, bytes: bytes)
        }
    }

    private enum Validation: Sendable {
        case ok(Validated)
        case skip(DerivedTarget, SkipReason, GitFacts)
    }

    private struct ActResult {
        var status: CleanupStatus
        var facts: GitFacts
        var bytes: Int64?
        var trashURLs: [URL] = []
        /// The `intent` line could not be written, so nothing was touched; no result line is attempted.
        var auditUnavailable = false
    }

    private enum TargetShape {
        case directory, regularFile, contentsOnly([String], ChildMatcher)

        var isRegularFile: Bool { if case .regularFile = self { return true } else { return false } }
    }

    private func process(_ entry: CacheEntry, selection: CleanupSelection, plan: CleanupPlan, run: RunState) async -> CleanupOutcome {
        let mode = selection.mode
        // 2. Catalog lookup.
        guard let rule = CatalogData.rule(id: entry.ruleID) else {
            return await finishSkip(entry, rule: nil, reason: .notInCatalog, subject: entry.packageDir, mode: mode, plan: plan, run: run)
        }
        // Class C (dependencies) is enforced HERE and not only by the UI (F-13): the plan must have been built with
        // dependencies enabled and the selection must carry the user's "Anladım".
        if rule.safety == .optIn {
            guard plan.includesDependencies else {
                return await finishSkip(entry, rule: rule, reason: .notInCatalog, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
            guard selection.acknowledgedDependencies else {
                return await finishSkip(entry, rule: rule, reason: .notSelected, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
        }
        let isDerivedData = rule.id == CatalogData.derivedDataRuleID
        let ceiling: String
        let targets: [DerivedTarget]

        if isDerivedData {
            // §5.2 global exception: a direct child of the canonical DerivedData root, name rule + parseable info.plist.
            let dd = catalog.engine.derived
            let root = dd.root()
            guard let instance = entry.instance, dd.isValidInstance(instance), PathPolicy.canonical(entry.packageDir) == root,
                  entry.packageDir == root else {
                return await finishSkip(entry, rule: rule, reason: .rootRejected, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
            ceiling = root
            targets = [DerivedTarget(path: root + "/" + instance, parent: root, name: instance, relative: instance)]
        } else {
            // 3. Fresh context (R1/R2) and canonical packageDir inside the plan root (R4).
            guard let ctx = await catalog.projects.projectContext(for: entry.packageDir) else {
                return await finishSkip(entry, rule: rule, reason: .rootRejected, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
            guard PathPolicy.canonical(entry.packageDir) == entry.packageDir,
                  PathPolicy.isInsideOrEqual(entry.packageDir, root: plan.rootPath) else {
                return await finishSkip(entry, rule: rule, reason: .outsideRoot, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
            guard ctx.ceiling == plan.rootPath else {
                return await finishSkip(entry, rule: rule, reason: .rootRejected, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
            ceiling = ctx.ceiling
            // The catalog must still vouch for this rule here (marker files, dependencies, class-C lockfile / no PnP).
            var searchDirs = [entry.packageDir]
            if rule.detect.ancestorOK, let i = ctx.packageDirs.firstIndex(of: entry.packageDir) { searchDirs += ctx.packageDirs[(i + 1)...] }
            guard catalog.engine.evaluator.detect(rule.detect, dirs: searchDirs) != nil else {
                return await finishSkip(entry, rule: rule, reason: .notInCatalog, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
            // 4. Derive targets from the rule table only (R3).
            let derived = deriveTargets(rule: rule, entry: entry, ceiling: ceiling)
            guard derived.allInside else {
                return await finishSkip(entry, rule: rule, reason: .outsideRoot, subject: entry.packageDir, mode: mode, plan: plan, run: run)
            }
            targets = derived.targets
        }
        guard !targets.isEmpty, let rootDev = PathPolicy.device(of: ceiling) else {
            return await finishSkip(entry, rule: rule, reason: .notFound, subject: entry.packageDir, mode: mode, plan: plan, run: run)
        }

        // 5–7. fd-relative checks, git, hard refusals (batched).
        let shape = Self.shape(of: rule)
        let validations = await validate(rule: rule, shape: shape, targets: targets, packageDir: entry.packageDir,
                                         ceiling: ceiling, rootDev: rootDev, skipGit: isDerivedData)

        // 8–11. Per target: measure, nested repositories, activity (R11/R15), intent, identity recheck, act, audit.
        var perTarget: [(path: String, status: CleanupStatus)] = []
        for validation in validations {
            if run.auditFailed {
                switch validation {
                case .skip(let target, _, _): perTarget.append((target.path, .failed(Self.auditFailureText)))
                case .ok(let validated): perTarget.append((validated.target.path, .failed(Self.auditFailureText)))
                }
                continue
            }
            switch validation {
            case .skip(let target, let reason, let facts):
                let status = CleanupStatus.skipped(reason)
                let written = await writeAudit(status: status, subject: target.path, entryID: entry.id, ruleID: rule.id, safety: rule.safety,
                                               mode: mode, packageDir: entry.packageDir, planID: plan.id, facts: facts, bytes: nil)
                if !written { run.auditFailed = true }
                perTarget.append((target.path, written ? status : .failed(Self.auditFailureText)))
            case .ok(let validated):
                let result = await act(validated, rule: rule, shape: shape, mode: mode, entry: entry, plan: plan,
                                       ceiling: ceiling, rootDev: rootDev, singleTarget: targets.count == 1,
                                       skipGit: isDerivedData)
                if result.auditUnavailable {
                    run.auditFailed = true
                    perTarget.append((validated.target.path, result.status))
                    continue
                }
                let written = await writeAudit(status: result.status, subject: validated.target.path, entryID: entry.id, ruleID: rule.id,
                                               safety: rule.safety, mode: mode, packageDir: entry.packageDir, planID: plan.id,
                                               facts: result.facts, bytes: result.bytes, trashURLs: result.trashURLs)
                // The act already happened: its real status stands, but nothing further is touched without a log.
                if !written { run.auditFailed = true }
                perTarget.append((validated.target.path, result.status))
            }
        }
        let path = targets.count == 1 ? targets[0].path : entry.packageDir
        return CleanupOutcome(entryID: entry.id, path: path, status: Self.aggregate(perTarget.map(\.status)))
    }

    private func finishSkip(_ entry: CacheEntry, rule: CacheRule?, reason: SkipReason, subject: String,
                            mode: DeleteMode, plan: CleanupPlan, run: RunState) async -> CleanupOutcome {
        let status = CleanupStatus.skipped(reason)
        let written = await writeAudit(status: status, subject: subject, entryID: entry.id, ruleID: entry.ruleID, safety: rule?.safety,
                                       mode: mode, packageDir: entry.packageDir, planID: plan.id, facts: nil, bytes: nil)
        if !written { run.auditFailed = true }
        return CleanupOutcome(entryID: entry.id, path: subject, status: written ? status : .failed(Self.auditFailureText))
    }

    // MARK: Derivation (R3)

    private static func shape(of rule: CacheRule) -> TargetShape {
        switch rule.kind {
        case .dir, .dirs, .discovered: return .directory
        case .file: return .regularFile
        case .contentsOnly(let comps, let matcher): return .contentsOnly(comps, matcher)
        }
    }

    private func deriveTargets(rule: CacheRule, entry: CacheEntry, ceiling: String) -> (targets: [DerivedTarget], allInside: Bool) {
        let packageDir = entry.packageDir
        switch rule.kind {
        case .dir, .dirs, .file, .contentsOnly:
            // A rule with several possible targets is narrowed to the ones the entry listed (they were shown to the user);
            // a single-target rule has nothing to narrow, so `displayPath` is ignored for it (D1).
            var listed: Set<String>?
            if case .dirs = rule.kind { listed = Set(entry.listedRelativePaths) }
            var out: [DerivedTarget] = []
            var inside = true
            for comps in rule.allComponentLists {
                guard let name = comps.last else { continue }
                let rel = comps.joined(separator: "/")
                if let listed, !listed.contains(rel) { continue }
                let path = packageDir + "/" + rel
                if !PathPolicy.isStrictlyInside(path, root: ceiling) { inside = false }
                out.append(DerivedTarget(path: path, parent: PathPolicy.parent(of: path), name: name, relative: rel))
            }
            return (out, inside)
        case .discovered:
            let found = catalog.engine.evaluator.discoveredTargets(rule: rule, packageDir: packageDir, ceiling: ceiling,
                                                                   listed: entry.listedRelativePaths)
            let out = found.map { DerivedTarget(path: $0.path, parent: $0.parent, name: $0.name, relative: $0.relative) }
            return (out, true)
        }
    }

    // MARK: Validation (steps 5–7)

    private func validate(rule: CacheRule, shape: TargetShape, targets: [DerivedTarget], packageDir: String,
                          ceiling: String, rootDev: dev_t, skipGit: Bool) async -> [Validation] {
        let evaluator = catalog.engine.evaluator
        let requireIgnored = rule.safety != .always
        var results: [(Int, Validation)] = []
        var gitCandidates: [(index: Int, target: DerivedTarget, identity: FileIdentity)] = []

        for (i, t) in targets.enumerated() {
            // 7. Hard refusals (R12).
            if t.name == ".git" || PathPolicy.isInsideOrEqual(ceiling + "/.git", root: t.path)
                || PathPolicy.isInsideOrEqual(policy.home, root: t.path) {
                results.append((i, .skip(t, .rootRejected, GitFacts())))
                continue
            }
            // QA F1: the package's own manifest points at this build output (read fresh, so a change after the plan counts).
            if !skipGit, evaluator.isPackageExportTarget(rule: rule, relative: t.relative, packageDir: packageDir) {
                results.append((i, .skip(t, .packageOutput, GitFacts())))
                continue
            }
            switch shape {
            case .contentsOnly(let comps, let matcher):
                let q = await evaluator.qualifyChildren(comps: comps, matcher: matcher, packageDir: packageDir,
                                                        ceiling: ceiling, rootDev: rootDev)
                if let r = q.rejection, q.children.isEmpty {
                    results.append((i, .skip(t, r, q.facts)))
                } else if let id = Self.directoryIdentity(of: t, rootDev: rootDev) {
                    results.append((i, .ok(Validated(target: t, identity: id, facts: q.facts, children: q.children, bytes: q.bytes))))
                } else {
                    results.append((i, .skip(t, .notFound, q.facts)))
                }
            case .directory, .regularFile:
                let expect: ExpectedType = { if case .regularFile = shape { return .regularFile } else { return .directory } }()
                switch SafeFS.openTarget(parent: t.parent, name: t.name, expect: expect, rootDev: rootDev) {
                case .skip(let reason):
                    results.append((i, .skip(t, reason, GitFacts())))
                case .ok(let fd, let st):
                    close(fd)
                    if case .regularFile = shape, !CacheEvaluator.laravelHotContentOK(t.path) {
                        results.append((i, .skip(t, .notFound, GitFacts())))
                    } else {
                        gitCandidates.append((i, t, st.identity))
                    }
                }
            }
        }

        // 6. Git (R10 / D7), grouped per git working directory so the nearest repository answers.
        if skipGit {
            for c in gitCandidates { results.append((c.index, .ok(Validated(target: c.target, identity: c.identity, facts: GitFacts(), children: [], bytes: nil)))) }
        } else {
            let discovered: Bool = { if case .discovered = rule.kind { return true } else { return false } }()
            // Discovered targets share one cwd (packageDir) and are asked as relative paths; literal targets are asked per parent.
            var groups: [String: [(index: Int, target: DerivedTarget, identity: FileIdentity)]] = [:]
            for c in gitCandidates { groups[discovered ? packageDir : c.target.parent, default: []].append(c) }
            for cwd in groups.keys.sorted() {
                let members = groups[cwd] ?? []
                let names = members.map { discovered ? $0.target.relative : $0.target.name }
                let verdicts = await evaluator.git.check(parent: cwd, names: names, requireIgnored: requireIgnored)
                for (m, name) in zip(members, names) {
                    switch verdicts[name] {
                    case .pass(let facts)?:
                        results.append((m.index, .ok(Validated(target: m.target, identity: m.identity, facts: facts, children: [], bytes: nil))))
                    case .reject(let reason, let facts)?:
                        results.append((m.index, .skip(m.target, reason, facts)))
                    case nil:
                        results.append((m.index, .skip(m.target, .gitUnavailable, GitFacts())))
                    }
                }
            }
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func directoryIdentity(of t: DerivedTarget, rootDev: dev_t) -> FileIdentity? {
        guard case .ok(let fd, let st) = SafeFS.openTarget(parent: t.parent, name: t.name, expect: .directory, rootDev: rootDev) else { return nil }
        close(fd)
        return st.identity
    }

    // MARK: Act

    /// Order per attempt: measure → blockers → the last slow step (nested-repository walk / git re-qualification) →
    /// blockers again → identity pre-check → intent → identity recheck + removal. Every suspension point is in the first
    /// four; what follows them never suspends except for the one audit append.
    /// * The first blocker check precedes the walk, so a target that is blocked never pays for the traversal (CodeReview P3-7).
    /// * The walk (directories) or the re-qualification of the children (contents-only) is the LAST slow step, directly in
    ///   front of the `intent` line, so a repository or worktree created — or a child that git started tracking — while the
    ///   earlier awaits ran is still seen (Security N-2, N-3). The walk is bounded at 20 s and fails closed.
    /// * The second blocker check follows that step: the verdict of the first one can be 20 s old by then, and a server
    ///   (or a container with a bind mount) that started during the walk must still refuse the removal (Security F3-2,
    ///   CodeReview P3-11). A regular-file target has no slow step, so its single check is already the fresh one.
    private func act(_ validated: Validated, rule: CacheRule, shape: TargetShape, mode: DeleteMode, entry: CacheEntry,
                     plan: CleanupPlan, ceiling: String, rootDev: dev_t, singleTarget: Bool,
                     skipGit: Bool) async -> ActResult {
        var current = validated
        let expect: ExpectedType = { if case .regularFile = shape { return .regularFile } else { return .directory } }()
        let isDirectory: Bool = { if case .directory = shape { return true } else { return false } }()

        for attempt in 0..<2 {
            var identityMoved = false

            // 1. Measure first (F-7a): a slow size walk must not sit between the checks and the removal.
            var measured: Int64?
            if isDirectory { measured = await measuredBytes(current, entry: entry, plan: plan, singleTarget: singleTarget) }
            let bytes = measured

            // 2. Activity (D8/R11/R15): fresh, for this target. DerivedData is exempt.
            if !skipGit, await isBlocked(ceiling: ceiling, safety: rule.safety) {
                return ActResult(status: .skipped(.blockedByActivity), facts: current.facts, bytes: nil)
            }

            // 3. The last slow step.
            switch shape {
            case .directory:
                // R12 / F-2: nothing that contains another repository or worktree is ever removed. DerivedData is exempt:
                // Xcode keeps SwiftPM clones under `SourcePackages` by design and regenerates them.
                guard !skipGit else { break }
                switch await nestedScan(current.target.path, current.identity, rootDev, scanLimits) {
                case .clean:
                    break
                case .found:
                    return ActResult(status: .skipped(.containsRepository), facts: current.facts, bytes: nil)
                case .inconclusive:
                    return ActResult(status: .skipped(.scanIncomplete), facts: current.facts, bytes: nil)
                case .unreadable:
                    switch SafeFS.openTarget(parent: current.target.parent, name: current.target.name, expect: expect, rootDev: rootDev) {
                    case .skip(let reason):
                        return ActResult(status: .skipped(reason), facts: current.facts, bytes: nil)
                    case .ok(let fd, _):
                        close(fd)
                        return ActResult(status: .skipped(.notFound), facts: current.facts, bytes: nil)
                    }
                case .identityChanged:
                    identityMoved = true
                }
            case .contentsOnly(let comps, let matcher):
                // N-3: the children were qualified by git when the run started; ask again now. A child that became tracked
                // (or stopped being ignored) since is left alone, and nothing that was not on the validated list is added.
                let fresh = await catalog.engine.evaluator.qualifyChildren(comps: comps, matcher: matcher, packageDir: entry.packageDir,
                                                                           ceiling: ceiling, rootDev: rootDev)
                let stillQualifying = Set(fresh.children)
                let kept = current.children.filter { stillQualifying.contains($0) }
                guard !kept.isEmpty else {
                    return ActResult(status: .skipped(fresh.rejection ?? .emptyAlready), facts: fresh.facts, bytes: nil)
                }
                current = current.narrowed(to: kept, bytes: kept.reduce(Int64(0)) { $0 + (fresh.childBytes[$1] ?? 0) },
                                           facts: fresh.facts)
            case .regularFile:
                break
            }

            // 3b. Activity again (F3-2): the step above may have taken seconds. Skipped when the identity moved: the attempt
            // is thrown away and the next one starts with its own check.
            if !skipGit, !identityMoved, !shape.isRegularFile, await isBlocked(ceiling: ceiling, safety: rule.safety) {
                return ActResult(status: .skipped(.blockedByActivity), facts: current.facts, bytes: nil)
            }

            // 4. Identity pre-check (D11) — synchronous, so a mismatch costs no `intent` line.
            if !identityMoved {
                switch SafeFS.openTarget(parent: current.target.parent, name: current.target.name, expect: expect, rootDev: rootDev) {
                case .skip(let reason):
                    return ActResult(status: .skipped(reason), facts: current.facts, bytes: nil)
                case .ok(let fd, let st):
                    close(fd)
                    if st.identity != current.identity { identityMoved = true }
                }
            }
            if identityMoved {
                if attempt == 1 { return ActResult(status: .skipped(.identityChanged), facts: current.facts, bytes: nil) }
                let again = await validate(rule: rule, shape: shape, targets: [current.target], packageDir: entry.packageDir,
                                           ceiling: ceiling, rootDev: rootDev, skipGit: skipGit)
                guard case .ok(let fresh)? = again.first else {
                    if case .skip(_, let reason, let facts)? = again.first { return ActResult(status: .skipped(reason), facts: facts, bytes: nil) }
                    return ActResult(status: .skipped(.identityChanged), facts: current.facts, bytes: nil)
                }
                current = fresh
                continue
            }

            // 5. Audit intent (F-5): logged BEFORE the removal; without it nothing is touched.
            guard await audit.recordDurably(intentEvent(target: current.target, rule: rule, entry: entry, mode: mode, plan: plan, bytes: bytes)) else {
                return ActResult(status: .failed(Self.auditFailureText), facts: current.facts, bytes: nil, auditUnavailable: true)
            }

            // 6. From here on nothing suspends: identity recheck, then the removal.
            switch SafeFS.openTarget(parent: current.target.parent, name: current.target.name, expect: expect, rootDev: rootDev) {
            case .skip(let reason):
                return ActResult(status: .skipped(reason), facts: current.facts, bytes: nil)
            case .ok(let parentFD, let st):
                defer { close(parentFD) }
                guard st.identity == current.identity else {
                    return ActResult(status: .skipped(.identityChanged), facts: current.facts, bytes: nil)
                }
                let done = perform(current, shape: shape, mode: mode, parentFD: parentFD, stat: st, rootDev: rootDev, bytes: bytes)
                return ActResult(status: done.status, facts: current.facts, bytes: done.bytes, trashURLs: done.trashURLs)
            }
        }
        return ActResult(status: .skipped(.identityChanged), facts: current.facts, bytes: nil)
    }

    /// D8 / R11 / R15: a fresh activity snapshot of the ceiling, asked once per call (never cached across the slow step).
    private func isBlocked(ceiling: String, safety: CacheSafety) async -> Bool {
        await activity.blockers(for: ceiling).contains { $0.blocks(safety) }
    }

    /// Step 1: the plan size when it is < 10 minutes old and the entry has one target; otherwise re-measured.
    private func measuredBytes(_ v: Validated, entry: CacheEntry, plan: CleanupPlan, singleTarget: Bool) async -> Int64 {
        if singleTarget, let planned = entry.sizeBytes, now().timeIntervalSince(plan.createdAt) < Self.planFreshness {
            return planned
        }
        return await DirectorySizer.sizeOffActor(of: v.target.path).bytes
    }

    private struct Performed {
        var status: CleanupStatus
        var bytes: Int64?
        var trashURLs: [URL] = []
    }

    /// The act itself. `parentFD` is an `O_NOFOLLOW_ANY` descriptor of the target's parent (D3).
    private func perform(_ v: Validated, shape: TargetShape, mode: DeleteMode, parentFD: Int32, stat st: FileStat,
                         rootDev: dev_t, bytes: Int64?) -> Performed {
        switch shape {
        case .directory:
            let size = bytes ?? 0
            let success: CleanupStatus = mode == .permanent ? .deleted(bytes: size) : .movedToTrash(bytes: size)
            if mode == .trash {
                let r = trashStatus(URL(fileURLWithPath: v.target.path), success: success)
                return Performed(status: r.status, bytes: size, trashURLs: r.url.map { [$0] } ?? [])
            }
            do {
                try SafeFS.removeTree(parentFD: parentFD, name: v.target.name, rootDev: rootDev, expected: v.identity)
                return Performed(status: success, bytes: size)
            } catch let f as SafeFSFailure {
                switch f {
                case .crossesDevice: return Performed(status: .skipped(.crossesDevice))
                case .notDirectory: return Performed(status: .skipped(.symlink))
                case .identityChanged: return Performed(status: .skipped(.identityChanged))
                default: return Performed(status: .failed(f.text))
                }
            } catch {
                return Performed(status: .failed(String(describing: error)))
            }
        case .regularFile:
            let size = st.blocks * 512
            let success: CleanupStatus = mode == .permanent ? .deleted(bytes: size) : .movedToTrash(bytes: size)
            if mode == .trash {
                let r = trashStatus(URL(fileURLWithPath: v.target.path), success: success)
                return Performed(status: r.status, bytes: size, trashURLs: r.url.map { [$0] } ?? [])
            }
            do {
                try SafeFS.unlinkFile(dirFD: parentFD, name: v.target.name)
                return Performed(status: success, bytes: size)
            } catch let f as SafeFSFailure {
                return Performed(status: .failed(f.text))
            } catch {
                return Performed(status: .failed(String(describing: error)))
            }
        case .contentsOnly:
            let size = v.bytes ?? 0
            let success: CleanupStatus = mode == .permanent ? .deleted(bytes: size) : .movedToTrash(bytes: size)
            let dirFD = SafeFS.openDirAt(parentFD, v.target.name)
            guard dirFD >= 0 else { return Performed(status: .skipped(.symlink)) }
            defer { close(dirFD) }
            var firstError: String?
            var urls: [URL] = []
            for child in v.children {
                // R13: the child must still be a regular, non-symlink, unflagged file on the root's device.
                guard let cst = SafeFS.statNoFollow(dirFD: dirFD, name: child), cst.isRegularFile, !cst.hasProtectedFlags, cst.dev == rootDev,
                      SafeFS.directoryContains(dirFD: dirFD, name: child) else { continue }
                if mode == .trash {
                    let r = trashStatus(URL(fileURLWithPath: v.target.path + "/" + child), success: success)
                    if case .failed(let text) = r.status, firstError == nil { firstError = text }
                    if let url = r.url { urls.append(url) }
                } else {
                    do { try SafeFS.unlinkFile(dirFD: dirFD, name: child) } catch let f as SafeFSFailure {
                        if firstError == nil { firstError = f.text }
                    } catch {
                        if firstError == nil { firstError = String(describing: error) }
                    }
                }
            }
            if let e = firstError { return Performed(status: .failed(e), bytes: size, trashURLs: urls) }
            return Performed(status: success, bytes: size, trashURLs: urls)
        }
    }

    /// R19: a Trash error is a failure, NEVER a fallback to permanent removal. `url` is where the item landed (QA F4).
    private func trashStatus(_ url: URL, success: CleanupStatus) -> (status: CleanupStatus, url: URL?) {
        do {
            let landed = try trasher.trash(url)
            return (success, landed)
        } catch {
            return (.failed(Self.describe(error)), nil)
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return ns.localizedDescription.isEmpty ? String(describing: error) : ns.localizedDescription
    }

    // MARK: Aggregation & audit

    /// failed > deleted > trashed > first skip.
    private static func aggregate(_ statuses: [CleanupStatus]) -> CleanupStatus {
        var deleted: Int64 = 0, trashed: Int64 = 0
        var anyDeleted = false, anyTrashed = false
        var firstSkip: CleanupStatus?
        for s in statuses {
            switch s {
            case .failed: return s
            case .deleted(let b): deleted += b; anyDeleted = true
            case .movedToTrash(let b): trashed += b; anyTrashed = true
            case .skipped: if firstSkip == nil { firstSkip = s }
            }
        }
        if anyDeleted { return .deleted(bytes: deleted) }
        if anyTrashed { return .movedToTrash(bytes: trashed) }
        return firstSkip ?? .skipped(.notFound)
    }

    private static func classLetter(_ s: CacheSafety) -> String {
        switch s {
        case .always: return "A"
        case .conditional: return "B"
        case .optIn: return "C"
        }
    }

    /// The line written BEFORE a removal (F-5): `result == "intent"`, followed by exactly one result line for the target.
    private func intentEvent(target: DerivedTarget, rule: CacheRule, entry: CacheEntry, mode: DeleteMode, plan: CleanupPlan,
                             bytes: Int64?) -> AuditEvent {
        var detail: [String: String] = ["mode": mode.rawValue, "entry": entry.id, "plan": plan.id.uuidString,
                                        "rule": rule.id, "class": Self.classLetter(rule.safety), "packageDir": entry.packageDir]
        if let b = bytes { detail["bytes"] = String(b) }
        return AuditEvent(time: now(), kind: .cleanup, subject: target.path, result: "intent", detail: detail)
    }

    /// Security F3-6: at most this many Trash locations, and at most this many UTF-8 bytes of them (line breaks included),
    /// go into one audit line. A contents-only Trash move yields one location per child — thousands for a large Laravel
    /// `storage/framework/views` — and a single line of that size would push the log's rotation forward by itself.
    static let auditTrashURLLimit = 50
    static let auditTrashURLBytes = 8 * 1024

    /// The `trashURL` value for one audit line: a PREFIX of `paths` (so after a part-way failure the first locations are
    /// the ones that were moved first) within both bounds, followed by a `+N more` line counting the rest. The items stay in
    /// the Trash, recoverable by name; only their listing in the log is cut.
    static func boundedTrashURLField(_ paths: [String], limit: Int = auditTrashURLLimit,
                                     maxBytes: Int = auditTrashURLBytes) -> String {
        var kept: [String] = []
        var used = 0
        for path in paths {
            let cost = path.utf8.count + (kept.isEmpty ? 0 : 1)
            guard kept.count < limit, used + cost <= maxBytes else { break }
            kept.append(path)
            used += cost
        }
        let omitted = paths.count - kept.count
        if omitted > 0 { kept.append("+\(omitted) more") }
        return kept.joined(separator: "\n")
    }

    /// `true` only when the line reached the log.
    private func writeAudit(status: CleanupStatus, subject: String, entryID: String, ruleID: String?, safety: CacheSafety?,
                            mode: DeleteMode, packageDir: String?, planID: UUID, facts: GitFacts?, bytes: Int64?,
                            trashURLs: [URL] = []) async -> Bool {
        var detail: [String: String] = ["mode": mode.rawValue, "entry": entryID, "plan": planID.uuidString]
        if let r = ruleID { detail["rule"] = r }
        if let s = safety { detail["class"] = Self.classLetter(s) }
        if let p = packageDir { detail["packageDir"] = p }
        if let f = facts { for (k, v) in f.detail { detail[k] = v } }
        let result: String
        switch status {
        case .deleted(let b):
            result = "deleted"
            detail["bytes"] = String(b)
        case .movedToTrash(let b):
            result = "trashed"
            detail["bytes"] = String(b)
        case .skipped(let reason):
            result = "skipped:\(reason.rawValue)"
        case .failed(let text):
            result = "failed:\(text)"
        }
        // QA F4 / N-4: where the items landed, for every result that moved something — a contents-only trash that fails
        // part-way has already moved some children, and the log is the only place that says where they are. Several items
        // are separated by a line break; the list is bounded (F3-6).
        if !trashURLs.isEmpty {
            detail["trashURL"] = Self.boundedTrashURLField(trashURLs.map(\.path))
        } else if case .movedToTrash = status {
            detail["trashURL"] = "unreported"
        }
        if let b = bytes, detail["bytes"] == nil { detail["bytes"] = String(b) }
        return await audit.recordDurably(AuditEvent(time: now(), kind: .cleanup, subject: subject, result: result, detail: detail))
    }
}
