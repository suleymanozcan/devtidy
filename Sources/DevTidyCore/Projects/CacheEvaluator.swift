import Foundation
import Darwin

// MARK: - Per-scan manifest/listing cache ---------------------------------------------

/// Each marker file / directory listing is read at most once per scan (D13: only manifests are ever read).
final class ManifestCache: @unchecked Sendable {
    private struct Slot<T> { let value: T? }
    private let lock = NSLock()
    private var listings: [String: Slot<[String]>] = [:]
    private var packages: [String: Slot<PackageManifest>] = [:]
    private var composers: [String: Slot<ComposerManifest>] = [:]
    private var flutter: [String: Bool] = [:]

    func names(in dir: String) -> [String]? {
        if let hit = lock.withLock({ listings[dir] }) { return hit.value }
        let value = SafeFS.listNames(atAbsolutePath: dir)
        lock.withLock { listings[dir] = Slot(value: value) }
        return value
    }

    func package(in dir: String) -> PackageManifest? {
        if let hit = lock.withLock({ packages[dir] }) { return hit.value }
        let value = PackageManifest.load(directory: dir)
        lock.withLock { packages[dir] = Slot(value: value) }
        return value
    }

    func composer(in dir: String) -> ComposerManifest? {
        if let hit = lock.withLock({ composers[dir] }) { return hit.value }
        let value = ComposerManifest.load(directory: dir)
        lock.withLock { composers[dir] = Slot(value: value) }
        return value
    }

    func pubspecDeclaresFlutter(in dir: String) -> Bool {
        if let hit = lock.withLock({ flutter[dir] }) { return hit }
        var result = false
        if let data = SafeFS.readSmallFile(dir + "/pubspec.yaml") {
            let text = String(decoding: data, as: UTF8.self)
            result = text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("flutter:") }
        }
        lock.withLock { flutter[dir] = result }
        return result
    }
}

// MARK: - Git gate (R10 / D7) -----------------------------------------------------------

struct GitFacts: Sendable, Equatable {
    var insideRepository = false
    var tracked = 0
    var ignored: Bool?
    var untracked: Int?

    var detail: [String: String] {
        var d: [String: String] = ["repository": insideRepository ? "yes" : "no", "tracked": String(tracked)]
        if let i = ignored { d["ignored"] = i ? "1" : "0" }
        if let u = untracked { d["untracked"] = String(u) }
        return d
    }
}

enum GitVerdict: Sendable, Equatable {
    case pass(GitFacts)
    case reject(SkipReason, GitFacts)

    var facts: GitFacts {
        switch self {
        case .pass(let f), .reject(_, let f): return f
        }
    }
}

struct GitGate: Sendable {
    let git: any GitProbing

