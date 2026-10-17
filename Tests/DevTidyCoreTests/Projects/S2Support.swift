import Foundation
import Darwin
@testable import DevTidyCore

// Every S2 test builds a fake `home` under a mkdtemp directory so nothing touches the real home or any real project.

enum S2Error: Error { case mkdtemp(Int32), write(String), command(String) }

struct S2TempDir {
    /// `realpath(NSTemporaryDirectory()) + "/devtidy-s2-XXXXXX"`
    let root: String
    var home: String { root + "/home" }
    var project: String { home + "/dev/proj" }

    init(createProject: Bool = true) throws {
        let base = PathPolicy.canonical(NSTemporaryDirectory())
        var template = Array((base + "/devtidy-s2-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw S2Error.mkdtemp(errno) }
        root = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        try FileManager.default.createDirectory(atPath: home + "/dev", withIntermediateDirectories: true)
        if createProject { try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true) }
    }

    /// Project-relative absolute path.
    func p(_ rel: String) -> String { project + "/" + rel }

    func mkdir(_ absolute: String) throws {
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true)
    }

    func write(_ absolute: String, _ text: String = "x") throws {
        let dir = (absolute as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: absolute, contents: Data(text.utf8)) else { throw S2Error.write(absolute) }
    }

    func symlink(_ absolute: String, to destination: String) throws {
        let dir = (absolute as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: absolute, withDestinationPath: destination)
    }

    func exists(_ absolute: String) -> Bool { lstatExists(absolute) }

    func isSymlink(_ absolute: String) -> Bool {
        var st = stat()
        return lstat(absolute, &st) == 0 && (st.st_mode & 0o170000) == 0o120000
    }

