import Darwin
import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    /// The runner aborted the run: the deadline passed, or a stream exceeded `ProcessCommandRunner.outputLimit`. The child's
    /// process group was signalled and the output may be incomplete, so callers treat this as a failure, never as a result.
    public let timedOut: Bool
    public var outputString: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorString: String { String(decoding: standardError, as: UTF8.self) }
}

public enum CommandError: Error, Sendable, Equatable { case launchFailed(String) }

public protocol CommandRunning: Sendable {
    /// argv array only, never a shell. Environment is exactly `environment`. stdin = /dev/null.
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?, timeout: TimeInterval) async throws -> CommandResult
}

/// Spawns the child with `posix_spawn` in its OWN process group and only the three standard descriptors
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so that
/// * the deadline and the output cap can signal the whole group (a grandchild such as a compose plugin included) with
///   `kill(-pgid)`, and that is only ever done while the child is still an unreaped zombie-or-live process of ours, so its
///   pid / pgid cannot have been recycled (F-10);
/// * output is captured up to `outputLimit` bytes per stream; exceeding it aborts the run instead of truncating silently;
/// * a grandchild that outlives the child and keeps the pipes open delays the result by at most `drainGrace` seconds.
public struct ProcessCommandRunner: CommandRunning {
    /// Per-stream cap on captured output. Real `git` / `docker` answers are kilobytes; a run beyond this is a runaway.
    public static let outputLimit = 16 * 1024 * 1024

    private let outputLimit: Int
    private let drainGrace: TimeInterval
    private let killGrace: TimeInterval

    public init() {
        self.init(outputLimit: Self.outputLimit, drainGrace: 2, killGrace: 2)
    }

    init(outputLimit: Int, drainGrace: TimeInterval, killGrace: TimeInterval) {
        self.outputLimit = outputLimit
        self.drainGrace = drainGrace
        self.killGrace = killGrace
    }