    /// `names` are paths relative to `parent` (the git working directory).
    /// * `requireIgnored == false` (class A): `ls-files --cached` must be empty; ONLY "not a git repository" is tolerated.
    /// * `requireIgnored == true` (class B/C, per-child, per-file): additionally a repository, `check-ignore` ⇒ ignored and
    ///   `ls-files --others --exclude-standard` empty. Any other git outcome ⇒ `.gitUnavailable`.
    func check(parent: String, names: [String], requireIgnored: Bool) async -> [String: GitVerdict] {
        var verdicts: [String: GitVerdict] = [:]
        guard !names.isEmpty else { return verdicts }

        func rejectAll(_ reason: SkipReason, facts: GitFacts = GitFacts()) -> [String: GitVerdict] {
            Dictionary(uniqueKeysWithValues: names.map { ($0, GitVerdict.reject(reason, facts)) })
        }

        let tracked: [String]
        switch await git.trackedPaths(inParent: parent, paths: names) {
        case .failed: return rejectAll(.gitUnavailable)
        case .notARepository:
            if requireIgnored { return rejectAll(.gitUnavailable) }
            return Dictionary(uniqueKeysWithValues: names.map { ($0, GitVerdict.pass(GitFacts())) })
        case .paths(let p): tracked = p
        }

        var survivors: [String] = []
        for n in names {
            let count = Self.count(in: tracked, below: n)
            let facts = GitFacts(insideRepository: true, tracked: count, ignored: nil, untracked: nil)
            if count > 0 { verdicts[n] = .reject(.trackedByGit, facts) } else { survivors.append(n) }
        }
        guard requireIgnored else {
            for n in survivors { verdicts[n] = .pass(GitFacts(insideRepository: true, tracked: 0, ignored: nil, untracked: nil)) }
            return verdicts
        }
        guard !survivors.isEmpty else { return verdicts }

        let ignoredSet: Set<String>
        switch await git.ignoredPaths(inParent: parent, paths: survivors) {
        case .ignored(let s): ignoredSet = s
        case .notARepository, .failed:
            for n in survivors { verdicts[n] = .reject(.gitUnavailable, GitFacts(insideRepository: true)) }
            return verdicts
        }
        var stillOK: [String] = []
        for n in survivors {
            if ignoredSet.contains(n) { stillOK.append(n) } else {
                verdicts[n] = .reject(.notIgnoredByGit, GitFacts(insideRepository: true, tracked: 0, ignored: false, untracked: nil))
            }
        }
        guard !stillOK.isEmpty else { return verdicts }

        let untracked: [String]
        switch await git.untrackedNotIgnoredPaths(inParent: parent, paths: stillOK) {
        case .paths(let p): untracked = p
        case .notARepository, .failed:
            for n in stillOK { verdicts[n] = .reject(.gitUnavailable, GitFacts(insideRepository: true, tracked: 0, ignored: true)) }
            return verdicts
        }
        for n in stillOK {
            let u = Self.count(in: untracked, below: n)
            let facts = GitFacts(insideRepository: true, tracked: 0, ignored: true, untracked: u)
            verdicts[n] = u > 0 ? .reject(.hasUntrackedFiles, facts) : .pass(facts)
        }
        return verdicts
    }

    /// Number of listed paths equal to or below `name`.
    static func count(in paths: [String], below name: String) -> Int {
        let prefix = name + "/"
        return paths.reduce(0) { $0 + (($1 == name || $1.hasPrefix(prefix)) ? 1 : 0) }
    }

    /// Turkish facts for `CacheEntry.qualifiedBecause`.
    static func reasons(for facts: GitFacts, requireIgnored: Bool) -> [String] {
        guard facts.insideRepository else { return ["git deposu yok"] }
        var r: [String] = []
        if requireIgnored { r.append("git tarafından yok sayılıyor") }
        r.append("izlenen dosya: \(facts.tracked)")
        if let u = facts.untracked { r.append("izlenmeyen dosya: \(u)") }
        return r
    }
}

// MARK: - Entry ids ---------------------------------------------------------------------

extension CacheEntry {
    static func makeID(ruleID: String, packageDir: String, instance: String?) -> String {
        "\(ruleID)@\(packageDir)" + (instance.map { "#" + $0 } ?? "")
    }
}

// MARK: - Evaluator -----------------------------------------------------------------------

/// A literal rule target re-derived from `(rule, packageDir)`.
struct ResolvedTarget: Sendable, Equatable {
    let path: String          // absolute
    let parent: String
    let name: String
    let relative: String      // relative to packageDir ("storage/framework/views")
}

struct CacheEvaluator: Sendable {
    let git: GitGate
    let policy: PathPolicy
    let manifests: ManifestCache

    init(git: any GitProbing, policy: PathPolicy, manifests: ManifestCache = ManifestCache()) {
        self.git = GitGate(git: git)
        self.policy = policy
        self.manifests = manifests
    }

    // MARK: Entry point

