import Foundation
import Darwin

// MARK: - Manifests (the only user files whose contents DevTidy reads, D13) ---------------

/// `package.json` facts: dependency names, `scripts.build`, package name, and the paths its own entry fields point at.
struct PackageManifest: Sendable, Equatable {
    let name: String?
    let dependencies: Set<String>      // dependencies ∪ devDependencies ∪ optionalDependencies
    let hasBuildScript: Bool
    /// Package-relative component lists named by `main`, `module`, `types`, `typings`, `browser`, `unpkg`, `jsdelivr`,
    /// `exports` (every nested condition), `bin`, `files`, `directories` and `typesVersions` (see `PackageEntryPaths`).
    let entryPaths: [[String]]

    static func load(directory: String) -> PackageManifest? {
        guard let data = SafeFS.readSmallFile(directory + "/package.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var deps = Set<String>()
        for key in ["dependencies", "devDependencies", "optionalDependencies"] {
            if let d = obj[key] as? [String: Any] { deps.formUnion(d.keys) }
        }
        let scripts = obj["scripts"] as? [String: Any]
        return PackageManifest(name: obj["name"] as? String, dependencies: deps, hasBuildScript: scripts?["build"] != nil,
                               entryPaths: PackageEntryPaths.collect(from: obj))
    }
}

/// `composer.json` facts: `require ∪ require-dev` package names.
struct ComposerManifest: Sendable, Equatable {
    let requires: Set<String>

    static func load(directory: String) -> ComposerManifest? {
        guard let data = SafeFS.readSmallFile(directory + "/composer.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var reqs = Set<String>()
        for key in ["require", "require-dev"] {
            if let d = obj[key] as? [String: Any] { reqs.formUnion(d.keys) }
        }
        return ComposerManifest(requires: reqs)
    }
}

// MARK: - Markers ------------------------------------------------------------------

enum ProjectMarkers {
    static let exactNames: Set<String> = [
        "package.json", "composer.json", "artisan", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt",
        "setup.py", "Pipfile", "manage.py", "Gemfile", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "pom.xml", "pubspec.yaml", "project.godot", "Package.swift", "turbo.json", "nx.json",
        "wrangler.json", "wrangler.jsonc", "wrangler.toml", ".git",
    ]

    static func isMarker(_ name: String) -> Bool {
        exactNames.contains(name) || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
    }

    static func hasMarker(in names: [String]) -> Bool { names.contains(where: isMarker) }
}

// MARK: - Kind detection -------------------------------------------------------------

enum ProjectKindDetector {
    /// Kinds for one directory, most specific first; `[.unknown]` when nothing is recognized.
    static func kinds(inDirectory dir: String, names: [String]) -> [ProjectKind] {
        let nameSet = Set(names)
        var kinds: [ProjectKind] = []
        func add(_ k: ProjectKind) { if !kinds.contains(k) { kinds.append(k) } }

        var jsFramework = false
        if nameSet.contains("package.json"), let pkg = PackageManifest.load(directory: dir) {
            let d = pkg.dependencies
            func has(_ n: String) -> Bool { d.contains(n) }
            if has("next") { add(.next) }
            if has("nuxt") || has("nuxt3") { add(.nuxt) }
            if has("@sveltejs/kit") { add(.svelteKit) }
            if has("astro") { add(.astro) }
            if d.contains(where: { $0.hasPrefix("@remix-run/") }) { add(.remix) }
            if has("@react-router/dev") { add(.reactRouter) }
            if has("gatsby") { add(.gatsby) }
            if has("@angular/core") { add(.angular) }
            if has("expo") { add(.expo) }
            if has("react-native") { add(.reactNative) }
            if has("parcel") { add(.parcel) }
            if has("vite") { add(.vite) }
            if has("wrangler") || d.contains(where: { $0.hasPrefix("@cloudflare/") }) { add(.cloudflareWorkers) }
            jsFramework = !kinds.isEmpty
        }
        if !nameSet.isDisjoint(with: ["wrangler.json", "wrangler.jsonc", "wrangler.toml"]) { add(.cloudflareWorkers) }

        let isLaravel = nameSet.contains("composer.json")
            && (ComposerManifest.load(directory: dir)?.requires.contains("laravel/framework") ?? false)
        if isLaravel { add(.laravel) }
        if nameSet.contains("composer.json") || nameSet.contains("artisan") { add(.php) }

        if !nameSet.isDisjoint(with: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "manage.py"]) { add(.python) }
        if nameSet.contains("Gemfile") { add(.ruby) }
        if nameSet.contains("pom.xml") { add(.java) }
        if !nameSet.isDisjoint(with: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]) { add(.gradle) }
        if nameSet.contains("Cargo.toml") { add(.rust) }
        if nameSet.contains("go.mod") { add(.go) }
        if nameSet.contains("Package.swift") { add(.swiftPackage) }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { add(.xcode) }
        if nameSet.contains("pubspec.yaml") { add(.flutter) }
        if nameSet.contains("project.godot") { add(.godot) }

