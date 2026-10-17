import Foundation

/// The only place DevTidy spawns `docker`: `docker compose -p NAME stop|down`. Compose owns dependency-ordered shutdown and
/// network cleanup, which the Engine API does not (design §3.1). The argv is built from a validated project name and a fixed
/// verb; no flag that widens the blast radius (volumes, images, orphans) is ever added (X4).
struct ComposeCLI: Sendable {
    static let timeout: TimeInterval = 120

    let runner: any CommandRunning
    let locator: any ToolLocating

    static func arguments(for action: ComposeAction, projectName: String) -> [String] {
        switch action {
        case .stop: return ["compose", "-p", projectName, "stop"]
        case .down: return ["compose", "-p", projectName, "down"]
        }
    }

    /// - Parameter socketPath: the Engine socket `DockerClient.requireSocket()` accepted. It is ALWAYS handed to the CLI as
    ///   `DOCKER_HOST`, so compose acts on exactly the daemon whose containers DevTidy listed and can never follow the CLI's own
    ///   `currentContext` (which may be a remote daemon the client refuses to talk to). Non-optional on purpose: there is no
    ///   way to spawn compose without a validated local socket.
    func run(_ action: ComposeAction, projectName: String, socketPath: String) async throws {
        // X2: validated before anything is spawned. The first character is alphanumeric, so the name can never be read as an option.
        guard DockerValidation.isValidProjectName(projectName) else {
            throw DockerError.invalidArgument("Geçersiz compose proje adı")
        }
        guard let executable = locator.dockerExecutable() else { throw DockerError.notInstalled }

        var environment = locator.childEnvironment()
        environment["DOCKER_HOST"] = "unix://" + socketPath

        let result: CommandResult
        do {
            // Neutral working directory: compose must not pick up a stray compose file from DevTidy's own cwd.
            result = try await runner.run(executable: executable,
                                          arguments: Self.arguments(for: action, projectName: projectName),
                                          environment: environment,
                                          currentDirectory: URL(fileURLWithPath: "/"),
                                          timeout: Self.timeout)
        } catch CommandError.launchFailed(let message) {
            throw DockerError.commandFailed(exitCode: -1, stderr: message)
        }
        if result.timedOut { throw DockerError.timeout }
        guard result.exitCode == 0 else {
            throw DockerError.commandFailed(exitCode: result.exitCode, stderr: Self.diagnosticText(result.standardError))
        }
    }

    /// Longest part of the child's stderr kept in `DockerError.commandFailed` (UTF-8 bytes). The runner caps a stream at 16 MiB;
    /// the cause of a compose failure is in the first lines, and everything downstream (card text, audit log) is short.
    static let stderrLimit = 4_096

    static func diagnosticText(_ errorOutput: Data) -> String {
        String(decoding: errorOutput.prefix(stderrLimit), as: UTF8.self)
    }
}