    /// Detection + discovery + gating for one `(rule, packageDir)`; unsized entries. No running-process check.
    func entries(rule: CacheRule, packageDir: String, ctx: ProjectContext) async -> [CacheEntry] {
        guard PathPolicy.isInsideOrEqual(packageDir, root: ctx.ceiling),
              let rootDev = PathPolicy.device(of: ctx.ceiling) else { return [] }
        var searchDirs = [packageDir]
        if rule.detect.ancestorOK, let i = ctx.packageDirs.firstIndex(of: packageDir) {
            searchDirs += ctx.packageDirs[(i + 1)...]
        }
        guard let reasons = detect(rule.detect, dirs: searchDirs) else { return [] }

        switch rule.kind {
        case .dir, .dirs:
            return await literalEntries(rule: rule, packageDir: packageDir, ceiling: ctx.ceiling, rootDev: rootDev, reasons: reasons,
                                        containingNothingOf: ctx.packageDirs)
        case .contentsOnly(let comps, let matcher):
            return await contentsOnlyEntries(rule: rule, comps: comps, matcher: matcher, packageDir: packageDir,
                                             ceiling: ctx.ceiling, rootDev: rootDev, reasons: reasons)
        case .file(let comps, let check):
            return await fileEntries(rule: rule, comps: comps, check: check, packageDir: packageDir,
                                     ceiling: ctx.ceiling, rootDev: rootDev, reasons: reasons)
        case .discovered(let discovery):
            switch discovery {
            case .pycache, .gradleModules:
                return await discoveredEntries(rule: rule, discovery: discovery, packageDir: packageDir,
                                               ceiling: ctx.ceiling, rootDev: rootDev, reasons: reasons)
            case .derivedDataChildren:
                return []   // global; see DerivedDataLocator
            }
        }
    }

    // MARK: Detection

    func detect(_ d: CacheRule.Detect, dirs: [String]) -> [String]? {
        for dir in dirs { if let r = detect(d, in: dir) { return r } }
        return nil
    }

    func detect(_ d: CacheRule.Detect, in dir: String) -> [String]? {
        var reasons: [String] = []
        for group in d.files {
            guard let hit = group.first(where: { exists($0, in: dir) }) else { return nil }
            reasons.append("`\(hit)` bulundu")
        }
        if !d.deps.isEmpty {
            guard let pkg = manifests.package(in: dir) else { return nil }
            for group in d.deps {
                guard let hit = group.first(where: { pkg.dependencies.contains($0) }) else { return nil }
                reasons.append("`\(hit)` bağımlılığı bulundu")
            }
        }
        if !d.composerRequires.isEmpty {
            guard let comp = manifests.composer(in: dir),
                  let hit = d.composerRequires.first(where: { comp.requires.contains($0) }) else { return nil }
            reasons.append("`\(hit)` composer bağımlılığı bulundu")
        }
        if d.needsBuildScript {
            guard manifests.package(in: dir)?.hasBuildScript == true else { return nil }
            reasons.append("package.json içinde build betiği var")
        }
        for forbidden in d.forbidFiles where exists(forbidden, in: dir) { return nil }
        if !d.requireOneOfLockfiles.isEmpty {
            guard let hit = d.requireOneOfLockfiles.first(where: { exists($0, in: dir) }) else { return nil }
            reasons.append("`\(hit)` bulundu")
        }
        if d.pubspecDeclaresFlutter {
            guard manifests.pubspecDeclaresFlutter(in: dir) else { return nil }
            reasons.append("pubspec.yaml flutter bildiriyor")
        }
        if d.requireDerivedDataInfoPlist {
            guard hasInTreeDerivedDataProject(in: dir) else { return nil }
            reasons.append("DerivedData/*/info.plist bulundu")
        }
        if !d.alternatives.isEmpty {
            var hit: [String]?
            for alt in d.alternatives {
                if let r = detect(alt, in: dir) { hit = r; break }
            }
            guard let altReasons = hit else { return nil }
            reasons += altReasons
        }
        return reasons
    }

    /// `pattern` may contain `/` (literal parents) and one `*` in the last component.
    func exists(_ pattern: String, in dir: String) -> Bool {
        let comps = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = comps.last else { return false }
        var base = dir
        for c in comps.dropLast() { base += "/" + c }
        guard let names = manifests.names(in: base) else { return false }
        if last.contains("*") { return names.contains { Self.globMatches(last, $0) } }
        return names.contains(last)
    }

