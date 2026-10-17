import Darwin
import Foundation
@testable import DevTidyCore

/// A scripted process table that is BOTH the scanner and the signaler of a `TreeTerminator` under test. It records every
/// signal, every sleep and every snapshot in order. It never touches a real process.
final class S1World: Signaling, ProcessScanning, @unchecked Sendable {
    enum Reaction {
        case diesOnTerm      // exits on SIGTERM or SIGKILL
        case diesOnKill      // ignores SIGTERM
        case immortal        // ignores both
    }

    enum Event: Equatable {
        case signal(Int32, pid: Int32)
        case group(Int32, pgid: Int32)
        case sleep(milliseconds: Int)
        case snapshot
    }

    private struct Entry {
        var node: ProcessNode
        var reaction: Reaction
        var alive = true
    }

    let selfPID: Int32
    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]
    private var log: [Event] = []
    private var snapshotCount = 0
    private var spawnAtSnapshot: [Int: [(node: ProcessNode, reaction: Reaction)]] = [:]
    private var identityOverrides: [Int32: ProcessIdentity] = [:]
    private var uidOverrides: [Int32: UInt32] = [:]
    private var permissionDenied: Set<Int32> = []
    private var unreadable: Set<Int32> = []
    private var ownGroup: Int32

    init(selfPID: Int32 = S1Fixtures.selfPID, ownPGID: Int32? = nil, nodes: [ProcessNode], reaction: Reaction = .diesOnTerm,
         reactions: [Int32: Reaction] = [:]) {
        self.selfPID = selfPID
        self.ownGroup = ownPGID ?? selfPID
        for node in nodes { entries[node.pid] = Entry(node: node, reaction: reactions[node.pid] ?? reaction) }
    }

    // MARK: Scripting

    func add(_ node: ProcessNode, reaction: Reaction = .diesOnTerm) {
        lock.lock(); defer { lock.unlock() }
        entries[node.pid] = Entry(node: node, reaction: reaction)
    }

    /// Adds `node` right before the `callNumber`-th (1-based) `snapshot(_:)` call is answered.
    func spawn(_ node: ProcessNode, atSnapshotCall callNumber: Int, reaction: Reaction = .diesOnTerm) {
        lock.lock(); defer { lock.unlock() }
        spawnAtSnapshot[callNumber, default: []].append((node, reaction))
    }

    /// Makes `identity(of:)` report a different start time for `pid` (the snapshot is unaffected): PID reuse after the scan.
    func overrideIdentity(of pid: Int32, startSeconds: Int64) {
        lock.lock(); defer { lock.unlock() }
        identityOverrides[pid] = ProcessIdentity(pid: pid, startSeconds: startSeconds, startMicroseconds: 0)
    }

    /// Alive, but `identity(of:)` cannot read it (failed `proc_pidinfo`): the F-9 "unreadable live process" case.
    func makeUnreadable(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        unreadable.insert(pid)
    }

    func overrideUID(of pid: Int32, to uid: UInt32) {
        lock.lock(); defer { lock.unlock() }
        uidOverrides[pid] = uid
    }

    func denyPermission(for pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        permissionDenied.insert(pid)
    }

    func setOwnPGID(_ pgid: Int32) {
        lock.lock(); defer { lock.unlock() }
        ownGroup = pgid
    }

    /// Replaces the node of `pid` by one with another start time: PID reuse visible to the scanner too.
    func reusePID(_ pid: Int32, startSeconds: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid] else { return }
        let n = entry.node
        entries[pid]?.node = ProcessNode(
            identity: ProcessIdentity(pid: pid, startSeconds: startSeconds, startMicroseconds: 0),
            parentPID: n.parentPID, pgid: n.pgid, uid: n.uid, name: n.name, executablePath: n.executablePath,
            arguments: n.arguments, workingDirectory: n.workingDirectory, hasControllingTTY: n.hasControllingTTY,
            memoryBytes: n.memoryBytes, cpuTimeNanoseconds: n.cpuTimeNanoseconds, cpuPercent: n.cpuPercent)
    }

    // MARK: Observation

    var events: [Event] { eventLog() }
    /// Signals only (individual and group), in order.
    var signalEvents: [Event] {
        var out: [Event] = []
        for event in eventLog() {
            switch event {
            case .signal, .group: out.append(event)
            case .sleep, .snapshot: break
            }
        }
        return out
    }

    /// Every pid that received an individual signal.
    var signalledPIDs: [Int32] {
        var out: [Int32] = []
        for event in eventLog() {
            if case .signal(_, let pid) = event { out.append(pid) }
        }
        return out
    }

    var snapshotCalls: Int { count() }

    func isAlive(_ pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[pid]?.alive ?? false
    }

    /// Current table as a snapshot WITHOUT counting as a scanner call (used to build `DevServer`s).
    func peek() -> ProcessSnapshot {
        lock.lock(); defer { lock.unlock() }
        return buildSnapshotLocked()
    }

    var sleepClosure: @Sendable (Duration) async -> Void {
        { [self] duration in self.recordSleep(duration) }
    }

    private func eventLog() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return snapshotCount
    }

    private func recordSleep(_ duration: Duration) {
        let parts = duration.components
        let milliseconds = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
        lock.lock(); defer { lock.unlock() }
        log.append(.sleep(milliseconds: milliseconds))
    }

    // MARK: ProcessScanning

    func snapshot(_ detail: ScanDetail) async -> ProcessSnapshot { answerSnapshot() }

    private func answerSnapshot() -> ProcessSnapshot {
        lock.lock(); defer { lock.unlock() }
        snapshotCount += 1
        for (node, reaction) in spawnAtSnapshot[snapshotCount] ?? [] { entries[node.pid] = Entry(node: node, reaction: reaction) }
        log.append(.snapshot)
        return buildSnapshotLocked()
    }

    /// Own-uid, alive processes only — exactly what the live scanner returns.
    private func buildSnapshotLocked() -> ProcessSnapshot {
        var nodes: [Int32: ProcessNode] = [:]
        for (pid, entry) in entries where entry.alive && entry.node.uid == getuid() { nodes[pid] = entry.node }
        return ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 1_760_000_000), selfPID: selfPID, nodes: nodes, listeners: [:])
    }

    // MARK: Signaling

    func identity(of pid: Int32) -> (identity: ProcessIdentity, uid: UInt32)? {
        lock.lock(); defer { lock.unlock() }
        guard !unreadable.contains(pid) else { return nil }
        guard let entry = entries[pid], entry.alive else { return nil }
        return (identityOverrides[pid] ?? entry.node.identity, uidOverrides[pid] ?? entry.node.uid)
    }

    func isDefinitelyGone(_ pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid] else { return true }
        return !entry.alive
    }

    /// Any uid: the world holds root-owned processes (`login`) that the own-uid snapshot never shows.
    func parentPID(of pid: Int32) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid], entry.alive else { return nil }
        return entry.node.parentPID
    }

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        log.append(.signal(signal, pid: pid))
        if permissionDenied.contains(pid) { return EPERM }
        guard entries[pid]?.alive == true else { return ESRCH }
        deliverLocked(signal, to: pid)
        return 0
    }

    func sendToGroup(_ signal: Int32, pgid: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        log.append(.group(signal, pgid: pgid))
        let members = entries.filter { $0.value.alive && $0.value.node.pgid == pgid }.map(\.key)
        if members.isEmpty { return ESRCH }
        if !permissionDenied.isDisjoint(with: members) { return EPERM }
        for pid in members { deliverLocked(signal, to: pid) }
        return 0
    }

    func groupPIDs(_ pgid: Int32) -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.value.alive && $0.value.node.pgid == pgid }.map(\.key).sorted()
    }

    var ownPGID: Int32 {
        lock.lock(); defer { lock.unlock() }
        return ownGroup
    }

    private func deliverLocked(_ signal: Int32, to pid: Int32) {
        guard let entry = entries[pid], entry.alive else { return }
        switch (signal, entry.reaction) {
        case (SIGTERM, .diesOnTerm): entries[pid]?.alive = false
        case (SIGKILL, .diesOnTerm), (SIGKILL, .diesOnKill): entries[pid]?.alive = false
        default: break
        }
    }
}

/// Records audit events; always writable.
final class S1RecordingAudit: AuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AuditEvent] = []

    var events: [AuditEvent] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func append(_ event: AuditEvent) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event)
    }

    func record(_ event: AuditEvent) async { append(event) }
    func isWritable() async -> Bool { true }
}
