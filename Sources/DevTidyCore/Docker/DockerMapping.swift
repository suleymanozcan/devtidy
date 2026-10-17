import Foundation

// MARK: - Wire → model ---------------------------------------------------------------------------------------------

enum DockerLabel {
    static let composeProject = "com.docker.compose.project"
    static let composeService = "com.docker.compose.service"
    static let composeWorkingDir = "com.docker.compose.project.working_dir"
}

enum DockerMapping {
    static func state(_ raw: String?) -> ContainerState {
        guard let raw, let state = ContainerState(rawValue: raw.lowercased()) else { return .unknown }
        return state
    }

    /// Returns nil when the summary has no id (nothing could be done with it).
    /// - `startedAt`: from inspect; honoured for running containers only, falling back to `Created` when inspect failed.
    /// - `stats`: honoured for running containers only.
    static func container(from wire: WireContainerSummary, startedAt: Date?, stats: DockerContainerStats?) -> DockerContainer? {
        guard let id = wire.id, !id.isEmpty else { return nil }
        let state = Self.state(wire.state)
        let isRunning = state == .running
        let createdDate = wire.created.map { Date(timeIntervalSince1970: $0) }
        let labels = wire.labels ?? [:]

        return DockerContainer(
            id: id,
            shortID: String(id.prefix(12)),
            name: name(from: wire.names, fallback: String(id.prefix(12))),
            image: wire.image ?? "",
            state: state,
            statusText: wire.status ?? "",
            createdAt: createdDate ?? Date(timeIntervalSince1970: 0),
            startedAt: isRunning ? (startedAt ?? createdDate) : nil,
            composeProject: nonEmpty(labels[DockerLabel.composeProject]),
            composeService: nonEmpty(labels[DockerLabel.composeService]),
            composeWorkingDir: nonEmpty(labels[DockerLabel.composeWorkingDir]),
            publishedPorts: publishedPorts(wire.ports),
            bindMountSources: bindMountSources(wire.mounts),
            health: health(summary: wire, state: state),
            cpuPercent: isRunning ? stats?.cpuPercent : nil,
            memoryBytes: isRunning ? stats?.memoryBytes : nil,
            memoryLimitBytes: isRunning ? stats?.memoryLimitBytes : nil
        )
    }