    static func globMatches(_ pattern: String, _ name: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        guard parts.count == 2 else { return pattern == name }
        return name.count >= parts[0].count + parts[1].count && name.hasPrefix(parts[0]) && name.hasSuffix(parts[1])
    }

    private func hasInTreeDerivedDataProject(in dir: String) -> Bool {
        let base = dir + "/DerivedData"
        guard let children = manifests.names(in: base) else { return false }
        for c in children {
            if let names = manifests.names(in: base + "/" + c), names.contains("info.plist") { return true }
        }
        return false
    }

    // MARK: Literal dir / dirs

    /// Absolute targets for the literal kinds (never `discovered`). R3: derived from the rule table only.
    func literalTargets(rule: CacheRule, packageDir: String, ceiling: String) -> [ResolvedTarget] {
        rule.allComponentLists.compactMap { comps in
            guard let name = comps.last else { return nil }
            let rel = comps.joined(separator: "/")
            let path = packageDir + "/" + rel
            guard PathPolicy.isStrictlyInside(path, root: ceiling) else { return nil }
            return ResolvedTarget(path: path, parent: PathPolicy.parent(of: path), name: name, relative: rel)
        }
    }

    /// QA F1: a class B build-output directory that the package's OWN `package.json` points at (`main`, `module`, `types`,
    /// `typings`, `exports` incl. nested conditions, `bin`, `files`, …) is the package's published artefact, not a cache.
    /// Read fresh from the manifest of `packageDir`; used both when offering and when deleting.
    /// Security I-7: a `package.json` that is present but cannot be read (invalid JSON, larger than the read bound, a symlink)
    /// may well point at this directory, so it refuses too; a directory without any `package.json` exports nothing.
    func isPackageExportTarget(rule: CacheRule, relative: String, packageDir: String) -> Bool {
        guard rule.safety == .conditional else { return false }
        if let manifest = manifests.package(in: packageDir) {
            return manifest.referencesPath(relative.split(separator: "/").map(String.init))
        }
        return manifests.names(in: packageDir)?.contains { $0.lowercased() == "package.json" } == true
    }

    /// `containingNothingOf`: R12 ancestor clause — a target that is, or contains, one of these project directories (the
    /// path the user opened and its parents up to the ceiling) is never offered.
    private func literalEntries(rule: CacheRule, packageDir: String, ceiling: String, rootDev: dev_t, reasons: [String],
                                containingNothingOf protectedDirs: [String]) async -> [CacheEntry] {
        let requireIgnored = rule.safety != .always
        var passing: [ResolvedTarget] = []
        var factsSeen: [GitFacts] = []
        let candidates = literalTargets(rule: rule, packageDir: packageDir, ceiling: ceiling).filter { t in
            guard !isPackageExportTarget(rule: rule, relative: t.relative, packageDir: packageDir),
                  !protectedDirs.contains(where: { PathPolicy.isInsideOrEqual($0, root: t.path) }) else { return false }
            if case .ok(let fd, _) = SafeFS.openTarget(parent: t.parent, name: t.name, expect: .directory, rootDev: rootDev) {
                close(fd)
                return true
            }
            return false
        }
        // Group by parent so `git -C <parent>` answers for the nearest repository (R10).
        let byParent = Dictionary(grouping: candidates, by: \.parent)
        for parent in byParent.keys.sorted() {
            let group = byParent[parent] ?? []
            let verdicts = await git.check(parent: parent, names: group.map(\.name), requireIgnored: requireIgnored)
            for t in group {
                if case .pass(let facts) = verdicts[t.name] {
                    passing.append(t)
                    factsSeen.append(facts)
                }
            }
        }
        guard !passing.isEmpty, let firstFacts = factsSeen.first else { return [] }
        let display = passing.map(\.relative).joined(separator: CacheEntry.displaySeparator)
        var allReasons = reasons + GitGate.reasons(for: firstFacts, requireIgnored: requireIgnored)
        var notes = rule.notes
        if rule.id == "dist.generic", let warning = siblingDependencyWarning(packageDir: packageDir) { notes.append(warning) }
        allReasons = Self.unique(allReasons)
        return [makeEntry(rule: rule, packageDir: packageDir, displayPath: display, reasons: allReasons,
                          notes: notes, itemCount: nil)]
    }

