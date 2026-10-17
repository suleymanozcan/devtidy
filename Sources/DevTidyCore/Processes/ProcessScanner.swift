import Darwin
import Foundation

/// libproc-based scanner (design §4.2). One pass per call: bsdinfo for every pid, then task info / memory / sockets
/// for own-uid pids, then argv + cwd only for listener owners and their ancestors. Every own-uid process also gets its
/// executable path (one `proc_pidpath`), which the browser / app-bundle rules need for tree descendants. ≈ 3–6 ms.
///
/// Stateful only for CPU%: `previous` holds the cumulative CPU time per `ProcessIdentity` at the CPU *baseline*;
/// identities absent from a scan are dropped from it. The baseline only advances once it is at least
/// `minimumCPUWindow` old: extra snapshots taken by other callers (the terminator's 1 s re-snapshots, the activity checker)
/// reuse the percentage measured over a proper window instead of producing a noisy rate over a few milliseconds and
/// stealing the poller's baseline (P2-2). Another uid's processes are never read beyond the initial bsdinfo uid filter
/// (ENV G3).
public actor LiveProcessScanner: ProcessScanning {
    private struct CPUSample {
        let cpuNanoseconds: UInt64
        let wallNanoseconds: UInt64
        /// Rate measured when this sample became the baseline; nil for a first sighting.
        let percent: Double?
    }

    private struct RawProcess {
        let identity: ProcessIdentity
        let parentPID: Int32
        let pgid: Int32
        let uid: UInt32
        let name: String
        let hasControllingTTY: Bool
    }

    private struct Metrics {
        var cpuNanoseconds: UInt64 = 0
        var wallNanoseconds: UInt64 = 0
        var memoryBytes: UInt64 = 0
        var cpuSampled = false
    }

    private var previous: [ProcessIdentity: CPUSample] = [:]
    private let minimumCPUWindow: UInt64
    private let uptime: @Sendable () -> UInt64

    public init() {
        self.minimumCPUWindow = 1_000_000_000
        self.uptime = { Libproc.uptimeNanoseconds() }
    }

    /// Tests drive the clocks and the window.
    init(minimumCPUWindowNanoseconds: UInt64, uptime: @escaping @Sendable () -> UInt64 = { Libproc.uptimeNanoseconds() }) {
        self.minimumCPUWindow = minimumCPUWindowNanoseconds
        self.uptime = uptime
    }

    public func snapshot(_ detail: ScanDetail) async -> ProcessSnapshot {
        scan(detail)
    }

    // MARK: Scan

    private func scan(_ detail: ScanDetail) -> ProcessSnapshot {
        let ownUID = getuid()

        // 1. Own-uid processes (zombies excluded: they cannot be signalled and have no sockets).
        var raws: [Int32: RawProcess] = [:]
        for pid in Libproc.listPids() {
            guard let bsd = Libproc.bsdInfo(pid), bsd.pbi_uid == ownUID, bsd.pbi_status != Libproc.zombieStatus else { continue }
            raws[pid] = RawProcess(
                identity: ProcessIdentity(pid: pid,
                                          startSeconds: Int64(truncatingIfNeeded: bsd.pbi_start_tvsec),
                                          startMicroseconds: Int64(truncatingIfNeeded: bsd.pbi_start_tvusec)),
                parentPID: Int32(truncatingIfNeeded: bsd.pbi_ppid),
                pgid: Int32(truncatingIfNeeded: bsd.pbi_pgid),
                uid: bsd.pbi_uid,
                name: Libproc.comm(bsd),
                hasControllingTTY: bsd.e_tdev != UInt32.max)
        }

        // 2./3. Task info, memory and sockets.
        var metrics: [Int32: Metrics] = [:]
        metrics.reserveCapacity(raws.count)
        var listeners: [Int32: [ListeningPort]] = [:]
        for pid in raws.keys {
            var m = Metrics()
            if let task = Libproc.taskInfo(pid) {
                m.cpuNanoseconds = Libproc.nanoseconds(fromMachTicks: task.pti_total_user &+ task.pti_total_system)
                m.wallNanoseconds = uptime()
                m.cpuSampled = true
                m.memoryBytes = Libproc.rusageFootprint(pid) ?? task.pti_resident_size
            } else {
                m.memoryBytes = Libproc.rusageFootprint(pid) ?? 0
            }
            metrics[pid] = m

            let sockets = Libproc.sockets(pid: pid)
            if !sockets.listening.isEmpty {
                listeners[pid] = Self.mergedListeners(pid: pid, sockets: sockets)
            }
        }

        // 4. Detail pass: listener owners and ≤ 12 ancestors of each get exe + argv + cwd.
        var detailPIDs = Set<Int32>()
        for pid in listeners.keys {
            detailPIDs.insert(pid)
            var current = raws[pid]?.parentPID ?? 0
            var hops = 0
            while hops < 12, current > 0, let parent = raws[current] {
                detailPIDs.insert(current)
                current = parent.parentPID
                hops += 1
            }
        }

        // 5. Nodes + CPU%.
        var nodes: [Int32: ProcessNode] = [:]
        nodes.reserveCapacity(raws.count)
        var nextPrevious: [ProcessIdentity: CPUSample] = [:]
        nextPrevious.reserveCapacity(raws.count)
        for (pid, raw) in raws {
            let m = metrics[pid] ?? Metrics()
            let executablePath = Libproc.pidPath(pid)
            var arguments: [String]?
            var workingDirectory: String?
            if detailPIDs.contains(pid) {
                arguments = Libproc.argv(pid)
                workingDirectory = Libproc.cwd(pid)
            } else if detail == .full {
                workingDirectory = Libproc.cwd(pid)
            }

            var cpuPercent: Double?
            if m.cpuSampled {
                let fresh = CPUSample(cpuNanoseconds: m.cpuNanoseconds, wallNanoseconds: m.wallNanoseconds, percent: nil)
                if let last = previous[raw.identity], m.wallNanoseconds > last.wallNanoseconds, m.cpuNanoseconds >= last.cpuNanoseconds {
                    let window = m.wallNanoseconds - last.wallNanoseconds
                    if window < minimumCPUWindow {
                        // Too close to the baseline for a meaningful rate: keep both the baseline and its percentage.
                        cpuPercent = last.percent
                        nextPrevious[raw.identity] = last
                    } else {
                        let measured = Double(m.cpuNanoseconds - last.cpuNanoseconds) / Double(window) * 100
                        cpuPercent = measured
                        nextPrevious[raw.identity] = CPUSample(cpuNanoseconds: m.cpuNanoseconds,
                                                               wallNanoseconds: m.wallNanoseconds, percent: measured)
                    }
                } else {
                    nextPrevious[raw.identity] = fresh      // first sighting, or a counter / clock that went backwards
                }
            }

            nodes[pid] = ProcessNode(
                identity: raw.identity,
                parentPID: raw.parentPID,
                pgid: raw.pgid,
                uid: raw.uid,
                name: raw.name,
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory,
                hasControllingTTY: raw.hasControllingTTY,
                memoryBytes: m.memoryBytes,
                cpuTimeNanoseconds: m.cpuNanoseconds,
                cpuPercent: cpuPercent)
        }
        previous = nextPrevious

        return ProcessSnapshot(takenAt: Date(), selfPID: getpid(), nodes: nodes, listeners: listeners)
    }

    // MARK: Listener merge

    /// Dedupe by port (dup'd fds, v4 + v6 twins — ENV §1.3); the widest scope wins and every socket's bind address is kept;
    /// ascending port order.
    private static func mergedListeners(pid: Int32, sockets: Libproc.SocketScan) -> [ListeningPort] {
        func rank(_ scope: BindScope) -> Int {
            switch scope {
            case .allInterfaces: 2
            case .other: 1
            case .loopback: 0
            }
        }
        var scopeByPort: [UInt16: BindScope] = [:]
        var bindsByPort: [UInt16: Set<BindAddress>] = [:]
        for socket in sockets.listening {
            if let address = socket.address { bindsByPort[socket.port, default: []].insert(address) }
            if let existing = scopeByPort[socket.port], rank(existing) >= rank(socket.scope) { continue }
            scopeByPort[socket.port] = socket.scope
        }
        return scopeByPort.sorted { $0.key < $1.key }.map { entry in
            ListeningPort(port: entry.key, ownerPID: pid, scope: entry.value, binds: bindsByPort[entry.key] ?? [],
                          establishedConnections: sockets.established[entry.key] ?? 0)
        }
    }
}
