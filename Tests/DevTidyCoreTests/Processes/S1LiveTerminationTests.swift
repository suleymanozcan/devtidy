import Darwin
import Foundation
import Testing
@testable import DevTidyCore

/// The ONLY real signals in the S1 suite, and only ever to processes this test spawned itself: a `/bin/sleep`, and a
/// `/bin/sh` that leads its own process group with two `/bin/sleep` children. Nothing else on the machine is touched.
@Suite struct S1LiveTerminationTests {
    private var patientPolicy: TerminationPolicy {
        var policy = TerminationPolicy()
        policy.graceSeconds = 5
        policy.killWaitSeconds = 2
        policy.pollMilliseconds = 20
        return policy
    }

    @Test func terminatesOnlyTheSleepChildThisTestSpawned() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["300"]
        try child.run()
        let pid = child.processIdentifier
        defer { if child.isRunning { child.terminate() } }        // SIGTERM to our own child only, if the test fails early

        let scanner = LiveProcessScanner()
        let snapshot = await scanner.snapshot(.standard)
        let node = try #require(snapshot.nodes[pid])
        #expect(node.uid == getuid())
        #expect(node.parentPID == getpid())

        let server = S1Servers.make(from: snapshot, root: pid, groupKillEligible: false)
        let audit = S1RecordingAudit()
        let report = try await TreeTerminator(scanner: scanner, audit: audit).terminate(server, policy: patientPolicy)

        #expect(report.terminated == [pid])
        #expect(report.forced.isEmpty && report.survivors.isEmpty && report.skipped.isEmpty)
        #expect(!report.usedGroupSignal)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
        #expect(audit.events.first?.result == "ok")

        // Idempotent: the very same server again is "already gone" and signals nothing.
        let again = try await TreeTerminator(scanner: scanner, audit: audit).terminate(server, policy: patientPolicy)
        #expect(again.wasAlreadyGone)
    }

    @Test func stopsAWholeProcessGroupWithOneVerifiedGroupSignal() async throws {
        let leader = try S1Spawner.spawnGroupLeader(script: "/bin/sleep 300 & /bin/sleep 300 & wait")
        var reaped = false
        defer { if !reaped { S1Spawner.killOwnGroupAndReap(leader) } }

        let scanner = LiveProcessScanner()
        var snapshot = await scanner.snapshot(.standard)
        var attempts = 0
        while snapshot.descendants(of: leader).count < 2, attempts < 100 {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = await scanner.snapshot(.standard)
            attempts += 1
        }
        let leaderNode = try #require(snapshot.nodes[leader])
        let children = snapshot.descendants(of: leader).map(\.pid)
        try #require(children.count == 2)
        #expect(leaderNode.pgid == leader)
        #expect(Libproc.groupPIDs(leader).sorted() == ([leader] + children).sorted())

        let server = S1Servers.make(from: snapshot, root: leader, groupKillEligible: true)
        let report = try await TreeTerminator(scanner: scanner, audit: S1RecordingAudit()).terminate(server, policy: patientPolicy)

        #expect(report.usedGroupSignal)
        #expect(Set(report.terminated) == Set([leader] + children))
        #expect(report.forced.isEmpty && report.survivors.isEmpty)

        var status: Int32 = 0
        #expect(waitpid(leader, &status, 0) == leader)
        reaped = true
        #expect(status & 0x7F == SIGTERM)       // the shell died of the group SIGTERM, it did not exit on its own
        let signaler = DarwinSignaler()
        for child in children { #expect(signaler.identity(of: child) == nil) }
    }

    @Test func aProcessThatIgnoresSigtermIsKilledAfterTheGracePeriod() async throws {
        // `trap '' TERM` makes the shell ignore SIGTERM; its `sleep` child dies on SIGTERM. Short grace keeps the test quick.
        let leader = try S1Spawner.spawnGroupLeader(script: "trap '' TERM; while :; do /bin/sleep 1; done")
        var reaped = false
        defer { if !reaped { S1Spawner.killOwnGroupAndReap(leader) } }

        let scanner = LiveProcessScanner()
        var snapshot = await scanner.snapshot(.standard)
        var attempts = 0
        while snapshot.nodes[leader] == nil, attempts < 100 {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = await scanner.snapshot(.standard)
            attempts += 1
        }
        // Let the shell install its trap before the first signal arrives.
        try await Task.sleep(for: .milliseconds(300))
        snapshot = await scanner.snapshot(.standard)
        let server = S1Servers.make(from: snapshot, root: leader, groupKillEligible: false)

        var policy = TerminationPolicy()
        policy.graceSeconds = 0.5
        policy.killWaitSeconds = 3
        policy.pollMilliseconds = 20
        let started = ContinuousClock.now
        let report = try await TreeTerminator(scanner: scanner, audit: S1RecordingAudit()).terminate(server, policy: policy)
        let elapsed = ContinuousClock.now - started

        #expect(report.survivors.isEmpty)
        #expect(report.forced.contains(leader))                     // needed SIGKILL
        #expect(elapsed >= .milliseconds(500))                      // K8: not before the grace period
        var status: Int32 = 0
        #expect(waitpid(leader, &status, 0) == leader)
        reaped = true
        #expect(status & 0x7F == SIGKILL)
    }
}

/// Spawns children of THIS process only. The group leader gets its own process group (`POSIX_SPAWN_SETPGROUP`), so a group
/// signal can never reach the test runner.
enum S1Spawner {
    struct SpawnError: Error { let code: Int32 }

    static func spawnGroupLeader(script: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw SpawnError(code: errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        // Never inherit the runner's signal state: a blocked or ignored SIGTERM would be inherited across exec and the
        // children would silently survive the very signal this suite verifies.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        _ = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        _ = posix_spawnattr_setsigmask(&attributes, &emptyMask)
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        _ = posix_spawnattr_setpgroup(&attributes, 0)

        let arguments = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]

        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", nil, &attributes, argv, &environment)
        guard status == 0 else { throw SpawnError(code: status) }
        return pid
    }

    /// Cleanup for a leader spawned by `spawnGroupLeader` that has NOT been reaped yet (an unreaped zombie keeps its pid
    /// reserved, so `-leader` cannot name anybody else's group).
    static func killOwnGroupAndReap(_ leader: pid_t) {
        guard leader > 1 else { return }
        _ = kill(-leader, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(leader, &status, 0)
    }
}