        if nameSet.contains("package.json") && !jsFramework { add(.node) }
        return kinds.isEmpty ? [.unknown] : kinds
    }
}

// MARK: - Expiring answer cache --------------------------------------------------------

/// P2-1: `project(containing:)` runs on every process tick for every candidate listener and costs up to 12 directory
/// listings plus manifest parses; `identity(ofProjectAt:)` costs a few more bounded reads. Answers (including "no project")
/// are kept for `ttl` seconds per key; the cache is bounded and never hands out anything older than the TTL.
final class ExpiringCache<Value: Sendable>: @unchecked Sendable {
    private struct Slot {
        let value: Value
        let at: Date
    }

    let ttl: TimeInterval
    let capacity: Int
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    init(ttl: TimeInterval, capacity: Int) {
        self.ttl = ttl
        self.capacity = capacity
    }

    /// `nil` = not cached (or expired). For an optional `Value`, `.some(nil)` is a cached "nothing there".
    func cached(_ key: String, now: Date) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[key], now.timeIntervalSince(slot.at) < ttl else { return nil }
        return slot.value
    }

    func store(_ value: Value, for key: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        if slots.count >= capacity {
            slots = slots.filter { now.timeIntervalSince($0.value.at) < ttl }
            if slots.count >= capacity { slots.removeAll() }
        }
        slots[key] = Slot(value: value, at: now)
    }
}

// MARK: - ProjectDetector ------------------------------------------------------------

public struct ProjectDetector: ProjectDetecting, ProjectIdentifying {
    let policy: PathPolicy
    let git: any GitProbing
    let now: @Sendable () -> Date
    let lookups = ExpiringCache<Project?>(ttl: ProjectDetector.cacheTTL, capacity: ProjectDetector.cacheCapacity)
    let identities = ExpiringCache<ProjectIdentity>(ttl: ProjectDetector.cacheTTL, capacity: ProjectDetector.cacheCapacity)
    static let cacheTTL: TimeInterval = 30
    static let cacheCapacity = 256
    static let maxWalkLevels = 12

    public init(homeDirectory: String = NSHomeDirectory()) {
        let git = GitProbe(runner: ProcessCommandRunner(), locator: ToolLocator(homeDirectory: homeDirectory))
        self.init(homeDirectory: homeDirectory, git: git)
    }

    /// Test seam: fake git, clock.
    init(homeDirectory: String, git: any GitProbing, now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = PathPolicy(homeDirectory: homeDirectory)
        self.git = git
        self.now = now
    }

    // MARK: Server association (ENV §3.4)

    public func project(containing path: String) -> Project? {
        let stamp = now()
        if let hit = lookups.cached(path, now: stamp) { return hit }
        let found = walkUp(from: path)
        lookups.store(found, for: path, now: stamp)
        return found
    }

    // MARK: Identity (cheap, cached)

