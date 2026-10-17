import Foundation
@testable import DevTidyCore

// Shared test support for the Docker slice. Everything here is S3-prefixed (one test module, no symbol clashes).
// Nothing in this file talks to a real Docker daemon: the only sockets are test-owned temp sockets under /tmp.

struct S3TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Temp directories / sockets -------------------------------------------------------------------------------

enum S3Temp {
    static let prefix = "/tmp/devtidy-s3-"

    /// `/tmp/devtidy-s3-XXXXXX` — deliberately NOT `$TMPDIR`: an AF_UNIX path must stay below 104 bytes.
    static func makeDirectory() throws -> String {
        var template = Array((prefix + "XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw S3TestError("mkdtemp failed: errno \(errno)") }
        return template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Removes only directories this support code created.
    static func remove(_ path: String) {
        guard path.hasPrefix(prefix), !path.contains("..") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

enum S3Sockets {
    /// Binds a unix socket at `path` and closes it again: leaves a socket *file* with nobody listening (a stale socket).
    static func makeSocketFile(at path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw S3TestError("socket failed: errno \(errno)") }
        defer { Darwin.close(fd) }
        var address = try UnixSocketHTTP.makeAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw S3TestError("bind \(path) failed: errno \(errno)") }
    }
}

/// A listening unix-socket HTTP server owned by the test (temp path). Serves one connection at a time.
final class S3UnixSocketServer: @unchecked Sendable {
    enum Behavior: Sendable {
        /// Reads the request, then writes the chunks returned by the closure (with a pause between chunks) and closes.
        case respond(gapMilliseconds: Int, @Sendable (_ request: String) -> [Data])
        /// Reads the request, then never answers until `stop()`.
        case hang
        /// Reads the request, then closes without writing anything.
        case closeAfterRequest
    }

    let directory: String
    let path: String
    private let behavior: Behavior
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var received: [String] = []

    init(_ behavior: Behavior) throws {
        let directory = try S3Temp.makeDirectory()
        let socketPath = directory + "/s.sock"
        let fd: Int32
        do {
            fd = try Self.makeListener(at: socketPath)
        } catch {
            S3Temp.remove(directory)
            throw error
        }
        self.directory = directory
        self.path = socketPath
        self.behavior = behavior
        self.listenFD = fd
        Thread.detachNewThread { [self] in serve() }
    }

    private static func makeListener(at path: String) throws -> Int32 {
        var address = try UnixSocketHTTP.makeAddress(path: path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw S3TestError("socket failed: errno \(errno)") }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw S3TestError("bind/listen failed: errno \(code)")
        }
        return fd
    }

    /// Raw request texts, in arrival order.
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func stop() {
        guard markStopped() else { return }
        unlink(path)
        S3Temp.remove(directory)
    }

    // MARK: Server loop

    private func markStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasStopped = stopped
        stopped = true
        return !wasStopped
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func store(_ request: String) {
        lock.lock()
        received.append(request)
        lock.unlock()
    }

    private func serve() {
        defer { Darwin.close(listenFD) }
        while !isStopped {
            var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
            let client = Darwin.accept(listenFD, nil, nil)
            guard client >= 0 else { continue }
            var noSigPipe: Int32 = 1
            Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        let request = readRequest(client)
        store(request)
        switch behavior {
        case .closeAfterRequest:
            return
        case .hang:
            while !isStopped { usleep(20_000) }
        case .respond(let gap, let makeChunks):
            for (index, chunk) in makeChunks(request).enumerated() {
                if index > 0, gap > 0 { usleep(UInt32(gap) * 1000) }
                writeAll(client, chunk)
            }
        }
    }

    private func readRequest(_ client: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<40 {
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(client, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeAll(_ client: Int32, _ data: Data) {
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress! + sent, $0.count - sent, 0) }
            if written <= 0 { return }
            sent += written
        }
    }
}

// MARK: - Fakes ---------------------------------------------------------------------------------------------------------

struct S3FakeLocator: ToolLocating, DockerSocketRejectionReporting {
    var socket: String? = "/fake/docker.sock"
    var desktopInstalled = false
    var docker: URL? = URL(fileURLWithPath: "/fake/bin/docker")
    var rejection: String?

    func dockerExecutable() -> URL? { docker }
    func gitExecutable() -> URL? { nil }
    func dockerSocketPath(override: String?) -> String? { socket }
    func isDockerDesktopInstalled() -> Bool { desktopInstalled }
    func childEnvironment() -> [String: String] {
        ["HOME": "/fake/home", "USER": "tester", "PATH": "/fake/bin", "LC_ALL": "C"]
    }
    func socketRejection(override: String?) -> String? { rejection }
}

actor S3FakeAudit: AuditLogging {
    private(set) var events: [AuditEvent] = []
    func record(_ event: AuditEvent) { events.append(event) }
    func isWritable() -> Bool { true }
}

final class S3FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectory: URL?
        let timeout: TimeInterval
    }

    enum Outcome {
        case result(CommandResult)
        case launchFailure(String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let outcome: Outcome

    init(_ outcome: Outcome = .result(S3FakeRunner.success())) {
        self.outcome = outcome
    }

    static func success() -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: Data(), standardError: Data(), timedOut: false)
    }

    static func failure(code: Int32, stderr: String, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: code, standardOutput: Data(), standardError: Data(stderr.utf8), timedOut: timedOut)
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return outcome
    }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?, timeout: TimeInterval) async throws -> CommandResult {
        let current = record(Call(executable: executable, arguments: arguments, environment: environment,
                                  currentDirectory: currentDirectory, timeout: timeout))
        switch current {
        case .result(let result): return result
        case .launchFailure(let message): throw CommandError.launchFailed(message)
        }
    }
}