    func read(_ absolute: String) -> String? {
        FileManager.default.contents(atPath: absolute).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Removes ONLY this temp tree (guarded by prefix) after restoring permissions of anything a test locked.
    func cleanup() {
        let base = PathPolicy.canonical(NSTemporaryDirectory())
        guard root.hasPrefix(base + "/devtidy-s2-"), !root.contains("..") else { return }
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let rel as String in e {
                let path = root + "/" + rel
                var st = stat()
                if lstat(path, &st) == 0, (st.st_mode & 0o170000) == 0o040000 { chmod(path, 0o755) }
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    /// A package.json with the given dependency names (devDependencies) and optional build script.
    func packageJSON(at dir: String, name: String = "app", deps: [String] = [], buildScript: Bool = false) throws {
        let depsJSON = deps.map { "\"\($0)\":\"1.0.0\"" }.joined(separator: ",")
        let scripts = buildScript ? "\"scripts\":{\"build\":\"x\"}," : ""
        try write(dir + "/package.json", "{\"name\":\"\(name)\",\(scripts)\"devDependencies\":{\(depsJSON)}}")
    }
}

private func lstatExists(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

// MARK: - Fakes ------------------------------------------------------------------------

/// Scripted git. Paths in the sets are ABSOLUTE; answers are derived from them.
final class S2FakeGit: GitProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _toplevel: GitRepoState = .notARepository
    private var _repository = true
    private var _failing = false
    private var _tracked = Set<String>()
    private var _ignored = Set<String>()
    private var _untracked = Set<String>()
    private var _calls: [String] = []
    private var _trackedCalls = 0
    private var _onTracked: (@Sendable (Int) -> Void)?

    var toplevelResult: GitRepoState { get { lock.withLock { _toplevel } } set { lock.withLock { _toplevel = newValue } } }
    /// false ⇒ every question answers `.notARepository`.
    var isRepository: Bool { get { lock.withLock { _repository } } set { lock.withLock { _repository = newValue } } }
    /// true ⇒ every question answers `.failed`.
    var failing: Bool { get { lock.withLock { _failing } } set { lock.withLock { _failing = newValue } } }
    var tracked: Set<String> { get { lock.withLock { _tracked } } set { lock.withLock { _tracked = newValue } } }
    var ignored: Set<String> { get { lock.withLock { _ignored } } set { lock.withLock { _ignored = newValue } } }
    var untracked: Set<String> { get { lock.withLock { _untracked } } set { lock.withLock { _untracked = newValue } } }
    var calls: [String] { lock.withLock { _calls } }
    /// Invoked AFTER each `trackedPaths` answer is computed, with the 1-based call index (race/TOCTOU simulation).
    var onTracked: (@Sendable (Int) -> Void)? { get { lock.withLock { _onTracked } } set { lock.withLock { _onTracked = newValue } } }

    private func note(_ s: String) { lock.withLock { _calls.append(s) } }
    private func mode() -> (repo: Bool, failing: Bool) { lock.withLock { (_repository, _failing) } }

    func toplevel(of directory: String) async -> GitRepoState {
        note("toplevel")
        return toplevelResult
    }

    func trackedPaths(inParent parent: String, paths: [String]) async -> GitListOutcome {
        note("tracked")
        let index = lock.withLock { () -> Int in _trackedCalls += 1; return _trackedCalls }
        let m = mode()
        let result: GitListOutcome
        if m.failing { result = .failed("fake") } else if !m.repo { result = .notARepository } else {
            result = .paths(list(tracked, parent: parent, paths: paths))
        }
        onTracked?(index)
        return result
    }

    func untrackedNotIgnoredPaths(inParent parent: String, paths: [String]) async -> GitListOutcome {
        note("untracked")
        let m = mode()
        if m.failing { return .failed("fake") }
        if !m.repo { return .notARepository }
        return .paths(list(untracked, parent: parent, paths: paths))
    }

    func ignoredPaths(inParent parent: String, paths: [String]) async -> GitBatchIgnoreOutcome {
        note("ignored")
        let m = mode()
        if m.failing { return .failed("fake") }
        if !m.repo { return .notARepository }
        let set = ignored
        let hits = paths.filter { p in
            let abs = parent + "/" + p
            return set.contains { abs == $0 || abs.hasPrefix($0 + "/") }
        }
        return .ignored(Set(hits))
    }

    private func list(_ files: Set<String>, parent: String, paths: [String]) -> [String] {
        var out: [String] = []
        for p in paths {
            let abs = parent + "/" + p
            for f in files where f == abs || f.hasPrefix(abs + "/") { out.append(String(f.dropFirst(parent.count + 1))) }
        }
        return out
    }
}

final class S2FakeActivity: ActivityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _blockers: [ActivityBlocker] = []
    private var _roots: [String] = []
    private var _onCall: (@Sendable () -> Void)?
    var blockers: [ActivityBlocker] { get { lock.withLock { _blockers } } set { lock.withLock { _blockers = newValue } } }
    var roots: [String] { lock.withLock { _roots } }
    /// Invoked on every `blockers(for:)` call (race/TOCTOU simulation).
    var onCall: (@Sendable () -> Void)? { get { lock.withLock { _onCall } } set { lock.withLock { _onCall = newValue } } }

    func blockers(for root: String) async -> [ActivityBlocker] {
        lock.withLock { _roots.append(root) }
        onCall?()
        return blockers
    }

    static func blocker(_ severity: ActivityBlocker.Severity, label: String = "node (PID 1)") -> ActivityBlocker {
        ActivityBlocker(kind: .process, severity: severity, label: label, pid: 1, containerID: nil)
    }
}

/// Records audit lines; `failFromAppend` makes every durable append from that 1-based attempt on fail (the line is NOT stored),
/// `onRecord` runs right after a line was stored (it sees the world as it is when the line is written).
final class S2FakeAudit: AuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AuditEvent] = []
    private var _writable = true
    private var _attempts = 0
    private var _failFrom: Int?
    private var _onRecord: (@Sendable (AuditEvent) -> Void)?
    var events: [AuditEvent] { lock.withLock { _events } }
    var writable: Bool { get { lock.withLock { _writable } } set { lock.withLock { _writable = newValue } } }
    var failFromAppend: Int? { get { lock.withLock { _failFrom } } set { lock.withLock { _failFrom = newValue } } }
    var onRecord: (@Sendable (AuditEvent) -> Void)? { get { lock.withLock { _onRecord } } set { lock.withLock { _onRecord = newValue } } }
    /// Lines excluding the `intent` lines the cleaner writes before it acts.
    var resultLines: [AuditEvent] { events.filter { $0.result != "intent" } }
    var intentLines: [AuditEvent] { events.filter { $0.result == "intent" } }

    func record(_ event: AuditEvent) async { _ = await recordDurably(event) }

    func recordDurably(_ event: AuditEvent) async -> Bool {
        let hook: (@Sendable (AuditEvent) -> Void)?? = lock.withLock {
            _attempts += 1
            if let from = _failFrom, _attempts >= from { return nil }
            _events.append(event)
            return .some(_onRecord)
        }
        guard let stored = hook else { return false }
        stored?(event)
        return true
    }

    func isWritable() async -> Bool { writable }
}

/// A test clock the cleaner and catalog read through their `now` seams.
final class S2Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date = Date()) { _now = start }
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

