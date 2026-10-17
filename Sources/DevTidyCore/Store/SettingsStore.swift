import Foundation

/// Minimal lock-protected box so a `@Sendable` closure can read a value that the main actor writes.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Where the settings JSON lives. The app uses `UserDefaultsSettingsStorage`; tests use an in-memory fake so
/// nothing is ever written to the real preferences.
public protocol SettingsStorage: Sendable {
    func read() -> Data?
    func write(_ data: Data)
}

/// `UserDefaults` key `devtidy.settings.v1`, value = JSON (§6.1). `UserDefaults` is documented thread-safe but not
/// annotated `Sendable` in the SDK, hence `@unchecked`.
public struct UserDefaultsSettingsStorage: SettingsStorage, @unchecked Sendable {
    public static let key = "devtidy.settings.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func read() -> Data? { defaults.data(forKey: Self.key) }
    public func write(_ data: Data) { defaults.set(data, forKey: Self.key) }
}

/// `DevTidySettings` persistence plus the derived values the store needs (effective scan roots, socket override reader).
@MainActor
public final class SettingsStore {
    /// Common development folders probed under the home directory when the user has not chosen any roots. Only the
    /// ones that exist are scanned. Desktop, Documents and Downloads are deliberately absent: walking them triggers
    /// macOS privacy prompts.
    public static let defaultRootNames = [
        "developer", "Developer", "Projects", "projects", "code", "Code", "dev", "src", "repos", "workspace", "GitHub", "Sites",
    ]

    private let storage: any SettingsStorage
    private let homeDirectory: String
    private let socketOverrideBox = LockedValue<String?>(nil)

    public init(storage: any SettingsStorage = UserDefaultsSettingsStorage(), homeDirectory: String = NSHomeDirectory()) {
        self.storage = storage
        self.homeDirectory = homeDirectory
    }

    /// Never throws: missing or undecodable data yields the defaults.
    public func load() -> DevTidySettings {
        var settings = DevTidySettings()
        if let data = storage.read(), let decoded = try? JSONDecoder().decode(DevTidySettings.self, from: data) {
            settings = Self.sanitized(decoded)
        }
        socketOverrideBox.value = settings.dockerSocketOverride
        return settings
    }

    public func save(_ settings: DevTidySettings) {
        let clean = Self.sanitized(settings)
        socketOverrideBox.value = clean.dockerSocketOverride
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(clean) {
            storage.write(data)
        }
    }

    /// Roots handed to the builds scan: the user's list with `~` expanded, or, when it is empty, every
    /// `defaultRootNames` folder that exists as a real directory (not a symlink) under the home directory, once per
    /// physical directory. With none present it falls back to `<home>/developer`.
    public func effectiveScanRoots(for settings: DevTidySettings) -> [String] {
        let chosen = settings.scanRoots.map(expandTilde).filter { !$0.isEmpty }
        if chosen.isEmpty {
            let found = existingDefaultRoots()
            return found.isEmpty ? [homeDirectory + "/" + Self.defaultRootNames[0]] : found
        }
        var seen = Set<String>()
        return chosen.filter { seen.insert($0).inserted }
    }

    /// `lstat`, so a symlinked folder is never followed; identity by device + inode, so `developer` and `Developer`
    /// on a case-insensitive volume are scanned once.
    private func existingDefaultRoots() -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for name in Self.defaultRootNames {
            let path = homeDirectory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
            roots.append(path)
        }
        return roots
    }

    /// Thread-safe reader for `DevTidyServices.live(socketOverride:)`; reflects the last `load()` / `save(_:)`.
    public nonisolated var socketOverrideProvider: @Sendable () -> String? {
        let box = socketOverrideBox
        return { box.value }
    }

    private func expandTilde(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return homeDirectory }
        if trimmed.hasPrefix("~/") { return homeDirectory + String(trimmed.dropFirst(1)) }
        return trimmed
    }

    static func sanitized(_ input: DevTidySettings) -> DevTidySettings {
        var s = input
        s.buildsMaxDepth = min(6, max(2, s.buildsMaxDepth))
        s.serverIdleMinutes = max(1, s.serverIdleMinutes)
        s.containerIdleMinutes = max(1, s.containerIdleMinutes)
        s.idleCPUPercent = max(0, s.idleCPUPercent)
        if let override = s.dockerSocketOverride?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            s.dockerSocketOverride = override
        } else {
            s.dockerSocketOverride = nil
        }
        return s
    }
}