struct S3Request: Equatable, Sendable {
    let method: String
    let path: String
    /// `name=value` in the order the client supplied.
    let query: [String]
}

final class S3FakeTransport: DockerHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (S3Request) throws -> HTTPResponse

    private let lock = NSLock()
    private var recorded: [S3Request] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [S3Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: S3Request) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    func request(method: String, path: String, query: [URLQueryItem], timeout: TimeInterval) async throws -> HTTPResponse {
        let request = S3Request(method: method, path: path, query: query.map { "\($0.name)=\($0.value ?? "")" })
        record(request)
        return try handler(request)
    }
}

/// A locator whose answer changes between calls: the user switches to a remote Docker context after a confirmation card
/// that will run compose was already armed.
final class S3SwitchableLocator: ToolLocating, DockerSocketRejectionReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var socket: String? = "/fake/docker.sock"
    private var rejection: String?

    func rejectWithRemoteContext(_ message: String) {
        lock.lock()
        socket = nil
        rejection = message
        lock.unlock()
    }

    func dockerExecutable() -> URL? { URL(fileURLWithPath: "/fake/bin/docker") }
    func gitExecutable() -> URL? { nil }
    func dockerSocketPath(override: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }
    func isDockerDesktopInstalled() -> Bool { false }
    func childEnvironment() -> [String: String] {
        ["HOME": "/fake/home", "USER": "tester", "PATH": "/fake/bin", "LC_ALL": "C"]
    }
    func socketRejection(override: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return rejection
    }
}

/// Answers like `S3FakeDaemon` but each request takes a moment, and records how many requests were already in flight when
/// each `GET /containers/json` started: overlapping snapshots show up as a non-zero count.
final class S3SlowTransport: DockerHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var inFlightAtListStarts: [Int] = []
    private let daemon: S3FakeDaemon

    init(daemon: S3FakeDaemon) {
        self.daemon = daemon
    }

    var inFlightAtListStart: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return inFlightAtListStarts
    }

    private func begin(isList: Bool) {
        lock.lock()
        if isList { inFlightAtListStarts.append(inFlight) }
        inFlight += 1
        lock.unlock()
    }

    private func end() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    func request(method: String, path: String, query: [URLQueryItem], timeout: TimeInterval) async throws -> HTTPResponse {
        begin(isList: method == "GET" && path == "/containers/json")
        defer { end() }
        try await Task.sleep(for: .milliseconds(15))
        return try daemon.handle(S3Request(method: method, path: path, query: query.map { "\($0.name)=\($0.value ?? "")" }))
    }
}

