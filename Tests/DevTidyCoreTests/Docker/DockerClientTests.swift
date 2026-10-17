import Foundation
import Testing
@testable import DevTidyCore

/// DockerClient against a fake transport / runner / audit. No request ever reaches a real Docker daemon.
@Suite("DockerClient")
struct DockerClientTests {
    // MARK: Harness

    private struct Harness {
        let daemon: S3FakeDaemon
        let transport: S3FakeTransport
        let runner: S3FakeRunner
        let audit: S3FakeAudit
        let client: DockerClient
    }

    private func makeHarness(locator: S3FakeLocator = S3FakeLocator(), runner: S3FakeRunner = S3FakeRunner()) -> Harness {
        let daemon = S3FakeDaemon()
        let transport = daemon.transport()
        let audit = S3FakeAudit()
        let client = DockerClient(locator: locator, runner: runner, audit: audit, transport: transport, socketOverride: { nil })
        return Harness(daemon: daemon, transport: transport, runner: runner, audit: audit, client: client)
    }

    private let idA = S3Fixtures.idA
    private let idB = S3Fixtures.idB
    private let idC = S3Fixtures.idC

    /// A and B running (standalone), C exited.
    private func standardList(aState: String = "running") -> String {
        S3Fixtures.listJSON([
            .init(id: idA, name: "svc-a", state: aState, status: aState == "running" ? "Up 2 hours" : "Exited (0) 1 hour ago"),
            .init(id: idB, name: "svc-b"),
            .init(id: idC, name: "svc-c", state: "exited", status: "Exited (0) 3 hours ago"),
        ])
    }

    private func primeStats(_ harness: Harness, aTotal: UInt64, bTotal: UInt64, system: UInt64) {
        harness.daemon.update {
            $0.stats[idA] = S3Fixtures.statsJSON(total: aTotal, system: system, usage: 1_000_000, inactiveFile: 200_000)
            $0.stats[idB] = S3Fixtures.statsJSON(total: bTotal, system: system, usage: 50_000_000)
        }
    }

    private func find(_ id: String, in snapshot: DockerSnapshot) throws -> DockerContainer {
        try #require(snapshot.allContainers.first { $0.id == id })
    }

    private func cpu(_ id: String, _ snapshot: DockerSnapshot) throws -> Double {
        try #require(find(id, in: snapshot).cpuPercent)
    }

    private func inspectRequests(_ transport: S3FakeTransport, id: String? = nil) -> [S3Request] {
        transport.requests.filter { request in
            let parts = request.path.split(separator: "/")
            guard request.method == "GET", parts.count == 3, parts[0] == "containers", parts[2] == "json" else { return false }
            return id.map { String(parts[1]) == $0 } ?? true
        }
    }

    private func statsRequests(_ transport: S3FakeTransport) -> [S3Request] {
        transport.requests.filter { $0.path.hasSuffix("/stats") }
    }

    // MARK: Status / listing

