import Foundation
import Darwin
import Testing
@testable import DevTidyCore

/// Holds the walk inside its `pauseAtVisit`-th directory visit until `release()`, so a test can cancel at a known point.
private final class S2WalkGate: @unchecked Sendable {
    private let lock = NSLock()
    private let pauseAt: Int
    private var count = 0
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    init(pauseAtVisit: Int) { pauseAt = pauseAtVisit }

    var visits: Int { lock.withLock { count } }

    /// Called by the walk for every visited directory; blocks the walking thread at the pause point.
    func visit() {
        let n = lock.withLock { () -> Int in count += 1; return count }
        if n == pauseAt {
            reached.signal()
            resume.wait()
        }
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.reached.wait()
                continuation.resume()
            }
        }
    }

    func release() { resume.signal() }
}

private struct S2ScanResult {
    var reports: [ProjectCacheReport] = []
    var summary: BuildsScanSummary?
    var progress: [Int] = []
    var roots: Set<String> { Set(reports.map(\.project.root)) }
}

@Suite("BuildsScanner (§5.6)")
struct BuildsScannerTests {
    private func collect(_ env: S2Env, roots: [String], configure: (inout BuildsScanOptions) -> Void = { _ in }) async -> S2ScanResult {
        var options = BuildsScanOptions(roots: roots)
        options.catalog.includeDerivedData = false
        configure(&options)
        var result = S2ScanResult()
        for await event in env.catalog.scan(options) {
            switch event {
            case .progress(let n): result.progress.append(n)
            case .report(let r): result.reports.append(r)
            case .finished(let s): result.summary = s
            }
        }
        return result
    }

    private func block(_ n: Int) -> String { String(repeating: "x", count: n) }

    /// `<home>/dev`: a turbo monorepo with two Next apps, a solo Vite project, a project at depth 4, plus every trap.
    @discardableResult
    private func fixture(_ env: S2Env) throws -> (mono: String, solo: String, deep4: String) {
        let t = env.tmp
        let dev = t.home + "/dev"
        // monorepo: one .git at the root, two apps
        let mono = dev + "/mono"
        try t.mkdir(mono + "/.git")
        try t.packageJSON(at: mono, name: "mono")
        try t.write(mono + "/turbo.json", "{}")
        try t.write(mono + "/.turbo/cache.bin", block(4096))
        for app in ["web", "admin"] {
            try t.packageJSON(at: mono + "/apps/" + app, name: app, deps: ["next"])
            try t.write(mono + "/apps/\(app)/.next/x.bin", block(4096))
        }
        // solo project with a nested dependency package that must NEVER be treated as a project
        let solo = dev + "/solo"
        try t.packageJSON(at: solo, name: "solo", deps: ["vite"])
        try t.write(solo + "/node_modules/.vite/deps.bin", block(4096))
        try t.packageJSON(at: solo + "/node_modules/foo", name: "foo", deps: ["next"])
        try t.write(solo + "/node_modules/foo/.next/y.bin", block(4096))
        // depth-4 project (dev/d1/d2/d3/d4) and a depth-5 project below it (beyond maxDepth)
        let deep4 = dev + "/d1/d2/d3/d4"
        try t.packageJSON(at: deep4, name: "deep4", deps: ["next"])
        try t.write(deep4 + "/.next/z.bin", block(4096))
        try t.packageJSON(at: deep4 + "/d5", name: "deep5", deps: ["next"])
        try t.write(deep4 + "/d5/.next/z.bin", block(4096))
        // hidden dir, bundle, skip-listed names, symlink loop, symlinked project
        try t.packageJSON(at: dev + "/.hidden/proj", deps: ["next"])
        try t.write(dev + "/.hidden/proj/.next/h.bin", block(4096))
        try t.packageJSON(at: dev + "/Thing.app/Contents", deps: ["next"])
        try t.write(dev + "/Thing.app/Contents/.next/b.bin", block(4096))
        try t.packageJSON(at: dev + "/dist/inner", deps: ["next"])
        try t.write(dev + "/dist/inner/.next/d.bin", block(4096))
        try t.mkdir(dev + "/loopdir")
        try t.symlink(dev + "/loopdir/back", to: dev)
        try t.packageJSON(at: t.root + "/elsewhere/proj", deps: ["next"])
        try t.write(t.root + "/elsewhere/proj/.next/e.bin", block(4096))
        try t.symlink(dev + "/linked-project", to: t.root + "/elsewhere/proj")
        return (mono, solo, deep4)
    }