    /// Canonical name: `/name` (exactly one slash). Legacy link aliases look like `/web/db` and are skipped when a canonical
    /// name exists. The leading slash is removed.
    static func name(from names: [String]?, fallback: String) -> String {
        let all = names ?? []
        let canonical = all.first { $0.hasPrefix("/") && !$0.dropFirst().contains("/") } ?? all.first
        guard let picked = canonical else { return fallback }
        let trimmed = picked.hasPrefix("/") ? String(picked.dropFirst()) : picked
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Only for running containers; the health of a stopped container is stale (ENV G8).
    static func health(summary: WireContainerSummary, state: ContainerState) -> ContainerHealth? {
        guard state == .running else { return nil }
        if let raw = summary.healthStatus?.lowercased() {
            switch raw {
            case "healthy": return .healthy
            case "unhealthy": return .unhealthy
            case "starting": return .starting
            default: break      // "none" / "" / unknown: fall back to the Status text
            }
        }
        return health(fromStatusText: summary.status)
    }

    /// `Up 2 hours (healthy)` / `(unhealthy)` / `(health: starting)` — the daemon's English text [doc].
    static func health(fromStatusText text: String?) -> ContainerHealth? {
        guard let text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasSuffix("(unhealthy)") { return .unhealthy }
        if text.hasSuffix("(healthy)") { return .healthy }
        if text.hasSuffix("(health: starting)") { return .starting }
        return nil
    }

    private struct PortKey: Hashable {
        let hostPort: UInt16
        let containerPort: UInt16
        let proto: String
    }

    /// Entries without a `PublicPort` (exposed-only) are skipped. IPv4/IPv6 twins of the same mapping collapse to the first
    /// listed one. Sorted by host port for stable output.
    static func publishedPorts(_ wires: [WirePort]?) -> [PublishedPort] {
        var seen = Set<PortKey>()
        var result: [PublishedPort] = []
        for wire in wires ?? [] {
            guard let publicPort = wire.publicPort, let privatePort = wire.privatePort,
                  let hostPort = UInt16(exactly: publicPort), hostPort > 0,
                  let containerPort = UInt16(exactly: privatePort) else { continue }
            let proto = (wire.type ?? "tcp").lowercased()
            guard seen.insert(PortKey(hostPort: hostPort, containerPort: containerPort, proto: proto)).inserted else { continue }
            result.append(PublishedPort(hostIP: nonEmpty(wire.ip), hostPort: hostPort, containerPort: containerPort, proto: proto))
        }
        return result.sorted { ($0.hostPort, $0.containerPort, $0.proto) < ($1.hostPort, $1.containerPort, $1.proto) }
    }

    /// DevTidy paths of bind mounts; Docker Desktop reports them under `/host_mnt`.
    static func bindMountSources(_ mounts: [WireMount]?) -> [String] {
        var result: [String] = []
        for mount in mounts ?? [] where mount.type?.lowercased() == "bind" {
            guard let source = mount.source, !source.isEmpty else { continue }
            let hostPath = stripHostMount(source)
            if !result.contains(hostPath) { result.append(hostPath) }
        }
        return result
    }

    static func stripHostMount(_ path: String) -> String {
        let prefix = "/host_mnt/"
        return path.hasPrefix(prefix) ? "/" + String(path.dropFirst(prefix.count)) : path
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `State.StartedAt` → Date; nil for unparsable text and for the zero time `0001-01-01T00:00:00Z`.
    static func startedAt(fromInspect wire: WireInspect) -> Date? {
        guard let text = wire.state?.startedAt, let date = DockerTimestamp.parse(text), date.timeIntervalSince1970 > 0 else {
            return nil
        }
        return date
    }
}

// MARK: - Grouping --------------------------------------------------------------------------------------------------

enum DockerGrouping {
    /// Containers carrying `com.docker.compose.project` form a `ComposeProject`; the rest are standalone (ENV §7.4).
    /// Projects sorted by name, project containers by service then name, standalone by name.
    static func group(_ containers: [DockerContainer]) -> (projects: [ComposeProject], standalone: [DockerContainer]) {
        var byProject: [String: [DockerContainer]] = [:]
        var standalone: [DockerContainer] = []
        for container in containers {
            if let project = container.composeProject {
                byProject[project, default: []].append(container)
            } else {
                standalone.append(container)
            }
        }
        let projects = byProject.keys.sorted().map { name -> ComposeProject in
            let members = byProject[name] ?? []
            let sorted = members.sorted { lhs, rhs in
                let left = lhs.composeService ?? ""
                let right = rhs.composeService ?? ""
                return left != right ? left < right : lhs.name < rhs.name
            }
            return ComposeProject(name: name, workingDir: members.lazy.compactMap { $0.composeWorkingDir }.first, containers: sorted)
        }
        return (projects, standalone.sorted { $0.name < $1.name })
    }
}

// MARK: - Build cache -----------------------------------------------------------------------------------------------

enum DockerBuildCache {
    /// Σ size of records with `InUse != true` (shared included) is `reclaimable`; additionally `Shared != true` is `private`.
    /// Every field is optional on the wire: a missing size counts as 0, a missing flag as "false".
    static func summarize(_ records: [WireBuildCacheRecord], measuredAt: Date) -> BuildCacheSummary {
        var total: Int64 = 0
        var reclaimable: Int64 = 0
        var privateReclaimable: Int64 = 0
        var active = 0
        for record in records {
            let size = max(record.size ?? 0, 0)
            total = total &+ size
            if record.inUse == true {
                active += 1
            } else {
                reclaimable = reclaimable &+ size
                if record.shared != true { privateReclaimable = privateReclaimable &+ size }
            }
        }
        return BuildCacheSummary(totalBytes: total, reclaimableBytes: reclaimable, privateReclaimableBytes: privateReclaimable,
                                 recordCount: records.count, activeCount: active, measuredAt: measuredAt)
    }
}

// MARK: - RFC 3339 --------------------------------------------------------------------------------------------------

/// Locale-free, formatter-free RFC 3339 parser (`2026-10-16T17:35:10.54781071Z`, any number of fraction digits, `Z` or ±HH:MM).
/// Docker prints nanoseconds, which `ISO8601DateFormatter` handling of long fractions is not documented to accept.
enum DockerTimestamp {
    private struct Cursor {
        let bytes: [UInt8]
        var index = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        var atEnd: Bool { index >= bytes.count }

        mutating func integer(digits: Int) -> Int? {
            guard index + digits <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<digits {
                let byte = bytes[index + offset]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += digits
            return value
        }

        mutating func consume(_ expected: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == expected else { return false }
            index += 1
            return true
        }

        mutating func consumeAny(_ options: [UInt8]) -> Bool {
            guard index < bytes.count, options.contains(bytes[index]) else { return false }
            index += 1
            return true
        }
    }

    static func parse(_ text: String) -> Date? {
        var cursor = Cursor(text)
        guard let year = cursor.integer(digits: 4), cursor.consume(0x2D),
              let month = cursor.integer(digits: 2), cursor.consume(0x2D),
              let day = cursor.integer(digits: 2), cursor.consumeAny([0x54, 0x74, 0x20]),
              let hour = cursor.integer(digits: 2), cursor.consume(0x3A),
              let minute = cursor.integer(digits: 2), cursor.consume(0x3A),
              let second = cursor.integer(digits: 2) else { return nil }
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }

        var nanoseconds = 0
        if cursor.consume(0x2E) {
            var digitCount = 0
            while !cursor.atEnd, cursor.bytes[cursor.index] >= 0x30, cursor.bytes[cursor.index] <= 0x39 {
                if digitCount < 9 { nanoseconds = nanoseconds * 10 + Int(cursor.bytes[cursor.index] - 0x30) }
                digitCount += 1
                cursor.index += 1
            }
            guard digitCount > 0 else { return nil }
            if digitCount < 9 { for _ in 0..<(9 - digitCount) { nanoseconds *= 10 } }
        }

        var offsetSeconds = 0
        if cursor.consumeAny([0x5A, 0x7A]) {
            offsetSeconds = 0
        } else {
            let sign: Int
            if cursor.consume(0x2B) { sign = 1 } else if cursor.consume(0x2D) { sign = -1 } else { return nil }
            guard let offsetHour = cursor.integer(digits: 2), cursor.consume(0x3A), let offsetMinute = cursor.integer(digits: 2),
                  offsetHour <= 23, offsetMinute <= 59 else { return nil }
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
        }
        guard cursor.atEnd else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthPrime = (month + 9) % 12
        let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
