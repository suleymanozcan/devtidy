import Darwin
import Foundation
import Testing
@testable import DevTidyCore

/// Read-only against the real kernel: scans this very test process and a loopback socket the test opens itself.
@Suite struct S1LibprocLiveTests {

    /// Binds 127.0.0.1:0, listens, connects a client and accepts it; runs `body` with the listening port; closes all fds.
    private func withLoopbackListener<T>(_ body: (UInt16) async throws -> T) async throws -> T {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        try #require(server >= 0)
        defer { close(server) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, length) }
        }
        try #require(bound == 0)
        try #require(listen(server, 4) == 0)

        var actual = sockaddr_in()
        var actualLength = length
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &actualLength) }
        }
        try #require(named == 0)
        let port = UInt16(bigEndian: actual.sin_port)

        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        var target = actual
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
        }
        try #require(connected == 0)
        let accepted = accept(server, nil, nil)
        try #require(accepted >= 0)
        defer { close(accepted) }

        return try await body(port)
    }

    private func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func scanContainsThisProcessWithItsOwnUid() async throws {
        let scanner = LiveProcessScanner()
        let snapshot = await scanner.snapshot(.standard)
        #expect(snapshot.selfPID == getpid())
        let me = try #require(snapshot.nodes[getpid()])
        #expect(me.uid == getuid())
        #expect(me.parentPID == getppid())
        #expect(me.pgid == getpgrp())
        #expect(!me.name.isEmpty)
        #expect(snapshot.nodes.values.allSatisfy { $0.uid == getuid() })     // never another uid (ENV G3)
        #expect(snapshot.nodes.values.allSatisfy { $0.identity.startSeconds > 0 })
    }

    @Test func aLoopbackListenerAndItsAcceptedConnectionAreSeen() async throws {
        try await withLoopbackListener { port in
            let snapshot = await LiveProcessScanner().snapshot(.standard)
            let ports = try #require(snapshot.listeners[getpid()])
            let mine = try #require(ports.first { $0.port == port })
            #expect(mine.scope == .loopback)
            #expect(mine.establishedConnections == 1)
            #expect(mine.ownerPID == getpid())
            #expect(ports.filter { $0.port == port }.count == 1)        // deduplicated by (pid, port)
        }
    }

    @Test func listenerOwnersGetExecutableArgumentsAndWorkingDirectory() async throws {
        try await withLoopbackListener { _ in
            let snapshot = await LiveProcessScanner().snapshot(.standard)
            let me = try #require(snapshot.nodes[getpid()])
            #expect(me.executablePath?.isEmpty == false)
            #expect(me.arguments?.isEmpty == false)
            let cwd = try #require(me.workingDirectory)
            #expect(canonical(cwd) == canonical(FileManager.default.currentDirectoryPath))
            // Detail is limited to listener owners and their ancestors (≤ 12 hops) under `.standard`.
            var detailed = Set<Int32>()
            for owner in snapshot.listeners.keys {
                detailed.insert(owner)
                for ancestor in snapshot.ancestors(of: owner, maxHops: 12) { detailed.insert(ancestor.pid) }
            }
            for node in snapshot.nodes.values where !detailed.contains(node.pid) {
                #expect(node.arguments == nil && node.workingDirectory == nil)
            }
            // The executable path is read for every own-uid process: the browser / app-bundle rules need it for descendants.
            #expect(snapshot.nodes.values.contains { !detailed.contains($0.pid) && $0.executablePath != nil })
        }
    }

    @Test func fullDetailAddsTheWorkingDirectoryOfEveryNode() async throws {
        let snapshot = await LiveProcessScanner().snapshot(.full)
        let me = try #require(snapshot.nodes[getpid()])
        #expect(me.workingDirectory != nil)
        let withCWD = snapshot.nodes.values.filter { $0.workingDirectory != nil }.count
        #expect(withCWD > 1)
    }

    @Test func secondScanGivesCpuPercentAfterBurningCpu() async throws {
        let scanner = LiveProcessScanner(minimumCPUWindowNanoseconds: 0)
        let first = await scanner.snapshot(.standard)
        #expect(first.nodes[getpid()]?.cpuPercent == nil)       // nil on first sight

        let deadline = Libproc.uptimeNanoseconds() + 60_000_000
        var sink = 0.0
        while Libproc.uptimeNanoseconds() < deadline { sink += sin(sink + 1) }
        #expect(sink.isFinite)

        let second = await scanner.snapshot(.standard)
        let percent = try #require(second.nodes[getpid()]?.cpuPercent)
        #expect(percent > 0)
        #expect(second.nodes[getpid()]!.cpuTimeNanoseconds >= first.nodes[getpid()]!.cpuTimeNanoseconds)
    }

    @Test func extraSnapshotsInsideTheWindowKeepTheBaselineAndTheLastMeasuredRate() async throws {
        let uptime = ManualUptime()
        let scanner = LiveProcessScanner(minimumCPUWindowNanoseconds: 1_000_000_000, uptime: { uptime.now })
        uptime.now = 10_000_000_000
        let first = await scanner.snapshot(.standard)
        #expect(first.nodes[getpid()]?.cpuPercent == nil)

        let deadline = Libproc.uptimeNanoseconds() + 60_000_000
        var sink = 0.0
        while Libproc.uptimeNanoseconds() < deadline { sink += sin(sink + 1) }
        #expect(sink.isFinite)

        uptime.now = 10_100_000_000                        // 0.1 s after the baseline: inside the 1 s window
        let early = await scanner.snapshot(.standard)
        #expect(early.nodes[getpid()]?.cpuPercent == nil)  // no rate over a 100 ms gap, and the baseline stays put

        uptime.now = 12_000_000_000                        // 2 s after the ORIGINAL baseline
        let late = await scanner.snapshot(.standard)
        let percent = try #require(late.nodes[getpid()]?.cpuPercent)
        let cpuDelta = late.nodes[getpid()]!.cpuTimeNanoseconds - first.nodes[getpid()]!.cpuTimeNanoseconds
        #expect(percent == Double(cpuDelta) / 2_000_000_000 * 100)

        uptime.now = 12_050_000_000                        // another extra snapshot: reuses the rate, does not recompute it
        let again = await scanner.snapshot(.standard)
        #expect(again.nodes[getpid()]?.cpuPercent == percent)
    }

    @Test func footprintNonZeroForSelf() async throws {
        let footprint = try #require(Libproc.rusageFootprint(getpid()))
        #expect(footprint > 0)
        let snapshot = await LiveProcessScanner().snapshot(.standard)
        #expect(try #require(snapshot.nodes[getpid()]).memoryBytes > 0)
    }

    @Test func groupPIDsOfTheOwnGroupContainSelf() {
        let pids = Libproc.groupPIDs(getpgrp())
        #expect(pids.contains(getpid()))
        #expect(pids == pids.sorted())
        #expect(Libproc.groupPIDs(0).isEmpty)
        #expect(Libproc.groupPIDs(-5).isEmpty)
    }

    @Test func darwinSignalerReadsIdentityAndRefusesReservedTargetsWithoutSignalling() throws {
        let signaler = DarwinSignaler()
        let identity = try #require(signaler.identity(of: getpid()))
        #expect(identity.uid == getuid())
        #expect(identity.identity.pid == getpid())
        #expect(identity.identity.startSeconds > 0)
        #expect(signaler.identity(of: 0) == nil)
        #expect(signaler.identity(of: -1) == nil)
        // K7 / K1 / K11 backstops. Signal 0 only, so even a broken guard could not hurt anyone.
        for pid in [Int32(-1), 0, 1] { #expect(signaler.send(0, to: pid) == EINVAL) }
        for pgid in [Int32(-1), 0, 1] { #expect(signaler.sendToGroup(0, pgid: pgid) == EINVAL) }
        #expect(signaler.send(0, to: getpid()) == EPERM)
        #expect(signaler.sendToGroup(0, pgid: getpgrp()) == EPERM)
        #expect(signaler.ownPGID == getpgrp())
    }

    @Test func darwinSignalerTellsAnExitedProcessFromALiveOneAndReadsAnyParent() async throws {
        let signaler = DarwinSignaler()
        #expect(!signaler.isDefinitelyGone(getpid()))
        #expect(!signaler.isDefinitelyGone(0) && !signaler.isDefinitelyGone(1))       // reserved pids are never "gone"
        #expect(signaler.parentPID(of: getpid()) == getppid())

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()                                                        // exited and reaped: ESRCH from here on
        #expect(signaler.isDefinitelyGone(child.processIdentifier))
        #expect(signaler.parentPID(of: child.processIdentifier) == nil)

        // An exited child its parent has not reaped yet is a zombie: `proc_pidinfo` cannot see it and `kill(pid, 0)` still succeeds,
        // but it is provably gone for the terminator (nothing left to signal, nothing left to wait for).
        let zombie = try S1Spawner.spawnGroupLeader(script: "exit 0")
        defer { var status: Int32 = 0; _ = waitpid(zombie, &status, 0) }
        var attempts = 0
        while !signaler.isDefinitelyGone(zombie), attempts < 200 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(signaler.isDefinitelyGone(zombie))
        #expect(signaler.identity(of: zombie) == nil)
    }
}

/// A settable uptime clock for the scanner under test: the window logic runs on virtual time, only the CPU counters are real.
final class ManualUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var now: UInt64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
