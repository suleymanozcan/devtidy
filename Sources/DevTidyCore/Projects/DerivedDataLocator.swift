import Foundation
import Darwin

/// Global Xcode DerivedData (CAT §5.1): root resolution, `info.plist` matching, orphans.
/// The directory name is only a pre-filter; `info.plist` is authoritative. The 28-letter hash is never recomputed.
struct DerivedDataLocator: Sendable {
    let policy: PathPolicy
    /// Absolute custom location from Xcode preferences (`IDECustomDerivedDataLocation`); nil = default. Injectable for tests.
    let customLocation: @Sendable () -> String?
    /// Test seam: use this directory as the DerivedData root instead of `~/Library/Developer/Xcode/DerivedData`.
    let rootOverride: String?

    init(policy: PathPolicy, rootOverride: String? = nil,
         customLocation: @escaping @Sendable () -> String? = DerivedDataLocator.readCustomLocation) {
        self.policy = policy
        self.rootOverride = rootOverride
        self.customLocation = customLocation
    }

    static let hashLength = 28

    @Sendable static func readCustomLocation() -> String? {
        let value = CFPreferencesCopyAppValue("IDECustomDerivedDataLocation" as CFString, "com.apple.dt.Xcode" as CFString)
        return value as? String
    }

    // MARK: Root

    /// Canonical DerivedData root (the directory may not exist).
    func root() -> String {
        if let o = rootOverride { return PathPolicy.canonical(o) }
        if let custom = customLocation(), custom.hasPrefix("/") {
            let c = PathPolicy.canonical(custom)
            if policy.isUnderHome(c) { return c }
        }
        return PathPolicy.canonical(policy.home + "/Library/Developer/Xcode/DerivedData")
    }

    // MARK: Name rule

    /// `^(.+)-([a-z]{28})$`, checked on the UTF-8 bytes.
    static func matchesNameRule(_ name: String) -> Bool {
        let u = Array(name.utf8)
        guard u.count >= hashLength + 2, u[u.count - hashLength - 1] == UInt8(ascii: "-") else { return false }
        return u[(u.count - hashLength)...].allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
    }

    /// Display name: everything before the last `-`.
    static func displayName(of name: String) -> String {
        guard let i = name.lastIndex(of: "-") else { return name }
        return String(name[..<i])
    }

    // MARK: Children

    struct Child: Sendable, Equatable {
        let name: String
        let path: String
        /// `realpath(WorkspacePath)`, or the lexical path when it no longer exists.
        let workspacePath: String
        let workspaceExists: Bool
        let lastAccessed: Date?
    }

    /// Steps 1–3 + 4 of CAT §5.1. Skips symlinks, plain files, other devices, names off the rule, a missing/unparseable
    /// `info.plist` and a missing/non-String `WorkspacePath` (fail closed).
    func children() -> [Child] {
        let rootPath = root()
        guard let homeDev = PathPolicy.device(of: policy.home) else { return [] }
        let fd = SafeFS.openDirAbsolute(rootPath)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        guard let entries = SafeFS.enumerate(dirFD: fd) else { return [] }
        var out: [Child] = []
        for e in entries.sorted(by: { $0.name < $1.name }) {
            guard e.stat.isDirectory, e.stat.dev == homeDev, Self.matchesNameRule(e.name) else { continue }
            let path = rootPath + "/" + e.name
            guard let info = Self.readInfoPlist(at: path + "/info.plist"), let wp = info.workspacePath, wp.hasPrefix("/") else { continue }
            let real = PathPolicy.realpathString(wp)
            let lexical = URL(fileURLWithPath: wp).standardizedFileURL.path
            out.append(Child(name: e.name, path: path, workspacePath: real ?? lexical, workspaceExists: real != nil,
                             lastAccessed: info.lastAccessed))
        }
        return out
    }

    struct InfoPlist { let workspacePath: String?; let lastAccessed: Date? }

    static func readInfoPlist(at path: String) -> InfoPlist? {
        guard let data = SafeFS.readSmallFile(path),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return InfoPlist(workspacePath: obj["WorkspacePath"] as? String, lastAccessed: obj["LastAccessedDate"] as? Date)
    }

    /// Execution-time validation of an `instance` (D2 exception): the exact name rule AND an `info.plist` that parses.
    func isValidInstance(_ instance: String) -> Bool {
        guard !instance.isEmpty, !instance.contains("/"), instance != ".", instance != "..", Self.matchesNameRule(instance) else { return false }
        guard let info = Self.readInfoPlist(at: root() + "/" + instance + "/info.plist"), info.workspacePath != nil else { return false }
        return true
    }

    // MARK: Entries

    /// Entries (unsized) for DerivedData folders whose workspace lies at/below `projectRoot` (CAT §5.1 step 5).
    func entries(matching projectRoot: String) -> [CacheEntry] {
        children().filter { PathPolicy.isInsideOrEqual($0.workspacePath, root: projectRoot) }.map { entry(for: $0, orphaned: false) }
    }

    /// Entries (unsized) whose workspace no longer exists on disk (step 4), default OFF.
    func orphanedEntries() -> [CacheEntry] {
        children().filter { !$0.workspaceExists }.map { entry(for: $0, orphaned: true) }
    }

    func entry(for child: Child, orphaned: Bool) -> CacheEntry {
        let rootPath = root()
        var reasons = ["info.plist okundu", "çalışma alanı: \(child.workspacePath)"]
        if orphaned { reasons.append("çalışma alanı artık yok") }
        if let d = child.lastAccessed {
            let f = ISO8601DateFormatter()
            reasons.append("son erişim: \(f.string(from: d))")
        }
        return CacheEntry(
            id: CacheEntry.makeID(ruleID: CatalogData.derivedDataRuleID, packageDir: rootPath, instance: child.name),
            ruleID: CatalogData.derivedDataRuleID, packageDir: rootPath, instance: child.name,
            displayPath: child.name, title: "Xcode DerivedData: " + Self.displayName(of: child.name),
            safety: .always, isContentsOnly: false, defaultSelected: !orphaned, defaultMode: .permanent,
            sizeBytes: nil, sizeIsPartial: false, itemCount: nil, qualifiedBecause: reasons,
            notes: ["Xcode yeniden derler ve dizinler", "SourcePackages silinirse paketler ağdan yeniden indirilir"],
            reinstallCommand: nil)
    }
}