    // MARK: Contents-only (Laravel, CAT note L / R13)

    struct ChildQualification: Sendable {
        var children: [String] = []
        var bytes: Int64 = 0
        /// Allocated bytes of each qualifying child (same keys as `children`), so a later re-qualification can narrow the total.
        var childBytes: [String: Int64] = [:]
        var rejection: SkipReason?
        var facts = GitFacts()
    }

    /// Children of a contents-only directory that pass R5–R7/R9/R10 (never `.gitignore`/`.gitkeep`).
    /// `rejection` is set (and `children` empty) when nothing qualifies.
    func qualifyChildren(comps: [String], matcher: ChildMatcher, packageDir: String,
                         ceiling: String, rootDev: dev_t) async -> ChildQualification {
        var result = ChildQualification()
        guard let dirName = comps.last else { result.rejection = .notFound; return result }
        let dirPath = packageDir + "/" + comps.joined(separator: "/")
        guard PathPolicy.isStrictlyInside(dirPath, root: ceiling) else { result.rejection = .outsideRoot; return result }
        let parent = PathPolicy.parent(of: dirPath)
        switch SafeFS.openTarget(parent: parent, name: dirName, expect: .directory, rootDev: rootDev) {
        case .skip(let reason):
            result.rejection = reason
            return result
        case .ok(let parentFD, _):
            close(parentFD)
        }
        let dirFD = SafeFS.openDirAbsolute(dirPath)
        guard dirFD >= 0 else { result.rejection = .symlink; return result }
        defer { close(dirFD) }
        guard let listing = SafeFS.enumerate(dirFD: dirFD) else { result.rejection = .notFound; return result }
        let candidates = listing.filter { e in
            e.stat.isRegularFile && !e.stat.hasProtectedFlags && e.stat.dev == rootDev
                && e.name != ".gitignore" && e.name != ".gitkeep" && matcher.matches(e.name)
        }
        guard !candidates.isEmpty else { result.rejection = .emptyAlready; return result }

        // One `ls-files --cached -- <dir>` set difference, one `check-ignore` batch (R13).
        let tracked: [String]
        switch await git.git.trackedPaths(inParent: parent, paths: [dirName]) {
        case .paths(let p): tracked = p
        case .notARepository, .failed:
            result.rejection = .gitUnavailable
            return result
        }
        let trackedSet = Set(tracked)
        let untrackedCandidates = candidates.map(\.name).sorted().filter { !trackedSet.contains(dirName + "/" + $0) }
        guard !untrackedCandidates.isEmpty else {
            result.rejection = .trackedByGit
            result.facts = GitFacts(insideRepository: true, tracked: candidates.count)
            return result
        }
        let ignored: Set<String>
        switch await git.git.ignoredPaths(inParent: dirPath, paths: untrackedCandidates) {
        case .ignored(let s): ignored = s
        case .notARepository, .failed:
            result.rejection = .gitUnavailable
            return result
        }
        let ok = untrackedCandidates.filter { ignored.contains($0) }
        guard !ok.isEmpty else {
            result.rejection = .notIgnoredByGit
            result.facts = GitFacts(insideRepository: true, tracked: 0, ignored: false)
            return result
        }
        let okSet = Set(ok)
        result.children = ok
        let qualifying = candidates.filter { okSet.contains($0.name) }
        result.childBytes = Dictionary(qualifying.map { ($0.name, $0.stat.blocks * 512) }, uniquingKeysWith: { first, _ in first })
        result.bytes = qualifying.reduce(Int64(0)) { $0 + $1.stat.blocks * 512 }
        result.facts = GitFacts(insideRepository: true, tracked: 0, ignored: true, untracked: 0)
        return result
    }