    public func run(executable: URL, arguments: [String], environment: [String: String],
                    currentDirectory: URL?, timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    cont.resume(returning: try self.execute(executable: executable, arguments: arguments,
                                                            environment: environment, currentDirectory: currentDirectory,
                                                            timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Shared state

    /// One run's lifecycle. `exited` flips under the lock, in the same critical section that reaps the child, so a signal
    /// sent under the lock can never reach a recycled pid.
    private final class RunState: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var exited = false
        private var aborted = false
        private var readingStopped = false

        init(pid: pid_t) { self.pid = pid }

        /// Deadline or output cap: signal the child's group while the child has not been reaped.
        func abort(_ signal: Int32) {
            lock.lock(); defer { lock.unlock() }
            guard !exited else { return }
            aborted = true
            if pid > 1 { _ = Darwin.kill(-pid, signal) }       // pgid == pid: spawned with POSIX_SPAWN_SETPGROUP(0)
        }

        /// The output cap was crossed. Always recorded: the last read can arrive after the child was reaped (a grandchild
        /// still held the pipe), and the result must then still say the output is incomplete. The group is only signalled
        /// while the child has not been reaped.
        func overflowed() {
            lock.lock(); defer { lock.unlock() }
            aborted = true
            if !exited, pid > 1 { _ = Darwin.kill(-pid, SIGKILL) }
        }

        var wasAborted: Bool { lock.withLock { aborted } }

        /// The child has exited and is still waitable. When the run was aborted, sweeps stragglers that keep the pipes open
        /// (the zombie leader still pins the pgid), then reaps and returns the raw wait status.
        func reap() -> Int32 {
            lock.lock(); defer { lock.unlock() }
            if aborted, pid > 1 { _ = Darwin.kill(-pid, SIGKILL) }
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            exited = true
            return status
        }

        func stopReading() { lock.withLock { readingStopped = true } }
        var isReadingStopped: Bool { lock.withLock { readingStopped } }
    }

    private final class Sink: @unchecked Sendable {
        var data = Data()
    }

    // MARK: Run

    private func execute(executable: URL, arguments: [String], environment: [String: String],
                         currentDirectory: URL?, timeout: TimeInterval) throws -> CommandResult {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw CommandError.launchFailed("pipe: \(Self.describe(errno))") }
        guard pipe(&errPipe) == 0 else {
            let failure = errno
            close(outPipe[0]); close(outPipe[1])
            throw CommandError.launchFailed("pipe: \(Self.describe(failure))")
        }
        for descriptor in outPipe + errPipe { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

        let spawned = Self.spawn(path: executable.path, arguments: arguments, environment: environment,
                                 currentDirectory: currentDirectory?.path, stdoutFD: outPipe[1], stderrFD: errPipe[1])
        close(outPipe[1]); close(errPipe[1])               // the child owns the write ends; EOF needs them closed here
        let pid: pid_t
        switch spawned {
        case .success(let value):
            pid = value
        case .failure(let failure):
            close(outPipe[0]); close(errPipe[0])
            throw CommandError.launchFailed("\(executable.path): \(failure.message)")
        }

        let state = RunState(pid: pid)
        let out = Sink(), err = Sink()
        let limit = outputLimit
        let readers = DispatchGroup()
        for (descriptor, sink) in [(outPipe[0], out), (errPipe[0], err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                Self.drain(descriptor, into: sink, limit: limit, state: state)
                readers.leave()
            }
        }

        let deadline = max(0, timeout)
        let term = DispatchWorkItem { state.abort(SIGTERM) }
        let kill = DispatchWorkItem { state.abort(SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: term)
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline + killGrace, execute: kill)

        // Wait for the exit WITHOUT reaping, so the pid stays ours until `reap()` runs under the state lock.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        term.cancel(); kill.cancel()
        let status = state.reap()

        // Normally both pipes are at EOF already. A grandchild that kept them open only delays us by `drainGrace`.
        let stop = DispatchWorkItem { state.stopReading() }
        DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace, execute: stop)
        readers.wait()
        stop.cancel()
        close(outPipe[0]); close(errPipe[0])

        let signalled = status & 0x7f
        let exitCode = signalled == 0 ? (status >> 8) & 0xff : signalled
        return CommandResult(exitCode: exitCode, standardOutput: out.data, standardError: err.data,
                             timedOut: state.wasAborted)
    }

    /// Reads until EOF (or until `state` stops reading), keeping at most `limit` bytes. Exceeding the limit aborts the run.
    private static func drain(_ descriptor: Int32, into sink: Sink, limit: Int, state: RunState) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var overflowed = false
        while !state.isReadingStopped {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                if overflowed { continue }                  // keep draining so the child is never blocked on a full pipe
                let room = limit - sink.data.count
                if count > room {
                    sink.data.append(contentsOf: buffer[0..<max(0, room)])
                    overflowed = true
                    state.overflowed()
                } else {
                    sink.data.append(contentsOf: buffer[0..<count])
                }
            } else if count == 0 {
                return                                      // EOF
            } else if errno != EAGAIN, errno != EINTR {
                return
            }
        }
    }

    // MARK: Spawn

    private struct SpawnFailure: Error {
        let message: String
    }

    private static func describe(_ code: Int32) -> String { String(cString: strerror(code)) }

    /// New process group (`pgid == pid`), signals reset to default, empty signal mask, descriptors 0/1/2 only.
    private static func spawn(path: String, arguments: [String], environment: [String: String], currentDirectory: String?,
                              stdoutFD: Int32, stderrFD: Int32) -> Result<pid_t, SpawnFailure> {
        var attributes: posix_spawnattr_t? = nil
        var status = posix_spawnattr_init(&attributes)
        guard status == 0 else { return .failure(SpawnFailure(message: "posix_spawnattr_init: \(describe(status))")) }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        var mask = sigset_t()
        sigemptyset(&mask)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        status = posix_spawnattr_setflags(&attributes, Int16(flags))
        if status == 0 { status = posix_spawnattr_setpgroup(&attributes, 0) }
        if status == 0 { status = posix_spawnattr_setsigdefault(&attributes, &defaults) }
        if status == 0 { status = posix_spawnattr_setsigmask(&attributes, &mask) }
        guard status == 0 else { return .failure(SpawnFailure(message: "posix_spawnattr: \(describe(status))")) }

        var actions: posix_spawn_file_actions_t? = nil
        status = posix_spawn_file_actions_init(&actions)
        guard status == 0 else { return .failure(SpawnFailure(message: "posix_spawn_file_actions_init: \(describe(status))")) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        status = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if status == 0 { status = posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1) }
        if status == 0 { status = posix_spawn_file_actions_adddup2(&actions, stderrFD, 2) }
        if status == 0, let currentDirectory { status = posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) }
        guard status == 0 else { return .failure(SpawnFailure(message: "posix_spawn_file_actions: \(describe(status))")) }

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard status == 0 else { return .failure(SpawnFailure(message: "posix_spawn: \(describe(status))")) }
        return .success(pid)
    }
}
