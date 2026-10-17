import Foundation
import Darwin
import Testing
@testable import DevTidyCore

private final class S2Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func add(_ v: Bool) { lock.withLock { items.append(v) } }
    var values: [Bool] { lock.withLock { items } }
}

struct S2NestedRepoCase: Sendable, CustomTestStringConvertible {
    enum Kind: Sendable { case gitDirectory, gitlinkFile, symlinkNamedGit }
    let name: String
    /// Path of the `.git` entry relative to the project.
    let relative: String
    let kind: Kind
    var testDescription: String { name }
}

@Suite("CacheCleaner safety (R12 nested repositories, F-5 audit, F-13 plan, P2-8 listing)")
struct CacheCleanerSafetyTests {
    static let nestedCases: [S2NestedRepoCase] = [
        .init(name: ".git directory right inside the target", relative: "dist/.git", kind: .gitDirectory),
        .init(name: ".git gitlink file of a worktree", relative: "dist/.git", kind: .gitlinkFile),
        .init(name: "repository five levels down", relative: "dist/a/b/c/d/.git", kind: .gitDirectory),
        .init(name: "symlink named .git", relative: "dist/pkg/.git", kind: .symlinkNamedGit),
    ]

    // MARK: Helpers

    private func plan(_ env: S2Env, at path: String? = nil, includeDependencies: Bool = false) async throws -> CleanupPlan {
        var o = CatalogOptions()
        o.includeDerivedData = false
        o.includeDependencies = includeDependencies
        return try #require(await env.cleaner.makePlan(forProjectAt: path ?? env.tmp.project, options: o))
    }

    private func select(_ plan: CleanupPlan, only ruleIDs: Set<String>? = nil, mode: DeleteMode? = nil,
                        acknowledged: Bool = true) -> [CleanupSelection] {
        plan.entries.filter { ruleIDs?.contains($0.ruleID) ?? true }.map {
            CleanupSelection(entryID: $0.id, mode: mode ?? $0.defaultMode, acknowledgedDependencies: acknowledged && $0.safety == .optIn)
        }
    }

    private func entry(_ plan: CleanupPlan, _ ruleID: String) throws -> CacheEntry {
        try #require(plan.entries.first { $0.ruleID == ruleID }, "no \(ruleID) in plan: \(plan.entries.map(\.ruleID))")
    }

    private func outcome(_ result: CleanupResult, _ entry: CacheEntry) throws -> CleanupOutcome {
        try #require(result.outcomes.first { $0.entryID == entry.id })
    }

    private func block(_ n: Int = 4096) -> String { String(repeating: "x", count: n) }

