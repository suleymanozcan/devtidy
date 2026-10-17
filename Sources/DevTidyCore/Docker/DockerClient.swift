import Foundation
import os

// Per-call budgets (design §3.3).
private enum Timeouts {
    static let list: TimeInterval = 3
    static let version: TimeInterval = 2
    static let stats: TimeInterval = 3
    static let inspect: TimeInterval = 2
    static let start: TimeInterval = 10
    static let stop: TimeInterval = 25      // `t=10` grace period + 15 s
    static let remove: TimeInterval = 10
    static let df: TimeInterval = 8
    static let prune: TimeInterval = 300
}

private let engineConcurrency = 4

// MARK: - Validation (X1, X2) ----------------------------------------------------------------------------------------

enum DockerValidation {
    /// X1: `^[0-9a-f]{12,64}$`, checked before any request is built.
    static func isValidContainerID(_ id: String) -> Bool {
        let bytes = id.utf8
        guard (12...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// X2: `^[A-Za-z0-9][A-Za-z0-9_.-]*$`, checked before any process is spawned.
    static func isValidProjectName(_ name: String) -> Bool {
        guard let first = name.utf8.first, isAlphanumeric(first) else { return false }
        return name.utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x5F || $0 == 0x2E || $0 == 0x2D }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}

// MARK: - Bounded concurrency ----------------------------------------------------------------------------------------

/// Runs `body` over `inputs` with at most `limit` in flight; results arrive in completion order.
private func dockerBoundedMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], limit: Int, _ body: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    var results: [Output] = []
    results.reserveCapacity(inputs.count)
    await withTaskGroup(of: Output.self) { group in
        var iterator = inputs.makeIterator()
        var started = 0
        while started < limit, let next = iterator.next() {
            group.addTask { await body(next) }
            started += 1
        }
        while let result = await group.next() {
            results.append(result)
            if let next = iterator.next() {
                group.addTask { await body(next) }
            }
        }
    }
    return results
}

// MARK: - Client -----------------------------------------------------------------------------------------------------

