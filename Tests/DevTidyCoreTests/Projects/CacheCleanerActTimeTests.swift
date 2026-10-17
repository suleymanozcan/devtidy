import Foundation
import Darwin
import Testing
@testable import DevTidyCore

private final class ActCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// A latch that holds a step open for exactly as long as the test wants: `wait()` suspends until `open()`. No timer is
/// involved, so how long the held step "takes" cannot depend on how loaded the machine is.
private final class ActTimeLatch: @unchecked Sendable {
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

/// What the cleaner checks at the moment it acts, not when the run started: the order of its slow steps (Security N-2,
/// CodeReview P3-7), the git re-qualification of a contents-only rule's children (N-3), the Trash locations kept in the log
/// when a contents-only trash fails part-way (N-4) and the case-insensitive repository marker (N-9).
@Suite("CacheCleaner act-time checks (N-2, N-3, N-4, N-9, P3-7, F3-2, F3-6)")
struct CacheCleanerActTimeTests {
    // MARK: Helpers

    private func plan(_ env: S2Env) async throws -> CleanupPlan {
        var o = CatalogOptions()
        o.includeDerivedData = false
        return try #require(await env.cleaner.makePlan(forProjectAt: env.tmp.project, options: o))
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

    private func laravel(_ env: S2Env) throws {
        try env.tmp.write(env.tmp.p("artisan"), "#!/usr/bin/env php")
        try env.tmp.write(env.tmp.p("composer.json"), "{\"require\":{\"laravel/framework\":\"^11.0\"}}")
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["laravel-vite-plugin"])
    }

    /// `storage/framework/views` (class A, contents-only) with two ignored compiled views.
    private func viewsProject(_ env: S2Env) throws -> String {
        try laravel(env)
        let views = env.tmp.p("storage/framework/views")
        try env.tmp.write(views + "/a1.php", block())
        try env.tmp.write(views + "/b2.php", block())
        env.git.ignored = [views + "/a1.php", views + "/b2.php"]
        return views
    }

    private func allocated(_ path: String) throws -> Int64 {
        try #require(SafeFS.lstatAbsolute(path)).blocks * 512
    }

    // MARK: N-2 / P3-7 — the walk is the last slow step, and a blocked target never pays for it