    /// A class B `dist`: bundler marker, git-ignored, clean.
    private func distProject(_ env: S2Env) throws {
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["left-pad"], buildScript: true)
        try env.tmp.write(env.tmp.p("dist/index.js"), block())
        env.git.ignored = [env.tmp.p("dist")]
    }

    private func buildNested(_ env: S2Env, _ c: S2NestedRepoCase) throws {
        let path = env.tmp.p(c.relative)
        switch c.kind {
        case .gitDirectory:
            try env.tmp.write(path + "/HEAD", "ref: refs/heads/gh-pages")
        case .gitlinkFile:
            try env.tmp.write(path, "gitdir: \(env.tmp.root)/main/.git/worktrees/dist")
        case .symlinkNamedGit:
            try env.tmp.write(env.tmp.root + "/outside/x", "x")
            try env.tmp.symlink(path, to: env.tmp.root + "/outside")
        }
    }

    private func nodeModulesProject(_ env: S2Env) throws {
        try env.tmp.packageJSON(at: env.tmp.project)
        try env.tmp.write(env.tmp.p("package-lock.json"), "{}")
        try env.tmp.write(env.tmp.p("node_modules/dep/index.js"), block())
        env.git.ignored = [env.tmp.p("node_modules")]
    }

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    // MARK: R12 / F-2 — nested repositories and worktrees

    @Test func aDistWithoutANestedRepositoryIsRemoved() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try distProject(env)
        let p = try await plan(env)
        let e = try entry(p, "dist.generic")
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted, got \(try outcome(r, e).status)"); return }
        #expect(!env.tmp.exists(env.tmp.p("dist")))
    }

    @Test(arguments: CacheCleanerSafetyTests.nestedCases)
    func aTargetContainingANestedRepositoryOrWorktreeIsNeverRemoved(_ c: S2NestedRepoCase) async throws {
        for mode in [DeleteMode.trash, DeleteMode.permanent] {
            let env = try S2Env()
            defer { env.tmp.cleanup() }
            try distProject(env)
            try buildNested(env, c)
            let p = try await plan(env)
            let e = try entry(p, "dist.generic")      // the OUTER repository's gates all pass: only the pre-walk can see it
            let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: mode)], progress: nil)
            #expect(try outcome(r, e).status == .skipped(.containsRepository), "\(c.name) / \(mode)")
            #expect(env.tmp.exists(env.tmp.p("dist/index.js")), "\(c.name) / \(mode)")
            #expect(env.tmp.exists(env.tmp.p(c.relative)), "the nested repository survives (\(c.name) / \(mode))")
            #expect(env.trasher.trashed.isEmpty)
            #expect(env.audit.events.map(\.result) == ["skipped:containsRepository"], "refused before any intent line")
            #expect(r.freedBytes == 0 && r.trashedBytes == 0)
        }
    }

    @Test func classAIsRefusedWhenItHoldsARepositoryToo() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        try env.tmp.write(env.tmp.p(".next/cache/clone/.git/HEAD"), "ref: refs/heads/main")
        let p = try await plan(env)
        let e = try entry(p, "next.cache")
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        #expect(try outcome(r, e).status == .skipped(.containsRepository))
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")) && env.tmp.exists(env.tmp.p(".next/cache/clone/.git/HEAD")))
    }

    @Test func aVendorDirectoryWithAClonedPackageIsRefusedEvenWithOptInAndAcknowledgement() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("composer.json"), "{}")
        try env.tmp.write(env.tmp.p("composer.lock"), "{}")
        try env.tmp.write(env.tmp.p("vendor/acme/lib/src.php"), block())
        try env.tmp.write(env.tmp.p("vendor/acme/lib/.git/HEAD"), "ref: refs/heads/main")     // composer --prefer-source
        env.git.ignored = [env.tmp.p("vendor")]
        let p = try await plan(env, includeDependencies: true)
        let e = try entry(p, "php.vendor")
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        #expect(try outcome(r, e).status == .skipped(.containsRepository))
        #expect(env.tmp.exists(env.tmp.p("vendor/acme/lib/src.php")) && env.tmp.exists(env.tmp.p("vendor/acme/lib/.git/HEAD")))
    }

    @Test func aWalkThatCannotFinishWithinItsBoundsFailsClosed() async throws {
        let env = try S2Env(scanLimits: RepositoryScanner.Limits(maxEntries: 1))
        defer { env.tmp.cleanup() }
        try distProject(env)
        try env.tmp.write(env.tmp.p("dist/a.js"), block())
        try env.tmp.write(env.tmp.p("dist/b.js"), block())
        let p = try await plan(env)
        let e = try entry(p, "dist.generic")
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        #expect(try outcome(r, e).status == .skipped(.scanIncomplete), "an unproven target is not removed")
        #expect(env.tmp.exists(env.tmp.p("dist/index.js")))
    }

    /// Xcode keeps SwiftPM clones under `SourcePackages` by design and regenerates them: DerivedData is exempt.
    @Test func derivedDataIsExemptFromTheNestedRepositoryRefusal() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let orphan = "Gone1-abcdefghijklmnopqrstuvwxyzab"
        let root = env.derivedRoot
        try env.tmp.write(root + "/" + orphan + "/Build/x.o", block())
        try env.tmp.write(root + "/" + orphan + "/SourcePackages/checkouts/pkg/.git/HEAD", "ref: refs/heads/main")
        try plist(["WorkspacePath": env.tmp.home + "/dev/deleted/Gone.xcworkspace"]).write(to: URL(fileURLWithPath: root + "/" + orphan + "/info.plist"))
        let p = try #require(await env.cleaner.makeOrphanedDerivedDataPlan())
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = r.outcomes[0].status else { Issue.record("expected deleted, got \(r.outcomes[0].status)"); return }
        #expect(!env.tmp.exists(root + "/" + orphan))
    }

    // MARK: F-13 — class C and plan staleness are enforced by the cleaner

    @Test func classCIsEnforcedByTheCleanerAndNotOnlyByTheUI() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try nodeModulesProject(env)
        let p = try await plan(env, includeDependencies: true)
        let e = try entry(p, "node.modules")
        #expect(p.includesDependencies)

        // a plan that was not built with dependencies enabled
        let withoutOptIn = CleanupPlan(id: p.id, rootPath: p.rootPath, project: p.project, entries: p.entries, blockers: p.blockers,
                                       createdAt: p.createdAt, includesDependencies: false)
        let r1 = try await env.cleaner.execute(withoutOptIn, selections: select(withoutOptIn), progress: nil)
        #expect(try outcome(r1, e).status == .skipped(.notInCatalog))

        // a selection without the user's "Anladım"
        let r2 = try await env.cleaner.execute(p, selections: select(p, acknowledged: false), progress: nil)
        #expect(try outcome(r2, e).status == .skipped(.notSelected))
        #expect(env.tmp.exists(env.tmp.p("node_modules/dep/index.js")), "neither refusal touched anything")
        #expect(env.audit.events.map(\.result) == ["skipped:notInCatalog", "skipped:notSelected"])

        // both gates open
        let r3 = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = try outcome(r3, e).status else { Issue.record("expected deleted, got \(try outcome(r3, e).status)"); return }
        #expect(!env.tmp.exists(env.tmp.p("node_modules")))
    }

    @Test func aPlanOlderThanItsMaximumAgeIsRefusedBeforeAnythingIsTouched() async throws {
        let clock = S2Clock()
        let env = try S2Env(clock: clock)
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        clock.advance(CacheCleaner.planMaxAge - 1)
        let ok = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = ok.outcomes[0].status else { Issue.record("a plan inside the limit executes, got \(ok.outcomes[0].status)"); return }

        try env.makeNextProject()
        let p2 = try await plan(env)
        clock.advance(CacheCleaner.planMaxAge + 1)
        let linesBefore = env.audit.events.count
        await #expect(throws: CleanupError.planStale) {
            _ = try await env.cleaner.execute(p2, selections: select(p2), progress: nil)
        }
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")))
        // I-1: the refusal itself is logged (one line, no intent), so "every attempt is logged" holds for it too
        let refusal = Array(env.audit.events.dropFirst(linesBefore))
        #expect(refusal.map(\.result) == ["refused:planStale"])
        #expect(refusal.first?.subject == p2.rootPath)
        #expect(refusal.first?.detail["plan"] == p2.id.uuidString)
        #expect(refusal.first?.detail["entries"] == String(p2.entries.count))
    }

    @Test func aProjectPlanWhoseCeilingMovedIsStale() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        let app = env.tmp.p("apps/web")
        try env.tmp.packageJSON(at: app, deps: ["next"])
        try env.tmp.write(app + "/.next/x", block())
        let p = try await plan(env, at: app)
        #expect(p.rootPath == app)
        // a repository now exists above the app: the plan's root is no longer its own ceiling
        env.git.toplevelResult = .repository(env.tmp.project)
        await #expect(throws: CleanupError.planStale) {
            _ = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        }
        #expect(env.tmp.exists(app + "/.next/x"))
        #expect(env.audit.events.map(\.result) == ["refused:planStale"], "a refusal is logged, nothing else is")
    }

    @Test func aPlanWhoseRootIsNoLongerAcceptableIsRejected() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        try FileManager.default.removeItem(atPath: env.tmp.project)
        await #expect(throws: CleanupError.rootRejected(env.tmp.project)) {
            _ = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        }
        #expect(env.audit.events.map(\.result) == ["refused:rootRejected"], "a refusal is logged, nothing else is")
        #expect(env.audit.events.first?.subject == p.rootPath)
    }

    @Test func anOrphanPlanForAnotherDerivedDataLocationIsStale() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let orphan = "Gone1-abcdefghijklmnopqrstuvwxyzab"
        try env.tmp.write(env.derivedRoot + "/" + orphan + "/Build/x.o", block())
        try plist(["WorkspacePath": env.tmp.home + "/dev/deleted/Gone.xcworkspace"])
            .write(to: URL(fileURLWithPath: env.derivedRoot + "/" + orphan + "/info.plist"))
        let p = try #require(await env.cleaner.makeOrphanedDerivedDataPlan())
        let moved = CleanupPlan(id: p.id, rootPath: env.tmp.root + "/OtherDerivedData", project: nil, entries: p.entries,
                                blockers: [], createdAt: p.createdAt)
        await #expect(throws: CleanupError.planStale) {
            _ = try await env.cleaner.execute(moved, selections: select(moved), progress: nil)
        }
        #expect(env.tmp.exists(env.derivedRoot + "/" + orphan + "/Build/x.o"))
    }

    // MARK: F-5 — the audit trail is written before the act and stops the run when it breaks

    @Test func theIntentLineIsWrittenBeforeTheRemoval() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        let next = env.tmp.p(".next")
        let presentAtIntent = S2Probe()
        env.audit.onRecord = { event in if event.result == "intent" { presentAtIntent.add(FileManager.default.fileExists(atPath: next)) } }
        _ = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        #expect(presentAtIntent.values == [true], "when the intent line is written the directory is still there")
        #expect(!env.tmp.exists(next))
        #expect(env.audit.events.map(\.result) == ["intent", "deleted"])
        #expect(env.audit.intentLines.first?.detail["rule"] == "next.cache")
        #expect(env.audit.intentLines.first?.detail["mode"] == "permanent")
    }

    private func twoEntries(_ env: S2Env) async throws -> CleanupPlan {
        try env.makeNextProject()
        try env.tmp.write(env.tmp.p("Cargo.toml"), "[package]")
        try env.tmp.write(env.tmp.p("target/debug/x"), block(8192))
        env.git.ignored = [env.tmp.p("target")]
        return try await plan(env)
    }

    @Test func ifTheIntentLineCannotBeWrittenNothingIsTouched() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let p = try await twoEntries(env)
        env.audit.failFromAppend = 1
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        #expect(r.outcomes.count == 2)
        #expect(r.outcomes.allSatisfy { $0.status == .failed("denetim günlüğü yazılamıyor") })
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")) && env.tmp.exists(env.tmp.p("target/debug/x")))
        #expect(env.audit.events.isEmpty)
        #expect(r.freedBytes == 0 && r.trashedBytes == 0)
    }

    @Test func aLogThatBreaksMidRunStopsTheRemainingTargets() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let p = try await twoEntries(env)
        env.audit.failFromAppend = 3                        // entry 1: intent (1) + result (2) fine; entry 2: its intent fails
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        let next = try entry(p, "next.cache"), rust = try entry(p, "rust.target")
        guard case .deleted = try outcome(r, next).status else { Issue.record("the first entry was fully logged and removed"); return }
        #expect(try outcome(r, rust).status == .failed("denetim günlüğü yazılamıyor"))
        #expect(env.tmp.exists(env.tmp.p("target/debug/x")), "no intent line ⇒ not touched")
        #expect(env.trasher.trashed.isEmpty)
        #expect(env.audit.events.map(\.result) == ["intent", "deleted"])
    }

    @Test func aLostResultLineStopsTheRunButTheCompletedActKeepsItsRealStatus() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let p = try await twoEntries(env)
        env.audit.failFromAppend = 2                        // the intent is written, the result line is lost
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        let next = try entry(p, "next.cache"), rust = try entry(p, "rust.target")
        guard case .deleted = try outcome(r, next).status else { Issue.record("the removal happened and is reported as such"); return }
        #expect(!env.tmp.exists(env.tmp.p(".next")))
        #expect(try outcome(r, rust).status == .failed("denetim günlüğü yazılamıyor"))
        #expect(env.tmp.exists(env.tmp.p("target/debug/x")), "nothing else is touched once the log is broken")
        #expect(env.audit.events.map(\.result) == ["intent"])
    }

    // MARK: P2-8 — the entry lists exactly what will be removed

    private func pycacheProject(_ env: S2Env) throws {
        try env.tmp.write(env.tmp.p("pyproject.toml"), "[project]")
        try env.tmp.write(env.tmp.p("pkg/__pycache__/a.cpython-311.pyc"), block())
        try env.tmp.write(env.tmp.p("pkg/sub/__pycache__/b.cpython-311.pyc"), block())
    }

    @Test func aDiscoveredEntryListsTheExactPathsAndOnlyThoseAreRemoved() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try pycacheProject(env)
        let p = try await plan(env)
        let e = try entry(p, "py.pycache")
        #expect(e.displayPath == "pkg/__pycache__, pkg/sub/__pycache__")
        #expect(e.targetPaths == [env.tmp.p("pkg/__pycache__"), env.tmp.p("pkg/sub/__pycache__")], "no glob: exact absolute paths")
        #expect(e.itemCount == 2)
        // a directory that appears after the plan was never shown to the user ⇒ never removed
        try env.tmp.write(env.tmp.p("late/__pycache__/c.cpython-311.pyc"), block())
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        #expect(!env.tmp.exists(env.tmp.p("pkg/__pycache__")) && !env.tmp.exists(env.tmp.p("pkg/sub/__pycache__")))
        #expect(env.tmp.exists(env.tmp.p("late/__pycache__/c.cpython-311.pyc")), "not listed ⇒ not removed")
        #expect(Set(env.audit.resultLines.map(\.subject)) == [env.tmp.p("pkg/__pycache__"), env.tmp.p("pkg/sub/__pycache__")])
    }

    @Test func aForgedDisplayPathCanOnlyNarrowADiscoveredEntryNeverWidenIt() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try pycacheProject(env)
        try env.tmp.write(env.tmp.p("src/keep.py"), "x")
        let p = try await plan(env)
        let real = try entry(p, "py.pycache")
        let forged = CacheEntry(id: real.id, ruleID: real.ruleID, packageDir: real.packageDir, instance: nil,
                                displayPath: "../../src, pkg/__pycache__/../../src", title: real.title, safety: real.safety,
                                isContentsOnly: false, defaultSelected: real.defaultSelected, defaultMode: real.defaultMode,
                                sizeBytes: real.sizeBytes, sizeIsPartial: false, itemCount: real.itemCount,
                                qualifiedBecause: [], notes: [], reinstallCommand: nil)
        let fp = CleanupPlan(id: p.id, rootPath: p.rootPath, project: p.project, entries: [forged], blockers: [], createdAt: p.createdAt)
        let r = try await env.cleaner.execute(fp, selections: select(fp), progress: nil)
        #expect(try outcome(r, forged).status == .skipped(.notFound), "nothing derived from the catalog matches the forged list")
        #expect(env.tmp.exists(env.tmp.p("src/keep.py")))
        #expect(env.tmp.exists(env.tmp.p("pkg/__pycache__/a.cpython-311.pyc")) && env.tmp.exists(env.tmp.p("pkg/sub/__pycache__/b.cpython-311.pyc")))
    }

    @Test func theListingIsCappedAndTheRestIsLeftForTheNextRun() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("pyproject.toml"), "[project]")
        let total = CacheEvaluator.maxListedDiscoveredPaths + 1
        for i in 0..<total {
            try env.tmp.write(env.tmp.p("pkg/m\(String(format: "%03d", i))/__pycache__/x.cpython-311.pyc"), block(512))
        }
        let p = try await plan(env)
        let e = try entry(p, "py.pycache")
        #expect(e.itemCount == total)
        #expect(e.targetPaths.count == CacheEvaluator.maxListedDiscoveredPaths, "bounded listing")
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        let remaining = (0..<total).filter { env.tmp.exists(env.tmp.p("pkg/m\(String(format: "%03d", $0))/__pycache__")) }
        #expect(remaining == [total - 1], "exactly the listed paths were removed; the unlisted one waits for the next run")
        let next = try await plan(env)
        #expect(try entry(next, "py.pycache").itemCount == 1, "the next plan offers what was left")
    }

    @Test func aPathThatCannotBeListedExactlyIsNeverOffered() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try pycacheProject(env)
        try env.tmp.write(env.tmp.p("a, b/__pycache__/c.cpython-311.pyc"), block())    // contains the display separator
        let p = try await plan(env)
        let e = try entry(p, "py.pycache")
        #expect(e.targetPaths == [env.tmp.p("pkg/__pycache__"), env.tmp.p("pkg/sub/__pycache__")])
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        #expect(env.tmp.exists(env.tmp.p("a, b/__pycache__/c.cpython-311.pyc")))
    }

    @Test func aMultiTargetRuleOnlyRemovesTheTargetsItListed() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("nx.json"), "{}")
        try env.tmp.write(env.tmp.p(".nx/cache/a"), block())
        let p = try await plan(env)
        let e = try entry(p, "nx.cache")
        #expect(e.targetPaths == [env.tmp.p(".nx/cache")])
        // the sibling target appears after the plan: it was never shown, so it is never removed
        try env.tmp.write(env.tmp.p(".nx/workspace-data/b"), block())
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        #expect(!env.tmp.exists(env.tmp.p(".nx/cache")))
        #expect(env.tmp.exists(env.tmp.p(".nx/workspace-data/b")))
    }
}

