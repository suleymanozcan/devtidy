import Foundation
import Testing
@testable import DevTidyCore

/// Records every invocation and answers with a canned result (no process is spawned).
final class S2StubRunner: CommandRunning, @unchecked Sendable {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var result: CommandResult
    private var error: CommandError?

    init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "", timedOut: Bool = false, error: CommandError? = nil) {
        result = CommandResult(exitCode: exitCode, standardOutput: Data(stdout.utf8), standardError: Data(stderr.utf8), timedOut: timedOut)
        self.error = error
    }

    var calls: [Call] { lock.withLock { _calls } }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock { _calls.append(Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout)) }
        if let e = error { throw e }
        return result
    }
}

@Suite("GitProbe (R10, D7)")
struct GitProbeTests {
    // MARK: Command shape (no real git)

    @Test func commandShapeEnvironmentAndTimeout() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let runner = S2StubRunner(exitCode: 0, stdout: "")
        let probe = GitProbe(runner: runner, locator: S2Locator(home: t.home))
        _ = await probe.trackedPaths(inParent: t.project, paths: ["-weird name", ".next"])
        _ = await probe.ignoredPaths(inParent: t.project, paths: [".next"])
        _ = await probe.untrackedNotIgnoredPaths(inParent: t.project, paths: [".next"])
        let calls = runner.calls
        #expect(calls.count == 3)
        for c in calls {
            let isCheckIgnore = c.arguments.contains("check-ignore")
            // `git check-ignore` rejects both `--literal-pathspecs` and `-z` (without --stdin) with exit 128 [obs, git 2.50].
            if isCheckIgnore {
                #expect(c.arguments.starts(with: ["-c", "core.fsmonitor=false", "-C", t.project]))
                #expect(!c.arguments.contains("--literal-pathspecs"))
                #expect(!c.arguments.contains("-z"))
            } else {
                #expect(c.arguments.starts(with: ["--literal-pathspecs", "-c", "core.fsmonitor=false", "-C", t.project]))
                #expect(c.arguments.contains("-z"))
            }
            #expect(c.executable.path == "/usr/bin/git")
            #expect(c.arguments.contains("--"))
            #expect(c.environment["GIT_OPTIONAL_LOCKS"] == "0")
            #expect(c.environment["GIT_TERMINAL_PROMPT"] == "0")
            #expect(c.environment["LC_ALL"] == "C")
            #expect(c.timeout == 5)
        }
        // a leading-dash name sits AFTER `--`
        let args = calls[0].arguments
        let dashIndex = try #require(args.firstIndex(of: "--"))
        let weird = try #require(args.firstIndex(of: "-weird name"))
        #expect(weird > dashIndex)
        #expect(Array(args[(dashIndex + 1)...]) == ["-weird name", ".next"])
    }

    @Test func outcomesAreFailClosed() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let locator = S2Locator(home: t.home)
        // dubious ownership is NOT "not a repository"
        let dubious = GitProbe(runner: S2StubRunner(exitCode: 128, stderr: "fatal: detected dubious ownership in repository"), locator: locator)
        #expect(await dubious.trackedPaths(inParent: t.project, paths: ["x"]) == .failed("fatal: detected dubious ownership in repository"))
        if case .failed = await dubious.toplevel(of: t.project) {} else { Issue.record("dubious ownership must fail closed") }
        // a plain "not a git repository" is recognized
        let notRepo = GitProbe(runner: S2StubRunner(exitCode: 128, stderr: "fatal: not a git repository (or any of the parent directories): .git"), locator: locator)
        #expect(await notRepo.trackedPaths(inParent: t.project, paths: ["x"]) == .notARepository)
        #expect(await notRepo.toplevel(of: t.project) == .notARepository)
        #expect(await notRepo.ignoredPaths(inParent: t.project, paths: ["x"]) == .notARepository)
        // …unless a `.git` entry exists right there (corrupt repository ⇒ error, never "no repo")
        try t.mkdir(t.project + "/.git")
        if case .failed = await notRepo.trackedPaths(inParent: t.project, paths: ["x"]) {} else { Issue.record("corrupt .git must fail closed") }
        // timeout and launch failure
        let timeout = GitProbe(runner: S2StubRunner(exitCode: 0, timedOut: true), locator: locator)
        if case .failed = await timeout.trackedPaths(inParent: t.project, paths: ["x"]) {} else { Issue.record("timeout must fail") }
        let launch = GitProbe(runner: S2StubRunner(error: .launchFailed("nope")), locator: locator)
        if case .failed = await launch.ignoredPaths(inParent: t.project, paths: ["x"]) {} else { Issue.record("launch failure must fail") }
        // git missing
        let noGit = GitProbe(runner: S2StubRunner(), locator: S2Locator(home: t.home, hasGit: false))
        if case .failed = await noGit.toplevel(of: t.project) {} else { Issue.record("missing git must fail") }
    }

    @Test func batchesAreChunked() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let runner = S2StubRunner(exitCode: 0)
        let probe = GitProbe(runner: runner, locator: S2Locator(home: t.home))
        let names = (0..<250).map { "n\($0)" }
        _ = await probe.trackedPaths(inParent: t.project, paths: names)
        #expect(runner.calls.count == 3)
        _ = await probe.trackedPaths(inParent: t.project, paths: [])
        #expect(runner.calls.count == 3, "no paths ⇒ no process")
    }

    // MARK: Real /usr/bin/git in temp repositories

    @Test(.enabled(if: S2RealGit.available))
    func trackedFileInsideIgnoredDirIsReported() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.write(t.p(".gitignore"), "build/\n")
        try t.write(t.p("build/keep.txt"), "tracked anyway")
        try S2RealGit.run(["add", "-f", "build/keep.txt", ".gitignore"], in: t.project, home: t.home)
        try S2RealGit.commitAll(in: t.project, home: t.home)
        let probe = S2RealGit.probe(home: t.home)
        #expect(await probe.trackedPaths(inParent: t.project, paths: ["build"]) == .paths(["build/keep.txt"]))
    }

    @Test(.enabled(if: S2RealGit.available))
    func ignoredDirectoryIsInTheIgnoredSet() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.write(t.p(".gitignore"), "dist/\n")
        try t.write(t.p("dist/a.js"), "x")
        try t.write(t.p("src/a.js"), "x")
        try S2RealGit.run(["add", ".gitignore", "src"], in: t.project, home: t.home)
        try S2RealGit.commitAll(in: t.project, home: t.home)
        let probe = S2RealGit.probe(home: t.home)
        #expect(await probe.ignoredPaths(inParent: t.project, paths: ["dist", "src"]) == .ignored(["dist"]))
        #expect(await probe.trackedPaths(inParent: t.project, paths: ["dist"]) == .paths([]))
        #expect(await probe.untrackedNotIgnoredPaths(inParent: t.project, paths: ["dist"]) == .paths([]))
        #expect(await probe.toplevel(of: t.project + "/src") == .repository(t.project))
    }

    @Test(.enabled(if: S2RealGit.available))
    func partiallyIgnoredDirectoryHasUntrackedFiles() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.write(t.p(".gitignore"), "build/*\n!build/keep\n")
        try t.write(t.p("build/keep"), "source-ish")
        try t.write(t.p("build/gen.js"), "generated")
        try S2RealGit.run(["add", ".gitignore"], in: t.project, home: t.home)
        try S2RealGit.run(["commit", "-q", "-m", "init"], in: t.project, home: t.home)   // `build/keep` stays untracked on purpose
        let probe = S2RealGit.probe(home: t.home)
        let untracked = await probe.untrackedNotIgnoredPaths(inParent: t.project, paths: ["build"])
        #expect(untracked == .paths(["build/keep"]))
        #expect(await probe.ignoredPaths(inParent: t.project, paths: ["build/gen.js"]) == .ignored(["build/gen.js"]))
    }

    @Test(.enabled(if: S2RealGit.available))
    func noRepositoryIsReportedAsSuch() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let probe = S2RealGit.probe(home: t.home)
        #expect(await probe.toplevel(of: t.project) == .notARepository)
        #expect(await probe.trackedPaths(inParent: t.project, paths: ["x"]) == .notARepository)
        #expect(await probe.ignoredPaths(inParent: t.project, paths: ["x"]) == .notARepository)
        #expect(await probe.untrackedNotIgnoredPaths(inParent: t.project, paths: ["x"]) == .notARepository)
    }

    @Test(.enabled(if: S2RealGit.available))
    func corruptGitEntryFailsClosed() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let probe = S2RealGit.probe(home: t.home)
        // a `.git` FILE with garbage
        try t.write(t.p(".git"), "garbage\n")
        if case .failed = await probe.trackedPaths(inParent: t.project, paths: ["x"]) {} else { Issue.record("garbage gitfile must fail closed") }
        if case .failed = await probe.toplevel(of: t.project) {} else { Issue.record("garbage gitfile must fail closed") }
        // a gitfile pointing nowhere: git says "not a git repository" but a .git entry exists ⇒ still an error
        try t.write(t.p(".git"), "gitdir: /nonexistent/devtidy-s2/gitdir\n")
        if case .failed = await probe.trackedPaths(inParent: t.project, paths: ["x"]) {} else { Issue.record("dangling gitfile must fail closed") }
        if case .failed = await probe.ignoredPaths(inParent: t.project, paths: ["x"]) {} else { Issue.record("dangling gitfile must fail closed") }
    }

    @Test(.enabled(if: S2RealGit.available))
    func namesWithSpacesAndLeadingDashAreHandled() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.write(t.p(".gitignore"), "with space/\n/-dash/\n")
        try t.write(t.p("with space/a.txt"), "x")
        try t.write(t.p("-dash/b.txt"), "x")
        try t.write(t.p("keep.txt"), "x")
        try S2RealGit.run(["add", ".gitignore", "keep.txt"], in: t.project, home: t.home)
        try S2RealGit.commitAll(in: t.project, home: t.home)
        let probe = S2RealGit.probe(home: t.home)
        #expect(await probe.ignoredPaths(inParent: t.project, paths: ["with space", "-dash", "keep.txt"]) == .ignored(["with space", "-dash"]))
        #expect(await probe.trackedPaths(inParent: t.project, paths: ["-dash", "with space"]) == .paths([]))
        #expect(await probe.trackedPaths(inParent: t.project, paths: ["keep.txt"]) == .paths(["keep.txt"]))
        #expect(await probe.untrackedNotIgnoredPaths(inParent: t.project, paths: ["-dash", "with space"]) == .paths([]))
    }

    /// `check-ignore` cannot run with `--literal-pathspecs`: a leading ":" would be pathspec magic and a name git C-quotes
    /// (`"`) cannot be matched on the newline-separated output. Both must stay "not ignored" without poisoning the batch.
    @Test(.enabled(if: S2RealGit.available))
    func namesGitCannotEchoBackAreNeverReportedIgnored() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.write(t.p(".gitignore"), "dist/\n/:odd/\n/quo*te/\n")
        try t.write(t.p("dist/a.js"), "x")
        try t.write(t.p(":odd/a.js"), "x")
        try t.write(t.p("quo\"te/a.js"), "x")
        let probe = S2RealGit.probe(home: t.home)
        #expect(await probe.ignoredPaths(inParent: t.project, paths: [":odd", "dist", "quo\"te"]) == .ignored(["dist"]))
    }

    @Test(.enabled(if: S2RealGit.available))
    func pathspecsAreLiteral() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.write(t.p("a.txt"), "x")
        try t.write(t.p("b.txt"), "x")
        try S2RealGit.run(["add", "a.txt", "b.txt"], in: t.project, home: t.home)
        try S2RealGit.commitAll(in: t.project, home: t.home)
        let probe = S2RealGit.probe(home: t.home)
        // `*.txt` must not glob under --literal-pathspecs
        #expect(await probe.trackedPaths(inParent: t.project, paths: ["*.txt"]) == .paths([]))
    }

    @Test(.enabled(if: S2RealGit.available))
    func nestedRepositoryIsAnsweredByTheNearestOne() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let nested = t.project + "/apps/web"
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.mkdir(nested)
        try S2RealGit.initRepo(at: nested, home: t.home)
        try t.write(nested + "/.gitignore", ".next/\n")
        try t.write(nested + "/.next/x", "x")
        let probe = S2RealGit.probe(home: t.home)
        #expect(await probe.toplevel(of: nested) == .repository(nested))
        #expect(await probe.ignoredPaths(inParent: nested, paths: [".next"]) == .ignored([".next"]))
    }

    /// End to end with the real probe: a class B directory (`target`) is offered only when git confirms it is ignored and
    /// untracked. Guards the `check-ignore` invocation, whose failure silently turned every class B/C entry into
    /// `gitUnavailable` (invisible in the app) while all fake-git tests stayed green.
    @Test(.enabled(if: S2RealGit.available))
    func classBEntryNeedsAndGetsRealGitEvidence() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try S2RealGit.initRepo(at: t.project, home: t.home)
        try t.write(t.p("Cargo.toml"), "[package]\nname=\"x\"")
        try t.write(t.p("src/main.rs"), "fn main(){}")
        try t.write(t.p("target/debug/x"), String(repeating: "r", count: 8192))
        func offered() async -> Bool {
            let probe = S2RealGit.probe(home: t.home)
            let catalog = CacheCatalog(projects: ProjectDetector(homeDirectory: t.home, git: probe), git: probe,
                                       homeDirectory: t.home, derivedDataRoot: t.home + "/DerivedData")
            var options = CatalogOptions()
            options.includeDerivedData = false
            let report = await catalog.report(forProjectAt: t.project, options: options)
            return report?.entries.contains { $0.ruleID == "rust.target" } ?? false
        }
        #expect(await offered() == false, "not ignored ⇒ never offered")
        try t.write(t.p(".gitignore"), "target/\n")
        #expect(await offered() == true, "ignored and untracked ⇒ offered")
    }
}