    private func contentsOnlyEntries(rule: CacheRule, comps: [String], matcher: ChildMatcher, packageDir: String,
                                     ceiling: String, rootDev: dev_t, reasons: [String]) async -> [CacheEntry] {
        let q = await qualifyChildren(comps: comps, matcher: matcher, packageDir: packageDir, ceiling: ceiling, rootDev: rootDev)
        guard !q.children.isEmpty else { return [] }
        let allReasons = Self.unique(reasons + ["\(q.children.count) dosya git tarafından yok sayılıyor", "izlenen dosya: 0"])
        return [makeEntry(rule: rule, packageDir: packageDir, displayPath: comps.joined(separator: "/"), reasons: allReasons,
                          notes: rule.notes, itemCount: q.children.count)]
    }

    // MARK: Single file (public/hot)

    /// Re-checks the content rule at the time of the call (D13: reads ≤ 512 bytes of this one catalog file).
    static func laravelHotContentOK(_ path: String) -> Bool {
        guard let data = SafeFS.readSmallFile(path, maxBytes: 512) else { return false }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("http://") || text.hasPrefix("https://")
    }

    private func fileEntries(rule: CacheRule, comps: [String], check: FileCheck, packageDir: String, ceiling: String,
                             rootDev: dev_t, reasons: [String]) async -> [CacheEntry] {
        guard let name = comps.last else { return [] }
        let path = packageDir + "/" + comps.joined(separator: "/")
        guard PathPolicy.isStrictlyInside(path, root: ceiling) else { return [] }
        let parent = PathPolicy.parent(of: path)
        guard case .ok(let fd, _) = SafeFS.openTarget(parent: parent, name: name, expect: .regularFile, rootDev: rootDev) else { return [] }
        close(fd)
        switch check {
        case .laravelHot: guard Self.laravelHotContentOK(path) else { return [] }
        }
        let verdicts = await git.check(parent: parent, names: [name], requireIgnored: true)
        guard case .pass(let facts)? = verdicts[name] else { return [] }
        let allReasons = Self.unique(reasons + ["boyut ve içerik denetimi geçti"] + GitGate.reasons(for: facts, requireIgnored: true))
        return [makeEntry(rule: rule, packageDir: packageDir, displayPath: comps.joined(separator: "/"), reasons: allReasons,
                          notes: rule.notes, itemCount: nil)]
    }

    // MARK: Discovered (pycache, gradle modules)

    /// At most this many discovered paths are listed (and therefore deletable) per entry; `itemCount` carries the full match
    /// count so the sheet can say how many are left for the next run.
    static let maxListedDiscoveredPaths = 200

    private func discoveredEntries(rule: CacheRule, discovery: Discovery, packageDir: String, ceiling: String,
                                   rootDev: dev_t, reasons: [String]) async -> [CacheEntry] {
        // A path containing the display separator (or a line break) cannot be listed exactly, so it is never offered.
        let found = DiscoveryWalker.discover(discovery, packageDir: packageDir, rootDev: rootDev)
            .filter { !$0.contains(CacheEntry.displaySeparator) && !$0.contains("\n") }
        guard !found.isEmpty else { return [] }
        let requireIgnored = rule.safety != .always
        let verdicts = await git.check(parent: packageDir, names: found, requireIgnored: requireIgnored)
        let passing = found.filter { if case .pass? = verdicts[$0] { return true } else { return false } }
        guard let first = passing.first, case .pass(let facts)? = verdicts[first] else { return [] }
        let label = discovery == .pycache ? "__pycache__" : "build"
        // The exact relative paths, so the confirmation sheet lists what will be removed (P2-8). `passing` is sorted.
        let display = passing.prefix(Self.maxListedDiscoveredPaths).joined(separator: CacheEntry.displaySeparator)
        let allReasons = Self.unique(reasons + ["\(passing.count) \(label) klasörü"] + GitGate.reasons(for: facts, requireIgnored: requireIgnored))
        return [makeEntry(rule: rule, packageDir: packageDir, displayPath: display, reasons: allReasons,
                          notes: rule.notes, itemCount: passing.count)]
    }