    @Test func fixtureTreeYieldsTheExpectedReports() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        let (mono, solo, deep4) = try fixture(env)
        let r = await collect(env, roots: [env.tmp.home + "/dev"])
        #expect(r.roots == [mono, solo, deep4], "got \(r.roots)")
        let s = try #require(r.summary)
        #expect(s.reportCount == 3)
        #expect(!s.truncated)
        #expect(s.permissionDeniedRoots.isEmpty)
        #expect(s.directoriesVisited > 5)

        let monoReport = try #require(r.reports.first { $0.project.root == mono })
        let monoEntries = Set(monoReport.entries.map { "\($0.ruleID)@\($0.packageDir)" })
        #expect(monoEntries == ["next.cache@\(mono)/apps/web", "next.cache@\(mono)/apps/admin", "turbo.cache@\(mono)"],
                "apps share ONE report grouped by the .git ceiling; got \(monoEntries)")
        #expect(monoReport.project.name == "mono")
        #expect(monoReport.project.repoRoot == mono)
        let soloReport = try #require(r.reports.first { $0.project.root == solo })
        #expect(Set(soloReport.entries.map(\.ruleID)) == ["vite.nm"])
        // reports are unsized (lazy sizing) and carry no `public`/dependency entries
        for report in r.reports { for e in report.entries { #expect(e.sizeBytes == nil && e.safety != .optIn) } }
        // nothing from the traps
        #expect(!r.roots.contains { $0.contains("node_modules") || $0.contains(".hidden") || $0.contains("Thing.app") })
        #expect(!r.roots.contains { $0.contains("/dist/") || $0.hasSuffix("/d5") || $0.contains("linked-project") || $0.contains("elsewhere") })
        #expect(env.tmp.exists(env.tmp.root + "/elsewhere/proj/.next/e.bin"))
    }

    @Test func scanningNeverModifiesTheTree() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        try fixture(env)
        func listing() -> [String] {
            (FileManager.default.subpaths(atPath: env.tmp.root) ?? []).sorted()
        }
        let before = listing()
        _ = await collect(env, roots: [env.tmp.home + "/dev"])
        #expect(listing() == before)
    }

    @Test func dependenciesAppearOnlyWithTheOption() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        let (_, solo, _) = try fixture(env)
        try env.tmp.write(solo + "/package-lock.json", "{}")
        env.git.ignored = [solo + "/node_modules"]
        let without = await collect(env, roots: [env.tmp.home + "/dev"])
        #expect(!without.reports.flatMap(\.entries).contains { $0.ruleID == "node.modules" })
        let with = await collect(env, roots: [env.tmp.home + "/dev"]) { $0.catalog.includeDependencies = true }
        let c = try #require(with.reports.flatMap(\.entries).first { $0.ruleID == "node.modules" })
        #expect(c.packageDir == solo && c.safety == .optIn)
        #expect(!with.reports.flatMap(\.entries).contains { $0.packageDir.contains("/node_modules/foo") })
    }

    @Test func classBEntriesNeedTheirGitEvidence() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        let proj = env.tmp.home + "/dev/rusty"
        try env.tmp.mkdir(proj + "/.git")
        try env.tmp.write(proj + "/Cargo.toml", "[package]")
        try env.tmp.write(proj + "/target/debug/x", block(4096))
        let plain = await collect(env, roots: [env.tmp.home + "/dev"])
        #expect(!plain.reports.flatMap(\.entries).contains { $0.ruleID == "rust.target" }, "not ignored ⇒ not offered")
        env.git.ignored = [proj + "/target"]
        let ignored = await collect(env, roots: [env.tmp.home + "/dev"])
        let e = try #require(ignored.reports.flatMap(\.entries).first { $0.ruleID == "rust.target" })
        #expect(e.defaultMode == .trash && !e.defaultSelected)
    }

    @Test func rootsOutsideHomeAtHomeOrDeniedAreIgnored() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        try fixture(env)
        try env.tmp.packageJSON(at: env.tmp.home + "/Library/Stuff/app", deps: ["next"])
        try env.tmp.write(env.tmp.home + "/Library/Stuff/app/.next/x", block(4096))
        let r = await collect(env, roots: [env.tmp.home, env.tmp.root + "/elsewhere", env.tmp.home + "/Library", env.tmp.home + "/missing"])
        #expect(r.reports.isEmpty)
        #expect(r.summary?.directoriesVisited == 0)
        #expect(r.summary?.truncated == false)
        #expect(r.summary?.permissionDeniedRoots.isEmpty == true)
    }

    @Test func directoryAndTimeBoundsReportTruncation() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        try fixture(env)
        let few = await collect(env, roots: [env.tmp.home + "/dev"]) { $0.maxDirectories = 3 }
        #expect(few.summary?.truncated == true)
        #expect(few.summary?.directoriesVisited == 3)
        let none = await collect(env, roots: [env.tmp.home + "/dev"]) { $0.maxSeconds = 0 }
        #expect(none.summary?.truncated == true)
        #expect(none.summary?.directoriesVisited == 0)
        let full = await collect(env, roots: [env.tmp.home + "/dev"])
        #expect(full.summary?.truncated == false)
        // the depth knob is clamped to 2…6
        let shallow = await collect(env, roots: [env.tmp.home + "/dev"]) { $0.maxDepth = 0 }
        #expect(!shallow.roots.contains(env.tmp.home + "/dev/d1/d2/d3/d4"))
        #expect(shallow.roots.contains(env.tmp.home + "/dev/mono"))
        let deeper = await collect(env, roots: [env.tmp.home + "/dev"]) { $0.maxDepth = 6 }
        #expect(deeper.roots.contains(env.tmp.home + "/dev/d1/d2/d3/d4"))
        #expect(deeper.roots.contains(env.tmp.home + "/dev/d1/d2/d3/d4/d5"))
    }

    @Test func gitBudgetFailsClosedAndMarksTruncation() async throws {
        let inner = S2FakeGit()
        let budget = BudgetedGit(base: inner, limit: 2)
        #expect(await budget.trackedPaths(inParent: "/x", paths: ["a"]) == .paths([]))
        #expect(await budget.ignoredPaths(inParent: "/x", paths: ["a"]) == .ignored([]))
        #expect(!budget.exceeded)
        if case .failed = await budget.untrackedNotIgnoredPaths(inParent: "/x", paths: ["a"]) {} else { Issue.record("over budget must fail") }
        if case .failed = await budget.toplevel(of: "/x") {} else { Issue.record("over budget must fail") }
        #expect(budget.exceeded)
        #expect(inner.calls.count == 2, "calls beyond the budget never reach git")
    }

    @Test func progressIsReportedEvery200Directories() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        for i in 0..<450 { try env.tmp.mkdir(env.tmp.home + "/dev/wide/d\(i)") }
        let r = await collect(env, roots: [env.tmp.home + "/dev"])
        #expect(r.progress.count >= 2)
        #expect(r.progress.allSatisfy { $0 % 200 == 0 })
        #expect((r.summary?.directoriesVisited ?? 0) >= 451)
    }

    @Test func unreadableRootIsReportedAsPermissionDenied() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        let locked = env.tmp.home + "/locked"
        try env.tmp.mkdir(locked + "/proj")
        #expect(chmod(locked, 0o000) == 0)
        defer { chmod(locked, 0o755) }
        let r = await collect(env, roots: [locked])
        #expect(r.summary?.permissionDeniedRoots == [locked])
        #expect(r.reports.isEmpty)
    }

    @Test func cancellingTheConsumerStopsTheProducer() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        for i in 0..<300 { try env.tmp.mkdir(env.tmp.home + "/dev/wide/d\(i)/s") }   // ≈ 600 directories
        let gate = S2WalkGate(pauseAtVisit: 20)
        let scanner = BuildsScanner(engine: env.catalog.engine, git: env.git, policy: PathPolicy(homeDirectory: env.tmp.home),
                                    now: { Date() }, onVisit: { gate.visit() })
        var options = BuildsScanOptions(roots: [env.tmp.home + "/dev"])
        options.catalog.includeDerivedData = false
        let task = Task { await scanner.run(options) { _ in } }
        await gate.waitUntilPaused()          // the walk is held inside visit 20
        task.cancel()
        gate.release()
        await task.value
        #expect(gate.visits == 20, "the walk stops at the first cancellation check after the visit it was held in")
    }

    /// P2-6: a burst of reports must reach a slow consumer intact — only progress events may ever be dropped.
    @Test func aSlowConsumerStillReceivesEveryReport() async throws {
        let env = try S2Env(repoAtProject: false)
        defer { env.tmp.cleanup() }
        let projects = 150                                   // well past the old 64-event buffer
        for i in 0..<projects {
            try env.tmp.packageJSON(at: env.tmp.home + "/dev/p\(i)", name: "p\(i)", deps: ["next"])
            try env.tmp.write(env.tmp.home + "/dev/p\(i)/.next/x.bin", block(4096))
        }
        var options = BuildsScanOptions(roots: [env.tmp.home + "/dev"])
        options.catalog.includeDerivedData = false
        var reports = 0
        var finished = false
        var first = true
        for await event in env.catalog.scan(options) {
            if first {
                first = false
                try await Task.sleep(for: .milliseconds(800))   // the producer runs ahead while nobody consumes
            }
            switch event {
            case .report: reports += 1
            case .finished: finished = true
            case .progress: break
            }
        }
        #expect(finished)
        #expect(reports == projects, "every report is delivered (got \(reports))")
    }
}