/// Docker control plane. Reads, per-container actions and build-cache measure/prune go through the Engine API over the unix
/// socket; `docker compose stop|down` is the only CLI use (`ComposeCLI`).
///
/// Invariants (design §9.2): X1 container ids validated before any request · X2 compose project names validated before any
/// spawn · X3 `remove` is `force=false&v=false` · X4 compose `down` carries no destructive flags · X5 the only prune call is
/// `POST /build/prune` · X6 `snapshot` and `buildCacheSummary` are GET-only. Every path that talks to a daemon (API or compose)
/// first resolves the socket through `requireSocket()`; compose additionally pins the CLI to that socket via `DOCKER_HOST`.
public actor DockerClient: DockerControlling {
    private struct StartedAtEntry {
        let state: ContainerState
        let date: Date?
    }

    /// Test visibility into the caches (daemon-down must clear them).
    struct CacheSizes: Equatable {
        let hasEngineInfo: Bool
        let startedAt: Int
        let previousCPU: Int
        let lastStats: Int
        let hasStatsDate: Bool
    }

    private static let log = Logger(subsystem: "dev.minata.DevTidy", category: "docker")

    private let locator: any ToolLocating
    private let audit: any AuditLogging
    private let compose: ComposeCLI
    private let socketOverride: @Sendable () -> String?
    private let transportFactory: @Sendable (String) -> any DockerHTTPTransport

    private var info: DockerEngineInfo?
    private var startedAtCache: [String: StartedAtEntry] = [:]
    private var previousCPU: [String: DockerCPUCounters] = [:]
    private var lastStats: [String: DockerContainerStats] = [:]
    private var statsAt: Date?
    /// Wall clock for `takenAt` / `statsAt`. Informational only: `DevTidyStore` orders snapshots by the sequence in which it
    /// issued the calls, never by these dates.
    private let clock: @Sendable () -> Date

    /// `snapshot` is single-flight and FIFO: an actor interleaves at every `await`, so two overlapping snapshots would apply
    /// stats samples against each other's counters (noisy CPU) and a slow, older list could finish after a newer one. The
    /// slot is handed to waiters in call order, so completion order equals start order.
    private var snapshotBusy = false
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []

    public init(locator: any ToolLocating, runner: any CommandRunning, audit: any AuditLogging,
                socketOverride: @escaping @Sendable () -> String?) {
        self.init(locator: locator, runner: runner, audit: audit, socketOverride: socketOverride,
                  transportFactory: { UnixSocketHTTP(socketPath: $0) })
    }

    /// Test seam: every request goes through `transport` regardless of the resolved socket path; `clock` is the wall clock.
    init(locator: any ToolLocating, runner: any CommandRunning, audit: any AuditLogging,
         transport: any DockerHTTPTransport, socketOverride: @escaping @Sendable () -> String?,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(locator: locator, runner: runner, audit: audit, socketOverride: socketOverride,
                  transportFactory: { _ in transport }, clock: clock)
    }

    private init(locator: any ToolLocating, runner: any CommandRunning, audit: any AuditLogging,
                 socketOverride: @escaping @Sendable () -> String?,
                 transportFactory: @escaping @Sendable (String) -> any DockerHTTPTransport,
                 clock: @escaping @Sendable () -> Date = { Date() }) {
        self.locator = locator
        self.audit = audit
        self.compose = ComposeCLI(runner: runner, locator: locator)
        self.socketOverride = socketOverride
        self.transportFactory = transportFactory
        self.clock = clock
    }

    func cacheSizes() -> CacheSizes {
        CacheSizes(hasEngineInfo: info != nil, startedAt: startedAtCache.count, previousCPU: previousCPU.count,
                   lastStats: lastStats.count, hasStatsDate: statsAt != nil)
    }

    private func acquireSnapshotSlot() async {
        if !snapshotBusy {
            snapshotBusy = true
            return
        }
        await withCheckedContinuation { snapshotWaiters.append($0) }
    }

    private func releaseSnapshotSlot() {
        if snapshotWaiters.isEmpty {
            snapshotBusy = false
        } else {
            snapshotWaiters.removeFirst().resume()      // the slot stays busy and passes to the next caller
        }
    }

    // MARK: Snapshot

    public func snapshot(stats: StatsRefresh) async -> DockerSnapshot {
        await acquireSnapshotSlot()
        defer { releaseSnapshotSlot() }
        return await takeSnapshot(stats: stats)
    }

    private func takeSnapshot(stats: StatsRefresh) async -> DockerSnapshot {
        // A caller cancelled while it queued behind another snapshot must not start a round of requests.
        if Task.isCancelled { return .unknown }
        let takenAt = clock()

        let socket: String
        switch lookupSocket() {
        case .found(let path):
            socket = path
        case .unavailable(let status):
            resetCaches()
            return DockerSnapshot(status: status, projects: [], standalone: [], takenAt: takenAt, statsAt: nil)
        }
        let transport = transportFactory(socket)

        // 1. List (GET only, X6).
        let summaries: [WireContainerSummary]
        do {
            let response = try await transport.request(method: "GET", path: "/containers/json",
                                                       query: [URLQueryItem(name: "all", value: "1")], timeout: Timeouts.list)
            try Self.requireSuccess(response)
            summaries = try Self.decode([WireContainerSummary].self, from: response.body)
        } catch {
            return failedSnapshot(error, takenAt: takenAt)
        }

        let engine = await engineInfo(transport)

        // Containers whose id cannot be acted on safely are dropped (X1 applies to everything we later address by id).
        let wires = summaries.filter { $0.id.map(DockerValidation.isValidContainerID) ?? false }
        let runningIDs = wires.compactMap { wire -> String? in
            DockerMapping.state(wire.state) == .running ? wire.id : nil
        }
        let runningSet = Set(runningIDs)
        startedAtCache = startedAtCache.filter { runningSet.contains($0.key) }
        previousCPU = previousCPU.filter { runningSet.contains($0.key) }
        lastStats = lastStats.filter { runningSet.contains($0.key) }

        // 2. StartedAt via inspect, only for running containers not cached under `.running` yet.
        let needsInspect = runningIDs.filter { startedAtCache[$0]?.state != .running }
        if !needsInspect.isEmpty {
            let inspected = await dockerBoundedMap(needsInspect, limit: engineConcurrency) { (id: String) async -> (String, Date?) in
                let date = await DockerClient.fetchStartedAt(transport, id: id)
                return (id, date)
            }
            for (id, date) in inspected {
                // A failed inspect is not cached: it is retried next tick and `Created` is used meanwhile.
                if let date { startedAtCache[id] = StartedAtEntry(state: .running, date: date) }
            }
        }

        // 3. One-shot stats on `.refresh`; CPU% = diff against the previous poll's counters.
        if stats == .refresh, !runningIDs.isEmpty {
            let samples = await dockerBoundedMap(runningIDs, limit: engineConcurrency) { (id: String) async -> (String, StatsSample?) in
                let sample = await DockerClient.fetchStats(transport, id: id)
                return (id, sample)
            }
            var anySucceeded = false
            for (id, sample) in samples {
                guard let sample else { continue }      // failure: the container keeps its previous values
                anySucceeded = true
                if DockerStatsCalculator.isWindowTooShort(previous: previousCPU[id], current: sample) {
                    // Two refreshes back to back (a tick right after a popover-open poke): the delta would span a sliver of
                    // host CPU time and give a spiky percentage. Keep the older baseline and CPU%, refresh memory only.
                    lastStats[id] = DockerContainerStats(cpuPercent: lastStats[id]?.cpuPercent,
                                                         memoryBytes: DockerStatsCalculator.memoryBytes(sample),
                                                         memoryLimitBytes: sample.memoryLimit)
                    continue
                }
                lastStats[id] = DockerStatsCalculator.stats(previous: previousCPU[id], current: sample)
                if let counters = sample.counters { previousCPU[id] = counters }
            }
            if anySucceeded { statsAt = clock() }
        }

        // 4. Map + group. `lastStats` is merged for both `.reuse` and `.refresh`, so list ticks never blank the CPU column.
        let containers = wires.compactMap { wire -> DockerContainer? in
            guard let id = wire.id else { return nil }
            return DockerMapping.container(from: wire, startedAt: startedAtCache[id]?.date, stats: lastStats[id])
        }
        let grouped = DockerGrouping.group(containers)
        return DockerSnapshot(status: .running(engine), projects: grouped.projects, standalone: grouped.standalone,
                              takenAt: takenAt, statsAt: statsAt)
    }

    private func failedSnapshot(_ error: any Error, takenAt: Date) -> DockerSnapshot {
        if error is CancellationError { return .unknown }
        info = nil
        if Self.isDaemonUnavailable(error) {
            resetCaches()
            return DockerSnapshot(status: .notRunning, projects: [], standalone: [], takenAt: takenAt, statsAt: nil)
        }
        let message = Self.describe(error)
        Self.log.error("docker list failed: \(message, privacy: .private)")
        return DockerSnapshot(status: .failed(message), projects: [], standalone: [], takenAt: takenAt, statsAt: nil)
    }

    private func resetCaches() {
        info = nil
        startedAtCache = [:]
        previousCPU = [:]
        lastStats = [:]
        statsAt = nil
    }

    /// `/version` is fetched once per connection lifetime; a failure here does not fail the snapshot.
    private func engineInfo(_ transport: any DockerHTTPTransport) async -> DockerEngineInfo {
        if let info { return info }
        do {
            let response = try await transport.request(method: "GET", path: "/version", query: [], timeout: Timeouts.version)
            try Self.requireSuccess(response)
            let wire = try Self.decode(WireVersion.self, from: response.body)
            let fetched = DockerEngineInfo(version: wire.version ?? "", apiVersion: wire.apiVersion ?? "")
            info = fetched
            return fetched
        } catch {
            return DockerEngineInfo(version: "", apiVersion: "")
        }
    }

    private static func fetchStartedAt(_ transport: any DockerHTTPTransport, id: String) async -> Date? {
        do {
            let response = try await transport.request(method: "GET", path: "/containers/\(id)/json", query: [],
                                                       timeout: Timeouts.inspect)
            try requireSuccess(response)
            return DockerMapping.startedAt(fromInspect: try decode(WireInspect.self, from: response.body))
        } catch {
            return nil
        }
    }

    private static func fetchStats(_ transport: any DockerHTTPTransport, id: String) async -> StatsSample? {
        do {
            let response = try await transport.request(
                method: "GET", path: "/containers/\(id)/stats",
                query: [URLQueryItem(name: "stream", value: "false"), URLQueryItem(name: "one-shot", value: "true")],
                timeout: Timeouts.stats)
            try requireSuccess(response)
            return StatsSample(try decode(WireStats.self, from: response.body))
        } catch {
            return nil
        }
    }

    // MARK: Container actions

    public func perform(_ action: ContainerAction, on containerID: String) async throws {
        // X1: nothing is built, resolved, or sent for an id that is not 12–64 lowercase hex characters.
        guard DockerValidation.isValidContainerID(containerID) else {
            throw DockerError.invalidArgument("Geçersiz konteyner kimliği")
        }

        let verb: String
        let method: String
        let path: String
        var query: [URLQueryItem] = []
        let accepted: Set<Int>
        let timeout: TimeInterval
        switch action {
        case .start:
            verb = "start"; method = "POST"; path = "/containers/\(containerID)/start"
            accepted = [204, 304]; timeout = Timeouts.start
        case .stop:
            verb = "stop"; method = "POST"; path = "/containers/\(containerID)/stop"
            query = [URLQueryItem(name: "t", value: "10")]
            accepted = [204, 304]; timeout = Timeouts.stop
        case .remove:
            // X3: never force, never remove volumes. 404 = already gone = success; 409 (running / in use) surfaces as `.http`.
            verb = "remove"; method = "DELETE"; path = "/containers/\(containerID)"
            query = [URLQueryItem(name: "force", value: "false"), URLQueryItem(name: "v", value: "false")]
            accepted = [204, 404]; timeout = Timeouts.remove
        }

        do {
            let transport = transportFactory(try requireSocket())
            let response = try await transport.request(method: method, path: path, query: query, timeout: timeout)
            guard accepted.contains(response.status) else {
                throw Self.httpError(response)
            }
            startedAtCache[containerID] = nil
            previousCPU[containerID] = nil
            lastStats[containerID] = nil
            await recordAudit(.dockerContainer, subject: containerID, error: nil,
                              detail: ["action": verb, "status": String(response.status)])
        } catch {
            Self.log.error("docker \(verb, privacy: .public) \(containerID, privacy: .public) failed: \(Self.describe(error), privacy: .private)")
            await recordAudit(.dockerContainer, subject: containerID, error: error, detail: ["action": verb])
            throw error
        }
    }

    public func perform(_ action: ComposeAction, projectName: String) async throws {
        // X2 (ComposeCLI validates again right before the spawn).
        guard DockerValidation.isValidProjectName(projectName) else {
            throw DockerError.invalidArgument("Geçersiz compose proje adı")
        }
        let verb = action == .stop ? "stop" : "down"
        do {
            // The socket is resolved now, not when the confirmation card was armed: a rejected (remote context, bad override)
            // or missing socket refuses before any process is spawned, and the CLI is pinned to this very socket, so compose
            // can never reach a daemon other than the one DevTidy talks to.
            let socket = try requireSocket()
            try await compose.run(action, projectName: projectName, socketPath: socket)
            await recordAudit(.dockerCompose, subject: projectName, error: nil, detail: ["action": verb])
        } catch {
            Self.log.error("docker compose \(verb, privacy: .public) \(projectName, privacy: .public) failed: \(Self.describe(error), privacy: .private)")
            await recordAudit(.dockerCompose, subject: projectName, error: error, detail: ["action": verb])
            throw error
        }
    }

    // MARK: Build cache

    public func buildCacheSummary() async throws -> BuildCacheSummary {
        let transport = transportFactory(try requireSocket())
        let response = try await transport.request(method: "GET", path: "/system/df",
                                                   query: [URLQueryItem(name: "type", value: "build-cache")],
                                                   timeout: Timeouts.df)
        try Self.requireSuccess(response)
        let usage = try Self.decode(WireDiskUsage.self, from: response.body)
        return DockerBuildCache.summarize(usage.buildCache ?? [], measuredAt: Date())
    }

    public func pruneBuildCache(_ mode: BuildCachePruneMode) async throws -> BuildCachePruneResult {
        // X5: this is the only prune endpoint the client can address; it removes build cache records only.
        var query = [URLQueryItem(name: "all", value: "1")]
        let modeText: String
        switch mode {
        case .allUnused:
            modeText = "allUnused"
        case .olderThan(let hours):
            guard (1...87_600).contains(hours) else { throw DockerError.invalidArgument("Geçersiz saat değeri") }
            query.append(URLQueryItem(name: "filters", value: "{\"until\":[\"\(hours)h\"]}"))
            modeText = "olderThan:\(hours)h"
        }

        do {
            let transport = transportFactory(try requireSocket())
            let response = try await transport.request(method: "POST", path: "/build/prune", query: query, timeout: Timeouts.prune)
            try Self.requireSuccess(response)
            // The prune already happened; an unreadable report must not turn it into an error.
            let reclaimed = max((try? Self.decode(WirePruneReport.self, from: response.body))?.spaceReclaimed ?? 0, 0)
            await recordAudit(.dockerPrune, subject: "build-cache", error: nil,
                              detail: ["mode": modeText, "reclaimedBytes": String(reclaimed)])
            return BuildCachePruneResult(reclaimedBytes: reclaimed)
        } catch {
            Self.log.error("docker build cache prune failed: \(Self.describe(error), privacy: .private)")
            await recordAudit(.dockerPrune, subject: "build-cache", error: error, detail: ["mode": modeText])
            throw error
        }
    }

    // MARK: Socket lookup

    private enum SocketLookup {
        case found(String)
        case unavailable(DockerStatus)
    }

    private func lookupSocket() -> SocketLookup {
        let override = socketOverride()
        if let path = locator.dockerSocketPath(override: override) { return .found(path) }
        // A configuration DevTidy refuses to use (remote context, unusable override / `$DOCKER_HOST`): no other daemon is tried.
        if let reason = (locator as? any DockerSocketRejectionReporting)?.socketRejection(override: override) {
            return .unavailable(.unsupported(reason))
        }
        let installed = locator.isDockerDesktopInstalled() || locator.dockerExecutable() != nil
        return .unavailable(installed ? .notRunning : .notInstalled)
    }

    /// The single gate in front of every daemon-facing call (API requests and compose spawns).
    private func requireSocket() throws -> String {
        switch lookupSocket() {
        case .found(let path):
            return path
        case .unavailable(.notInstalled):
            throw DockerError.notInstalled
        case .unavailable(.unsupported(let reason)):
            throw DockerError.daemonUnavailable(reason)
        case .unavailable:
            throw DockerError.daemonUnavailable("Docker soketi bulunamadı")
        }
    }

    // MARK: Helpers

    private func recordAudit(_ kind: AuditEvent.Kind, subject: String, error: (any Error)?, detail: [String: String]) async {
        let result = error.map { Self.boundedForAudit("failed:" + Self.describe($0)) } ?? "ok"
        await audit.record(AuditEvent(time: Date(), kind: kind, subject: subject, result: result, detail: detail))
    }

    /// Longest `result` text (UTF-8 bytes) written to the audit log. The log is rotated by size and every line is kept whole,
    /// so one runaway error text (a compose plugin's stderr) must not push the retained history out (N-8).
    static let auditResultLimit = 2_048

    /// `text` cut to at most `auditResultLimit` UTF-8 bytes on a character boundary, marked with "…" when something was dropped.
    static func boundedForAudit(_ text: String) -> String {
        let marker = "…"
        guard text.utf8.count > auditResultLimit else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: auditResultLimit - marker.utf8.count)
        while end > text.startIndex, end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end]) + marker
    }

    private static func isDaemonUnavailable(_ error: any Error) -> Bool {
        guard let dockerError = error as? DockerError, case .daemonUnavailable = dockerError else { return false }
        return true
    }

    private static func requireSuccess(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.status) else {
            throw httpError(response)
        }
    }

    private static func bodyText(_ response: HTTPResponse) -> String {
        String(decoding: response.body.prefix(4096), as: UTF8.self)
    }

    /// `DockerError.http` carries the daemon's own `message` rather than the raw `{"message":…}` JSON body, so every
    /// consumer (store text, audit) shows clean text.
    private static func httpError(_ response: HTTPResponse) -> DockerError {
        .http(status: response.status, body: shortMessage(fromBody: bodyText(response)))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DockerError.decoding(String(String(describing: error).prefix(200)))
        }
    }

    /// Short, user-facing text for `DockerStatus.failed` and audit results.
    static func describe(_ error: any Error) -> String {
        switch error as? DockerError {
        case .http(let status, let body)?:
            return "Docker HTTP \(status): \(shortMessage(fromBody: body))"
        case .timeout?:
            return "Docker yanıt vermedi (zaman aşımı)"
        case .decoding(let detail)?:
            return "Docker yanıtı okunamadı: \(detail)"
        case .invalidArgument(let detail)?:
            return "Geçersiz istek: \(detail)"
        case .daemonUnavailable(let detail)?:
            return detail
        case .notInstalled?:
            return "Docker kurulu değil"
        case .commandFailed(let exitCode, let stderr)?:
            return "docker çıkış kodu \(exitCode): \(stderr)"
        case nil:
            return String(describing: error)
        }
    }

    /// `{"message":"..."}` → the message, otherwise the first 200 characters of the body.
    private static func shortMessage(fromBody body: String) -> String {
        if let data = body.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(WireErrorBody.self, from: data),
           let message = decoded.message, !message.isEmpty {
            return message
        }
        return String(body.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