/// Scripted Engine API: tests mutate the state between client calls.
final class S3FakeDaemon: @unchecked Sendable {
    struct State {
        var down = false
        var listStatus = 200
        var listBody = "[]"
        var versionBody = #"{"Version":"29.8.2","ApiVersion":"1.56"}"#
        var startedAt: [String: String] = [:]
        var failInspect: Set<String> = []
        var stats: [String: String] = [:]
        var failStats: Set<String> = []
        var dfBody = #"{"BuildCache":[]}"#
        var pruneBody = #"{"CachesDeleted":[],"SpaceReclaimed":0}"#
        var actionStatus = 204
        var actionBody = ""
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ change: (inout State) -> Void) {
        lock.lock()
        change(&state)
        lock.unlock()
    }

    private func current() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func transport() -> S3FakeTransport {
        S3FakeTransport { [self] request in try handle(request) }
    }

    func handle(_ request: S3Request) throws -> HTTPResponse {
        let state = current()
        if state.down { throw DockerError.daemonUnavailable("connect: No such file or directory") }
        let method = request.method
        let parts = request.path.split(separator: "/").map(String.init)
        let isContainerPath = parts.count >= 2 && parts[0] == "containers"

        if method == "GET", parts == ["containers", "json"] {
            return S3Fixtures.response(state.listStatus, state.listBody)
        }
        if method == "GET", parts == ["version"] {
            return S3Fixtures.response(200, state.versionBody)
        }
        if method == "GET", isContainerPath, parts.count == 3, parts[2] == "json" {
            let id = parts[1]
            if state.failInspect.contains(id) { return S3Fixtures.response(500, #"{"message":"inspect failed"}"#) }
            let startedAt = state.startedAt[id] ?? "2026-10-16T17:35:10.54781071Z"
            return S3Fixtures.response(200, "{\"Id\":\"\(id)\",\"State\":{\"Status\":\"running\",\"StartedAt\":\"\(startedAt)\"}}")
        }
        if method == "GET", isContainerPath, parts.count == 3, parts[2] == "stats" {
            let id = parts[1]
            if state.failStats.contains(id) { return S3Fixtures.response(500, #"{"message":"stats failed"}"#) }
            guard let body = state.stats[id] else { return S3Fixtures.response(404, #"{"message":"no such container"}"#) }
            return S3Fixtures.response(200, body)
        }
        if method == "POST", isContainerPath, parts.count == 3, parts[2] == "start" || parts[2] == "stop" {
            return S3Fixtures.response(state.actionStatus, state.actionBody)
        }
        if method == "DELETE", isContainerPath, parts.count == 2 {
            return S3Fixtures.response(state.actionStatus, state.actionBody)
        }
        if method == "GET", parts == ["system", "df"] {
            return S3Fixtures.response(200, state.dfBody)
        }
        if method == "POST", parts == ["build", "prune"] {
            return S3Fixtures.response(200, state.pruneBody)
        }
        return S3Fixtures.response(404, #"{"message":"unexpected request in fake daemon"}"#)
    }
}

// MARK: - Fixtures ------------------------------------------------------------------------------------------------------

enum S3Fixtures {
    static let idA = String(repeating: "a1", count: 32)
    static let idB = String(repeating: "b2", count: 32)
    static let idC = String(repeating: "c3", count: 32)

    /// 64-hex id whose first 12 characters are `prefix12` (a real `docker ps` short id).
    static func fullID(_ prefix12: String) -> String {
        String(String(repeating: prefix12, count: 6).prefix(64))
    }

    static func response(_ status: Int, _ body: String = "", headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
    }

    static func date(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }

    // MARK: Stats

    static func statsJSON(total: UInt64, system: UInt64, cpus: Int? = 4, perCPU: [UInt64]? = nil,
                          usage: UInt64 = 0, inactiveFile: UInt64? = nil, totalInactiveFile: UInt64? = nil,
                          limit: UInt64 = 6_210_576_384) -> String {
        var cpuUsage = "\"total_usage\":\(total)"
        if let perCPU { cpuUsage += ",\"percpu_usage\":[" + perCPU.map { String($0) }.joined(separator: ",") + "]" }
        var cpuFields = ["\"cpu_usage\":{\(cpuUsage)}", "\"system_cpu_usage\":\(system)"]
        if let cpus { cpuFields.append("\"online_cpus\":\(cpus)") }
        var memoryDetail: [String] = []
        if let inactiveFile { memoryDetail.append("\"inactive_file\":\(inactiveFile)") }
        if let totalInactiveFile { memoryDetail.append("\"total_inactive_file\":\(totalInactiveFile)") }
        let cpu = "\"cpu_stats\":{" + cpuFields.joined(separator: ",") + "}"
        let precpu = "\"precpu_stats\":{\"cpu_usage\":{\"total_usage\":0},\"system_cpu_usage\":0}"
        let memory = "\"memory_stats\":{\"usage\":\(usage),\"limit\":\(limit),\"stats\":{" + memoryDetail.joined(separator: ",") + "}}"
        return "{\"read\":\"2026-10-17T08:00:00.123456789Z\"," + cpu + "," + precpu + "," + memory + "}"
    }

    // MARK: Container lists

    struct Item {
        var id: String
        var name: String
        var state: String = "running"
        var status: String = "Up 2 hours"
        var created: Int = 1_792_172_104
        var project: String?
        var service: String?
    }

    static func listJSON(_ items: [Item]) -> String {
        let objects: [[String: Any]] = items.map { item in
            var labels: [String: String] = [:]
            if let project = item.project { labels["com.docker.compose.project"] = project }
            if let service = item.service { labels["com.docker.compose.service"] = service }
            return [
                "Id": item.id, "Names": ["/" + item.name], "Image": "img:latest", "Created": item.created,
                "State": item.state, "Status": item.status, "Labels": labels, "Ports": [Any](), "Mounts": [Any](),
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: ENV-shaped list (ENV §7.3 / §7.4 / §7.9)

    static let nginxID = fullID("4b90705d7188")
    static let hindsightID = fullID("a1aac3e59622")
    static let e2eQueueID = fullID("4f4d647ac9f1")
    static let phpID = fullID("9d3c1b7e5a20")
    static let redisID = fullID("bef41843fa24")
    static let mailpitID = fullID("1e1de08a8ea8")

    static let tunahanDir = "/Users/suleymanozcan/developer/tunahan/otopark-api"

    /// Three compose projects (`tunahan` 3 containers, `rentacar-api` 1 exited, `eticaretsaas-monolith` 1 exited) + standalone `hindsight`.
    static var envListJSON: String {
        #"""
        [
         {"Id":"\#(nginxID)","Names":["/tunahan-nginx-1"],"Image":"nginx:1.29-alpine","ImageID":"sha256:11","Command":"/docker-entrypoint.sh nginx -g 'daemon off;'","Created":1792172104,
          "Ports":[{"IP":"127.0.0.1","PrivatePort":80,"PublicPort":8000,"Type":"tcp"},{"IP":"127.0.0.1","PrivatePort":81,"PublicPort":8001,"Type":"tcp"},{"PrivatePort":9000,"Type":"tcp"}],
          "Labels":{"com.docker.compose.project":"tunahan","com.docker.compose.project.working_dir":"\#(tunahanDir)","com.docker.compose.service":"nginx","com.docker.compose.depends_on":"redis:service_healthy:false,postgres:service_healthy:false","com.docker.compose.config-hash":"abc"},
          "State":"running","Status":"Up 14 hours",
          "Mounts":[{"Type":"bind","Source":"/host_mnt\#(tunahanDir)/docker/nginx/default.conf","Destination":"/etc/nginx/conf.d/default.conf","Mode":"ro","RW":false},{"Type":"volume","Name":"pgdata","Source":"/var/lib/docker/volumes/pgdata/_data","Destination":"/data"}]},
         {"Id":"\#(hindsightID)","Names":["/hindsight"],"Image":"ghcr.io/vectorize-io/hindsight:latest","Created":1792178012,
          "Ports":[{"IP":"127.0.0.1","PrivatePort":8888,"PublicPort":8888,"Type":"tcp"},{"IP":"::1","PrivatePort":8888,"PublicPort":8888,"Type":"tcp"},{"IP":"127.0.0.1","PrivatePort":9999,"PublicPort":9999,"Type":"tcp"}],
          "Labels":{"desktop.docker.io/ports.scheme":"v2","desktop.docker.io/ports/8888/tcp":"127.0.0.1:8888"},
          "State":"running","Status":"Up 12 hours (healthy)","Mounts":[{"Type":"volume","Name":"hindsight-data","Source":"/var/lib/docker/volumes/hindsight-data/_data","Destination":"/data"}]},
         {"Id":"\#(e2eQueueID)","Names":["/tunahan-e2e-queue-1"],"Image":"tunahan-php","Created":1792172150,"Ports":[],
          "Labels":{"com.docker.compose.project":"tunahan","com.docker.compose.project.working_dir":"\#(tunahanDir)","com.docker.compose.service":"e2e-queue"},
          "State":"running","Status":"Up 14 hours (unhealthy)","Mounts":[]},
         {"Id":"\#(phpID)","Names":["/tunahan-php-1"],"Image":"tunahan-php","Created":1792172160,"Ports":[{"PrivatePort":9000,"Type":"tcp"}],
          "Labels":{"com.docker.compose.project":"tunahan","com.docker.compose.project.working_dir":"\#(tunahanDir)","com.docker.compose.service":"php"},
          "State":"running","Status":"Up 2 minutes (health: starting)","Mounts":[]},
         {"Id":"\#(redisID)","Names":["/rentacar-api-redis-1"],"Image":"redis:7-alpine","Created":1792178076,"Ports":[],
          "Labels":{"com.docker.compose.project":"rentacar-api","com.docker.compose.project.working_dir":"/Users/suleymanozcan/developer/rentacarsaas/monolith-api","com.docker.compose.service":"redis"},
          "State":"exited","Status":"Exited (0) 12 hours ago","Health":{"Status":"unhealthy","FailingStreak":3},"Mounts":[]},
         {"Id":"\#(mailpitID)","Names":["/eticaretsaas-monolith-mailpit"],"Image":"axllent/mailpit","Created":1792100000,"Ports":[],
          "Labels":{"com.docker.compose.project":"eticaretsaas-monolith","com.docker.compose.project.working_dir":"/Users/suleymanozcan/developer/eticaretsaas/monolith","com.docker.compose.service":"mailpit"},
          "State":"exited","Status":"Exited (137) 3 days ago","Mounts":[]}
        ]
        """#
    }
}

// MARK: - Small assertions helpers ----------------------------------------------------------------------------------

func s3Error(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

func s3IsDaemonUnavailable(_ error: (any Error)?) -> Bool {
    guard let dockerError = error as? DockerError, case .daemonUnavailable = dockerError else { return false }
    return true
}

func s3IsInvalidArgument(_ error: (any Error)?) -> Bool {
    guard let dockerError = error as? DockerError, case .invalidArgument = dockerError else { return false }
    return true
}

func s3IsHTTP(_ error: (any Error)?, status: Int) -> Bool {
    guard let dockerError = error as? DockerError, case .http(let code, _) = dockerError else { return false }
    return code == status
}