/// Moves the item into `<trashDir>` (inside the test's temp tree) or fails on demand. Never touches the real Trash.
final class S2FakeTrasher: Trashing, @unchecked Sendable {
    struct Failure: LocalizedError { var errorDescription: String? { "S2 trash failure" } }
    private let lock = NSLock()
    private var _trashed: [URL] = []
    private var _landed: [URL] = []
    private var _fail = false
    private var _calls = 0
    private var _failFromCall: Int?
    let trashDir: String
    init(trashDir: String) { self.trashDir = trashDir }
    var shouldFail: Bool { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
    /// Every call from this 1-based call number on fails (earlier calls succeed): a Trash that breaks part-way.
    var failFromCall: Int? { get { lock.withLock { _failFromCall } } set { lock.withLock { _failFromCall = newValue } } }
    var trashed: [URL] { lock.withLock { _trashed } }
    /// Where each trashed item ended up (what `NSFileManager.trashItem` reports as `resultingItemURL`).
    var landed: [URL] { lock.withLock { _landed } }

    func trash(_ url: URL) throws -> URL? {
        let call = lock.withLock { () -> Int in _calls += 1; return _calls }
        if shouldFail { throw Failure() }
        if let from = failFromCall, call >= from { throw Failure() }
        try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
        let dest = trashDir + "/" + UUID().uuidString + "-" + url.lastPathComponent
        try FileManager.default.moveItem(atPath: url.path, toPath: dest)
        lock.withLock {
            _trashed.append(url)
            _landed.append(URL(fileURLWithPath: dest))
        }
        return URL(fileURLWithPath: dest)
    }
}

struct S2Locator: ToolLocating {
    let home: String
    var hasGit = true
    func dockerExecutable() -> URL? { nil }
    func gitExecutable() -> URL? {
        hasGit && FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? URL(fileURLWithPath: "/usr/bin/git") : nil
    }
    func dockerSocketPath(override: String?) -> String? { nil }
    func isDockerDesktopInstalled() -> Bool { false }
    func childEnvironment() -> [String: String] {
        // GIT_CEILING_DIRECTORIES = the temp root, so git never discovers a repository above the test tree.
        ["HOME": home, "USER": "s2", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
         "GIT_CEILING_DIRECTORIES": (home as NSString).deletingLastPathComponent]
    }
}

/// Everything a catalog/cleaner test needs, wired to a temp home and fakes.
struct S2Env {
    let tmp: S2TempDir
    let git: S2FakeGit
    let detector: ProjectDetector
    let catalog: CacheCatalog
    let activity: S2FakeActivity
    let audit: S2FakeAudit
    let trasher: S2FakeTrasher
    let cleaner: CacheCleaner
    let derivedRoot: String

    init(repoAtProject: Bool = true, clock: S2Clock? = nil, scanLimits: RepositoryScanner.Limits = RepositoryScanner.Limits(),
         nestedScan: @escaping CacheCleaner.NestedScan = CacheCleaner.defaultNestedScan) throws {
        let tmp = try S2TempDir()
        let git = S2FakeGit()
        if repoAtProject { git.toplevelResult = .repository(tmp.project) }
        let now: @Sendable () -> Date
        if let clock { now = { clock.now } } else { now = { Date() } }
        let detector = ProjectDetector(homeDirectory: tmp.home, git: git, now: now)
        let derivedRoot = tmp.home + "/Library/Developer/Xcode/DerivedData"
        let catalog = CacheCatalog(projects: detector, git: git, homeDirectory: tmp.home, derivedDataRoot: derivedRoot, now: now)
        let activity = S2FakeActivity()
        let audit = S2FakeAudit()
        let trasher = S2FakeTrasher(trashDir: tmp.root + "/trash")
        self.tmp = tmp
        self.git = git
        self.detector = detector
        self.catalog = catalog
        self.activity = activity
        self.audit = audit
        self.trasher = trasher
        self.derivedRoot = derivedRoot
        self.cleaner = CacheCleaner(catalog: catalog, activity: activity, audit: audit, homeDirectory: tmp.home,
                                    trasher: trasher, now: now, scanLimits: scanLimits, nestedScan: nestedScan)
    }

    /// A Next.js project at `tmp.project`: `.next/` (with content), `src/`, `.env`, `public/`, `node_modules/`.
    func makeNextProject() throws {
        try tmp.packageJSON(at: tmp.project, deps: ["next"])
        try tmp.write(tmp.p(".next/dev/lock"), "lock")
        try tmp.write(tmp.p(".next/cache/x.bin"), String(repeating: "x", count: 8192))
        try tmp.write(tmp.p("src/page.tsx"), "export default 1")
        try tmp.write(tmp.p(".env"), "SECRET=1")
        try tmp.write(tmp.p("public/logo.txt"), "logo")
        try tmp.write(tmp.p("node_modules/dep/index.js"), "module.exports=1")
    }
}

/// Real-git test setup helper (synchronous; only used inside temp repositories).
enum S2RealGit {
    static var available: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    @discardableResult
    static func run(_ args: [String], in dir: String, home: String) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = S2Locator(home: home).childEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    static func initRepo(at dir: String, home: String) throws {
        try run(["init", "-q"], in: dir, home: home)
        try run(["config", "user.name", "s2"], in: dir, home: home)
        try run(["config", "user.email", "s2@example.invalid"], in: dir, home: home)
    }

    static func commitAll(in dir: String, home: String) throws {
        try run(["add", "-A"], in: dir, home: home)
        try run(["commit", "-q", "-m", "init"], in: dir, home: home)
    }

    static func probe(home: String) -> GitProbe {
        GitProbe(runner: ProcessCommandRunner(), locator: S2Locator(home: home))
    }
}
