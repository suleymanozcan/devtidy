import Foundation
import Testing
@testable import DevTidyCore

/// Every path lives under a throw-away `/tmp/devtidy-s3-XXXXXX` sandbox (short on purpose: AF_UNIX paths are limited to 103 bytes).
/// The real `$HOME`, `/var/run/docker.sock` and the real Docker socket are never consulted: every system-wide location is injected.
@Suite("ToolLocator")
struct ToolLocatorTests {
    private final class Sandbox {
        let root: String
        var home: String { root + "/home" }
        var system: String { root + "/system" }

        init() throws {
            root = try S3Temp.makeDirectory()
            try FileManager.default.createDirectory(atPath: root + "/home", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: root + "/system", withIntermediateDirectories: true)
        }

        deinit { S3Temp.remove(root) }

        func makeFile(_ path: String, executable: Bool) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        }

        func makeSocket(_ path: String) throws {
            try S3Sockets.makeSocketFile(at: path)
        }

        func remove(_ path: String) throws {
            try FileManager.default.removeItem(atPath: path)
        }

        func writeConfig(currentContext: String) throws {
            try write(#"{"auths":{},"currentContext":"\#(currentContext)"}"#, to: home + "/.docker/config.json")
        }

        func writeContext(directory: String, name: String, host: String) throws {
            let json = #"{"Name":"\#(name)","Metadata":{},"Endpoints":{"docker":{"Host":"\#(host)","SkipTLSVerify":false}}}"#
            try write(json, to: home + "/.docker/contexts/meta/\(directory)/meta.json")
        }

        func write(_ text: String, to path: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }

        // Injected system-wide locations.
        var usrLocalDocker: String { system + "/usr-local-bin/docker" }
        var homebrewDocker: String { system + "/opt-homebrew-bin/docker" }
        var appDocker: String { system + "/Docker.app/Contents/Resources/bin/docker" }
        var varRunSocket: String { system + "/var-run/docker.sock" }
        var dockerApp: String { system + "/Docker.app" }
        var git: String { system + "/usr-bin/git" }
        var homeDocker: String { home + "/.docker/bin/docker" }

        func locator(environment: [String: String] = [:]) -> ToolLocator {
            ToolLocator(homeDirectory: home, environment: environment,
                        systemDockerPaths: [usrLocalDocker, homebrewDocker, appDocker],
                        varRunSocket: varRunSocket, dockerAppPath: dockerApp, gitPath: git)
        }
    }

    // MARK: Executables

    @Test func dockerExecutableFollowsTheCandidateOrder() throws {
        let sandbox = try Sandbox()
        let locator = sandbox.locator()
        #expect(locator.dockerExecutable() == nil)

        try sandbox.makeFile(sandbox.appDocker, executable: true)
        #expect(locator.dockerExecutable()?.path == sandbox.appDocker)
        try sandbox.makeFile(sandbox.homebrewDocker, executable: true)
        #expect(locator.dockerExecutable()?.path == sandbox.homebrewDocker)
        try sandbox.makeFile(sandbox.usrLocalDocker, executable: true)
        #expect(locator.dockerExecutable()?.path == sandbox.usrLocalDocker)
        try sandbox.makeFile(sandbox.homeDocker, executable: true)
        #expect(locator.dockerExecutable()?.path == sandbox.homeDocker)

        try sandbox.remove(sandbox.homeDocker)
        #expect(locator.dockerExecutable()?.path == sandbox.usrLocalDocker)
    }

    @Test func nonExecutableFilesAndDirectoriesAreSkipped() throws {
        let sandbox = try Sandbox()
        try sandbox.makeFile(sandbox.homeDocker, executable: false)
        try FileManager.default.createDirectory(atPath: sandbox.usrLocalDocker, withIntermediateDirectories: true)
        try sandbox.makeFile(sandbox.homebrewDocker, executable: true)
        #expect(sandbox.locator().dockerExecutable()?.path == sandbox.homebrewDocker)
    }

