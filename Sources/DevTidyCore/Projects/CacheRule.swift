import Foundation

/// One row of the closed cache catalog (CAT §3 + §10). S2-internal.
struct CacheRule: Sendable {
    enum Kind: Sendable {
        case dir([String])                                   // literal components under packageDir
        case dirs([[String]])                                // several literal dirs, one row
        case contentsOnly([String], ChildMatcher)            // Laravel (CAT note L): children enumerated, dir kept
        case file([String], FileCheck)                       // public/hot
        case discovered(Discovery)                           // __pycache__ walk, gradle modules, DerivedData children
    }

    enum GitPolicy: Sendable { case untracked, ignoredUntracked }   // A / B+C (CAT §1)

    enum Reinstall: Sendable {
        case none
        case fixed(String)
        /// `npm ci | pnpm install --frozen-lockfile | yarn install --immutable | bun install --frozen-lockfile`
        case fromLockfile
    }

    struct Detect: Sendable {
        var files: [[String]] = []            // each inner array = "any of" (files or dirs; `*` globs in the last component)
        var deps: [[String]] = []             // package.json dependencies ∪ devDependencies ∪ optionalDependencies, any-of per group
        var composerRequires: [String] = []   // any-of in composer.json require/require-dev
        var needsBuildScript = false
        var ancestorOK = false                // may be satisfied at an ancestor up to `ceiling` (turbo.json)
        var forbidFiles: [String] = []        // e.g. Yarn PnP `.pnp.cjs` for node_modules
        var requireOneOfLockfiles: [String] = []   // class C
        /// If non-empty the rule is detected when the own conditions hold AND at least one alternative holds.
        var alternatives: [Detect] = []
        var pubspecDeclaresFlutter = false    // pubspec.yaml contains a top-level `flutter:` key
        var requireDerivedDataInfoPlist = false   // in-tree DerivedData/*/info.plist (CAT §3 xcode.derived)

        init(files: [[String]] = [], deps: [[String]] = [], composerRequires: [String] = [],
             needsBuildScript: Bool = false, ancestorOK: Bool = false, forbidFiles: [String] = [],
             requireOneOfLockfiles: [String] = [], alternatives: [Detect] = [],
             pubspecDeclaresFlutter: Bool = false, requireDerivedDataInfoPlist: Bool = false) {
            self.files = files
            self.deps = deps
            self.composerRequires = composerRequires
            self.needsBuildScript = needsBuildScript
            self.ancestorOK = ancestorOK
            self.forbidFiles = forbidFiles
            self.requireOneOfLockfiles = requireOneOfLockfiles
            self.alternatives = alternatives
            self.pubspecDeclaresFlutter = pubspecDeclaresFlutter
            self.requireDerivedDataInfoPlist = requireDerivedDataInfoPlist
        }

        /// `D(a|b)` — dependency any-of.
        static func D(_ names: String...) -> Detect { Detect(deps: [names]) }
        /// `F(a|b)` — file any-of.
        static func F(_ names: String...) -> Detect { Detect(files: [names]) }
        /// Satisfied when any one alternative is.
        static func anyOf(_ alternatives: Detect...) -> Detect { Detect(alternatives: alternatives) }
        /// Own conditions AND `other`'s conditions.
        func and(_ other: Detect) -> Detect {
            var d = self
            d.files += other.files
            d.deps += other.deps
            d.composerRequires += other.composerRequires
            d.needsBuildScript = d.needsBuildScript || other.needsBuildScript
            d.ancestorOK = d.ancestorOK || other.ancestorOK
            d.forbidFiles += other.forbidFiles
            d.requireOneOfLockfiles += other.requireOneOfLockfiles
            d.alternatives += other.alternatives
            d.pubspecDeclaresFlutter = d.pubspecDeclaresFlutter || other.pubspecDeclaresFlutter
            d.requireDerivedDataInfoPlist = d.requireDerivedDataInfoPlist || other.requireDerivedDataInfoPlist
            return d
        }
        func withAncestorOK() -> Detect { var d = self; d.ancestorOK = true; return d }
    }

    let id: String
    let title: String                    // Turkish
    let safety: CacheSafety
    let kind: Kind
    let git: GitPolicy
    let detect: Detect
    let defaultOn: Bool                  // implies safety == .always
    let mode: DeleteMode                 // A: .permanent, B: .trash, C: .permanent, DerivedData: .permanent
    let notes: [String]                  // Turkish
    let reinstall: Reinstall

    /// `git` and `mode` follow the class (A: untracked/permanent, B: ignored/trash, C: ignored/permanent).
    init(_ id: String, _ title: String, _ safety: CacheSafety, _ kind: Kind, detect: Detect,
         defaultOn: Bool = false, notes: [String] = [], reinstall: Reinstall = .none) {
        self.id = id
        self.title = title
        self.safety = safety
        self.kind = kind
        self.detect = detect
        self.defaultOn = defaultOn
        self.notes = notes
        self.reinstall = reinstall
        switch safety {
        case .always:
            self.git = .untracked
            self.mode = .permanent
        case .conditional:
            self.git = .ignoredUntracked
            self.mode = .trash
        case .optIn:
            self.git = .ignoredUntracked
            self.mode = .permanent
        }
    }

    /// Every literal component list this rule can touch (empty for `discovered`).
    var allComponentLists: [[String]] {
        switch kind {
        case .dir(let c), .contentsOnly(let c, _), .file(let c, _): return [c]
        case .dirs(let lists): return lists
        case .discovered: return []
        }
    }

    var isContentsOnly: Bool {
        if case .contentsOnly = kind { return true }
        return false
    }
}

enum ChildMatcher: Sendable {
    case suffix(String)
    case exact([String])

    func matches(_ name: String) -> Bool {
        switch self {
        case .suffix(let s): return name.hasSuffix(s) && name != s
        case .exact(let names): return names.contains(name)
        }
    }
}

enum FileCheck: Sendable { case laravelHot }               // regular file, ≤ 512 B, content ^https?://

enum Discovery: Sendable { case pycache, gradleModules, derivedDataChildren }