    /// Discovered targets of `rule` below `packageDir`, re-derived (no git) and restricted to `listed` — the relative paths
    /// the entry showed the user. A target that appeared after the plan, or fell beyond the listing cap, is not returned,
    /// so the confirmation sheet's list is the most that can ever be removed. `listed` can only narrow, never add.
    func discoveredTargets(rule: CacheRule, packageDir: String, ceiling: String, listed: [String]) -> [ResolvedTarget] {
        guard case .discovered(let discovery) = rule.kind, discovery != .derivedDataChildren,
              let rootDev = PathPolicy.device(of: ceiling) else { return [] }
        let allowed = Set(listed)
        return DiscoveryWalker.discover(discovery, packageDir: packageDir, rootDev: rootDev).compactMap { rel in
            guard allowed.contains(rel) else { return nil }
            let path = packageDir + "/" + rel
            guard PathPolicy.isStrictlyInside(path, root: ceiling) else { return nil }
            return ResolvedTarget(path: path, parent: PathPolicy.parent(of: path), name: (rel as NSString).lastPathComponent, relative: rel)
        }
    }

    // MARK: Helpers

    private func makeEntry(rule: CacheRule, packageDir: String, displayPath: String, reasons: [String],
                           notes: [String], itemCount: Int?) -> CacheEntry {
        CacheEntry(id: CacheEntry.makeID(ruleID: rule.id, packageDir: packageDir, instance: nil),
                   ruleID: rule.id, packageDir: packageDir, instance: nil, displayPath: displayPath, title: rule.title,
                   safety: rule.safety, isContentsOnly: rule.isContentsOnly, defaultSelected: rule.defaultOn,
                   defaultMode: rule.mode, sizeBytes: nil, sizeIsPartial: false, itemCount: itemCount,
                   qualifiedBecause: reasons, notes: notes, reinstallCommand: reinstallCommand(rule: rule, packageDir: packageDir))
    }

    private func reinstallCommand(rule: CacheRule, packageDir: String) -> String? {
        switch rule.reinstall {
        case .none: return nil
        case .fixed(let c): return c
        case .fromLockfile:
            let table: [(String, String)] = [
                ("package-lock.json", "npm ci"), ("npm-shrinkwrap.json", "npm ci"), ("pnpm-lock.yaml", "pnpm install --frozen-lockfile"),
                ("yarn.lock", "yarn install --immutable"), ("bun.lock", "bun install --frozen-lockfile"),
                ("bun.lockb", "bun install --frozen-lockfile"),
            ]
            return table.first { exists($0.0, in: packageDir) }?.1
        }
    }

    /// dist: warn (not block) when a sibling workspace package depends on this package (its `main`/`exports` often point into `dist`).
    private func siblingDependencyWarning(packageDir: String) -> String? {
        guard let name = manifests.package(in: packageDir)?.name, !name.isEmpty else { return nil }
        let parent = PathPolicy.parent(of: packageDir)
        guard let siblings = manifests.names(in: parent) else { return nil }
        for s in siblings.sorted().prefix(40) where !s.hasPrefix(".") {
            let dir = parent + "/" + s
            guard dir != packageDir, let pkg = manifests.package(in: dir) else { continue }
            if pkg.dependencies.contains(name) {
                // `s` is a directory name: it goes into a note on the cleanup sheet, so it is cleaned for display (F3-4).
                return "kardeş paket (\(DisplayText.label(s, limit: 80))) bu paketi kullanıyor: yeniden derlenene kadar çalışmayabilir"
            }
        }
        return nil
    }

    static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }
}

// MARK: - Discovery walkers (R14) ---------------------------------------------------------

enum DiscoveryWalker {
    static let pycacheSkip: Set<String> = [".git", "node_modules", ".venv", "venv", "env", "site-packages", ".tox", "vendor", "target"]
    static let gradleSkip: Set<String> = ["node_modules", ".git", "build", ".gradle"]
    static let pycacheMaxDepth = 6
    static let pycacheMaxEntries = 200_000
    static let gradleMaxDepth = 3