    /// The walk used to run BEFORE the blocker check (a process scan and a Docker snapshot, seconds): a worktree that
    /// appeared during it was deleted. The repository is created from inside the blocker check here.
    @Test func aRepositoryThatAppearsWhileTheBlockersAreCheckedIsStillSeen() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try distProject(env)
        let p = try await plan(env)
        let e = try entry(p, "dist.generic")
        let nested = env.tmp.p("dist/wt/.git")
        env.activity.onCall = {
            try? FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: nested + "/HEAD", contents: Data("ref: refs/heads/x".utf8))
        }
        for mode in [DeleteMode.permanent, DeleteMode.trash] {
            let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: mode)], progress: nil)
            #expect(try outcome(r, e).status == .skipped(.containsRepository), "\(mode)")
        }
        #expect(env.tmp.exists(env.tmp.p("dist/index.js")) && env.tmp.exists(nested + "/HEAD"))
        #expect(env.trasher.trashed.isEmpty)
        #expect(env.audit.events.map(\.result) == ["skipped:containsRepository", "skipped:containsRepository"],
                "seen before any intent line")
    }

    /// CodeReview P3-7: with the blockers first, a blocked target is reported as blocked and the walk never starts for it.
    /// The same plan is refused for the repository as soon as nothing blocks any more, so the walk was not dropped.
    @Test func aBlockedTargetIsReportedAsBlockedBeforeTheNestedRepositoryWalk() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try distProject(env)
        try env.tmp.write(env.tmp.p("dist/wt/.git/HEAD"), "ref: refs/heads/x")
        env.activity.blockers = [S2FakeActivity.blocker(.hard)]
        let p = try await plan(env)
        let e = try entry(p, "dist.generic")
        let selection = [CleanupSelection(entryID: e.id, mode: .permanent)]

        let blocked = try await env.cleaner.execute(p, selections: selection, progress: nil)
        #expect(try outcome(blocked, e).status == .skipped(.blockedByActivity))
        #expect(env.audit.events.map(\.result) == ["skipped:blockedByActivity"])

        env.activity.blockers = []
        let free = try await env.cleaner.execute(p, selections: selection, progress: nil)
        #expect(try outcome(free, e).status == .skipped(.containsRepository))
        #expect(env.tmp.exists(env.tmp.p("dist/index.js")) && env.tmp.exists(env.tmp.p("dist/wt/.git/HEAD")))
    }

    // MARK: F3-2 — the blockers are asked again after the slow step

    /// The first blocker check stays in front of the walk (a blocked target never pays for it), but the walk can take
    /// seconds. The walk is held open here, a hard blocker "appears" while it is held, and the target is refused: with the
    /// verdict taken before the walk the directory would have been removed under a server that had just started.
    @Test func aServerThatStartsWhileTheNestedRepositoryWalkRunsRefusesTheRemoval() async throws {
        let walkStarted = ActTimeLatch()
        let walkMayFinish = ActTimeLatch()
        let env = try S2Env(nestedScan: { path, expected, rootDev, limits in
            walkStarted.open()
            await walkMayFinish.wait()
            return RepositoryScanner.scan(path: path, expected: expected, rootDev: rootDev, limits: limits)
        })
        defer { env.tmp.cleanup() }
        try distProject(env)
        let p = try await plan(env)
        let e = try entry(p, "dist.generic")
        let asked = env.activity.roots.count                      // the plan's own check

        let cleaner = env.cleaner
        let selection = [CleanupSelection(entryID: e.id, mode: .permanent)]
        let run = Task { try await cleaner.execute(p, selections: selection, progress: nil) }
        await walkStarted.wait()
        #expect(env.activity.roots.count == asked + 1, "the first check ran before the walk started")
        env.activity.blockers = [S2FakeActivity.blocker(.hard)]   // `npm run dev` starts while the walk is running
        walkMayFinish.open()

        let result = try await run.value
        #expect(try outcome(result, e).status == .skipped(.blockedByActivity))
        #expect(env.activity.roots.count == asked + 2, "asked again once the walk was over")
        #expect(env.tmp.exists(env.tmp.p("dist/index.js")))
        #expect(env.audit.events.map(\.result) == ["skipped:blockedByActivity"], "refused before any intent line")
    }

    /// The same for a contents-only target, whose slow step is git's re-qualification of the children (N-3): the second
    /// `trackedPaths` question is the one the cleaner asks at act time, and the server "starts" during it.
    @Test func aServerThatStartsWhileTheChildrenAreRequalifiedRefusesTheRemoval() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let views = try viewsProject(env)
        let p = try await plan(env)
        let e = try entry(p, "laravel.views")
        let asked = env.activity.roots.count

        let activity = env.activity
        let calls = ActCalls()
        env.git.onTracked = { _ in    // 1 = the run's own qualification of the children, 2 = the re-qualification at act time
            if calls.next() == 2 { activity.blockers = [S2FakeActivity.blocker(.hard)] }
        }
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        #expect(try outcome(r, e).status == .skipped(.blockedByActivity))
        #expect(env.tmp.exists(views + "/a1.php") && env.tmp.exists(views + "/b2.php"))
        #expect(env.activity.roots.count == asked + 2)
        #expect(env.audit.events.map(\.result) == ["skipped:blockedByActivity"], "refused before any intent line")
    }

    /// The second check must not turn into a refusal of its own: with nothing running, the target is still removed, and the
    /// activity is asked exactly twice for it (before and after the slow step).
    @Test func aTargetNothingBlocksIsStillRemovedAfterTheSecondCheck() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try distProject(env)
        let p = try await plan(env)
        let e = try entry(p, "dist.generic")
        let asked = env.activity.roots.count
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        guard case .deleted = try outcome(r, e).status else { Issue.record("expected deleted, got \(try outcome(r, e).status)"); return }
        #expect(!env.tmp.exists(env.tmp.p("dist")))
        #expect(env.activity.roots.count == asked + 2)
        #expect(env.audit.events.map(\.result) == ["intent", "deleted"])
    }

    // MARK: N-3 — contents-only children are asked of git again when the cleaner acts

    /// `git add -f` of one compiled view after the run started and its children were qualified.
    @Test func aChildThatBecomesTrackedBeforeTheRemovalIsKept() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let views = try viewsProject(env)
        let p = try await plan(env)
        let e = try entry(p, "laravel.views")
        #expect(e.itemCount == 2)
        let removedBytes = try allocated(views + "/a1.php")

        let git = env.git
        let calls = ActCalls()
        git.onTracked = { _ in    // 1 = the run's own qualification of the children, 2 = the re-qualification at act time
            if calls.next() == 1 { git.tracked = git.tracked.union([views + "/b2.php"]) }
        }
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        #expect(try outcome(r, e).status == .deleted(bytes: removedBytes), "only the child that is still untracked is counted")
        #expect(!env.tmp.exists(views + "/a1.php"))
        #expect(env.tmp.exists(views + "/b2.php"), "a child git started tracking is never removed")
        #expect(env.audit.events.map(\.result) == ["intent", "deleted"])
    }

    @Test func ifEveryChildBecameTrackedNothingIsRemovedAndNoIntentLineIsWritten() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let views = try viewsProject(env)
        let p = try await plan(env)
        let e = try entry(p, "laravel.views")
        let git = env.git
        let calls = ActCalls()
        git.onTracked = { _ in
            if calls.next() == 1 { git.tracked = git.tracked.union([views + "/a1.php", views + "/b2.php"]) }
        }
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        #expect(try outcome(r, e).status == .skipped(.trackedByGit))
        #expect(env.tmp.exists(views + "/a1.php") && env.tmp.exists(views + "/b2.php"))
        #expect(env.audit.events.map(\.result) == ["skipped:trackedByGit"])
        #expect(r.freedBytes == 0)
    }

    /// The re-qualification can only narrow the list the run validated: a view compiled after that is not on it.
    @Test func aChildThatAppearsAfterTheValidationIsNeverAdded() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let views = try viewsProject(env)
        let p = try await plan(env)
        let e = try entry(p, "laravel.views")
        let removedBytes = try allocated(views + "/a1.php") + allocated(views + "/b2.php")

        let git = env.git
        let calls = ActCalls()
        let late = views + "/c3.php"
        git.onTracked = { _ in
            if calls.next() == 1 {
                FileManager.default.createFile(atPath: late, contents: Data(repeating: 1, count: 4096))
                git.ignored = git.ignored.union([late])
            }
        }
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        #expect(try outcome(r, e).status == .deleted(bytes: removedBytes))
        #expect(!env.tmp.exists(views + "/a1.php") && !env.tmp.exists(views + "/b2.php"))
        #expect(env.tmp.exists(late), "not on the validated list ⇒ not removed")
    }

    // MARK: N-4 — a contents-only trash that fails part-way still logs where the moved children went

    @Test func aTrashThatFailsPartWayKeepsTheLocationsOfWhatWasAlreadyMoved() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        let cache = env.tmp.p("bootstrap/cache")
        try env.tmp.write(cache + "/packages.php", block())
        try env.tmp.write(cache + "/services.php", block())
        env.git.ignored = [cache + "/packages.php", cache + "/services.php"]
        let p = try await plan(env)
        let e = try entry(p, "laravel.bootcache")
        env.trasher.failFromCall = 2          // children are processed in sorted order: packages.php moves, services.php fails

        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .trash)], progress: nil)
        guard case .failed = try outcome(r, e).status else { Issue.record("expected failed, got \(try outcome(r, e).status)"); return }
        let landed = try #require(env.trasher.landed.first)
        #expect(env.trasher.landed.count == 1)
        #expect(!env.tmp.exists(cache + "/packages.php") && env.tmp.exists(cache + "/services.php"))

        let line = try #require(env.audit.resultLines.last)
        #expect(line.result.hasPrefix("failed:"))
        #expect(line.detail["trashURL"] == landed.path, "the log says where the moved child is")
        #expect(env.audit.events.map(\.result).first == "intent")
    }

    // MARK: F3-6 — the trash locations of one audit line are bounded

    /// More children than the log lists: every child is moved, the line names a prefix of them and counts the rest.
    @Test func theTrashLocationsOfALargeContentsOnlyMoveAreBoundedInTheAuditLine() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        let views = env.tmp.p("storage/framework/views")
        let limit = CacheCleaner.auditTrashURLLimit
        let total = limit + 25
        var ignored = Set<String>()
        for i in 0..<total {
            let child = views + "/" + String(format: "v%03d.php", i)       // sorted order is numeric order
            try env.tmp.write(child, block(64))
            ignored.insert(child)
        }
        env.git.ignored = ignored
        let p = try await plan(env)
        let e = try entry(p, "laravel.views")
        #expect(e.itemCount == total)

        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .trash)], progress: nil)
        guard case .movedToTrash = try outcome(r, e).status else { Issue.record("expected trashed, got \(try outcome(r, e).status)"); return }
        #expect(env.trasher.landed.count == total, "everything was moved: only the listing in the log is cut")

        // Which bound bites first (the 50 locations or the 8 KiB) depends on how long `$TMPDIR` is; the line must be cut by
        // one of them, name a prefix of what was moved, and count exactly the rest.
        let field = try #require(env.audit.resultLines.last?.detail["trashURL"])
        let lines = field.components(separatedBy: "\n")
        let kept = lines.count - 1
        #expect(kept >= 1 && kept <= limit, "got \(kept) locations")
        #expect(lines.last == "+\(total - kept) more")
        #expect(Array(lines.dropLast()) == env.trasher.landed.prefix(kept).map(\.path), "a prefix, in the order the children were moved")
        #expect(lines.dropLast().joined(separator: "\n").utf8.count <= CacheCleaner.auditTrashURLBytes)
    }

    @Test func theTrashFieldIsAPrefixWithinBothBoundsAndNamesTheRest() {
        let short = (0..<10).map { "/t/\($0)" }                           // 4 bytes each
        #expect(CacheCleaner.boundedTrashURLField(short) == short.joined(separator: "\n"), "within the bounds nothing changes")
        #expect(CacheCleaner.boundedTrashURLField([]) == "")
        #expect(CacheCleaner.boundedTrashURLField(short, limit: 4) == "/t/0\n/t/1\n/t/2\n/t/3\n+6 more")
        // 4 + (1 + 4) + (1 + 4) = 14 bytes: three fit in a 14-byte budget, the fourth does not
        #expect(CacheCleaner.boundedTrashURLField(short, maxBytes: 14) == "/t/0\n/t/1\n/t/2\n+7 more")
        // bytes, not characters: "/ğ/a" is five bytes
        let wide = ["/ğ/a", "/ğ/b"]
        #expect(CacheCleaner.boundedTrashURLField(wide, maxBytes: 11) == "/ğ/a\n/ğ/b")
        #expect(CacheCleaner.boundedTrashURLField(wide, maxBytes: 10) == "/ğ/a\n+1 more")
    }

    @Test func longLocationsHitTheByteBoundBeforeTheCountBound() {
        let count = 200
        let long = (0..<count).map { "/t/" + String(repeating: "x", count: 597) + String(format: "%03d", $0) }   // 603 bytes
        let field = CacheCleaner.boundedTrashURLField(long)
        let lines = field.components(separatedBy: "\n")
        let kept = lines.count - 1
        #expect(kept > 0 && kept < CacheCleaner.auditTrashURLLimit, "the byte bound cuts the list, not the count bound")
        #expect(lines.last == "+\(count - kept) more")
        #expect(lines.dropLast().joined(separator: "\n").utf8.count <= CacheCleaner.auditTrashURLBytes)
        #expect(Array(lines.dropLast()) == Array(long.prefix(kept)), "still a prefix")
    }

    // MARK: N-9 — the repository marker is `.git` in any letter case

    @Test(arguments: [".git", ".GIT", ".Git", ".gIT", ".gIt"])
    func theMarkerMatchesEveryCaseOfDotGit(_ name: String) {
        #expect(RepositoryScanner.isRepositoryMarker(Array(name.utf8CString)))
    }

    @Test(arguments: [".gitignore", ".github", ".gitkeep", ".git ", " .git", "git", ".gi", ".GITX", ".g1t", "..git", "x.git", ""])
    func theMarkerMatchesNothingElse(_ name: String) {
        #expect(!RepositoryScanner.isRepositoryMarker(Array(name.utf8CString)))
    }

    @Test func aNameThatIsNotUTF8IsNeverTheMarker() {
        let raw: [CChar] = [0x2E, CChar(bitPattern: 0xFF), 0x69, 0x74, 0]
        #expect(!RepositoryScanner.isRepositoryMarker(raw))
    }

    @Test func theWalkFindsAMarkerInAnyCaseAndReportsItsOwnSpelling() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let root = t.root + "/work"
        try t.write(root + "/a/b/c.txt", "c")
        func scan() -> NestedRepositoryScan {
            guard let st = SafeFS.lstatAbsolute(root) else { return .unreadable }
            return RepositoryScanner.scan(path: root, expected: st.identity, rootDev: st.dev)
        }
        #expect(scan() == .clean)
        try t.write(root + "/a/b/deep/.GiT/HEAD", "ref")                 // a directory
        #expect(scan() == .found("a/b/deep/.GiT"))
        try FileManager.default.removeItem(atPath: root + "/a/b/deep")
        try t.write(root + "/a/.Git", "gitdir: /x")                       // a worktree's gitlink file
        #expect(scan() == .found("a/.Git"))
        try FileManager.default.removeItem(atPath: root + "/a/.Git")
        try t.write(root + "/.GIT", "gitdir: /x")                         // at the very top
        #expect(scan() == .found(".GIT"))
    }

    @Test func aTargetHoldingAnUpperCaseRepositoryIsNeverRemoved() async throws {
        for mode in [DeleteMode.trash, DeleteMode.permanent] {
            let env = try S2Env()
            defer { env.tmp.cleanup() }
            try distProject(env)
            try env.tmp.write(env.tmp.p("dist/vendor/.GiT/HEAD"), "ref: refs/heads/gh-pages")
            let p = try await plan(env)
            let e = try entry(p, "dist.generic")
            let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: mode)], progress: nil)
            #expect(try outcome(r, e).status == .skipped(.containsRepository), "\(mode)")
            #expect(env.tmp.exists(env.tmp.p("dist/index.js")) && env.tmp.exists(env.tmp.p("dist/vendor/.GiT/HEAD")))
            #expect(env.trasher.trashed.isEmpty)
            #expect(env.audit.events.map(\.result) == ["skipped:containsRepository"])
        }
    }
}