    @Test func runningDaemonYieldsEngineInfoAndGroupedContainers() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = S3Fixtures.envListJSON }
        let snapshot = await h.client.snapshot(stats: .reuse)
        #expect(snapshot.status == .running(DockerEngineInfo(version: "29.8.2", apiVersion: "1.56")))
        #expect(snapshot.projects.map(\.name) == ["eticaretsaas-monolith", "rentacar-api", "tunahan"])
        #expect(snapshot.standalone.map(\.name) == ["hindsight"])
        #expect(snapshot.allContainers.count == 6)
        #expect(snapshot.statsAt == nil)
    }

    @Test func listUsesAllAndVersionIsFetchedOnce() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }
        for _ in 0..<3 { _ = await h.client.snapshot(stats: .reuse) }
        let requests = h.transport.requests
        #expect(requests.filter { $0.path == "/containers/json" }.allSatisfy { $0.query == ["all=1"] })
        #expect(requests.filter { $0.path == "/containers/json" }.count == 3)
        #expect(requests.filter { $0.path == "/version" }.count == 1)
    }

    @Test func daemonDownIsNotRunningWithEmptyListsAndClearedCaches() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }
        primeStats(h, aTotal: 1_000_000_000, bTotal: 500_000_000, system: 100_000_000_000)
        _ = await h.client.snapshot(stats: .refresh)
        _ = await h.client.snapshot(stats: .refresh)
        #expect(await h.client.cacheSizes() == DockerClient.CacheSizes(hasEngineInfo: true, startedAt: 2, previousCPU: 2,
                                                                       lastStats: 2, hasStatsDate: true))

        h.daemon.update { $0.down = true }
        let down = await h.client.snapshot(stats: .refresh)
        #expect(down.status == .notRunning)
        #expect(down.projects.isEmpty && down.standalone.isEmpty && down.allContainers.isEmpty)
        #expect(down.statsAt == nil)
        #expect(await h.client.cacheSizes() == DockerClient.CacheSizes(hasEngineInfo: false, startedAt: 0, previousCPU: 0,
                                                                       lastStats: 0, hasStatsDate: false))

        // Coming back: first refresh has no previous sample again.
        h.daemon.update { $0.down = false }
        let back = await h.client.snapshot(stats: .refresh)
        #expect(back.status == .running(DockerEngineInfo(version: "29.8.2", apiVersion: "1.56")))
        #expect(try find(idA, in: back).cpuPercent == nil)
    }

    @Test func noSocketAndNoDockerAtAllIsNotInstalled() async {
        let h = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: false, docker: nil))
        let snapshot = await h.client.snapshot(stats: .refresh)
        #expect(snapshot.status == .notInstalled)
        #expect(snapshot.allContainers.isEmpty)
        #expect(h.transport.requests.isEmpty)
    }

    @Test func noSocketButDockerDesktopOrCLIPresentIsNotRunning() async {
        let desktop = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: true, docker: nil))
        #expect(await desktop.client.snapshot(stats: .reuse).status == .notRunning)
        let cli = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: false,
                                                     docker: URL(fileURLWithPath: "/fake/bin/docker")))
        #expect(await cli.client.snapshot(stats: .reuse).status == .notRunning)
        #expect(desktop.transport.requests.isEmpty && cli.transport.requests.isEmpty)
    }

    @Test func remoteContextIsReportedAsUnsupportedWithoutAnyRequest() async {
        let h = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: true, rejection: "Uzak Docker bağlamı desteklenmiyor"))
        let snapshot = await h.client.snapshot(stats: .refresh)
        #expect(snapshot.status == .unsupported("Uzak Docker bağlamı desteklenmiyor"))
        #expect(h.transport.requests.isEmpty)
    }

    @Test func httpServerErrorIsFailedAndRecovers() async throws {
        let h = makeHarness()
        h.daemon.update {
            $0.listStatus = 500
            $0.listBody = #"{"message":"boom"}"#
        }
        let failed = await h.client.snapshot(stats: .refresh)
        guard case .failed(let message) = failed.status else {
            Issue.record("expected .failed, got \(failed.status)")
            return
        }
        #expect(message.contains("500") && message.contains("boom"))
        #expect(failed.allContainers.isEmpty)

        h.daemon.update {
            $0.listStatus = 200
            $0.listBody = standardList()
        }
        let recovered = await h.client.snapshot(stats: .reuse)
        #expect(recovered.status == .running(DockerEngineInfo(version: "29.8.2", apiVersion: "1.56")))
        #expect(recovered.allContainers.count == 3)
    }

    @Test func undecodableListIsFailed() async {
        let h = makeHarness()
        h.daemon.update { $0.listBody = "this is not json" }
        let snapshot = await h.client.snapshot(stats: .reuse)
        guard case .failed = snapshot.status else {
            Issue.record("expected .failed, got \(snapshot.status)")
            return
        }
    }

    @Test func containersWithUnsafeIdsAreDropped() async {
        let h = makeHarness()
        h.daemon.update {
            $0.listBody = S3Fixtures.listJSON([
                .init(id: idA, name: "ok"),
                .init(id: "../../etc/passwd", name: "evil"),
                .init(id: "ABCDEF012345", name: "uppercase"),
            ])
        }
        let snapshot = await h.client.snapshot(stats: .reuse)
        #expect(snapshot.allContainers.map(\.name) == ["ok"])
        // Nothing was ever addressed by the unsafe ids (inspect only for the valid running container).
        #expect(h.transport.requests.allSatisfy { !$0.path.contains("evil") && !$0.path.contains("..") })
    }

    // MARK: Stats

    @Test func refreshYieldsCPUOnlyOnTheSecondCallAndReuseKeepsIt() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }

        primeStats(h, aTotal: 1_000_000_000, bTotal: 500_000_000, system: 100_000_000_000)
        let first = await h.client.snapshot(stats: .refresh)
        let a1 = try find(idA, in: first)
        #expect(a1.cpuPercent == nil)
        #expect(a1.memoryBytes == 800_000)                    // usage − inactive_file
        #expect(a1.memoryLimitBytes == 6_210_576_384)
        #expect(first.statsAt != nil)
        #expect(try find(idB, in: first).memoryBytes == 50_000_000)

        primeStats(h, aTotal: 1_400_000_000, bTotal: 500_000_000, system: 104_000_000_000)
        let second = await h.client.snapshot(stats: .refresh)
        #expect(abs(try cpu(idA, second) - 40.0) < 1e-9)
        #expect(try find(idB, in: second).cpuPercent == 0)    // genuinely idle
        let statsCallsAfterSecond = statsRequests(h.transport).count
        #expect(statsCallsAfterSecond == 4)                   // 2 running containers × 2 refreshes; the exited one is never sampled

        let reused = await h.client.snapshot(stats: .reuse)
        #expect(abs(try cpu(idA, reused) - 40.0) < 1e-9)
        #expect(try find(idA, in: reused).memoryBytes == 800_000)
        #expect(statsRequests(h.transport).count == statsCallsAfterSecond)      // `.reuse` samples nothing
        #expect(reused.statsAt == second.statsAt)

        // The exited container never carries stats.
        let c = try find(idC, in: second)
        #expect(c.cpuPercent == nil && c.memoryBytes == nil && c.memoryLimitBytes == nil)
        #expect(!statsRequests(h.transport).contains { $0.path.contains(idC) })
    }

    @Test func statsRequestsAreOneShotGETs() async {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }
        primeStats(h, aTotal: 1, bTotal: 1, system: 10)
        _ = await h.client.snapshot(stats: .refresh)
        let stats = statsRequests(h.transport)
        #expect(stats.count == 2)
        #expect(stats.allSatisfy { $0.method == "GET" && $0.query == ["stream=false", "one-shot=true"] })
    }

    @Test func oneContainersStatsFailureKeepsItsOldValues() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }
        primeStats(h, aTotal: 1_000_000_000, bTotal: 500_000_000, system: 100_000_000_000)
        _ = await h.client.snapshot(stats: .refresh)
        primeStats(h, aTotal: 1_400_000_000, bTotal: 500_000_000, system: 104_000_000_000)
        let second = await h.client.snapshot(stats: .refresh)
        #expect(abs(try cpu(idA, second) - 40.0) < 1e-9)

        // Third refresh: A's stats call fails (and would have reported different numbers); B succeeds.
        h.daemon.update {
            $0.failStats = [idA]
            $0.stats[idA] = S3Fixtures.statsJSON(total: 9_000_000_000, system: 108_000_000_000, usage: 9_999_999)
            $0.stats[idB] = S3Fixtures.statsJSON(total: 700_000_000, system: 108_000_000_000, usage: 60_000_000)
        }
        let third = await h.client.snapshot(stats: .refresh)
        let a = try find(idA, in: third)
        #expect(abs(try cpu(idA, third) - 40.0) < 1e-9)       // untouched
        #expect(a.memoryBytes == 800_000)                              // untouched
        let b = try find(idB, in: third)
        #expect(abs(try cpu(idB, third) - 20.0) < 1e-9)       // Δ2e8 / Δ4e9 × 4 × 100
        #expect(b.memoryBytes == 60_000_000)
        #expect(third.statsAt != nil)
    }

    @Test func backToBackRefreshesKeepTheEarlierBaselineAndCPU() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }
        primeStats(h, aTotal: 1_000_000_000, bTotal: 500_000_000, system: 100_000_000_000)
        _ = await h.client.snapshot(stats: .refresh)
        primeStats(h, aTotal: 1_400_000_000, bTotal: 500_000_000, system: 104_000_000_000)
        let second = await h.client.snapshot(stats: .refresh)
        #expect(abs(try cpu(idA, second) - 40.0) < 1e-9)

        // A third refresh lands right behind the second: 1 ms of host CPU on 4 CPUs, far below the minimum window.
        h.daemon.update {
            $0.stats[idA] = S3Fixtures.statsJSON(total: 1_400_500_000, system: 104_001_000_000, usage: 2_000_000, inactiveFile: 200_000)
        }
        let third = await h.client.snapshot(stats: .refresh)
        #expect(abs(try cpu(idA, third) - 40.0) < 1e-9)       // not a spike over a sliver of time
        #expect(try find(idA, in: third).memoryBytes == 1_800_000)     // memory is still refreshed

        // The baseline did not advance: the next refresh is measured against the SECOND sample (Δ4e8 / Δ4e9 × 4 × 100).
        primeStats(h, aTotal: 1_800_000_000, bTotal: 500_000_000, system: 108_000_000_000)
        let fourth = await h.client.snapshot(stats: .refresh)
        #expect(abs(try cpu(idA, fourth) - 40.0) < 1e-9)
    }

    @Test func overlappingSnapshotsRunStrictlyOneAfterAnother() async {
        let daemon = S3FakeDaemon()
        daemon.update {
            $0.listBody = standardList()
            $0.stats[idA] = S3Fixtures.statsJSON(total: 1_000_000_000, system: 100_000_000_000, usage: 1_000_000)
            $0.stats[idB] = S3Fixtures.statsJSON(total: 500_000_000, system: 100_000_000_000, usage: 50_000_000)
        }
        let transport = S3SlowTransport(daemon: daemon)
        let client = DockerClient(locator: S3FakeLocator(), runner: S3FakeRunner(), audit: S3FakeAudit(),
                                  transport: transport, socketOverride: { nil })

        async let first = client.snapshot(stats: .refresh)
        async let second = client.snapshot(stats: .refresh)
        async let third = client.snapshot(stats: .reuse)
        let snapshots = await [first, second, third]

        // Each list request started with nothing else in flight: no snapshot began while another was still running.
        #expect(transport.inFlightAtListStart == [0, 0, 0])
        #expect(snapshots.allSatisfy { $0.allContainers.count == 3 })
    }

    @Test func snapshotsCompleteInTheOrderTheyWereStarted() async {
        // `takenAt` is read when a snapshot starts, from a clock that ticks once per call (no wall clock involved): the
        // order in which the snapshots finish is the order of their `takenAt`.
        let daemon = S3FakeDaemon()
        daemon.update { $0.listBody = standardList() }
        let ticks = S4Locked(0)
        let client = DockerClient(locator: S3FakeLocator(), runner: S3FakeRunner(), audit: S3FakeAudit(),
                                  transport: S3SlowTransport(daemon: daemon), socketOverride: { nil },
                                  clock: { Date(timeIntervalSince1970: Double(ticks.with { value -> Int in value += 1; return value })) })
        let completed = await withTaskGroup(of: Date.self) { group -> [Date] in
            for _ in 0..<4 { group.addTask { await client.snapshot(stats: .reuse).takenAt } }
            var order: [Date] = []
            for await takenAt in group { order.append(takenAt) }
            return order
        }
        #expect(completed.count == 4)
        #expect(completed == completed.sorted())
    }

    @Test func containerThatStopsLosesItsStatsAndStartsOverOnRestart() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }
        primeStats(h, aTotal: 1_000_000_000, bTotal: 500_000_000, system: 100_000_000_000)
        _ = await h.client.snapshot(stats: .refresh)
        primeStats(h, aTotal: 1_400_000_000, bTotal: 500_000_000, system: 104_000_000_000)
        _ = await h.client.snapshot(stats: .refresh)

        h.daemon.update { $0.listBody = standardList(aState: "exited") }
        let stopped = await h.client.snapshot(stats: .reuse)
        let stoppedA = try find(idA, in: stopped)
        #expect(stoppedA.state == .exited && stoppedA.cpuPercent == nil && stoppedA.memoryBytes == nil)

        h.daemon.update { $0.listBody = standardList() }
        primeStats(h, aTotal: 10_000, bTotal: 500_000_000, system: 112_000_000_000)
        let restarted = await h.client.snapshot(stats: .refresh)
        #expect(try find(idA, in: restarted).cpuPercent == nil)       // no previous sample after the restart
    }

    // MARK: startedAt

    @Test func startedAtComesFromInspectAndIsCached() async throws {
        let h = makeHarness()
        h.daemon.update {
            $0.listBody = standardList()
            $0.startedAt[idB] = "2026-10-16T18:00:00Z"
        }
        let first = await h.client.snapshot(stats: .reuse)
        let startedA = try #require(try find(idA, in: first).startedAt)
        #expect(abs(startedA.timeIntervalSince1970 - 1_792_172_110.54781071) < 0.001)
        #expect(try find(idB, in: first).startedAt?.timeIntervalSince1970 == 1_792_173_600)
        #expect(try find(idC, in: first).startedAt == nil)
        #expect(inspectRequests(h.transport).count == 2)              // the exited container is not inspected

        _ = await h.client.snapshot(stats: .reuse)
        #expect(inspectRequests(h.transport).count == 2)              // cached

        // A stops, then runs again: cached under a different state ⇒ inspected again; B stays cached.
        h.daemon.update { $0.listBody = standardList(aState: "exited") }
        _ = await h.client.snapshot(stats: .reuse)
        h.daemon.update { $0.listBody = standardList() }
        _ = await h.client.snapshot(stats: .reuse)
        #expect(inspectRequests(h.transport, id: idA).count == 2)
        #expect(inspectRequests(h.transport, id: idB).count == 1)
    }

    @Test func failedInspectFallsBackToCreatedAndIsRetried() async throws {
        let h = makeHarness()
        h.daemon.update {
            $0.listBody = standardList()
            $0.failInspect = [idB]
        }
        let first = await h.client.snapshot(stats: .reuse)
        let b = try find(idB, in: first)
        #expect(b.startedAt == b.createdAt)
        #expect(b.createdAt.timeIntervalSince1970 == 1_792_172_104)

        h.daemon.update { $0.failInspect = [] }
        let second = await h.client.snapshot(stats: .reuse)
        let restartedB = try #require(try find(idB, in: second).startedAt)
        #expect(abs(restartedB.timeIntervalSince1970 - 1_792_172_110.54781071) < 0.001)
        #expect(inspectRequests(h.transport, id: idB).count == 2)
        #expect(inspectRequests(h.transport, id: idA).count == 1)
    }

    // MARK: X6 — reads are GET-only

    @Test func snapshotAndBuildCacheSummaryIssueOnlyGETs() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = S3Fixtures.envListJSON }
        for id in [S3Fixtures.nginxID, S3Fixtures.hindsightID, S3Fixtures.e2eQueueID, S3Fixtures.phpID] {
            h.daemon.update { $0.stats[id] = S3Fixtures.statsJSON(total: 10, system: 100) }
        }
        _ = await h.client.snapshot(stats: .refresh)
        _ = await h.client.snapshot(stats: .refresh)
        _ = await h.client.snapshot(stats: .reuse)
        _ = try await h.client.buildCacheSummary()
        #expect(!h.transport.requests.isEmpty)
        #expect(h.transport.requests.allSatisfy { $0.method == "GET" })
        #expect(await h.audit.events.isEmpty)                          // reads are not audited
        #expect(h.runner.calls.isEmpty)
    }

    // MARK: X1 / X3 — container actions

    @Test func startIsAPostWithoutQuery() async throws {
        let h = makeHarness()
        try await h.client.perform(.start, on: idA)
        #expect(h.transport.requests == [S3Request(method: "POST", path: "/containers/\(idA)/start", query: [])])
    }

    @Test func stopIsAPostWithTenSecondGracePeriod() async throws {
        let h = makeHarness()
        try await h.client.perform(.stop, on: idA)
        #expect(h.transport.requests == [S3Request(method: "POST", path: "/containers/\(idA)/stop", query: ["t=10"])])
    }

    @Test func removeNeverForcesAndNeverRemovesVolumes() async throws {
        let h = makeHarness()
        try await h.client.perform(.remove, on: idC)
        #expect(h.transport.requests == [S3Request(method: "DELETE", path: "/containers/\(idC)", query: ["force=false", "v=false"])])
    }

    @Test func shortAndFullIdsAreBothAccepted() async throws {
        let h = makeHarness()
        try await h.client.perform(.stop, on: String(idA.prefix(12)))
        try await h.client.perform(.stop, on: idA)
        #expect(h.transport.requests.count == 2)
    }

    @Test func notModifiedCountsAsSuccessForStartAndStop() async throws {
        let h = makeHarness()
        h.daemon.update { $0.actionStatus = 304 }
        try await h.client.perform(.start, on: idA)
        try await h.client.perform(.stop, on: idA)
    }

    @Test func removingAMissingContainerIsSuccessButConflictIsAnError() async throws {
        let h = makeHarness()
        h.daemon.update { $0.actionStatus = 404 }
        try await h.client.perform(.remove, on: idC)

        h.daemon.update {
            $0.actionStatus = 409
            $0.actionBody = #"{"message":"cannot remove a running container"}"#
        }
        let error = await s3Error { try await h.client.perform(.remove, on: idA) }
        #expect(s3IsHTTP(error, status: 409))
        // 404 is only idempotent for remove: a stop of a missing container is an error.
        h.daemon.update { $0.actionStatus = 404 }
        #expect(s3IsHTTP(await s3Error { try await h.client.perform(.stop, on: idA) }, status: 404))
    }

    @Test func serverErrorOnStopSurfacesAsHTTPError() async {
        let h = makeHarness()
        h.daemon.update {
            $0.actionStatus = 500
            $0.actionBody = #"{"message":"driver failed"}"#
        }
        let error = await s3Error { try await h.client.perform(.stop, on: idA) }
        #expect(error as? DockerError == .http(status: 500, body: "driver failed"))      // the daemon's message, not the raw JSON
    }

    @Test(arguments: ["", "abc", "ABCDEF012345", "abcdef01234g", "abcdef01234", " abcdef012345", "abcdef012345\n",
                      "abcdef012345/stop", "../../etc/passwd", "abcdef012345?force=true", "sha256:abcdef012345",
                      String(repeating: "a", count: 65)])
    func invalidContainerIdsNeverReachTheTransport(id: String) async {
        let h = makeHarness()
        for action in [ContainerAction.start, .stop, .remove] {
            let error = await s3Error { try await h.client.perform(action, on: id) }
            #expect(s3IsInvalidArgument(error))
        }
        #expect(h.transport.requests.isEmpty)
        #expect(await h.audit.events.isEmpty)
    }

    @Test func containerActionInvalidatesCachesForThatContainer() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = standardList() }
        primeStats(h, aTotal: 1_000_000_000, bTotal: 500_000_000, system: 100_000_000_000)
        _ = await h.client.snapshot(stats: .refresh)
        #expect(await h.client.cacheSizes().startedAt == 2)
        try await h.client.perform(.stop, on: idA)
        let sizes = await h.client.cacheSizes()
        #expect(sizes.startedAt == 1 && sizes.previousCPU == 1 && sizes.lastStats == 1)
    }

    @Test func containerActionsWithoutASocketFail() async {
        let missing = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: false, docker: nil))
        let notInstalledError = await s3Error { try await missing.client.perform(.stop, on: idA) }
        #expect(notInstalledError as? DockerError == .notInstalled)
        let down = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: true, docker: nil))
        let downError = await s3Error { try await down.client.perform(.stop, on: idA) }
        #expect(s3IsDaemonUnavailable(downError))
        #expect(missing.transport.requests.isEmpty && down.transport.requests.isEmpty)
    }

    // MARK: X2 / X4 — compose

    @Test func composeDownRunsExactlyTheExpectedArgv() async throws {
        let h = makeHarness()
        try await h.client.perform(.down, projectName: "tunahan")
        let call = try #require(h.runner.calls.first)
        #expect(h.runner.calls.count == 1)
        #expect(call.arguments == ["compose", "-p", "tunahan", "down"])
        #expect(call.executable == URL(fileURLWithPath: "/fake/bin/docker"))
        #expect(call.environment["LC_ALL"] == "C")
        #expect(call.environment["HOME"] == "/fake/home")
        #expect(call.environment["DOCKER_HOST"] == "unix:///fake/docker.sock")
        #expect(call.timeout == 120)
        #expect(call.currentDirectory == URL(fileURLWithPath: "/"))
        // X4: nothing that widens the blast radius.
        #expect(!call.arguments.contains { $0.hasPrefix("-") && $0 != "-p" })
        #expect(h.transport.requests.isEmpty)
    }

    @Test func composeStopRunsExactlyTheExpectedArgv() async throws {
        let h = makeHarness()
        try await h.client.perform(.stop, projectName: "rentacar-api")
        #expect(h.runner.calls.map(\.arguments) == [["compose", "-p", "rentacar-api", "stop"]])
    }

    @Test(arguments: ["", "-evil", "--help", "-f", "a b", "a;rm -rf /", "a$(id)", "a`id`", "../x", "a/b", "_x", ".x", "a\nb", "ä", "a|b", "a&b"])
    func invalidProjectNamesSpawnNothing(name: String) async {
        let h = makeHarness()
        for action in [ComposeAction.stop, .down] {
            let error = await s3Error { try await h.client.perform(action, projectName: name) }
            #expect(s3IsInvalidArgument(error))
        }
        #expect(h.runner.calls.isEmpty)
        #expect(await h.audit.events.isEmpty)
    }

    @Test(arguments: ["tunahan", "rentacar-api", "eticaretsaas-monolith", "A1", "a_b", "a.b", "0abc", "x"])
    func validProjectNamesAreAccepted(name: String) async throws {
        let h = makeHarness()
        try await h.client.perform(.stop, projectName: name)
        #expect(h.runner.calls.first?.arguments == ["compose", "-p", name, "stop"])
    }

    @Test func composeFailureSurfacesStderrVerbatim() async {
        let runner = S3FakeRunner(.result(S3FakeRunner.failure(code: 1, stderr: "no configuration file provided: not found\n")))
        let h = makeHarness(runner: runner)
        let error = await s3Error { try await h.client.perform(.down, projectName: "tunahan") }
        #expect(error as? DockerError == .commandFailed(exitCode: 1, stderr: "no configuration file provided: not found\n"))
        let events = await h.audit.events
        #expect(events.count == 1 && events[0].result.hasPrefix("failed:"))
    }

    @Test func aHugeComposeFailureIsBoundedInTheErrorAndInTheAuditLog() async {
        // N-8: a compose plugin that prints pages of text must not become a multi-megabyte audit line. Two-byte characters make
        // the cut fall inside a character unless it is made on a boundary.
        let huge = String(repeating: "é", count: 50_000)               // 100 000 bytes
        let runner = S3FakeRunner(.result(S3FakeRunner.failure(code: 1, stderr: huge)))
        let h = makeHarness(runner: runner)
        let error = await s3Error { try await h.client.perform(.down, projectName: "tunahan") }

        guard case .commandFailed(let code, let stderr)? = error as? DockerError else {
            Issue.record("expected commandFailed, got \(String(describing: error))")
            return
        }
        #expect(code == 1)
        #expect(stderr.utf8.count == ComposeCLI.stderrLimit)
        #expect(stderr.hasPrefix("ééé") && !stderr.contains("\u{FFFD}"))

        let events = await h.audit.events
        #expect(events.count == 1)
        let result = events[0].result
        #expect(result.hasPrefix("failed:docker çıkış kodu 1: ééé"))
        #expect(result.utf8.count <= DockerClient.auditResultLimit)
        #expect(result.hasSuffix("…") && !result.contains("\u{FFFD}"))
    }

    @Test func auditTextShorterThanTheLimitIsKeptVerbatim() {
        #expect(DockerClient.boundedForAudit("failed:Docker HTTP 409: conflict") == "failed:Docker HTTP 409: conflict")
        let exact = String(repeating: "a", count: DockerClient.auditResultLimit)
        #expect(DockerClient.boundedForAudit(exact) == exact)
        let over = exact + "a"
        #expect(DockerClient.boundedForAudit(over).utf8.count == DockerClient.auditResultLimit)
        #expect(DockerClient.boundedForAudit(over).hasSuffix("…"))
    }

    @Test func composeTimeoutAndLaunchFailureAreTyped() async {
        let timedOut = makeHarness(runner: S3FakeRunner(.result(S3FakeRunner.failure(code: 15, stderr: "", timedOut: true))))
        let timeoutError = await s3Error { try await timedOut.client.perform(.stop, projectName: "p") }
        #expect(timeoutError as? DockerError == .timeout)
        let launch = makeHarness(runner: S3FakeRunner(.launchFailure("posix_spawn failed")))
        let launchError = await s3Error { try await launch.client.perform(.stop, projectName: "p") }
        #expect(launchError as? DockerError == .commandFailed(exitCode: -1, stderr: "posix_spawn failed"))
    }

    @Test func composeWithoutDockerCLIIsNotInstalledAndSpawnsNothing() async {
        let h = makeHarness(locator: S3FakeLocator(socket: "/fake/docker.sock", desktopInstalled: false, docker: nil))
        let error = await s3Error { try await h.client.perform(.down, projectName: "tunahan") }
        #expect(error as? DockerError == .notInstalled)
        #expect(h.runner.calls.isEmpty)
    }

    // MARK: F-1 — compose only ever runs against a validated local socket

    @Test func composeIsRefusedOnARejectedRemoteSocketWithZeroSpawns() async {
        let h = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: true, rejection: "Uzak Docker bağlamı desteklenmiyor"))
        for action in [ComposeAction.stop, .down] {
            let error = await s3Error { try await h.client.perform(action, projectName: "tunahan") }
            #expect(error as? DockerError == .daemonUnavailable("Uzak Docker bağlamı desteklenmiyor"))
        }
        #expect(h.runner.calls.isEmpty)
        #expect(h.transport.requests.isEmpty)
        let events = await h.audit.events
        #expect(events.count == 2 && events.allSatisfy { $0.kind == .dockerCompose && $0.result.hasPrefix("failed:") })
    }

    @Test func composeWithoutAnyLocalSocketIsRefusedWithZeroSpawns() async {
        let desktopOnly = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: true))
        let cliOnly = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: false))
        let nothing = makeHarness(locator: S3FakeLocator(socket: nil, desktopInstalled: false, docker: nil))

        let desktopError = await s3Error { try await desktopOnly.client.perform(.stop, projectName: "tunahan") }
        let cliError = await s3Error { try await cliOnly.client.perform(.down, projectName: "tunahan") }
        let nothingError = await s3Error { try await nothing.client.perform(.down, projectName: "tunahan") }
        #expect(s3IsDaemonUnavailable(desktopError))
        #expect(s3IsDaemonUnavailable(cliError))
        #expect(nothingError as? DockerError == .notInstalled)
        #expect(desktopOnly.runner.calls.isEmpty && cliOnly.runner.calls.isEmpty && nothing.runner.calls.isEmpty)
    }

    @Test func composeArmedBeforeAContextSwitchIsRefusedAtRunTime() async throws {
        let locator = S3SwitchableLocator()
        let runner = S3FakeRunner()
        let client = DockerClient(locator: locator, runner: runner, audit: S3FakeAudit(),
                                  transport: S3FakeDaemon().transport(), socketOverride: { nil })

        try await client.perform(.down, projectName: "tunahan")
        #expect(runner.calls.count == 1)

        // `docker context use prod-ssh` in a terminal while the confirmation card is still open.
        locator.rejectWithRemoteContext("Uzak Docker bağlamı desteklenmiyor")
        let error = await s3Error { try await client.perform(.down, projectName: "tunahan") }
        #expect(error as? DockerError == .daemonUnavailable("Uzak Docker bağlamı desteklenmiyor"))
        #expect(runner.calls.count == 1)        // nothing was spawned the second time
    }

    @Test func composeAlwaysCarriesDockerHostOfTheResolvedSocket() async throws {
        let h = makeHarness(locator: S3FakeLocator(socket: "/tmp/other/docker.sock"))
        for action in [ComposeAction.stop, .down] { try await h.client.perform(action, projectName: "p") }
        #expect(h.runner.calls.map { $0.environment["DOCKER_HOST"] } == Array(repeating: "unix:///tmp/other/docker.sock", count: 2))
    }

    // MARK: X5 — build cache

    @Test func pruneOlderThanSendsAllAndTheUntilFilter() async throws {
        let h = makeHarness()
        h.daemon.update { $0.pruneBody = #"{"CachesDeleted":["a","b"],"SpaceReclaimed":1645000000}"# }
        let result = try await h.client.pruneBuildCache(.olderThan(hours: 168))
        #expect(result == BuildCachePruneResult(reclaimedBytes: 1_645_000_000))
        #expect(h.transport.requests == [S3Request(method: "POST", path: "/build/prune", query: ["all=1", #"filters={"until":["168h"]}"#])])
    }

    @Test func pruneAllUnusedSendsOnlyAll() async throws {
        let h = makeHarness()
        let result = try await h.client.pruneBuildCache(.allUnused)
        #expect(result == BuildCachePruneResult(reclaimedBytes: 0))
        #expect(h.transport.requests == [S3Request(method: "POST", path: "/build/prune", query: ["all=1"])])
    }

    @Test func pruneNeverAddressesAnythingButBuildPrune() async throws {
        let h = makeHarness()
        _ = try await h.client.pruneBuildCache(.allUnused)
        _ = try await h.client.pruneBuildCache(.olderThan(hours: 24))
        #expect(h.transport.requests.allSatisfy { $0.method == "POST" && $0.path == "/build/prune" })
        #expect(h.transport.requests.count == 2)
    }

    /// Replaces the former grep over the Docker sources: whatever the whole public surface of the client sends over the wire
    /// must be one of these shapes — no image/volume/container/system prune, no force, no volumes, no other verb.
    @Test func everyRequestOfTheWholeClientSurfaceMatchesTheAllowlist() async throws {
        let h = makeHarness()
        h.daemon.update { $0.listBody = S3Fixtures.envListJSON }
        for id in [S3Fixtures.nginxID, S3Fixtures.hindsightID, S3Fixtures.e2eQueueID, S3Fixtures.phpID] {
            h.daemon.update { $0.stats[id] = S3Fixtures.statsJSON(total: 10, system: 100) }
        }
        _ = await h.client.snapshot(stats: .refresh)
        _ = await h.client.snapshot(stats: .reuse)
        _ = try await h.client.buildCacheSummary()
        for action in [ContainerAction.start, .stop, .remove] { try await h.client.perform(action, on: idA) }
        for action in [ComposeAction.stop, .down] { try await h.client.perform(action, projectName: "tunahan") }
        _ = try await h.client.pruneBuildCache(.allUnused)
        _ = try await h.client.pruneBuildCache(.olderThan(hours: 24))

        func shape(_ request: S3Request) -> String {
            let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let generic = parts.enumerated().map { index, part in index == 1 && parts.first == "containers" && part != "json" ? "<id>" : part }
            return ([request.method, "/" + generic.joined(separator: "/")] + request.query).joined(separator: " ")
        }
        let allowed: Set<String> = [
            "GET /containers/json all=1", "GET /version", "GET /containers/<id>/json", "GET /containers/<id>/stats stream=false one-shot=true",
            "GET /system/df type=build-cache",
            "POST /containers/<id>/start", "POST /containers/<id>/stop t=10", "DELETE /containers/<id> force=false v=false",
            "POST /build/prune all=1", #"POST /build/prune all=1 filters={"until":["24h"]}"#,
        ]
        let seen = Set(h.transport.requests.map(shape))
        #expect(seen.subtracting(allowed).isEmpty, "unexpected requests: \(seen.subtracting(allowed).sorted())")
        #expect(!seen.contains { $0.contains("prune") && !$0.contains("/build/prune") })
        // The CLI is used for compose stop/down only, with no flag that widens the blast radius (X4).
        #expect(h.runner.calls.map(\.arguments) == [["compose", "-p", "tunahan", "stop"], ["compose", "-p", "tunahan", "down"]])
    }

    @Test(arguments: [0, -1, -168, 87_601, Int.max])
    func pruneRejectsNonsensicalAges(hours: Int) async {
        let h = makeHarness()
        let error = await s3Error { _ = try await h.client.pruneBuildCache(.olderThan(hours: hours)) }
        #expect(s3IsInvalidArgument(error))
        #expect(h.transport.requests.isEmpty)
        #expect(await h.audit.events.isEmpty)
    }

    @Test func unreadablePruneReportDoesNotTurnASuccessfulPruneIntoAnError() async throws {
        let h = makeHarness()
        h.daemon.update { $0.pruneBody = "" }
        let result = try await h.client.pruneBuildCache(.allUnused)
        #expect(result.reclaimedBytes == 0)
        #expect(await h.audit.events.map(\.result) == ["ok"])
    }

    @Test func pruneServerErrorIsTypedAndAudited() async {
        let failing = S3FakeTransport { _ in S3Fixtures.response(500, #"{"message":"prune failed"}"#) }
        let audit = S3FakeAudit()
        let client = DockerClient(locator: S3FakeLocator(), runner: S3FakeRunner(), audit: audit, transport: failing, socketOverride: { nil })
        let error = await s3Error { _ = try await client.pruneBuildCache(.allUnused) }
        #expect(s3IsHTTP(error, status: 500))
        let events = await audit.events
        #expect(events.count == 1 && events[0].kind == .dockerPrune && events[0].result.hasPrefix("failed:"))
    }

    @Test func buildCacheSummaryReadsSystemDfBuildCache() async throws {
        let h = makeHarness()
        h.daemon.update {
            $0.dfBody = #"""
            {"LayersSize":13629683333,"BuildCache":[
              {"ID":"a","Size":1000,"InUse":false,"Shared":false},
              {"ID":"b","Size":2000,"InUse":false,"Shared":true},
              {"ID":"c","Size":4000,"InUse":true,"Shared":false}]}
            """#
        }
        let summary = try await h.client.buildCacheSummary()
        #expect(summary.totalBytes == 7_000 && summary.reclaimableBytes == 3_000 && summary.privateReclaimableBytes == 1_000)
        #expect(summary.recordCount == 3 && summary.activeCount == 1)
        #expect(h.transport.requests == [S3Request(method: "GET", path: "/system/df", query: ["type=build-cache"])])
    }

    @Test func buildCacheSummaryErrors() async {
        let down = makeHarness()
        down.daemon.update { $0.down = true }
        #expect(s3IsDaemonUnavailable(await s3Error { _ = try await down.client.buildCacheSummary() }))

        let garbage = makeHarness()
        garbage.daemon.update { $0.dfBody = "<html>" }
        let decoding = await s3Error { _ = try await garbage.client.buildCacheSummary() }
        guard case .decoding? = decoding as? DockerError else {
            Issue.record("expected .decoding, got \(String(describing: decoding))")
            return
        }
    }

    // MARK: Audit

    @Test func everyMutatingCallWritesExactlyOneAuditEvent() async throws {
        let h = makeHarness()
        try await h.client.perform(.stop, on: idA)
        try await h.client.perform(.start, on: idA)
        try await h.client.perform(.remove, on: idC)
        try await h.client.perform(.down, projectName: "tunahan")
        try await h.client.perform(.stop, projectName: "rentacar-api")
        _ = try await h.client.pruneBuildCache(.olderThan(hours: 168))

        let events = await h.audit.events
        #expect(events.map(\.kind) == [.dockerContainer, .dockerContainer, .dockerContainer, .dockerCompose, .dockerCompose, .dockerPrune])
        #expect(events.map(\.subject) == [idA, idA, idC, "tunahan", "rentacar-api", "build-cache"])
        #expect(events.allSatisfy { $0.result == "ok" })
        #expect(events[0].detail["action"] == "stop")
        #expect(events[2].detail["action"] == "remove")
        #expect(events[3].detail["action"] == "down")
        #expect(events[5].detail["mode"] == "olderThan:168h")
    }

    @Test func failedMutationsAreAuditedAsFailures() async {
        let h = makeHarness()
        h.daemon.update { $0.actionStatus = 409 }
        _ = await s3Error { try await h.client.perform(.remove, on: idA) }
        let events = await h.audit.events
        #expect(events.count == 1)
        #expect(events[0].kind == .dockerContainer && events[0].subject == idA)
        #expect(events[0].result.hasPrefix("failed:"))
    }

    // MARK: Real transport, test-owned sockets only

    @Test func daemonDownWithRealTransportIsNotRunning() async throws {
        let directory = try S3Temp.makeDirectory()
        defer { S3Temp.remove(directory) }
        let client = DockerClient(locator: S3FakeLocator(socket: directory + "/missing.sock"), runner: S3FakeRunner(),
                                  audit: S3FakeAudit(), socketOverride: { nil })
        let snapshot = await client.snapshot(stats: .refresh)
        #expect(snapshot.status == .notRunning)      // connect(2) failed: the list budget (Timeouts.list) did not run out
        #expect(snapshot.allContainers.isEmpty)
    }

    @Test func staleSocketWithRealTransportIsNotRunning() async throws {
        let directory = try S3Temp.makeDirectory()
        defer { S3Temp.remove(directory) }
        let path = directory + "/stale.sock"
        try S3Sockets.makeSocketFile(at: path)
        let client = DockerClient(locator: S3FakeLocator(socket: path), runner: S3FakeRunner(), audit: S3FakeAudit(), socketOverride: { nil })
        #expect(await client.snapshot(stats: .reuse).status == .notRunning)
    }

    @Test func snapshotEndToEndOverATestOwnedSocket() async throws {
        let list = S3Fixtures.listJSON([.init(id: S3Fixtures.idA, name: "svc-a")])
        let server = try S3UnixSocketServer(.respond(gapMilliseconds: 0) { request in
            func http(_ status: String, _ body: String) -> [Data] {
                [Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)]
            }
            if request.hasPrefix("GET /containers/json?all=1 ") { return http("200 OK", list) }
            if request.hasPrefix("GET /version ") { return http("200 OK", #"{"Version":"29.8.2","ApiVersion":"1.56"}"#) }
            if request.contains("/json HTTP/1.1") { return http("200 OK", #"{"State":{"StartedAt":"2026-10-16T17:35:10.54781071Z"}}"#) }
            return http("404 Not Found", #"{"message":"unexpected"}"#)
        })
        defer { server.stop() }

        let client = DockerClient(locator: S3FakeLocator(socket: server.path), runner: S3FakeRunner(), audit: S3FakeAudit(), socketOverride: { nil })
        let snapshot = await client.snapshot(stats: .reuse)
        #expect(snapshot.status == .running(DockerEngineInfo(version: "29.8.2", apiVersion: "1.56")))
        let container = try #require(snapshot.standalone.first)
        #expect(container.name == "svc-a")
        let started = try #require(container.startedAt)
        #expect(abs(started.timeIntervalSince1970 - 1_792_172_110.54781071) < 0.001)
        // list, version, inspect: reads only.
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.hasPrefix("GET ") })
    }
}
