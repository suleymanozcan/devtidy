import Foundation
import Darwin
import Testing
@testable import DevTidyCore

private final class S2Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

private final class S2Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ id: String) { lock.withLock { items.append(id) } }
    var ids: [String] { lock.withLock { items } }
}

/// Swaps `<path>` for a brand-new directory (new inode) and keeps the old one aside.
private func swapDirectory(_ path: String) {
    try? FileManager.default.moveItem(atPath: path, toPath: path + "-old-" + UUID().uuidString)
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path + "/fresh.bin", contents: Data(repeating: 1, count: 4096))
}

@Suite("CacheCleaner (D1–D14)")
struct CacheCleanerTests {
    // MARK: Helpers

    private func plan(_ env: S2Env, at path: String? = nil, includeDependencies: Bool = false) async throws -> CleanupPlan {
        var o = CatalogOptions()
        o.includeDerivedData = false
        o.includeDependencies = includeDependencies
        return try #require(await env.cleaner.makePlan(forProjectAt: path ?? env.tmp.project, options: o))
    }

    /// Class C entries carry the user's "Anladım" unless a test says otherwise.
    private func select(_ plan: CleanupPlan, only ruleIDs: Set<String>? = nil, mode: DeleteMode? = nil) -> [CleanupSelection] {
        plan.entries.filter { ruleIDs?.contains($0.ruleID) ?? true }.map {
            CleanupSelection(entryID: $0.id, mode: mode ?? $0.defaultMode, acknowledgedDependencies: $0.safety == .optIn)
        }
    }

    private func entry(_ plan: CleanupPlan, _ ruleID: String) throws -> CacheEntry {
        try #require(plan.entries.first { $0.ruleID == ruleID }, "no \(ruleID) in plan: \(plan.entries.map(\.ruleID))")
    }

    private func outcome(_ result: CleanupResult, _ entry: CacheEntry) throws -> CleanupOutcome {
        try #require(result.outcomes.first { $0.entryID == entry.id })
    }

    private func forged(_ e: CacheEntry, id: String? = nil, ruleID: String? = nil, packageDir: String? = nil,
                        instance: String?? = nil, displayPath: String? = nil, safety: CacheSafety? = nil) -> CacheEntry {
        CacheEntry(id: id ?? e.id, ruleID: ruleID ?? e.ruleID, packageDir: packageDir ?? e.packageDir, instance: instance ?? e.instance,
                   displayPath: displayPath ?? e.displayPath, title: e.title, safety: safety ?? e.safety,
                   isContentsOnly: e.isContentsOnly, defaultSelected: e.defaultSelected, defaultMode: e.defaultMode,
                   sizeBytes: e.sizeBytes, sizeIsPartial: e.sizeIsPartial, itemCount: e.itemCount,
                   qualifiedBecause: e.qualifiedBecause, notes: e.notes, reinstallCommand: e.reinstallCommand)
    }

    private func replacing(_ p: CleanupPlan, with entries: [CacheEntry]) -> CleanupPlan {
        CleanupPlan(id: p.id, rootPath: p.rootPath, project: p.project, entries: entries, blockers: p.blockers, createdAt: p.createdAt,
                    includesDependencies: p.includesDependencies)
    }

    private func expectSkipped(_ o: CleanupOutcome, _ reason: SkipReason, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(o.status == .skipped(reason), "got \(o.status)", sourceLocation: sourceLocation)
    }

    private func rustProject(_ env: S2Env) throws {
        try env.tmp.write(env.tmp.p("Cargo.toml"), "[package]\nname=\"x\"")
        try env.tmp.write(env.tmp.p("target/debug/x"), String(repeating: "r", count: 8192))
        try env.tmp.write(env.tmp.p("src/main.rs"), "fn main(){}")
        env.git.ignored = [env.tmp.p("target")]
    }