    @Test func symlinkedDockerCLIIsAccepted() throws {
        // ~/.docker/bin/docker is a symlink into Docker.app (ENV §7.1).
        let sandbox = try Sandbox()
        try sandbox.makeFile(sandbox.appDocker, executable: true)
        try FileManager.default.createDirectory(atPath: (sandbox.homeDocker as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox.homeDocker, withDestinationPath: sandbox.appDocker)
        #expect(sandbox.locator().dockerExecutable()?.path == sandbox.homeDocker)
    }

    @Test func gitExecutableIsAbsoluteAndOptional() throws {
        let sandbox = try Sandbox()
        #expect(sandbox.locator().gitExecutable() == nil)
        try sandbox.makeFile(sandbox.git, executable: true)
        #expect(sandbox.locator().gitExecutable()?.path == sandbox.git)
        // Production default location.
        let real = ToolLocator(homeDirectory: sandbox.home)
        #expect((real.gitExecutable() != nil) == FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        if let url = real.gitExecutable() { #expect(url.path == "/usr/bin/git") }
    }

    @Test func dockerDesktopDetectionNeedsADirectory() throws {
        let sandbox = try Sandbox()
        #expect(!sandbox.locator().isDockerDesktopInstalled())
        try sandbox.makeFile(sandbox.dockerApp, executable: false)           // a plain file is not an app bundle
        #expect(!sandbox.locator().isDockerDesktopInstalled())
        try sandbox.remove(sandbox.dockerApp)
        try FileManager.default.createDirectory(atPath: sandbox.dockerApp, withIntermediateDirectories: true)
        #expect(sandbox.locator().isDockerDesktopInstalled())
    }

    // MARK: Child environment

    @Test func childEnvironmentIsMinimal() throws {
        let sandbox = try Sandbox()
        let environment = sandbox.locator(environment: ["USER": "alice", "PATH": "/evil", "DOCKER_HOST": "tcp://x", "LANG": "tr_TR.UTF-8"]).childEnvironment()
        #expect(environment == [
            "HOME": sandbox.home,
            "USER": "alice",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(sandbox.home)/.docker/bin",     // user-writable dir last: it never shadows a system tool
            "LC_ALL": "C",
        ])
        // Without USER in the environment it falls back to the account name.
        #expect(sandbox.locator().childEnvironment()["USER"] == NSUserName())
        #expect(sandbox.locator().childEnvironment().count == 4)
    }

    // MARK: Socket precedence

    @Test func socketPrecedenceListIsRespectedStepByStep() throws {
        let sandbox = try Sandbox()
        let overrideSocket = sandbox.root + "/override.sock"
        let dockerHostSocket = sandbox.root + "/dockerhost.sock"
        let contextSocket = sandbox.root + "/context.sock"
        let decoySocket = sandbox.root + "/decoy.sock"
        let runSocket = sandbox.home + "/.docker/run/docker.sock"
        let colimaSocket = sandbox.home + "/.colima/default/docker.sock"
        let orbstackSocket = sandbox.home + "/.orbstack/run/docker.sock"

        try [overrideSocket, dockerHostSocket, contextSocket, decoySocket, runSocket, sandbox.varRunSocket, colimaSocket, orbstackSocket]
            .forEach { try sandbox.makeSocket($0) }
        try sandbox.writeConfig(currentContext: "desktop-linux")
        try sandbox.writeContext(directory: "aaa111", name: "colima", host: "unix://" + decoySocket)          // not the current context
        try sandbox.writeContext(directory: "bbb222", name: "desktop-linux", host: "unix://" + contextSocket)
        let withDockerHost = sandbox.locator(environment: ["DOCKER_HOST": "unix://" + dockerHostSocket])
        let walk = sandbox.locator()

        // (1) and (2) each stop the search, so they are checked with everything below them present.
        #expect(withDockerHost.dockerSocketPath(override: overrideSocket) == overrideSocket)    // (1) override
        #expect(withDockerHost.dockerSocketPath(override: nil) == dockerHostSocket)             // (2) $DOCKER_HOST

        // (3)…(7): a socket that is not there simply lets the walk continue.
        #expect(walk.dockerSocketPath(override: nil) == contextSocket)                          // (3) current context
        try sandbox.remove(contextSocket)
        #expect(walk.dockerSocketPath(override: nil) == runSocket)                              // (4) ~/.docker/run/docker.sock
        try sandbox.remove(runSocket)
        #expect(walk.dockerSocketPath(override: nil) == sandbox.varRunSocket)                   // (5) /var/run/docker.sock
        try sandbox.remove(sandbox.varRunSocket)
        #expect(walk.dockerSocketPath(override: nil) == colimaSocket)                           // (6) colima
        try sandbox.remove(colimaSocket)
        #expect(walk.dockerSocketPath(override: nil) == orbstackSocket)                         // (7) OrbStack
        try sandbox.remove(orbstackSocket)
        #expect(walk.dockerSocketPath(override: nil) == nil)                                    // the decoy context is never used
        #expect(walk.socketRejection(override: nil) == nil)
    }

    @Test func overrideThatIsNotASocketIsRejectedAndNeverFallsBackToAnotherDaemon() throws {
        let sandbox = try Sandbox()
        let runSocket = sandbox.home + "/.docker/run/docker.sock"
        try sandbox.makeSocket(runSocket)                                // another, perfectly healthy local daemon
        let notASocket = sandbox.root + "/regular-file"
        try sandbox.makeFile(notASocket, executable: false)
        let missing = sandbox.root + "/does-not-exist.sock"
        let locator = sandbox.locator()

        let unusable: [(input: String, shown: String)] = [
            (notASocket, notASocket), (missing, missing), ("unix://" + missing, missing), ("  \(missing)\n", missing),
        ]
        for (input, shown) in unusable {
            #expect(locator.dockerSocketPath(override: input) == nil)
            #expect(locator.socketRejection(override: input) == "Soket bulunamadı: \(shown)")
        }
        for remote in ["tcp://10.0.0.5:2376", "ssh://user@build-box"] {
            #expect(locator.dockerSocketPath(override: remote) == nil)
            #expect(locator.socketRejection(override: remote) == "Uzak Docker bağlamı desteklenmiyor")
        }

        // No override configured at all is not a configuration: the default candidates apply.
        let unset: [String?] = [nil, "", "   "]
        for blank in unset {
            #expect(locator.dockerSocketPath(override: blank) == runSocket)
            #expect(locator.socketRejection(override: blank) == nil)
        }
    }

    @Test func overrideAcceptsUnixSchemeAndTilde() throws {
        let sandbox = try Sandbox()
        let custom = sandbox.home + "/custom.sock"
        try sandbox.makeSocket(custom)
        let locator = sandbox.locator()
        #expect(locator.dockerSocketPath(override: "unix://" + custom) == custom)
        #expect(locator.dockerSocketPath(override: "~/custom.sock") == custom)
        #expect(locator.dockerSocketPath(override: "  \(custom)\n") == custom)
    }

    @Test func symlinkToASocketCountsAsASocket() throws {
        // /var/run/docker.sock is a symlink to the real socket under Docker Desktop's "default socket" option and OrbStack.
        let sandbox = try Sandbox()
        let real = sandbox.home + "/.orbstack/run/docker.sock"
        try sandbox.makeSocket(real)
        try FileManager.default.createDirectory(atPath: (sandbox.varRunSocket as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox.varRunSocket, withDestinationPath: real)
        #expect(sandbox.locator().dockerSocketPath(override: nil) == sandbox.varRunSocket)
    }

    @Test func regularFilesAndDirectoriesAreNeverSockets() throws {
        let sandbox = try Sandbox()
        try sandbox.makeFile(sandbox.home + "/.docker/run/docker.sock", executable: false)
        try FileManager.default.createDirectory(atPath: sandbox.varRunSocket, withIntermediateDirectories: true)
        #expect(sandbox.locator().dockerSocketPath(override: nil) == nil)
    }

    // MARK: Contexts

    @Test func defaultContextAndMissingConfigUseTheFallbackCandidates() throws {
        let sandbox = try Sandbox()
        let runSocket = sandbox.home + "/.docker/run/docker.sock"
        try sandbox.makeSocket(runSocket)
        #expect(sandbox.locator().dockerSocketPath(override: nil) == runSocket)              // no config.json at all
        try sandbox.writeConfig(currentContext: "default")
        #expect(sandbox.locator().dockerSocketPath(override: nil) == runSocket)
        try sandbox.write("{ this is not json", to: sandbox.home + "/.docker/config.json")
        #expect(sandbox.locator().dockerSocketPath(override: nil) == runSocket)              // corrupt config is ignored
    }

    /// Deliberate exception to "a configured endpoint stops the search": a context that points at a missing unix socket is
    /// what a quit Docker Desktop looks like, which must stay "not running" rather than "failed".
    @Test func contextWithAMissingUnixSocketFallsThrough() throws {
        let sandbox = try Sandbox()
        let runSocket = sandbox.home + "/.docker/run/docker.sock"
        try sandbox.makeSocket(runSocket)
        try sandbox.writeConfig(currentContext: "desktop-linux")
        try sandbox.writeContext(directory: "ccc333", name: "desktop-linux", host: "unix://" + sandbox.root + "/gone.sock")
        let locator = sandbox.locator()
        #expect(locator.dockerSocketPath(override: nil) == runSocket)
        #expect(locator.socketRejection(override: nil) == nil)
    }

    @Test func unknownContextNameAndBrokenMetaAreIgnored() throws {
        let sandbox = try Sandbox()
        let runSocket = sandbox.home + "/.docker/run/docker.sock"
        try sandbox.makeSocket(runSocket)
        try sandbox.writeConfig(currentContext: "nope")
        try sandbox.write("garbage", to: sandbox.home + "/.docker/contexts/meta/ddd444/meta.json")
        try sandbox.writeContext(directory: "eee555", name: "other", host: "ssh://user@host")
        #expect(sandbox.locator().dockerSocketPath(override: nil) == runSocket)
        #expect(sandbox.locator().socketRejection(override: nil) == nil)
    }

    @Test(arguments: ["ssh://user@build-box", "tcp://10.0.0.5:2376", "npipe:////./pipe/docker_engine", "fd://3"])
    func remoteContextIsRejectedEvenWhenALocalSocketExists(host: String) throws {
        let sandbox = try Sandbox()
        try sandbox.makeSocket(sandbox.home + "/.docker/run/docker.sock")
        try sandbox.writeConfig(currentContext: "remote-box")
        try sandbox.writeContext(directory: "fff666", name: "remote-box", host: host)
        let locator = sandbox.locator()
        #expect(locator.dockerSocketPath(override: nil) == nil)
        #expect(locator.socketRejection(override: nil) == "Uzak Docker bağlamı desteklenmiyor")

        // An explicit, valid override still wins: the user asked for exactly that socket.
        let explicit = sandbox.root + "/explicit.sock"
        try sandbox.makeSocket(explicit)
        #expect(locator.dockerSocketPath(override: explicit) == explicit)
        #expect(locator.socketRejection(override: explicit) == nil)
    }

    @Test func remoteOrDeadDockerHostIsRejectedAndNeverFallsBackToAnotherDaemon() throws {
        let sandbox = try Sandbox()
        let runSocket = sandbox.home + "/.docker/run/docker.sock"
        try sandbox.makeSocket(runSocket)                                // another, perfectly healthy local daemon

        let remote = sandbox.locator(environment: ["DOCKER_HOST": "tcp://192.168.1.10:2375"])
        #expect(remote.dockerSocketPath(override: nil) == nil)
        #expect(remote.socketRejection(override: nil) == "Uzak Docker bağlamı desteklenmiyor")

        let gone = sandbox.root + "/gone.sock"
        let stale = sandbox.locator(environment: ["DOCKER_HOST": "unix://" + gone])
        #expect(stale.dockerSocketPath(override: nil) == nil)
        #expect(stale.socketRejection(override: nil) == "Soket bulunamadı: \(gone)")

        // A usable override still wins over a dead $DOCKER_HOST: the user asked for exactly that socket.
        let explicit = sandbox.root + "/explicit.sock"
        try sandbox.makeSocket(explicit)
        #expect(stale.dockerSocketPath(override: explicit) == explicit)
        #expect(stale.socketRejection(override: explicit) == nil)
    }

    @Test func unixEndpointParsing() {
        #expect(ToolLocator.unixPath(fromEndpoint: "unix:///Users/x/.docker/run/docker.sock") == "/Users/x/.docker/run/docker.sock")
        #expect(ToolLocator.unixPath(fromEndpoint: "unix://") == nil)
        #expect(ToolLocator.unixPath(fromEndpoint: "tcp://host:2375") == nil)
        #expect(ToolLocator.unixPath(fromEndpoint: "/plain/path") == nil)
    }

    // MARK: End to end with DockerClient

    @Test func sshContextSurfacesAsUnsupportedStatusAndRefusesEveryActionThroughTheClient() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeSocket(sandbox.home + "/.docker/run/docker.sock")
        try sandbox.makeFile(sandbox.homeDocker, executable: true)
        try sandbox.writeConfig(currentContext: "remote-box")
        try sandbox.writeContext(directory: "fff666", name: "remote-box", host: "ssh://user@build-box")
        let runner = S3FakeRunner()
        let client = DockerClient(locator: sandbox.locator(), runner: runner, audit: S3FakeAudit(), socketOverride: { nil })
        #expect(await client.snapshot(stats: .refresh).status == .unsupported("Uzak Docker bağlamı desteklenmiyor"))
        let containerError = await s3Error { try await client.perform(.stop, on: S3Fixtures.idA) }
        #expect(s3IsDaemonUnavailable(containerError))
        // F-1: compose must not follow the CLI's own (remote) context either — nothing is spawned.
        let composeError = await s3Error { try await client.perform(.down, projectName: "tunahan") }
        #expect(composeError as? DockerError == .daemonUnavailable("Uzak Docker bağlamı desteklenmiyor"))
        #expect(runner.calls.isEmpty)
    }

    @Test func unusableOverrideIsUnsupportedAndRefusesActionsInsteadOfUsingAnotherDaemon() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeSocket(sandbox.home + "/.docker/run/docker.sock")        // a healthy default daemon that must NOT be used
        try sandbox.makeFile(sandbox.homeDocker, executable: true)
        let missing = sandbox.root + "/gone.sock"
        let runner = S3FakeRunner()
        let client = DockerClient(locator: sandbox.locator(), runner: runner, audit: S3FakeAudit(), socketOverride: { missing })
        #expect(await client.snapshot(stats: .refresh).status == .unsupported("Soket bulunamadı: \(missing)"))
        let composeError = await s3Error { try await client.perform(.stop, projectName: "tunahan") }
        #expect(composeError as? DockerError == .daemonUnavailable("Soket bulunamadı: \(missing)"))
        let containerError = await s3Error { try await client.perform(.stop, on: S3Fixtures.idA) }
        #expect(containerError as? DockerError == .daemonUnavailable("Soket bulunamadı: \(missing)"))
        #expect(runner.calls.isEmpty)
    }

    @Test func composeIsPinnedToTheResolvedSocketNotToTheCLIsOwnContext() async throws {
        let sandbox = try Sandbox()
        let custom = sandbox.root + "/custom.sock"
        try sandbox.makeSocket(custom)
        try sandbox.makeFile(sandbox.homeDocker, executable: true)
        try sandbox.writeConfig(currentContext: "remote-box")                    // what the bare CLI would have followed
        try sandbox.writeContext(directory: "fff666", name: "remote-box", host: "ssh://user@build-box")
        let runner = S3FakeRunner()
        let client = DockerClient(locator: sandbox.locator(), runner: runner, audit: S3FakeAudit(), socketOverride: { custom })
        try await client.perform(.down, projectName: "tunahan")
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.environment["DOCKER_HOST"] == "unix://" + custom)
    }

    @Test func staleSocketFoundByTheLocatorIsNotRunningThroughTheClient() async throws {
        let sandbox = try Sandbox()
        try sandbox.makeSocket(sandbox.home + "/.docker/run/docker.sock")        // a socket file nobody listens on
        let client = DockerClient(locator: sandbox.locator(), runner: S3FakeRunner(), audit: S3FakeAudit(), socketOverride: { nil })
        #expect(await client.snapshot(stats: .reuse).status == .notRunning)
    }

    @Test func nothingInstalledIsNotInstalledThroughTheClient() async throws {
        let sandbox = try Sandbox()
        let client = DockerClient(locator: sandbox.locator(), runner: S3FakeRunner(), audit: S3FakeAudit(), socketOverride: { nil })
        #expect(await client.snapshot(stats: .reuse).status == .notInstalled)
        try sandbox.makeFile(sandbox.homeDocker, executable: true)
        #expect(await client.snapshot(stats: .reuse).status == .notRunning)
    }

    @Test func socketOverrideClosureIsConsultedOnEveryCall() async throws {
        let sandbox = try Sandbox()
        let custom = sandbox.root + "/custom.sock"
        let box = OverrideBox()
        let client = DockerClient(locator: sandbox.locator(), runner: S3FakeRunner(), audit: S3FakeAudit(),
                                  socketOverride: { box.value })
        #expect(await client.snapshot(stats: .reuse).status == .notInstalled)
        try sandbox.makeSocket(custom)                       // nobody listens, but it is a socket file
        box.value = custom
        #expect(await client.snapshot(stats: .reuse).status == .notRunning)
    }

    private final class OverrideBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
