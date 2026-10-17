import Darwin
import Foundation
import Testing
@testable import DevTidyCore

/// F-10 / P2-15: the runner spawns real helper processes (`/bin/sh`, `/usr/bin/yes`) that the tests start themselves and only
/// ever signals through its own process group.
@Suite struct CommandRunnerTests {
    private let sh = URL(fileURLWithPath: "/bin/sh")
    private let environment = ["PATH": "/usr/bin:/bin"]

    private func shell(_ script: String, runner: ProcessCommandRunner, timeout: TimeInterval = 30,
                       directory: URL? = nil) async throws -> CommandResult {
        try await runner.run(executable: sh, arguments: ["-c", script], environment: environment,
                             currentDirectory: directory, timeout: timeout)
    }

    private func pid(in result: CommandResult) throws -> Int32 {
        try #require(Int32(result.outputString.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func capturesBothStreamsTheExitCodeTheEnvironmentAndTheDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devtidy-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let physical = try #require(realpath(directory.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        })

        let runner = ProcessCommandRunner()
        var variables = environment
        variables["DEVTIDY_RUNNER_VAR"] = "42"
        let result = try await runner.run(
            executable: sh,
            arguments: ["-c", "echo out; echo err >&2; echo $DEVTIDY_RUNNER_VAR; pwd; cat; echo after-cat; exit 3"],
            environment: variables, currentDirectory: directory, timeout: 30)
        #expect(result.exitCode == 3)
        #expect(result.outputString == "out\n42\n\(physical)\nafter-cat\n")      // stdin is /dev/null: `cat` returns at once
        #expect(result.errorString == "err\n")
        #expect(!result.timedOut)
    }

    @Test func descriptorsOtherThanTheStandardThreeAreNotInherited() async throws {
        let descriptor = open("/dev/null", O_RDONLY)
        try #require(descriptor > 2)
        defer { close(descriptor) }
        let runner = ProcessCommandRunner()
        let result = try await shell("if [ -e /dev/fd/\(descriptor) ]; then echo leaked; else echo clean; fi", runner: runner)
        #expect(result.outputString == "clean\n")
    }

    @Test func aMissingExecutableIsALaunchFailure() async {
        let runner = ProcessCommandRunner()
        await #expect(throws: CommandError.self) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/devtidy-runner-test"), arguments: [],
                                     environment: [:], currentDirectory: nil, timeout: 5)
        }
    }

    @Test func aGrandchildHoldingThePipeDoesNotHoldTheResultHostage() async throws {
        // The shell exits at once; its background `sleep` keeps stdout open for 30 s. The result must come back after the
        // drain grace with the shell's output, and the grandchild must be left alone (it is not DevTidy's to kill).
        let runner = ProcessCommandRunner(outputLimit: 1 << 20, drainGrace: 0.3, killGrace: 0.5)
        let result = try await shell("/bin/sleep 30 & echo $!", runner: runner)
        let grandchild = try pid(in: result)
        defer { if kill(grandchild, 0) == 0 { kill(grandchild, SIGKILL) } }       // the test's own helper
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(kill(grandchild, 0) == 0)       // still running: nothing but the pipe wait was cut short
    }

    @Test func aTimeoutStopsTheWholeGroupIncludingAGrandchildThatHoldsThePipe() async throws {
        let runner = ProcessCommandRunner(outputLimit: 1 << 20, drainGrace: 2, killGrace: 0.5)
        let result = try await shell("/bin/sleep 60 & echo $!; wait", runner: runner, timeout: 0.5)
        let grandchild = try pid(in: result)
        defer { if kill(grandchild, 0) == 0 { kill(grandchild, SIGKILL) } }
        #expect(result.timedOut)
        var gone = false
        for _ in 0..<100 {
            if kill(grandchild, 0) != 0 { gone = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(gone)
    }

    @Test func outputBeyondTheLimitAbortsTheRunInsteadOfTruncatingSilently() async throws {
        let runner = ProcessCommandRunner(outputLimit: 4096, drainGrace: 1, killGrace: 0.5)
        let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [],
                                          environment: environment, currentDirectory: nil, timeout: 30)
        #expect(result.timedOut)                                  // callers treat it as a failure, not as a complete answer
        #expect(result.standardOutput.count == 4096)
        #expect(result.exitCode == SIGKILL)
    }

    @Test func outputCrossingTheLimitAfterTheChildWasReapedStillAbortsTheRun() async throws {
        // The shell exits at once and is reaped; a background subshell keeps the pipe open and only writes (more than the
        // limit) once the test says so, i.e. after the reap. The cap is then crossed by the last read of an already finished
        // child: the result must still be flagged as aborted, never reported as a clean, complete answer (P3-1).
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devtidy-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }       // also ends the subshell's wait loop
        let go = directory.appendingPathComponent("go").path
        let pidFile = directory.appendingPathComponent("pid").path

        let script = "(while [ -d \"$DEVTIDY_RUNNER_DIR\" ] && [ ! -e \"$DEVTIDY_RUNNER_DIR/go\" ]; do /bin/sleep 0.05; done; "
            + "[ -e \"$DEVTIDY_RUNNER_DIR/go\" ] && /usr/bin/head -c 8192 /dev/zero) & echo $$ > \"$DEVTIDY_RUNNER_DIR/pid\""
        var variables = environment
        variables["DEVTIDY_RUNNER_DIR"] = directory.path
        let runner = ProcessCommandRunner(outputLimit: 4096, drainGrace: 30, killGrace: 0.5)
        let sh = self.sh
        let run = Task { try await runner.run(executable: sh, arguments: ["-c", script], environment: variables,
                                              currentDirectory: nil, timeout: 60) }

        var shellPID: Int32?
        for _ in 0..<500 where shellPID == nil {
            shellPID = (try? String(contentsOfFile: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if shellPID == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pid = try #require(shellPID)
        var reaped = false
        for _ in 0..<500 where !reaped {
            reaped = kill(pid, 0) != 0              // a zombie still answers 0: ESRCH means the runner has reaped the shell
            if !reaped { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(reaped)
        FileManager.default.createFile(atPath: go, contents: nil)

        let result = try await run.value
        #expect(result.timedOut)
        #expect(result.standardOutput.count == 4096)
        #expect(result.exitCode == 0)               // the shell itself finished normally; only the output was cut
    }
}
