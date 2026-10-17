import Foundation

/// Internal seam: lets `DockerClient` learn *why* `dockerSocketPath` returned nil (an unsupported remote endpoint, or a
/// user-configured socket that is not there) without widening the shared `ToolLocating` protocol.
protocol DockerSocketRejectionReporting: Sendable {
    /// Non-nil when the endpoint the user's Docker setup points at is unusable on purpose: ssh / tcp / remote context, or an
    /// explicitly configured socket (override, `$DOCKER_HOST`) that does not exist. Never a reason to try another daemon.
    func socketRejection(override: String?) -> String?
}

/// Absolute-path discovery for `docker` / `git` and the Engine socket. GUI apps do not inherit the shell PATH, so nothing here
/// consults `$PATH`. Stateless; every call re-reads the filesystem (a handful of `stat`s and one small JSON read).
public struct ToolLocator: ToolLocating, DockerSocketRejectionReporting {
    static let remoteContextMessage = "Uzak Docker bağlamı desteklenmiyor"

    static func socketNotFoundMessage(_ path: String) -> String { "Soket bulunamadı: \(path)" }

    enum SocketResolution: Equatable {
        case socket(String)
        case rejected(String)
        case none
    }

    private enum ContextEndpoint {
        case none
        case unix(String)
        case remote
    }

    private let home: String
    private let environment: [String: String]
    private let systemDockerPaths: [String]
    private let varRunSocket: String
    private let dockerAppPath: String
    private let gitPath: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.init(homeDirectory: homeDirectory, environment: ProcessInfo.processInfo.environment)
    }

    /// Test seam: every system-wide location can be redirected into a temp directory.
    init(homeDirectory: String,
         environment: [String: String],
         systemDockerPaths: [String] = ["/usr/local/bin/docker",
                                        "/opt/homebrew/bin/docker",
                                        "/Applications/Docker.app/Contents/Resources/bin/docker"],
         varRunSocket: String = "/var/run/docker.sock",
         dockerAppPath: String = "/Applications/Docker.app",
         gitPath: String = "/usr/bin/git") {
        self.home = homeDirectory
        self.environment = environment
        self.systemDockerPaths = systemDockerPaths
        self.varRunSocket = varRunSocket
        self.dockerAppPath = dockerAppPath
        self.gitPath = gitPath
    }

    // MARK: ToolLocating

    public func dockerExecutable() -> URL? {
        let candidates = ["\(home)/.docker/bin/docker"] + systemDockerPaths
        for path in candidates where Self.isExecutableFile(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func gitExecutable() -> URL? {
        Self.isExecutableFile(gitPath) ? URL(fileURLWithPath: gitPath) : nil
    }

    public func dockerSocketPath(override: String?) -> String? {
        if case .socket(let path) = resolveSocket(override: override) { return path }
        return nil
    }

    public func isDockerDesktopInstalled() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: dockerAppPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `~/.docker/bin` (user-writable; holds Docker Desktop's credential helpers and CLI shims) comes LAST so nothing in it can
    /// shadow a system tool for any child, git included.
    public func childEnvironment() -> [String: String] {
        [
            "HOME": home,
            "USER": environment["USER"] ?? NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.docker/bin",
            "LC_ALL": "C",
        ]
    }

    // MARK: DockerSocketRejectionReporting

    func socketRejection(override: String?) -> String? {
        if case .rejected(let reason) = resolveSocket(override: override) { return reason }
        return nil
    }

    // MARK: Socket resolution

    /// Precedence: (1) override, (2) `$DOCKER_HOST`, (3) current Docker context, (4) `~/.docker/run/docker.sock`,
    /// (5) `/var/run/docker.sock`, (6) colima, (7) OrbStack.
    ///
    /// Silently talking to a *different* local daemon than the one the user configured is worse than reporting it, so an
    /// endpoint the user named explicitly STOPS the search whether or not it is usable: a non-unix endpoint (2, 3) is
    /// `.rejected` as remote, and an override (1) or unix `$DOCKER_HOST` (2) that is not a socket is `.rejected` as missing.
    /// The one deliberate exception is a context whose unix socket is missing (3): a quit Docker Desktop (its context points at
    /// `~/.docker/run/docker.sock`) must keep reading as "not running" rather than "failed", and a stale context name must not
    /// hide a daemon sitting at a default location. Accepted design (SecurityReview N-7): whatever daemon is found here is the
    /// one DevTidy lists AND acts on (container ids, compose `DOCKER_HOST` pin), so no action can reach a different daemon than
    /// the one on screen; the only cost is that the CLI's own idea of "current context" may differ from what the Docker tab shows.
    func resolveSocket(override: String?) -> SocketResolution {
        if let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let unixPath = Self.unixPath(fromEndpoint: raw)
            if unixPath == nil, raw.contains("://"), !raw.hasPrefix("unix://") { return .rejected(Self.remoteContextMessage) }
            let path = expandTilde(unixPath ?? raw)
            return Self.isSocket(path) ? .socket(path) : .rejected(Self.socketNotFoundMessage(path))
        }

        if let host = environment["DOCKER_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            guard let path = Self.unixPath(fromEndpoint: host) else { return .rejected(Self.remoteContextMessage) }
            return Self.isSocket(path) ? .socket(path) : .rejected(Self.socketNotFoundMessage(path))
        }

        switch currentContextEndpoint() {
        case .unix(let path):
            if Self.isSocket(path) { return .socket(path) }
        case .remote:
            return .rejected(Self.remoteContextMessage)
        case .none:
            break
        }

        let candidates = [
            "\(home)/.docker/run/docker.sock",
            varRunSocket,
            "\(home)/.colima/default/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
        ]
        for path in candidates where Self.isSocket(path) { return .socket(path) }
        return .none
    }

    private func currentContextEndpoint() -> ContextEndpoint {
        let fileManager = FileManager.default
        guard let configData = fileManager.contents(atPath: "\(home)/.docker/config.json"),
              let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any],
              let name = config["currentContext"] as? String,
              !name.isEmpty, name != "default" else { return .none }

        let metaRoot = "\(home)/.docker/contexts/meta"
        guard let directories = try? fileManager.contentsOfDirectory(atPath: metaRoot) else { return .none }
        for directory in directories.sorted() {
            guard let data = fileManager.contents(atPath: "\(metaRoot)/\(directory)/meta.json"),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (meta["Name"] as? String) == name else { continue }
            guard let endpoints = meta["Endpoints"] as? [String: Any],
                  let docker = endpoints["docker"] as? [String: Any],
                  let host = docker["Host"] as? String, !host.isEmpty else { return .none }
            if let path = Self.unixPath(fromEndpoint: host) { return .unix(path) }
            return .remote
        }
        return .none
    }

    private func expandTilde(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    // MARK: Filesystem predicates

    /// `unix:///path` → `/path`; anything else (tcp://, ssh://, npipe://, fd://) → nil.
    static func unixPath(fromEndpoint endpoint: String) -> String? {
        let prefix = "unix://"
        guard endpoint.hasPrefix(prefix) else { return nil }
        let path = String(endpoint.dropFirst(prefix.count))
        return path.isEmpty ? nil : path
    }

    /// Follows symlinks: `/var/run/docker.sock` is a symlink to the real socket under Docker Desktop and OrbStack.
    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return mode_t(info.st_mode) & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }
}