// MARK: - The pre-walk itself ---------------------------------------------------------------

@Suite("RepositoryScanner (R12 pre-walk)")
struct RepositoryScannerTests {
    private func scan(_ path: String, limits: RepositoryScanner.Limits = RepositoryScanner.Limits()) -> NestedRepositoryScan {
        guard let st = SafeFS.lstatAbsolute(path) else { return .unreadable }
        return RepositoryScanner.scan(path: path, expected: st.identity, rootDev: st.dev, limits: limits)
    }

    @Test func cleanTreesAreCleanAndMarkersAreReportedWithTheirRelativePath() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let root = t.root + "/work"
        try t.write(root + "/a/b/c.txt", "c")
        try t.write(root + "/a/.gitignore", "x")        // not a marker
        try t.write(root + "/a/.github/workflow.yml", "x")
        #expect(scan(root) == .clean)
        try t.write(root + "/a/b/deeper/.git/HEAD", "ref")
        #expect(scan(root) == .found("a/b/deeper/.git"))
        try FileManager.default.removeItem(atPath: root + "/a/b/deeper")
        try t.write(root + "/.git", "gitdir: /x")        // gitlink file at the top
        #expect(scan(root) == .found(".git"))
    }

    @Test func symlinkedDirectoriesAreNeverFollowed() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.root + "/outside/.git/HEAD", "ref")
        try t.write(t.root + "/work/f.txt", "f")
        try t.symlink(t.root + "/work/link", to: t.root + "/outside")
        #expect(scan(t.root + "/work") == .clean, "a link to a repository is a name, not a repository inside the target")
        // the scan target itself must be a real directory
        #expect(scan(t.root + "/work/link") == .unreadable)
    }

    @Test func aDifferentDirectoryThanTheValidatedOneAndAMissingOneAreReported() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.root + "/work/f.txt", "f")
        try t.write(t.root + "/other/f.txt", "f")
        let other = try #require(SafeFS.lstatAbsolute(t.root + "/other"))
        #expect(RepositoryScanner.scan(path: t.root + "/work", expected: other.identity, rootDev: other.dev) == .identityChanged)
        #expect(scan(t.root + "/missing") == .unreadable)
    }

    @Test func everyBoundFailsClosed() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let root = t.root + "/work"
        // depth
        try t.write(root + "/a/b/c/d/e.txt", "e")
        #expect(scan(root, limits: .init(maxDepth: 2)) == .inconclusive)
        #expect(scan(root, limits: .init(maxDepth: 8)) == .clean)
        // entry count and wall time are polled every 1024 entries
        for i in 0..<1_100 { try t.write(root + "/flat/f\(i)", "x") }
        #expect(scan(root, limits: .init(maxEntries: 500)) == .inconclusive)
        #expect(scan(root, limits: .init(maxSeconds: 0)) == .inconclusive)
        #expect(scan(root) == .clean)
        // cancellation
        let path = root
        let task = Task { () -> NestedRepositoryScan in
            while !Task.isCancelled { await Task.yield() }
            return RepositoryScanner.scan(path: path, expected: SafeFS.lstatAbsolute(path)?.identity ?? FileIdentity(dev: 0, ino: 0),
                                          rootDev: SafeFS.lstatAbsolute(path)?.dev ?? 0)
        }
        task.cancel()
        #expect(await task.value == .inconclusive)
    }
}