    /// Relative paths (to `packageDir`) of discovered targets: `__pycache__` dirs or `<module>/build` dirs.
    static func discover(_ discovery: Discovery, packageDir: String, rootDev: dev_t) -> [String] {
        switch discovery {
        case .pycache: return pycache(packageDir: packageDir, rootDev: rootDev)
        case .gradleModules: return gradleBuildDirs(packageDir: packageDir, rootDev: rootDev)
        case .derivedDataChildren: return []
        }
    }

    /// Every `__pycache__` whose entries are ALL regular `.pyc`/`.pyo` files. Never follows symlinks (O_NOFOLLOW_ANY opens),
    /// never crosses a device, bounded by depth and entry count, cancellable.
    static func pycache(packageDir: String, rootDev: dev_t) -> [String] {
        var found: [String] = []
        var stack: [(path: String, rel: String, depth: Int)] = [(packageDir, "", 0)]
        var visited = 0
        while let cur = stack.popLast() {
            if Task.isCancelled { break }
            let fd = SafeFS.openDirAbsolute(cur.path)
            guard fd >= 0 else { continue }
            let listing = SafeFS.enumerate(dirFD: fd)
            close(fd)
            guard let entries = listing else { continue }
            for e in entries.sorted(by: { $0.name > $1.name }) {
                visited += 1
                if visited > pycacheMaxEntries { return found.sorted() }
                guard e.stat.isDirectory, e.stat.dev == rootDev else { continue }
                let rel = cur.rel.isEmpty ? e.name : cur.rel + "/" + e.name
                if e.name == "__pycache__" {
                    if isPureBytecodeDir(cur.path + "/" + e.name, rootDev: rootDev) { found.append(rel) }
                    continue
                }
                if cur.depth < pycacheMaxDepth, !pycacheSkip.contains(e.name) {
                    stack.append((cur.path + "/" + e.name, rel, cur.depth + 1))
                }
            }
        }
        return found.sorted()
    }

    static func isPureBytecodeDir(_ path: String, rootDev: dev_t) -> Bool {
        let fd = SafeFS.openDirAbsolute(path)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard let st = SafeFS.statOfFD(fd), st.dev == rootDev, !st.hasProtectedFlags,
              let raw = SafeFS.readRawNames(dirFD: fd) else { return false }
        for name in raw {
            guard let s = SafeFS.decodeExact(name) else { return false }
            guard s.hasSuffix(".pyc") || s.hasSuffix(".pyo"),
                  let est = SafeFS.statNoFollow(dirFD: fd, name: s), est.isRegularFile, !est.hasProtectedFlags else { return false }
        }
        return true
    }

    /// `<module>/build` for every module (a dir with `build.gradle(.kts)`) up to 3 levels below `packageDir`, root included.
    static func gradleBuildDirs(packageDir: String, rootDev: dev_t) -> [String] {
        var out: [String] = []
        var stack: [(path: String, rel: String, depth: Int)] = [(packageDir, "", 0)]
        while let cur = stack.popLast() {
            if Task.isCancelled { break }
            let fd = SafeFS.openDirAbsolute(cur.path)
            guard fd >= 0 else { continue }
            let listing = SafeFS.enumerate(dirFD: fd)
            close(fd)
            guard let entries = listing else { continue }
            let names = Set(entries.map(\.name))
            if names.contains("build.gradle") || names.contains("build.gradle.kts") {
                if let b = entries.first(where: { $0.name == "build" }), b.stat.isDirectory, b.stat.dev == rootDev {
                    out.append(cur.rel.isEmpty ? "build" : cur.rel + "/build")
                }
            }
            guard cur.depth < gradleMaxDepth else { continue }
            for e in entries where e.stat.isDirectory && e.stat.dev == rootDev && !gradleSkip.contains(e.name) {
                stack.append((cur.path + "/" + e.name, cur.rel.isEmpty ? e.name : cur.rel + "/" + e.name, cur.depth + 1))
            }
        }
        return out.sorted()
    }
}