    private func laravel(_ env: S2Env) throws {
        try env.tmp.write(env.tmp.p("artisan"), "#!/usr/bin/env php")
        try env.tmp.write(env.tmp.p("composer.json"), "{\"require\":{\"laravel/framework\":\"^11.0\"}}")
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["laravel-vite-plugin"])
    }

    // MARK: Happy path (D1, D14)

    @Test func happyPathDeletesOnlyDotNext() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let watched = [".env", "src/page.tsx", "public/logo.txt", "node_modules/dep/index.js", "package.json"]
        let before = Dictionary(uniqueKeysWithValues: watched.map { ($0, env.tmp.read(env.tmp.p($0))) })
        let p = try await plan(env)
        #expect(p.entries.map(\.ruleID) == ["next.cache"])
        #expect(p.rootPath == env.tmp.project)
        #expect(p.project?.root == env.tmp.project)
        #expect(p.includesDependencies == false)
        let e = p.entries[0]
        #expect((e.sizeBytes ?? 0) > 0 && !e.sizeIsPartial)

        var seen: [CleanupOutcome] = []
        let progress = S2Outcomes()
        let result = try await env.cleaner.execute(p, selections: select(p), progress: { progress.add($0.entryID) })
        seen = result.outcomes
        let o = try #require(seen.first)
        guard case .deleted(let bytes) = o.status else { Issue.record("expected deleted, got \(o.status)"); return }
        #expect(bytes == e.sizeBytes, "plan size (< 10 min old) is what is reported")
        #expect(o.path == env.tmp.p(".next"))
        #expect(!env.tmp.exists(env.tmp.p(".next")))
        for w in watched { #expect(env.tmp.read(env.tmp.p(w)) == before[w], "\(w) must be byte-identical") }
        #expect(result.freedBytes == bytes && result.trashedBytes == 0)
        #expect(result.planID == p.id)
        #expect(progress.ids == seen.map(\.entryID), "progress is reported once per outcome, in order")

        // one `intent` line before the removal, then exactly one result line (D12, F-5)
        let events = env.audit.events
        #expect(events.map(\.result) == ["intent", "deleted"])
        #expect(events.allSatisfy { $0.subject == env.tmp.p(".next") && $0.kind == .cleanup })
        let ev = try #require(env.audit.resultLines.first)
        #expect(ev.result == "deleted")
        #expect(ev.detail["rule"] == "next.cache")
        #expect(ev.detail["class"] == "A")
        #expect(ev.detail["mode"] == "permanent")
        #expect(ev.detail["bytes"] == String(bytes))
        #expect(ev.detail["packageDir"] == env.tmp.project)
        #expect(ev.detail["tracked"] == "0")
    }

    @Test func zeroSizeEntriesAreNeverPlanned() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["next"])
        try env.tmp.mkdir(env.tmp.p(".next/empty/deeper"))
        var o = CatalogOptions()
        o.includeDerivedData = false
        #expect(await env.cleaner.makePlan(forProjectAt: env.tmp.project, options: o) == nil)
        // an entry that becomes non-empty is planned (the size cache key is the target directory's own mtime, §5.6, so the
        // new file must be a direct child of `.next`)
        try env.tmp.write(env.tmp.p(".next/f"), String(repeating: "x", count: 4096))
        #expect(await env.cleaner.makePlan(forProjectAt: env.tmp.project, options: o) != nil)
    }

    @Test func rejectedRootsYieldNoPlan() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.home + "/dev", deps: ["next"])
        try env.tmp.write(env.tmp.home + "/dev/.next/x", String(repeating: "x", count: 4096))
        #expect(await env.cleaner.makePlan(forProjectAt: env.tmp.home + "/dev", options: CatalogOptions()) == nil)
        #expect(await env.cleaner.makePlan(forProjectAt: env.tmp.home, options: CatalogOptions()) == nil)
    }

    @Test func blockersAreEvaluatedAtTheCeiling() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let app = env.tmp.p("apps/web")
        try env.tmp.packageJSON(at: app, deps: ["next"])
        try env.tmp.write(app + "/.next/x", String(repeating: "x", count: 4096))
        env.activity.blockers = [S2FakeActivity.blocker(.soft)]
        let p = try await plan(env, at: app)
        #expect(p.rootPath == env.tmp.project, "R17: the plan root is the ceiling, not the package dir")
        #expect(env.activity.roots == [env.tmp.project])
        #expect(p.blockers.count == 1)
        #expect(p.entries.first?.packageDir == app)
    }

    // MARK: Class B / Trash (D10)

    @Test func classBDefaultsToTrashAndATrashFailureNeverFallsBack() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try rustProject(env)
        let p = try await plan(env)
        let e = try entry(p, "rust.target")
        #expect(e.safety == .conditional && e.defaultMode == .trash && !e.defaultSelected)

        env.trasher.shouldFail = true
        let failed = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        let fo = try outcome(failed, e)
        guard case .failed(let text) = fo.status else { Issue.record("expected failed, got \(fo.status)"); return }
        #expect(text.contains("S2 trash failure"))
        #expect(env.tmp.exists(env.tmp.p("target/debug/x")), "the directory must still be present: NO fallback to permanent removal")
        #expect(env.trasher.trashed.isEmpty)
        #expect(env.audit.events.last?.result.hasPrefix("failed:") == true)
        #expect(failed.freedBytes == 0 && failed.trashedBytes == 0)

        env.trasher.shouldFail = false
        let ok = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .movedToTrash(let bytes) = try outcome(ok, e).status else { Issue.record("expected movedToTrash"); return }
        #expect(bytes > 0)
        #expect(!env.tmp.exists(env.tmp.p("target")))
        #expect(env.trasher.trashed.map(\.path) == [env.tmp.p("target")])
        #expect(ok.trashedBytes == bytes && ok.freedBytes == 0)
        #expect(env.tmp.read(env.tmp.p("src/main.rs")) == "fn main(){}")
        #expect(env.audit.events.last?.result == "trashed")
        #expect(env.audit.events.last?.detail["class"] == "B")
        #expect(env.audit.events.last?.detail["mode"] == "trash")
    }

    /// QA F4: the Trash move is traceable — the audit line names where the item landed.
    @Test func trashedAuditLinesRecordTheResultingTrashURL() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try rustProject(env)
        let p = try await plan(env)
        let e = try entry(p, "rust.target")
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .movedToTrash = try outcome(r, e).status else { Issue.record("expected movedToTrash"); return }
        let landed = try #require(env.trasher.landed.first)
        #expect(landed.path.hasPrefix(env.trasher.trashDir + "/"))
        #expect(env.tmp.exists(landed.path + "/debug/x"), "the item really is where the log says")
        let line = try #require(env.audit.resultLines.first)
        #expect(line.result == "trashed")
        #expect(line.detail["trashURL"] == landed.path)
        // a permanent delete carries no trash URL
        try rustProject(env)
        let p2 = try await plan(env)
        let e2 = try entry(p2, "rust.target")
        _ = try await env.cleaner.execute(p2, selections: [CleanupSelection(entryID: e2.id, mode: .permanent)], progress: nil)
        #expect(env.audit.resultLines.last?.result == "deleted")
        #expect(env.audit.resultLines.last?.detail["trashURL"] == nil)
    }

    @Test func classBPermanentToggleDeletes() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try rustProject(env)
        let p = try await plan(env)
        let e = try entry(p, "rust.target")
        let result = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        guard case .deleted = try outcome(result, e).status else { Issue.record("expected deleted"); return }
        #expect(!env.tmp.exists(env.tmp.p("target")))
        #expect(env.trasher.trashed.isEmpty)
    }

    @Test func classAMayBeSentToTrashToo() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        let result = try await env.cleaner.execute(p, selections: select(p, mode: .trash), progress: nil)
        guard case .movedToTrash = result.outcomes[0].status else { Issue.record("expected movedToTrash"); return }
        #expect(env.trasher.trashed.count == 1)
    }

    // MARK: Activity (D8)

    @Test func hardBlockerSkipsEverythingAndSoftOnlyStopsClassBAndC() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        try env.tmp.write(env.tmp.p("Cargo.toml"), "[package]")
        try env.tmp.write(env.tmp.p("target/debug/x"), String(repeating: "r", count: 4096))
        env.git.ignored = [env.tmp.p("target")]
        let p = try await plan(env)
        let a = try entry(p, "next.cache")
        let b = try entry(p, "rust.target")

        // the plan was built without blockers; they appear BEFORE execute ⇒ re-evaluated fresh (D8)
        env.activity.blockers = [S2FakeActivity.blocker(.hard)]
        let hard = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        expectSkipped(try outcome(hard, a), .blockedByActivity)
        expectSkipped(try outcome(hard, b), .blockedByActivity)
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")) && env.tmp.exists(env.tmp.p("target/debug/x")))
        #expect(env.activity.roots.last == env.tmp.project)
        #expect(env.audit.events.map(\.result) == ["skipped:blockedByActivity", "skipped:blockedByActivity"],
                "a blocked target never gets an intent line")

        env.activity.blockers = [S2FakeActivity.blocker(.soft, label: "tunahan-php-1")]
        let soft = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = try outcome(soft, a).status else { Issue.record("class A must proceed with a soft blocker"); return }
        expectSkipped(try outcome(soft, b), .blockedByActivity)
        #expect(!env.tmp.exists(env.tmp.p(".next")))
        #expect(env.tmp.exists(env.tmp.p("target/debug/x")))
    }

    // MARK: Forgery (D1, D2)

    @Test func forgedPackageDirOutsideTheRootIsRejected() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        // a perfectly valid sibling project and a foreign directory with the same layout
        let evil = env.tmp.home + "/dev/proj-evil"
        try env.tmp.packageJSON(at: evil, deps: ["next"])
        try env.tmp.write(evil + "/.next/x", "victim")
        let foreign = env.tmp.root + "/outside/proj"
        try env.tmp.packageJSON(at: foreign, deps: ["next"])
        try env.tmp.write(foreign + "/.next/x", "victim")
        let p = try await plan(env)
        let real = try entry(p, "next.cache")

        let cases: [(String, SkipReason)] = [
            (evil, .outsideRoot),                                   // sibling-prefix of the plan root
            (env.tmp.project + "/../proj-evil", .outsideRoot),     // lexical `..` escape
            (foreign, .rootRejected),                               // outside HOME entirely (R1)
            (env.tmp.home + "/dev", .rootRejected),                // depth-1 container (R1)
            (env.tmp.project + "/missing-subdir", .rootRejected),  // not a directory
        ]
        for (dir, reason) in cases {
            let f = forged(real, id: "forged-\(reason.rawValue)-\(dir)", packageDir: dir, displayPath: "../../../outside")
            let fp = replacing(p, with: [f])
            let result = try await env.cleaner.execute(fp, selections: [CleanupSelection(entryID: f.id, mode: .permanent)], progress: nil)
            expectSkipped(try outcome(result, f), reason)
        }
        #expect(env.tmp.read(evil + "/.next/x") == "victim")
        #expect(env.tmp.read(foreign + "/.next/x") == "victim")
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")))
    }

    @Test func displayPathAndForgedSafetyHaveNoEffect() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        try rustProject(env)
        env.git.ignored = []                       // `target` is NOT ignored ⇒ class B must refuse
        let p = try await plan(env)
        let next = try entry(p, "next.cache")
        // displayPath points at the source tree: ignored; only the catalog rule decides what is touched
        let a = forged(next, displayPath: "../../src")
        let r1 = try await env.cleaner.execute(replacing(p, with: [a]), selections: [CleanupSelection(entryID: a.id, mode: .permanent)], progress: nil)
        guard case .deleted = try outcome(r1, a).status else { Issue.record("expected deleted"); return }
        #expect(!env.tmp.exists(env.tmp.p(".next")))
        #expect(env.tmp.exists(env.tmp.p("src/page.tsx")) && env.tmp.exists(env.tmp.p("src/main.rs")))
        #expect(env.audit.events.last?.subject == env.tmp.p(".next"))

        // an entry that LIES about its class (claims A for the class-B rust.target) is gated by the catalog's class
        try env.tmp.write(env.tmp.p("target/debug/x"), String(repeating: "r", count: 4096))
        let rustEntry = forged(CacheEntry(id: "rust.target@\(env.tmp.project)", ruleID: "rust.target", packageDir: env.tmp.project,
                                          instance: nil, displayPath: "target", title: "x", safety: .conditional, isContentsOnly: false,
                                          defaultSelected: false, defaultMode: .trash, sizeBytes: 4096, sizeIsPartial: false, itemCount: nil,
                                          qualifiedBecause: [], notes: [], reinstallCommand: nil), safety: .always)
        let r2 = try await env.cleaner.execute(replacing(p, with: [rustEntry]),
                                               selections: [CleanupSelection(entryID: rustEntry.id, mode: .permanent)], progress: nil)
        expectSkipped(try outcome(r2, rustEntry), .notIgnoredByGit)
        #expect(env.tmp.exists(env.tmp.p("target/debug/x")))
    }

    @Test func unknownRuleAndUnknownEntryAreNotInCatalog_andUnselectedEntriesAreUntouched() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        try rustProject(env)
        let p = try await plan(env)
        let next = try entry(p, "next.cache")
        let rust = try entry(p, "rust.target")

        let unknownRule = forged(next, id: "x@y", ruleID: "totally.fake")
        let fp = replacing(p, with: [unknownRule])
        let r0 = try await env.cleaner.execute(fp, selections: [CleanupSelection(entryID: unknownRule.id, mode: .permanent)], progress: nil)
        expectSkipped(try outcome(r0, unknownRule), .notInCatalog)
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")))

        let before = env.audit.events.count
        let result = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: next.id, mode: .permanent),
                                                                   CleanupSelection(entryID: "bogus@nowhere", mode: .permanent)], progress: nil)
        #expect(result.outcomes.map(\.entryID) == [next.id, rust.id, "bogus@nowhere"])
        guard case .deleted = result.outcomes[0].status else { Issue.record("expected deleted"); return }
        expectSkipped(result.outcomes[1], .notSelected)
        expectSkipped(result.outcomes[2], .notInCatalog)
        #expect(env.tmp.exists(env.tmp.p("target/debug/x")), "unselected entries are never touched")
        // the deletion (intent + result) and the bogus selection; nothing for the unselected entry
        let written = Array(env.audit.events.dropFirst(before))
        #expect(written.map(\.result) == ["intent", "deleted", "skipped:notInCatalog"])
        #expect(!written.contains { $0.subject == env.tmp.p("target") })
    }

    // MARK: Symlink swap (D3)

    @Test func targetSwappedForASymlinkBetweenPlanAndExecuteIsSkipped() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        let outside = env.tmp.root + "/outside"
        try env.tmp.write(outside + "/precious.txt", "keep me")
        try FileManager.default.removeItem(atPath: env.tmp.p(".next"))
        try env.tmp.symlink(env.tmp.p(".next"), to: outside)
        let result = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        expectSkipped(result.outcomes[0], .symlink)
        #expect(env.tmp.isSymlink(env.tmp.p(".next")), "the link itself is never unlinked")
        #expect(env.tmp.read(outside + "/precious.txt") == "keep me")
        #expect(env.audit.events.map(\.result) == ["skipped:symlink"])
    }

    @Test func aSymlinkedParentComponentIsRefused() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project)
        try env.tmp.write(env.tmp.p("node_modules/.cache/prettier/x"), String(repeating: "x", count: 4096))
        let p = try await plan(env)
        let e = try entry(p, "node.cache")
        let outside = env.tmp.root + "/outside"
        try env.tmp.write(outside + "/.cache/precious.txt", "keep me")
        try FileManager.default.removeItem(atPath: env.tmp.p("node_modules"))
        try env.tmp.symlink(env.tmp.p("node_modules"), to: outside)
        let result = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        expectSkipped(try outcome(result, e), .symlink)
        #expect(env.tmp.read(outside + "/.cache/precious.txt") == "keep me")
        #expect(env.tmp.isSymlink(env.tmp.p("node_modules")))
    }

    // MARK: Git (D7)

    @Test func gitTrackedAtExecuteTimeSkipsClassA() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        env.git.tracked = [env.tmp.p(".next/dev/lock")]
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        expectSkipped(r.outcomes[0], .trackedByGit)
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")))
        #expect(env.audit.events.last?.result == "skipped:trackedByGit")
    }

    @Test func classBGitGatesAreReRunAtExecuteTime() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try rustProject(env)
        let p = try await plan(env)
        let e = try entry(p, "rust.target")
        let sel = [CleanupSelection(entryID: e.id, mode: .permanent)]
        let target = env.tmp.p("target/debug/x")

        env.git.ignored = []
        expectSkipped(try outcome(try await env.cleaner.execute(p, selections: sel, progress: nil), e), .notIgnoredByGit)
        env.git.ignored = [env.tmp.p("target")]
        env.git.untracked = [env.tmp.p("target/stray.rs")]
        expectSkipped(try outcome(try await env.cleaner.execute(p, selections: sel, progress: nil), e), .hasUntrackedFiles)
        env.git.untracked = []
        env.git.tracked = [target]
        expectSkipped(try outcome(try await env.cleaner.execute(p, selections: sel, progress: nil), e), .trackedByGit)
        env.git.tracked = []
        env.git.failing = true
        expectSkipped(try outcome(try await env.cleaner.execute(p, selections: sel, progress: nil), e), .gitUnavailable)
        env.git.failing = false
        env.git.isRepository = false
        expectSkipped(try outcome(try await env.cleaner.execute(p, selections: sel, progress: nil), e), .gitUnavailable)
        #expect(env.tmp.exists(target), "every refusal left the directory alone")
        env.git.isRepository = true
        guard case .deleted = try outcome(try await env.cleaner.execute(p, selections: sel, progress: nil), e).status else {
            Issue.record("with every gate green the target is removed"); return
        }
        #expect(!env.tmp.exists(env.tmp.p("target")))
    }

    @Test func classAToleratesOnlyNotARepository() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        env.git.failing = true
        expectSkipped(try await env.cleaner.execute(p, selections: select(p), progress: nil).outcomes[0], .gitUnavailable)
        #expect(env.tmp.exists(env.tmp.p(".next")))
        env.git.failing = false
        env.git.isRepository = false
        guard case .deleted = try await env.cleaner.execute(p, selections: select(p), progress: nil).outcomes[0].status else {
            Issue.record("not-a-repository is tolerated for class A"); return
        }
    }

    // MARK: Audit (D12)

    @Test func unwritableAuditLogMeansNothingIsTouched() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        env.audit.writable = false
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        #expect(r.outcomes.count == 1)
        #expect(r.outcomes[0].status == .failed("denetim günlüğü yazılamıyor"))
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")))
        #expect(env.audit.events.isEmpty)
        #expect(r.freedBytes == 0)
    }

    @Test func everyTargetYieldsOneResultLineAndActedTargetsAnIntentLineBeforeIt() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        try rustProject(env)
        let p = try await plan(env)
        env.trasher.shouldFail = true
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        #expect(r.outcomes.count == 2)
        let events = env.audit.events
        #expect(events.count == 4)
        #expect(Set(events.map(\.subject)) == [env.tmp.p(".next"), env.tmp.p("target")])
        #expect(events.allSatisfy { $0.kind == .cleanup && $0.detail["plan"] == p.id.uuidString })
        let kinds = Set(env.audit.resultLines.map { $0.result.split(separator: ":").first.map(String.init) ?? "" })
        #expect(kinds == ["deleted", "failed"])
        #expect(env.audit.resultLines.count == 2, "exactly one result line per target")
        for subject in [env.tmp.p(".next"), env.tmp.p("target")] {
            let mine = events.filter { $0.subject == subject }.map(\.result)
            #expect(mine.first == "intent" && mine.count == 2, "\(subject): \(mine)")
        }
    }

    // MARK: Immutable flags (D6)

    @Test func immutableFlagsAreNeverCleared() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        let uchg: UInt32 = 0x2
        guard chflags(env.tmp.p(".next"), uchg) == 0 else { return }   // the filesystem refuses flags: nothing to prove
        defer { chflags(env.tmp.p(".next"), 0) }
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        expectSkipped(r.outcomes[0], .immutable)
        #expect(SafeFS.lstatAbsolute(env.tmp.p(".next"))?.hasProtectedFlags == true)
        #expect(env.tmp.exists(env.tmp.p(".next/dev/lock")))
    }

    // MARK: Identity recheck (D11)

    @Test func swapAfterTheActivityCheckIsRevalidatedOnce() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        let next = env.tmp.p(".next")
        let swaps = S2Counter()
        env.activity.onCall = { if swaps.next() == 1 { swapDirectory(next) } }
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        // (dev, ino) changed ⇒ steps 5–6 re-ran against the NEW directory, which passed every gate and was removed
        guard case .deleted = r.outcomes[0].status else { Issue.record("expected deleted after revalidation, got \(r.outcomes[0].status)"); return }
        #expect(!env.tmp.exists(next))
        let aside = try FileManager.default.contentsOfDirectory(atPath: env.tmp.project).filter { $0.hasPrefix(".next-old") }
        #expect(aside.count == 1)
        #expect(env.tmp.exists(env.tmp.p(aside.first ?? "missing") + "/dev/lock"), "the swapped-out original is untouched")
        #expect(env.audit.resultLines.count == 1)
        #expect(env.audit.events.map(\.result) == ["intent", "deleted"], "the mismatch was caught before any intent line")
    }

    @Test func aSecondSwapDuringRevalidationIsIdentityChanged() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        let next = env.tmp.p(".next")
        let activityCalls = S2Counter()
        let gitCalls = S2Counter()
        env.activity.onCall = { if activityCalls.next() == 1 { swapDirectory(next) } }
        env.git.onTracked = { _ in if gitCalls.next() == 2 { swapDirectory(next) } }   // 1 = initial gate, 2 = revalidation
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        expectSkipped(r.outcomes[0], .identityChanged)
        #expect(env.tmp.exists(next + "/fresh.bin"), "the directory that was swapped in last is not deleted")
        #expect(env.audit.events.map(\.result) == ["skipped:identityChanged"])
    }

    /// Security F-7a: the size walk of a stale plan runs BEFORE the blocker check, so the figure it reports is the one
    /// taken before the checks, and nothing slow sits between the last check and the removal.
    @Test func aStalePlanIsMeasuredBeforeTheBlockersAreChecked() async throws {
        let clock = S2Clock()
        let env = try S2Env(clock: clock)
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let p = try await plan(env)
        clock.advance(CacheCleaner.planFreshness + 60)               // too old to trust its own byte figure, not stale yet
        try env.tmp.write(env.tmp.p(".next/before.bin"), String(repeating: "b", count: 40_000))
        let expected = DirectorySizer.size(of: env.tmp.p(".next")).bytes
        let duringPath = env.tmp.p(".next/during.bin")
        env.activity.onCall = {
            FileManager.default.createFile(atPath: duringPath, contents: Data(repeating: 1, count: 80_000))
        }
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted(let bytes) = r.outcomes[0].status else { Issue.record("expected deleted, got \(r.outcomes[0].status)"); return }
        #expect(bytes == expected, "measured before the blockers ran (and re-measured, not the plan's figure)")
        #expect(bytes != p.entries[0].sizeBytes)
        #expect(!env.tmp.exists(env.tmp.p(".next")))
    }

    // MARK: Contents-only, file, discovered

    @Test func laravelViewsAreEmptiedButTheDirectoryAndGitignoreStay() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        let views = env.tmp.p("storage/framework/views")
        try env.tmp.write(views + "/a1.php", String(repeating: "<", count: 4096))
        try env.tmp.write(views + "/b2.php", String(repeating: "<", count: 4096))
        try env.tmp.write(views + "/.gitignore", "*\n!.gitignore\n")
        try env.tmp.write(views + "/note.txt", "keep")
        try env.tmp.write(env.tmp.root + "/outside.php", "outside")
        try env.tmp.symlink(views + "/link.php", to: env.tmp.root + "/outside.php")
        env.git.tracked = [views + "/.gitignore"]
        env.git.ignored = [views + "/a1.php", views + "/b2.php", views + "/note.txt", views + "/link.php"]
        let p = try await plan(env)
        let e = try entry(p, "laravel.views")
        #expect(e.isContentsOnly && e.itemCount == 2)
        let r = try await env.cleaner.execute(p, selections: select(p, only: ["laravel.views"]), progress: nil)
        guard case .deleted(let bytes) = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        #expect(bytes > 0)
        #expect(!env.tmp.exists(views + "/a1.php") && !env.tmp.exists(views + "/b2.php"))
        #expect(env.tmp.exists(views + "/.gitignore") && env.tmp.exists(views + "/note.txt"))
        #expect(env.tmp.isSymlink(views + "/link.php"), "symlinked children are never unlinked")
        #expect(env.tmp.read(env.tmp.root + "/outside.php") == "outside")
        #expect(env.tmp.exists(views), "the directory itself is never removed")
        #expect(env.audit.events.map(\.result) == ["intent", "deleted"])
        #expect(env.audit.events.allSatisfy { $0.subject == views })
    }

    @Test func contentsOnlyClassBGoesToTrashPerChild() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        let cache = env.tmp.p("bootstrap/cache")
        try env.tmp.write(cache + "/packages.php", String(repeating: "p", count: 4096))
        try env.tmp.write(cache + "/services.php", String(repeating: "s", count: 4096))
        try env.tmp.write(cache + "/.gitignore", "*")
        env.git.tracked = [cache + "/.gitignore"]
        env.git.ignored = [cache + "/packages.php", cache + "/services.php"]
        let p = try await plan(env)
        let e = try entry(p, "laravel.bootcache")
        #expect(e.defaultMode == .trash)
        let r = try await env.cleaner.execute(p, selections: select(p, only: ["laravel.bootcache"]), progress: nil)
        let trashedOutcome = try outcome(r, e)
        guard case .movedToTrash = trashedOutcome.status else { Issue.record("expected movedToTrash, got \(trashedOutcome.status)"); return }
        #expect(env.trasher.trashed.map(\.lastPathComponent).sorted() == ["packages.php", "services.php"])
        #expect(env.tmp.exists(cache + "/.gitignore"))
        // QA F4: every child's resulting Trash URL is in the one audit line
        let logged = try #require(env.audit.resultLines.last?.detail["trashURL"]).components(separatedBy: "\n")
        #expect(Set(logged) == Set(env.trasher.landed.map(\.path)))
        // a trash failure on a contents-only entry is a failure, never a permanent delete
        try env.tmp.write(cache + "/packages.php", String(repeating: "p", count: 4096))
        env.trasher.shouldFail = true
        let p2 = try await plan(env)
        let e2 = try entry(p2, "laravel.bootcache")
        let r2 = try await env.cleaner.execute(p2, selections: select(p2, only: ["laravel.bootcache"]), progress: nil)
        guard case .failed = try outcome(r2, e2).status else { Issue.record("expected failed"); return }
        #expect(env.tmp.exists(cache + "/packages.php"))
    }

    @Test func laravelHotFileIsRemovedAndPublicStays() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        try env.tmp.write(env.tmp.p("public/hot"), "http://[::1]:5173")
        try env.tmp.write(env.tmp.p("public/index.php"), "<?php")
        env.git.ignored = [env.tmp.p("public/hot")]
        let p = try await plan(env)
        let e = try entry(p, "laravel.hot")
        let r = try await env.cleaner.execute(p, selections: select(p, only: ["laravel.hot"]), progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        #expect(!env.tmp.exists(env.tmp.p("public/hot")))
        #expect(env.tmp.exists(env.tmp.p("public/index.php")))
        // content changed after the plan ⇒ the content rule is re-checked and refuses
        try env.tmp.write(env.tmp.p("public/hot"), "<?php echo 1;")
        let r2 = try await env.cleaner.execute(p, selections: select(p, only: ["laravel.hot"]), progress: nil)
        expectSkipped(try outcome(r2, e), .notFound)
        #expect(env.tmp.exists(env.tmp.p("public/hot")))
    }

    @Test func discoveredTargetsAreRemovedIndividuallyWithOneResultLineEach() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("pyproject.toml"), "[project]")
        try env.tmp.write(env.tmp.p("pkg/mod.py"), "print(1)")
        try env.tmp.write(env.tmp.p("pkg/__pycache__/mod.cpython-311.pyc"), String(repeating: "x", count: 4096))
        try env.tmp.write(env.tmp.p("pkg/sub/__pycache__/s.cpython-311.pyc"), String(repeating: "x", count: 4096))
        try env.tmp.write(env.tmp.p("notes/__pycache__/notes.txt"), "user data")
        let p = try await plan(env)
        let e = try entry(p, "py.pycache")
        #expect(e.itemCount == 2)
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted(let bytes) = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        #expect(bytes > 0)
        #expect(try outcome(r, e).path == env.tmp.project)
        #expect(!env.tmp.exists(env.tmp.p("pkg/__pycache__")) && !env.tmp.exists(env.tmp.p("pkg/sub/__pycache__")))
        #expect(env.tmp.exists(env.tmp.p("pkg/mod.py")))
        #expect(env.tmp.exists(env.tmp.p("notes/__pycache__/notes.txt")), "a __pycache__ with foreign files is never touched")
        #expect(env.audit.resultLines.count == 2)
        #expect(env.audit.intentLines.count == 2)
        #expect(Set(env.audit.events.map(\.subject)) == [env.tmp.p("pkg/__pycache__"), env.tmp.p("pkg/sub/__pycache__")])
    }

    @Test func classCNeedsOptInAndIsPermanentWithReinstallCommand() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project)
        try env.tmp.write(env.tmp.p("package-lock.json"), "{}")
        try env.tmp.write(env.tmp.p("node_modules/dep/index.js"), String(repeating: "x", count: 4096))
        env.git.ignored = [env.tmp.p("node_modules")]
        var plain = CatalogOptions()
        plain.includeDerivedData = false
        #expect(await env.cleaner.makePlan(forProjectAt: env.tmp.project, options: plain) == nil, "node_modules is opt-in only")
        let p = try await plan(env, includeDependencies: true)
        #expect(p.includesDependencies)
        let e = try entry(p, "node.modules")
        #expect(e.safety == .optIn && e.defaultMode == .permanent && !e.defaultSelected)
        #expect(e.reinstallCommand == "npm ci")
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted"); return }
        #expect(!env.tmp.exists(env.tmp.p("node_modules")))
        #expect(env.tmp.exists(env.tmp.p("package.json")))
    }

    // MARK: DerivedData (D2 exception)

    private func derived(_ env: S2Env) throws -> (orphans: [String], matched: String) {
        let root = env.derivedRoot
        let orphans = ["Gone1-abcdefghijklmnopqrstuvwxyzab", "Gone2-bcdefghijklmnopqrstuvwxyzabc"]
        for o in orphans {
            try env.tmp.write(root + "/" + o + "/Build/x.o", String(repeating: "o", count: 4096))
            try plist(["WorkspacePath": env.tmp.home + "/dev/deleted/\(o).xcworkspace"]).write(to: URL(fileURLWithPath: root + "/" + o + "/info.plist"))
        }
        let matched = "App-cdefghijklmnopqrstuvwxyzabcd"
        try env.tmp.mkdir(env.tmp.p("App.xcworkspace"))
        try env.tmp.write(root + "/" + matched + "/Build/y.o", String(repeating: "m", count: 4096))
        try plist(["WorkspacePath": env.tmp.p("App.xcworkspace")]).write(to: URL(fileURLWithPath: root + "/" + matched + "/info.plist"))
        try env.tmp.write(root + "/Unsaved_Xcode_Document-defghijklmnopqrstuvwxyzabcde/Logs/l.txt", "x")
        try env.tmp.write(root + "/ModuleCache.noindex/m", "x")
        return (orphans, matched)
    }

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    @Test func orphanPlanDeletesOnlyMatchingChildrenOfTheInjectedRoot() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let (orphans, matched) = try derived(env)
        let p = try #require(await env.cleaner.makeOrphanedDerivedDataPlan())
        #expect(p.project == nil)
        #expect(p.rootPath == env.derivedRoot)
        #expect(p.blockers.isEmpty)
        #expect(Set(p.entries.compactMap(\.instance)) == Set(orphans))
        #expect(p.entries.allSatisfy { $0.safety == .always && $0.defaultMode == .permanent && !$0.defaultSelected })
        let r = try await env.cleaner.execute(p, selections: select(p), progress: nil)
        #expect(r.outcomes.count == 2)
        for o in r.outcomes { if case .deleted = o.status {} else { Issue.record("expected deleted, got \(o.status)") } }
        for name in orphans { #expect(!env.tmp.exists(env.derivedRoot + "/" + name)) }
        #expect(env.tmp.exists(env.derivedRoot + "/" + matched + "/Build/y.o"))
        #expect(env.tmp.exists(env.derivedRoot + "/ModuleCache.noindex/m"))
        #expect(env.tmp.exists(env.derivedRoot + "/Unsaved_Xcode_Document-defghijklmnopqrstuvwxyzabcde/Logs/l.txt"))
        #expect(env.activity.roots.isEmpty, "DerivedData entries skip the activity step")
        #expect(Set(env.audit.events.map(\.subject)) == Set(orphans.map { env.derivedRoot + "/" + $0 }))
        #expect(env.audit.events.allSatisfy { $0.detail["class"] == "A" && $0.detail["rule"] == "xcode.deriveddata" })
    }

    @Test func derivedDataForgeriesAndSwapsAreRefused() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let (orphans, matched) = try derived(env)
        let p = try #require(await env.cleaner.makeOrphanedDerivedDataPlan())
        let real = try entry(p, "xcode.deriveddata")
        let outside = env.tmp.root + "/outside"
        try env.tmp.write(outside + "/victim.txt", "keep me")
        let forgeries: [CacheEntry] = [
            forged(real, id: "f1", instance: .some("../../outside")),                       // traversal
            forged(real, id: "f2", instance: .some("ModuleCache.noindex")),                  // fails the name rule
            forged(real, id: "f3", instance: .some("Unsaved_Xcode_Document-defghijklmnopqrstuvwxyzabcde")),   // no info.plist
            forged(real, id: "f4", packageDir: env.tmp.project, instance: .some(matched)),    // wrong root
            forged(real, id: "f5", instance: .some(nil)),                                     // no instance
        ]
        let r = try await env.cleaner.execute(replacing(p, with: forgeries),
                                              selections: forgeries.map { CleanupSelection(entryID: $0.id, mode: .permanent) }, progress: nil)
        for f in forgeries { expectSkipped(try outcome(r, f), .rootRejected) }
        #expect(env.tmp.exists(env.derivedRoot + "/" + matched + "/Build/y.o"))
        #expect(env.tmp.exists(outside + "/victim.txt"))

        // a child swapped for a symlink between plan and execute is skipped; link and destination survive
        let victim = orphans[0]
        try FileManager.default.removeItem(atPath: env.derivedRoot + "/" + victim)
        try env.tmp.write(outside + "/info.plist", String(decoding: try plist(["WorkspacePath": "/nowhere"]), as: UTF8.self))
        try env.tmp.symlink(env.derivedRoot + "/" + victim, to: outside)
        let swapped = try #require(p.entries.first { $0.instance == victim })
        let r2 = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: swapped.id, mode: .permanent)], progress: nil)
        let status = try outcome(r2, swapped).status
        #expect(status == .skipped(.symlink) || status == .skipped(.rootRejected), "\(status)")
        #expect(env.tmp.isSymlink(env.derivedRoot + "/" + victim))
        #expect(env.tmp.exists(outside + "/victim.txt") && env.tmp.exists(outside + "/info.plist"))
    }
}
