import Foundation

/// What git said about "which repository am I in". Anything but a clean answer is fail-closed for B/C (R10).
enum GitRepoState: Sendable, Equatable {
    case repository(String)          // canonical toplevel
    case notARepository
    case failed(String)
}

enum GitListOutcome: Sendable, Equatable {
    case paths([String])
    case notARepository
    case failed(String)
}

enum GitBatchIgnoreOutcome: Sendable, Equatable {
    case ignored(Set<String>)        // the subset of the asked paths that git ignores
    case notARepository
    case failed(String)
}

/// Read-only git questions. Every path argument is relative to `parent` (the git working directory).
protocol GitProbing: Sendable {
    func toplevel(of directory: String) async -> GitRepoState
    /// `ls-files --cached -z -- <paths…>` (chunked): every tracked file below any of `paths`.
    func trackedPaths(inParent parent: String, paths: [String]) async -> GitListOutcome
    /// `ls-files --others --exclude-standard -z -- <paths…>` (chunked): untracked, not-ignored files below any of `paths`.
    func untrackedNotIgnoredPaths(inParent parent: String, paths: [String]) async -> GitListOutcome
    /// `check-ignore -- <paths…>` (chunked, newline output): the subset of `paths` that git ignores. `check-ignore` accepts
    /// neither `-z` without `--stdin` nor `--literal-pathspecs`, so it is the one probe that runs without them (git 2.50 [obs]).
    func ignoredPaths(inParent parent: String, paths: [String]) async -> GitBatchIgnoreOutcome
}

/// `/usr/bin/git --literal-pathspecs -C <parent> …` (except `check-ignore`, see `GitProbing`), 5 s timeout, `-z` outputs, argv arrays only (R10).
struct GitProbe: GitProbing {
    let runner: any CommandRunning
    let locator: any ToolLocating
    var timeout: TimeInterval = 5
    static let batchSize = 100

    init(runner: any CommandRunning, locator: any ToolLocating) {
        self.runner = runner
        self.locator = locator
    }

    // MARK: GitProbing

    func toplevel(of directory: String) async -> GitRepoState {
        switch await run(["rev-parse", "--show-toplevel"], in: directory) {
        case .success(let r):
            if r.exitCode == 0 {
                let line = r.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("/") else { return .failed("beklenmeyen git çıktısı") }
                return .repository(PathPolicy.canonical(line))
            }
            return Self.isNotARepository(r, directory: directory) ? .notARepository : .failed(Self.failureText(r))
        case .failure(let message):
            return .failed(message)
        }
    }

    func trackedPaths(inParent parent: String, paths: [String]) async -> GitListOutcome {
        await listChunked(["ls-files", "--cached", "-z", "--"], paths: paths, in: parent)
    }

    func untrackedNotIgnoredPaths(inParent parent: String, paths: [String]) async -> GitListOutcome {
        await listChunked(["ls-files", "--others", "--exclude-standard", "-z", "--"], paths: paths, in: parent)
    }

    func ignoredPaths(inParent parent: String, paths: [String]) async -> GitBatchIgnoreOutcome {
        var ignored = Set<String>()
        var index = 0
        while index < paths.count {
            // A leading ":" would be parsed as pathspec magic (`--literal-pathspecs` is rejected by check-ignore): such a
            // name is never asked, hence never reported ignored (fail closed).
            let chunk = paths[index..<min(index + Self.batchSize, paths.count)].filter { !$0.hasPrefix(":") }
            index += Self.batchSize
            if chunk.isEmpty { continue }
            switch await run(["-c", "core.quotePath=false", "check-ignore", "--"] + chunk, in: parent, literalPathspecs: false) {
            case .success(let r):
                // exit 0 = at least one ignored, 1 = none ignored, 128 = error.
                if r.exitCode == 0 || r.exitCode == 1 {
                    // Only a line equal to an asked path counts: names git has to C-quote (`"`, `\`, control bytes) never
                    // match and therefore stay "not ignored" (fail closed).
                    let asked = Set(chunk)
                    for line in r.outputString.split(separator: "\n", omittingEmptySubsequences: true) where asked.contains(String(line)) {
                        ignored.insert(String(line))
                    }
                } else if Self.isNotARepository(r, directory: parent) {
                    return .notARepository
                } else {
                    return .failed(Self.failureText(r))
                }
            case .failure(let message):
                return .failed(message)
            }
        }
        return .ignored(ignored)
    }

    // MARK: Plumbing

    private enum Ran {
        case success(CommandResult)
        case failure(String)
    }

    private func environment() -> [String: String] {
        var env = locator.childEnvironment()
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        return env
    }

    private func run(_ arguments: [String], in directory: String, literalPathspecs: Bool = true) async -> Ran {
        guard let git = locator.gitExecutable() else { return .failure("git bulunamadı") }
        let argv = (literalPathspecs ? ["--literal-pathspecs"] : []) + ["-c", "core.fsmonitor=false", "-C", directory] + arguments
        do {
            let r = try await runner.run(executable: git, arguments: argv, environment: environment(),
                                         currentDirectory: nil, timeout: timeout)
            if r.timedOut { return .failure("git zaman aşımına uğradı") }
            return .success(r)
        } catch {
            return .failure("git başlatılamadı: \(error)")
        }
    }

    private func listChunked(_ prefix: [String], paths: [String], in directory: String) async -> GitListOutcome {
        guard !paths.isEmpty else { return .paths([]) }
        var all: [String] = []
        var index = 0
        while index < paths.count {
            let chunk = Array(paths[index..<min(index + Self.batchSize, paths.count)])
            index += Self.batchSize
            switch await run(prefix + chunk, in: directory) {
            case .success(let r):
                if r.exitCode == 0 {
                    all.append(contentsOf: Self.splitNUL(r.standardOutput))
                } else {
                    return Self.isNotARepository(r, directory: directory) ? .notARepository : .failed(Self.failureText(r))
                }
            case .failure(let message):
                return .failed(message)
            }
        }
        return .paths(all)
    }

    static func splitNUL(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Exit 128 with git's "not a git repository" text (LC_ALL=C). "dubious ownership", corruption, … are NOT this.
    /// A `.git` entry in `directory` itself means the repository exists but is unusable ⇒ never "no repository".
    static func isNotARepository(_ r: CommandResult, directory: String) -> Bool {
        guard r.exitCode == 128, r.errorString.contains("not a git repository") else { return false }
        return !FileManager.default.fileExists(atPath: directory + "/.git")
    }

    static func failureText(_ r: CommandResult) -> String {
        let text = r.errorString.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git çıkış kodu \(r.exitCode)" : String(text.prefix(300))
    }
}

/// Convenience: the "git says no repository" case collapsed to a flag for rule gating.
extension GitRepoState {
    var repositoryRoot: String? {
        if case .repository(let r) = self { return r }
        return nil
    }
}
