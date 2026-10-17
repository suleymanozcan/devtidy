import Foundation
import Testing
import Darwin
@testable import DevTidyCore

/// Live smoke test (design §9.3). Skipped unless `scripts/smoke.sh` set `DEVTIDY_SMOKE_DIR`.
///
/// It only ever mutates the throwaway project under `DEVTIDY_SMOKE_DIR` and the one `http.server` process the script
/// spawned (`DEVTIDY_SMOKE_PID`). Docker is read-only: the wrapper below aborts on any mutating call.
struct LiveSmokeTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVTIDY_SMOKE_DIR"] != nil))
    func liveServerCleanupAndDockerReadOnly() async throws {
        let env = Self.environment
        let smokeDir = try #require(env["DEVTIDY_SMOKE_DIR"])
        let smokeCase = try #require(env["DEVTIDY_SMOKE_CASE"])
        let port = try #require(env["DEVTIDY_SMOKE_PORT"].flatMap { UInt16($0) })
        let serverPID = try #require(env["DEVTIDY_SMOKE_PID"].flatMap { Int32($0) })
        let scriptPID = try #require(env["DEVTIDY_SMOKE_SCRIPT_PID"].flatMap { Int32($0) })
        #expect(["A", "B"].contains(smokeCase))

        // The throwaway directory must be the one scripts/smoke.sh creates directly under $HOME.
        try #require(smokeDir.hasPrefix(NSHomeDirectory() + "/devtidy-smoke-"))
        let project = URL(fileURLWithPath: smokeDir + "/proj").resolvingSymlinksInPath().path
        let fm = FileManager.default

        // The audit trail goes to a temporary file: the smoke run must not append test lines to the user's real
        // ~/Library/Logs/DevTidy/cleanup.log.
        let auditDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devtidy-smoke-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: auditDirectory) }
        let auditURL = auditDirectory.appendingPathComponent("cleanup.log")
        let services = DevTidyServices.live(socketOverride: { nil }, audit: AuditLog(fileURL: auditURL))

        // a. live scan + classify ⇒ exactly one server for the throwaway project
        _ = await services.scanner.snapshot(.standard)          // primes the CPU baseline
        try await Task.sleep(for: .milliseconds(150))
        let snapshot = await services.scanner.snapshot(.standard)
        let scan = await services.classifier.classify(snapshot)
        let mine = scan.servers.filter { $0.project?.root == project }
        #expect(mine.count == 1)
        let server = try #require(mine.first)

        // Safety gate: abort before ANY mutating call unless this is provably the script's own server.
        try #require(server.members.map(\.pid).contains(serverPID))
        try #require(server.project?.root == project)

        #expect(server.mainPort == port)
        #expect(server.kind == .python)
        #expect(server.groupKillEligible == (smokeCase == "A"))
        let memberPIDs = Set(server.members.map(\.pid))
        for other in scan.servers where other.id != server.id {
            #expect(!memberPIDs.contains(other.root.pid), "another server's root is inside the smoke server's tree")
        }

        // a2. who it is, and what its page says: the identity of the throwaway project and ONE `GET /` to the script's own
        //     loopback `http.server` (never any other server).
        let identity = services.identities.identity(ofProjectAt: project)
        #expect(identity.repoName == "proj")
        #expect(identity.pathInRepo == nil)
        #expect(identity.manifest?.name == "devtidy-smoke")
        #expect(identity.head != nil)
        let titleTarget = try #require(PageTitleTarget.make(for: server))
        #expect(titleTarget.port == port)
        #expect(await services.pageTitles.title(for: titleTarget) == .title("DevTidy Smoke"))

        // b. the catalog offers the cache and nothing else
        let catalogReport = try #require(await services.catalog.report(forProjectAt: project, options: CatalogOptions()))
        #expect(catalogReport.entries.contains { $0.ruleID == "next.cache" && $0.safety == .always })
        let forbidden: Set<String> = ["public", ".env", "src", "node_modules"]
        #expect(catalogReport.entries.allSatisfy { !forbidden.contains($0.displayPath) && !forbidden.contains($0.ruleID) })

        // c. cleaning BEFORE stopping is refused by the live activity checker
        let planBefore = try #require(await services.cleaner.makePlan(forProjectAt: project, options: CatalogOptions()))
        let nextBefore = try #require(planBefore.entries.first { $0.ruleID == "next.cache" })
        let refused = try await services.cleaner.execute(
            planBefore, selections: [CleanupSelection(entryID: nextBefore.id, mode: .permanent)], progress: nil)
        #expect(refused.outcomes.first { $0.entryID == nextBefore.id }?.status == .skipped(.blockedByActivity))
        #expect(fm.fileExists(atPath: project + "/.next"))

        // d. stop the server
        let termination = try await services.terminator.terminate(server, policy: TerminationPolicy())
        print("SMOKE termination terminated=\(termination.terminated) forced=\(termination.forced) survivors=\(termination.survivors) skipped=\(termination.skipped) group=\(termination.usedGroupSignal) gone=\(termination.wasAlreadyGone)")
        #expect(await Self.waitUntilPortClosed(port))
        #expect(await Self.waitUntilGone(serverPID))
        if smokeCase == "A" {
            #expect(termination.usedGroupSignal == true)
        } else {
            #expect(termination.usedGroupSignal == false)
            #expect(Darwin.kill(scriptPID, 0) == 0, "the script must survive an individual-signal stop")
        }

        // e. fresh plan + execute ⇒ only the cache is removed
        let fresh = try #require(await services.cleaner.makePlan(forProjectAt: project, options: CatalogOptions()))
        let nextFresh = try #require(fresh.entries.first { $0.ruleID == "next.cache" })
        let result = try await services.cleaner.execute(
            fresh, selections: [CleanupSelection(entryID: nextFresh.id, mode: .permanent)], progress: nil)
        guard case .deleted? = result.outcomes.first(where: { $0.entryID == nextFresh.id })?.status else {
            Issue.record("expected .deleted, got \(String(describing: result.outcomes))"); return
        }
        #expect(!fm.fileExists(atPath: project + "/.next"))
        for kept in ["src/keep.txt", ".env", "public/logo.txt", "node_modules/dep/index.js", "package.json"] {
            #expect(fm.fileExists(atPath: project + "/" + kept), "\(kept) must be intact")
        }
        let newLines = Self.lines(of: auditURL)
        #expect(newLines.contains { $0.contains("\"kind\":\"cleanup\"") && $0.contains(smokeDir) })
        #expect(newLines.contains { $0.contains("\"kind\":\"terminate\"") && $0.contains(String(serverPID)) })

        // f. (case A only) Docker, read-only
        if smokeCase == "A" {
            let docker = S4SmokeReadOnlyDocker(wrapped: services.docker)
            let first = await docker.snapshot(stats: .refresh)
            try await Task.sleep(for: .seconds(1))
            let second = await docker.snapshot(stats: .refresh)
            print("SMOKE docker status=\(second.status) projects=\(second.projects.count) standalone=\(second.standalone.count) "
                  + "running=\(second.allContainers.filter(\.isRunning).count) statsAt=\(String(describing: second.statsAt)) "
                  + "(first pass: \(first.allContainers.count) containers)")
            switch second.status {
            case .notRunning, .notInstalled:
                #expect(second.allContainers.isEmpty)
            default:
                break
            }
            do {
                let cache = try await docker.buildCacheSummary()
                print("SMOKE docker build cache total=\(cache.totalBytes) reclaimable=\(cache.reclaimableBytes) "
                      + "private=\(cache.privateReclaimableBytes) records=\(cache.recordCount) active=\(cache.activeCount)")
            } catch {
                print("SMOKE docker build cache unavailable: \(error)")
            }
        }
    }

    // MARK: Helpers

    static func lines(of url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// True if something accepts a TCP connection on 127.0.0.1:`port`.
    static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// The kernel stops reporting a process (libproc: "gone") a few milliseconds before it has torn down the sockets of the
    /// exiting process, so a connect right after `terminate` can still succeed. Poll, bounded.
    static func waitUntilPortClosed(_ port: UInt16, seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !canConnect(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !canConnect(port: port)
    }

    /// `kill(pid, 0)` until ESRCH (the process may linger briefly as a zombie).
    static func waitUntilGone(_ pid: Int32, seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Darwin.kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }
}

/// Forwards the two read-only calls and aborts the run on anything that could change Docker state.
struct S4SmokeReadOnlyDocker: DockerControlling {
    let wrapped: any DockerControlling

    func snapshot(stats: StatsRefresh) async -> DockerSnapshot { await wrapped.snapshot(stats: stats) }
    func buildCacheSummary() async throws -> BuildCacheSummary { try await wrapped.buildCacheSummary() }

    func perform(_ action: ContainerAction, on containerID: String) async throws {
        fatalError("smoke test must never mutate Docker (container \(action) on \(containerID))")
    }
    func perform(_ action: ComposeAction, projectName: String) async throws {
        fatalError("smoke test must never mutate Docker (compose \(action) on \(projectName))")
    }
    func pruneBuildCache(_ mode: BuildCachePruneMode) async throws -> BuildCachePruneResult {
        fatalError("smoke test must never mutate Docker (prune \(mode))")
    }
}
