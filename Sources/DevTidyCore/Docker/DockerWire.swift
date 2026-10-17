import Foundation

// Engine API wire shapes. Every field is optional and decoded leniently (a field of an unexpected type becomes nil instead of
// failing the whole response): only the fields recon verified live are relied upon for correctness, the rest degrade to
// "unknown". Keys follow the Docker docs; list/inspect/version/stats shapes are [obs] ENV §7.9.

extension KeyedDecodingContainer {
    /// `decodeIfPresent` that maps a missing key, `null`, or a type mismatch to nil.
    func dockerLenient<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

// MARK: - GET /containers/json?all=1

struct WireContainerSummary: Decodable, Sendable {
    let id: String?
    let names: [String]?
    let image: String?
    /// Epoch seconds.
    let created: Double?
    let state: String?
    let status: String?
    /// JSON map (ENV G7: label values contain commas, so this is never split).
    let labels: [String: String]?
    let ports: [WirePort]?
    let mounts: [WireMount]?
    /// `Health.Status` when the daemon reports it (newer API versions); the Status text suffix is the fallback.
    let healthStatus: String?

    private enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", created = "Created", state = "State", status = "Status"
        case labels = "Labels", ports = "Ports", mounts = "Mounts", health = "Health"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.dockerLenient(.id)
        names = container.dockerLenient(.names)
        image = container.dockerLenient(.image)
        created = container.dockerLenient(.created)
        state = container.dockerLenient(.state)
        status = container.dockerLenient(.status)
        labels = container.dockerLenient(.labels)
        ports = container.dockerLenient(.ports)
        mounts = container.dockerLenient(.mounts)
        let health: WireHealth? = container.dockerLenient(.health)
        healthStatus = health?.status
    }
}

struct WirePort: Decodable, Sendable {
    let ip: String?
    let privatePort: Int?
    let publicPort: Int?
    let type: String?

    private enum CodingKeys: String, CodingKey {
        case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ip = container.dockerLenient(.ip)
        privatePort = container.dockerLenient(.privatePort)
        publicPort = container.dockerLenient(.publicPort)
        type = container.dockerLenient(.type)
    }
}

struct WireMount: Decodable, Sendable {
    let type: String?
    let source: String?
    let destination: String?

    private enum CodingKeys: String, CodingKey {
        case type = "Type", source = "Source", destination = "Destination"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.dockerLenient(.type)
        source = container.dockerLenient(.source)
        destination = container.dockerLenient(.destination)
    }
}

struct WireHealth: Decodable, Sendable {
    let status: String?

    private enum CodingKeys: String, CodingKey { case status = "Status" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.dockerLenient(.status)
    }
}

// MARK: - GET /version

struct WireVersion: Decodable, Sendable {
    let version: String?
    let apiVersion: String?

    private enum CodingKeys: String, CodingKey { case version = "Version", apiVersion = "ApiVersion" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.dockerLenient(.version)
        apiVersion = container.dockerLenient(.apiVersion)
    }
}

// MARK: - GET /containers/<id>/json

struct WireInspect: Decodable, Sendable {
    let state: WireInspectState?

    private enum CodingKeys: String, CodingKey { case state = "State" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = container.dockerLenient(.state)
    }
}

struct WireInspectState: Decodable, Sendable {
    /// RFC 3339 with nanoseconds, e.g. `2026-10-16T17:35:10.54781071Z`. `0001-01-01T00:00:00Z` = never started.
    let startedAt: String?

    private enum CodingKeys: String, CodingKey { case startedAt = "StartedAt" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = container.dockerLenient(.startedAt)
    }
}

// MARK: - GET /containers/<id>/stats?stream=false&one-shot=true

struct WireStats: Decodable, Sendable {
    let cpuStats: WireCPUStats?
    let memoryStats: WireMemoryStats?

    private enum CodingKeys: String, CodingKey { case cpuStats = "cpu_stats", memoryStats = "memory_stats" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuStats = container.dockerLenient(.cpuStats)
        memoryStats = container.dockerLenient(.memoryStats)
    }
}

struct WireCPUStats: Decodable, Sendable {
    let cpuUsage: WireCPUUsage?
    let systemCPUUsage: UInt64?
    let onlineCPUs: Int?

    private enum CodingKeys: String, CodingKey {
        case cpuUsage = "cpu_usage", systemCPUUsage = "system_cpu_usage", onlineCPUs = "online_cpus"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuUsage = container.dockerLenient(.cpuUsage)
        systemCPUUsage = container.dockerLenient(.systemCPUUsage)
        onlineCPUs = container.dockerLenient(.onlineCPUs)
    }
}

struct WireCPUUsage: Decodable, Sendable {
    let totalUsage: UInt64?
    let perCPUUsage: [UInt64]?

    private enum CodingKeys: String, CodingKey { case totalUsage = "total_usage", perCPUUsage = "percpu_usage" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalUsage = container.dockerLenient(.totalUsage)
        perCPUUsage = container.dockerLenient(.perCPUUsage)
    }
}

struct WireMemoryStats: Decodable, Sendable {
    let usage: UInt64?
    let limit: UInt64?
    let stats: WireMemoryDetail?

    private enum CodingKeys: String, CodingKey { case usage, limit, stats }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = container.dockerLenient(.usage)
        limit = container.dockerLenient(.limit)
        stats = container.dockerLenient(.stats)
    }
}

struct WireMemoryDetail: Decodable, Sendable {
    /// cgroup v2.
    let inactiveFile: UInt64?
    /// cgroup v1.
    let totalInactiveFile: UInt64?

    private enum CodingKeys: String, CodingKey { case inactiveFile = "inactive_file", totalInactiveFile = "total_inactive_file" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inactiveFile = container.dockerLenient(.inactiveFile)
        totalInactiveFile = container.dockerLenient(.totalInactiveFile)
    }
}

// MARK: - GET /system/df?type=build-cache  [doc: field names not verified live]

struct WireDiskUsage: Decodable, Sendable {
    let buildCache: [WireBuildCacheRecord]?

    private enum CodingKeys: String, CodingKey { case buildCache = "BuildCache" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buildCache = container.dockerLenient(.buildCache)
    }
}

struct WireBuildCacheRecord: Decodable, Sendable {
    let id: String?
    let size: Int64?
    let inUse: Bool?
    let shared: Bool?

    private enum CodingKeys: String, CodingKey { case id = "ID", size = "Size", inUse = "InUse", shared = "Shared" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.dockerLenient(.id)
        size = container.dockerLenient(.size)
        inUse = container.dockerLenient(.inUse)
        shared = container.dockerLenient(.shared)
    }
}

// MARK: - POST /build/prune  [doc: field names not verified live]

struct WirePruneReport: Decodable, Sendable {
    let spaceReclaimed: Int64?

    private enum CodingKeys: String, CodingKey { case spaceReclaimed = "SpaceReclaimed" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spaceReclaimed = container.dockerLenient(.spaceReclaimed)
    }
}

// MARK: - Error body `{"message": "..."}`

struct WireErrorBody: Decodable, Sendable {
    let message: String?

    private enum CodingKeys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = container.dockerLenient(.message)
    }
}