    public func identity(ofProjectAt root: String) -> ProjectIdentity {
        let stamp = now()
        if let hit = identities.cached(root, now: stamp) { return hit }
        let resolved = ProjectIdentityResolver.resolve(projectRoot: root, home: policy.home)
        identities.store(resolved, for: root, now: stamp)
        return resolved
    }

    private func walkUp(from path: String) -> Project? {
        var dir = PathPolicy.canonical(path)
        if let st = SafeFS.lstatAbsolute(dir), !st.isDirectory { dir = PathPolicy.parent(of: dir) }
        var levels = 0
        while dir != policy.home, dir != "/", levels < Self.maxWalkLevels {
            if let names = SafeFS.listNames(atAbsolutePath: dir), ProjectMarkers.hasMarker(in: names) {
                return makeProject(root: dir, names: names, repoRoot: nearestGitRoot(from: dir))
            }
            let parent = PathPolicy.parent(of: dir)
            if parent == dir { break }
            dir = parent
            levels += 1
        }
        return nil
    }

    // MARK: Cleanup gate (CAT §2, R1/R2)

    public func projectContext(for path: String) async -> ProjectContext? {
        let start = PathPolicy.canonical(path)
        guard PathPolicy.isRealDirectory(start) else { return nil }
        let repoRoot = await git.toplevel(of: start).repositoryRoot
        return makeContext(start: start, repoRoot: repoRoot)
    }

    /// Pure part of `projectContext` (no git): applies the ceiling rule and the R1/R2 gates.
    func makeContext(start: String, repoRoot: String?) -> ProjectContext? {
        var ceiling = start
        if let r = repoRoot, policy.isUnderHome(r), (policy.depthBelowHome(r) ?? 0) >= 2,
           PathPolicy.isInsideOrEqual(start, root: r) {
            ceiling = r
        }
        guard policy.passesRootDepthAndDenyGate(ceiling), policy.isRealDirectoryOnHomeDevice(ceiling) else { return nil }
        let packageDirs = PathPolicy.packageDirs(start: start, ceiling: ceiling)
        var kinds: [ProjectKind] = []
        for dir in packageDirs {
            guard let names = SafeFS.listNames(atAbsolutePath: dir) else { continue }
            for k in ProjectKindDetector.kinds(inDirectory: dir, names: names) where k != .unknown && !kinds.contains(k) {
                kinds.append(k)
            }
        }
        let project = Project(root: ceiling, name: displayName(of: ceiling), groupName: groupName(for: ceiling),
                              kinds: kinds.isEmpty ? [.unknown] : kinds, repoRoot: repoRoot)
        return ProjectContext(project: project, ceiling: ceiling, packageDirs: packageDirs)
    }

    // MARK: Helpers

    func makeProject(root: String, names: [String], repoRoot: String?) -> Project {
        Project(root: root, name: displayName(of: root), groupName: groupName(for: root),
                kinds: ProjectKindDetector.kinds(inDirectory: root, names: names), repoRoot: repoRoot)
    }

    /// The grouping label of a root (display only), cleaned like every other name that comes from a directory.
    func groupName(for root: String) -> String? {
        policy.groupName(forProjectRoot: root).map { DisplayText.label($0) }
    }

    /// `Project.name` is shown on rows, on the kill card and in the activity messages: the folder name, cleaned (`DisplayText`),
    /// so a directory named with a bidirectional override or a zero-width character is never shown as such.
    private func displayName(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return DisplayText.label(last.isEmpty ? path : last)
    }

    /// The same walk as the identity's (`ProjectIdentityResolver.findRepoRoot`: a `.git` directory or file, never a symlink),
    /// so `Project.repoRoot` and `ProjectIdentity.repoRoot` cannot disagree about one project. Stops before home.
    private func nearestGitRoot(from start: String) -> String? {
        ProjectIdentityResolver.findRepoRoot(from: start, home: policy.home)
    }
}
