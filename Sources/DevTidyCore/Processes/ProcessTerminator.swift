import Darwin
import Foundation

/// Stops a dev server's whole process tree: SIGTERM → grace → SIGKILL, with a PID-reuse guard (design §4.5, K1–K11).
///
/// Safety model — nothing is signalled unless ALL of these hold at the instant of the signal:
/// * the target is in the member set: `{root} ∪ descendants(root) ∪ identity-matched original members`, grown only by
///   children of *living* members (K2, K4);
/// * its live identity (pid + start time) equals the recorded one (K3) and its uid equals `getuid()` (K6);
/// * it is not pid ≤ 1, DevTidy itself or an ancestor of DevTidy (K1);
/// * for a group signal: `root.pgid == root.pid`, not DevTidy's own group (K11), and EVERY pid in `PROC_PGRP_ONLY(pgid)` — all
///   uids — is a verified member (K5). A live process whose info cannot be read is not "exited": it forces the individual
///   path (F-9). `kill(-pgid)` with pgid ≤ 1 is impossible (K7);
/// * the root is never a shell, terminal, IDE, agent, browser or app bundle (F-3), DevTidy's whole parent chain is protected
///   even behind other-uid processes (F-8), and browser / app-bundle / terminal / IDE / agent subtrees below the root are
///   never admitted (QA F6, N-5; a listening server process is exempt from the name rule).
/// `EPERM` is reported and never retried or escalated (K10). No shell, `killall`, `pkill`, `lsof` or `ps` (K9).
public actor TreeTerminator: ProcessTerminating {
    private let scanner: any ProcessScanning
    private let signaler: any Signaling
    private let audit: any AuditLogging
    private let pause: @Sendable (Duration) async -> Void

    public init(scanner: any ProcessScanning, audit: any AuditLogging) {
        self.scanner = scanner
        self.signaler = DarwinSignaler()
        self.audit = audit
        self.pause = { duration in await TreeTerminator.sleepUninterrupted(duration) }
    }

    /// Tests inject a recording signaler and an instant `sleep`.
    init(scanner: any ProcessScanning, signaler: any Signaling, audit: any AuditLogging,
         sleep: @escaping @Sendable (Duration) async -> Void) {
        self.scanner = scanner
        self.signaler = signaler
        self.audit = audit
        self.pause = sleep
    }

    /// Detached so that cancelling the caller never shortens the SIGTERM → SIGKILL grace (K8).
    private static func sleepUninterrupted(_ duration: Duration) async {
        let nap = Task.detached { try? await Task.sleep(for: duration) }
        _ = await nap.value
    }

    // MARK: Run state

    private struct Run {
        let server: DevServer
        let rootID: ProcessIdentity
        let rootPGID: Int32
        let selfPID: Int32
        let protectedPIDs: Set<Int32>
        /// Pids of the listening processes that make this tree a server: never refused for their name alone (N-5).
        let servingPIDs: Set<Int32>
        let ownUID: UInt32
        let gracePolls: Int

        /// Members in signalling order: root first, then BFS order, later additions appended.
        var order: [Int32] = []
        var identities: [Int32: ProcessIdentity] = [:]
        /// Poll tick at which SIGTERM was delivered to a pid; SIGKILL is due `gracePolls` ticks later (K8, per process).
        var termTick: [Int32: Int] = [:]
        var killed: Set<Int32> = []
        /// Never signalled again: EPERM / other errno (K10) or a failed pre-signal check.
        var denied: Set<Int32> = []
        var gone: Set<Int32> = []
        var reused: Set<Int32> = []
        var skips: [SignalSkip] = []
        var signals: [String] = []
        var usedGroup = false
        var groupFinished = false
        var tick = 0
        var lastKillTick: Int?

        mutating func skip(_ pid: Int32, _ reason: String) {
            let entry = SignalSkip(pid: pid, reason: reason)
            if !skips.contains(entry) { skips.append(entry) }
        }

        /// Adds `node` to the member set unless it is protected (K1), a browser / app-bundle process (QA F6) or a terminal,
        /// IDE or agent below the root (N-5): such a node is never signalled and, because the caller does not descend into a
        /// refused node, neither is anything below it. The caller guarantees the pid is not yet known.
        mutating func admit(_ node: ProcessNode) -> Bool {
            if node.pid <= 1 || node.pid == selfPID || protectedPIDs.contains(node.pid) {
                skip(node.pid, "protected")
                return false
            }
            if ProcessNames.isBrowserOrAppBundle(node) {
                skip(node.pid, "app-bundle")
                return false
            }
            if ProcessNames.isSparedBelowRoot(node, serving: servingPIDs) {
                skip(node.pid, "protected-role")
                return false
            }
            identities[node.pid] = node.identity
            order.append(node.pid)
            return true
        }

        func isDue(_ pid: Int32) -> Bool {
            guard let delivered = termTick[pid] else { return false }
            return tick - delivered >= gracePolls
        }

        mutating func markDelivered(_ signal: Int32, to pid: Int32) {
            if signal == SIGKILL {
                killed.insert(pid)
                lastKillTick = tick
            } else if termTick[pid] == nil {
                termTick[pid] = tick
            }
        }
    }

    private enum Verdict {
        case ok
        case gone
        case skip(String)
    }

    // MARK: terminate

    public func terminate(_ server: DevServer, policy: TerminationPolicy) async throws -> TerminationReport {
        let rootID = server.root.identity
        let first = await scanner.snapshot(.standard)
        // K1 + F-8: DevTidy's ancestry is protected all the way up, including ancestors the own-uid snapshot cannot see
        // (`login`, `sudo`), so `iTermServer` / `iTerm2` behind a root-owned `login` stay protected.
        let protectedPIDs = TreeRootResolver.protectedPIDs(in: first).union(liveAncestry(of: first.selfPID))

        // K1: refuse before anything else.
        if let tag = Self.refusalTag(root: rootID.pid, selfPID: first.selfPID, protectedPIDs: protectedPIDs) {
            await audit.record(AuditEvent(time: Date(), kind: .terminate, subject: Self.subject(rootID),
                                          result: "refused:\(tag)", detail: [:]))
            throw ProcessTerminationError.refused(tag)
        }

        // K3: the recorded root must still be the same process.
        guard let rootNode = first.node(matching: rootID) else {
            await audit.record(AuditEvent(time: Date(), kind: .terminate, subject: Self.subject(rootID),
                                          result: "gone", detail: ["reason": "root-missing-or-pid-reused"]))
            return TerminationReport(root: rootID, terminated: [], forced: [], survivors: [], skipped: [],
                                     usedGroupSignal: false, wasAlreadyGone: true)
        }

        // F-3 (defence in depth): whatever the resolver decided, a shell / terminal / IDE / agent / browser / app bundle is never
        // a kill root. The recorded node carries the full argv; the live one is checked by name as well. A root that is itself
        // a listening server of this tree is exempt from the EDITOR / IDE NAME rule only (a project binary called `fleet`).
        let rootServes = server.listeners.contains { $0.pid == rootID.pid }
        if let tag = Self.rootRefusalTag(recorded: server.root, live: rootNode, serving: rootServes) {
            await audit.record(AuditEvent(time: Date(), kind: .terminate, subject: Self.subject(rootID),
                                          result: "refused:\(tag)", detail: [:]))
            throw ProcessTerminationError.refused(tag)
        }

        let pollMilliseconds = max(1, policy.pollMilliseconds)
        var run = Run(server: server, rootID: rootID, rootPGID: rootNode.pgid, selfPID: first.selfPID,
                      protectedPIDs: protectedPIDs, servingPIDs: Set(server.listeners.map(\.pid)), ownUID: getuid(),
                      gracePolls: Self.polls(policy.graceSeconds, pollMilliseconds))
        let killPolls = max(1, Self.polls(policy.killWaitSeconds, pollMilliseconds))
        let resnapshotEvery = max(1, 1000 / pollMilliseconds)
        let maxTicks = (run.gracePolls + killPolls) * 3 + resnapshotEvery * 2

        // K2: root, its descendants, and the original members that are still the same process (reparented orphans).
        var seeds: [ProcessNode] = [rootNode]
        for original in server.members where original.identity != rootID {
            if let live = first.node(matching: original.identity) { seeds.append(live) }
        }
        _ = Self.grow(&run, seeds: seeds, in: first)

        // Phase 1 — SIGTERM, group path when allowed, individual signals (root first) for everything else.
        let groupCovered = sendGroup(SIGTERM, run: &run, requireDue: false) ?? []
        for pid in run.order where !groupCovered.contains(pid) {
            sendIndividually(SIGTERM, to: pid, run: &run)
        }

        // Phase 2 — poll; every ~1 s pick up respawned children (K4); SIGKILL each survivor once ITS grace is over (K8).
        while true {
            if run.tick > 0, run.tick % resnapshotEvery == 0 {
                let snapshot = await scanner.snapshot(.standard)
                absorb(&run, snapshot: snapshot)
            }
            let alive = refreshLiveness(&run)
            if alive.isEmpty { break }

            let due = alive.filter { !run.killed.contains($0) && !run.denied.contains($0) && run.isDue($0) }
            if !due.isEmpty {
                let covered = sendGroup(SIGKILL, run: &run, requireDue: true) ?? []
                for pid in due where !covered.contains(pid) {
                    sendIndividually(SIGKILL, to: pid, run: &run)
                }
            }

            let signalable = alive.filter { !run.denied.contains($0) }
            if !signalable.contains(where: { !run.killed.contains($0) }) {
                if signalable.isEmpty { break }   // nothing left that we are allowed to signal
                if let lastKill = run.lastKillTick, run.tick - lastKill >= killPolls { break }
            }
            if run.tick >= maxTicks { break }
            await pause(.milliseconds(pollMilliseconds))
            run.tick += 1
        }

        let remaining = Set(refreshLiveness(&run))
        let forced = run.order.filter { run.killed.contains($0) && !remaining.contains($0) && !run.reused.contains($0) }
        let terminated = run.order.filter {
            !remaining.contains($0) && !run.killed.contains($0) && !run.reused.contains($0)
        }
        let survivors = run.order.filter { remaining.contains($0) }

        await audit.record(AuditEvent(
            time: Date(), kind: .terminate, subject: Self.subject(rootID),
            result: survivors.isEmpty ? "ok" : "survivors",
            detail: Self.auditDetail(run: run, terminated: terminated, forced: forced, survivors: survivors)))

        return TerminationReport(root: rootID, terminated: terminated, forced: forced, survivors: survivors,
                                 skipped: run.skips, usedGroupSignal: run.usedGroup, wasAlreadyGone: false)
    }

    // MARK: Membership

    private static func refusalTag(root: Int32, selfPID: Int32, protectedPIDs: Set<Int32>) -> String? {
        if root <= 1 { return "root-pid-reserved" }
        if root == selfPID { return "root-is-self" }
        if protectedPIDs.contains(root) { return "root-is-self-ancestor" }
        return nil
    }

    /// F-3: roots that must never be signalled even when the resolver (or a forged `DevServer`) names them. Terminals, IDEs,
    /// agents and browsers are matched by name / bundle path; `serving` (the root is a listener of the tree) lifts only the
    /// editor / IDE names (`ProcessNames.isRefusedRootName`), never the terminal, agent, shell, browser or app-bundle rules. An interactive
    /// shell is told from a `sh -c` launcher only by its argv, which the scanner fetches for listener owners and their
    /// ancestors; when neither node carries argv the shell rule cannot be judged and is not applied (the resolver already
    /// excludes interactive shells for every server it builds).
    private static func rootRefusalTag(recorded: ProcessNode, live: ProcessNode, serving: Bool) -> String? {
        if ProcessNames.isRefusedRootName(recorded, serving: serving) || ProcessNames.isRefusedRootName(live, serving: serving) {
            return "root-is-shell-terminal-ide-agent"
        }
        let withArgv = recorded.arguments != nil ? recorded : live
        if withArgv.arguments != nil, ProcessNames.isShell(withArgv), !ProcessNames.hasCommandFlag(withArgv) {
            return "root-is-shell-terminal-ide-agent"
        }
        if ProcessNames.isBrowserOrAppBundle(recorded) || ProcessNames.isBrowserOrAppBundle(live) {
            return "root-is-browser-or-app-bundle"
        }
        return nil
    }

    /// Parent chain of `pid` read live for ALL uids (`pbi_ppid`), nearest first, never including pid ≤ 1.
    private func liveAncestry(of pid: Int32) -> Set<Int32> {
        var out: Set<Int32> = []
        var current = pid
        for _ in 0..<64 {
            guard let parent = signaler.parentPID(of: current), parent > 1, out.insert(parent).inserted else { break }
            current = parent
        }
        return out
    }

    /// Admits each seed (if new) and breadth-first every not-yet-known descendant of it. Returns the newly admitted pids.
    private static func grow(_ run: inout Run, seeds: [ProcessNode], in snapshot: ProcessSnapshot) -> [Int32] {
        var added: [Int32] = []
        for seed in seeds {
            if run.identities[seed.pid] == nil {
                guard run.admit(seed) else { continue }
                added.append(seed.pid)
            }
            var queue = snapshot.childPIDs(of: seed.pid)
            var index = 0
            while index < queue.count {
                let pid = queue[index]
                index += 1
                guard run.identities[pid] == nil, let child = snapshot.nodes[pid] else { continue }
                guard run.admit(child) else { continue }
                added.append(pid)
                queue.append(contentsOf: snapshot.childPIDs(of: pid))
            }
        }
        return added
    }

    /// K4: children of LIVING members (identity-matched in the new snapshot) join the set and get SIGTERM immediately.
    /// Children of dead members, strangers and ancestors never do.
    private func absorb(_ run: inout Run, snapshot: ProcessSnapshot) {
        var seeds: [ProcessNode] = []
        for pid in run.order where !run.gone.contains(pid) && !run.reused.contains(pid) {
            if let identity = run.identities[pid], let node = snapshot.node(matching: identity) { seeds.append(node) }
        }
        for pid in Self.grow(&run, seeds: seeds, in: snapshot) {
            sendIndividually(SIGTERM, to: pid, run: &run)
        }
    }

    /// Members whose live identity still matches; updates `gone` / `reused`.
    private func refreshLiveness(_ run: inout Run) -> [Int32] {
        var alive: [Int32] = []
        for pid in run.order where !run.gone.contains(pid) && !run.reused.contains(pid) {
            guard let live = signaler.identity(of: pid) else {
                if signaler.isDefinitelyGone(pid) {
                    run.gone.insert(pid)
                } else {
                    alive.append(pid)       // alive but unreadable: never reported as exited (F-9); verify() refuses to signal it
                }
                continue
            }
            guard live.identity == run.identities[pid] else {
                run.reused.insert(pid)
                run.skip(pid, "identity-changed")
                continue
            }
            alive.append(pid)
        }
        return alive
    }

    // MARK: Signalling

    /// The single pre-signal gate for one pid (K1, K2, K3, K6).
    private func verify(_ pid: Int32, in run: Run) -> Verdict {
        if pid <= 1 || pid == run.selfPID || run.protectedPIDs.contains(pid) { return .skip("protected") }
        guard let recorded = run.identities[pid] else { return .skip("outside-tree") }
        guard let live = signaler.identity(of: pid) else {
            return signaler.isDefinitelyGone(pid) ? .gone : .skip("unverifiable")   // F-9: unreadable ≠ exited
        }
        guard live.identity == recorded else { return .skip("identity-changed") }
        guard live.uid == run.ownUID else { return .skip("not-owned") }
        return .ok
    }

    private func sendIndividually(_ signal: Int32, to pid: Int32, run: inout Run) {
        guard !run.denied.contains(pid), !run.gone.contains(pid), !run.reused.contains(pid) else { return }
        switch verify(pid, in: run) {
        case .gone:
            run.gone.insert(pid)
        case .skip(let reason):
            run.skip(pid, reason)
            if reason == "identity-changed" { run.reused.insert(pid) } else { run.denied.insert(pid) }
        case .ok:
            let status = signaler.send(signal, to: pid)
            run.signals.append("\(Self.signalName(signal)):\(pid)")
            switch status {
            case 0:
                run.markDelivered(signal, to: pid)
            case ESRCH:
                run.gone.insert(pid)
            case EPERM:
                run.denied.insert(pid)
                run.skip(pid, "eperm")          // K10: reported, never retried or escalated
            default:
                run.denied.insert(pid)
                run.skip(pid, "errno-\(status)")
            }
        }
    }

    /// `kill(-pgid, signal)` when every K5 condition holds right now. Returns the pids it covered, or nil when the group
    /// path was not taken (the caller then signals individually).
    private func sendGroup(_ signal: Int32, run: inout Run, requireDue: Bool) -> Set<Int32>? {
        guard run.server.groupKillEligible, !run.groupFinished,
              run.rootPGID == run.rootID.pid,           // the root leads its own group
              run.rootPGID > 1,                         // K7
              run.rootPGID != signaler.ownPGID          // K11
        else { return nil }

        let groupPIDs = signaler.groupPIDs(run.rootPGID)   // all uids
        guard !groupPIDs.isEmpty else { return nil }
        var live: [Int32] = []
        for pid in groupPIDs {
            guard run.identities[pid] != nil else {
                if signaler.isDefinitelyGone(pid) { continue }   // provably exited (ESRCH / unreaped zombie): nothing to signal
                return nil                                       // K5 / F-9: a live (or unreadable) process that is not a verified member
            }
            guard !run.denied.contains(pid) else { return nil }     // K10
            switch verify(pid, in: run) {
            case .ok: live.append(pid)
            case .gone: continue
            case .skip: return nil
            }
        }
        guard !live.isEmpty else { return nil }
        if requireDue, !live.allSatisfy({ run.isDue($0) }) { return nil }

        let status = signaler.sendToGroup(signal, pgid: run.rootPGID)
        run.signals.append("\(Self.signalName(signal)):-\(run.rootPGID)")
        switch status {
        case 0:
            run.usedGroup = true
            for pid in live { run.markDelivered(signal, to: pid) }
        case ESRCH:
            for pid in live { run.gone.insert(pid) }
        default:
            run.groupFinished = true                 // K10: never retried
            run.skip(run.rootID.pid, status == EPERM ? "eperm" : "errno-\(status)")
            for pid in live { run.denied.insert(pid) }
        }
        return Set(live)
    }

    // MARK: Helpers

    private static func polls(_ seconds: Double, _ pollMilliseconds: Int) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(1_000_000, Int((seconds * 1000 / Double(pollMilliseconds)).rounded(.up)))
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTERM: "TERM"
        case SIGKILL: "KILL"
        default: "\(signal)"
        }
    }

    private static func subject(_ identity: ProcessIdentity) -> String { "\(identity.pid):\(identity.startSeconds)" }

    private static func auditDetail(run: Run, terminated: [Int32], forced: [Int32], survivors: [Int32]) -> [String: String] {
        func list(_ pids: [Int32]) -> String { pids.map(String.init).joined(separator: ",") }
        var detail: [String: String] = [
            "pids": list(run.order),
            "signals": run.signals.joined(separator: ","),
            "path": run.usedGroup ? "group" : "individual",
            "terminated": list(terminated),
            "forced": list(forced),
            "survivors": list(survivors),
            "skipped": run.skips.map { "\($0.pid)=\($0.reason)" }.joined(separator: ","),
        ]
        if let port = run.server.mainPort { detail["port"] = String(port) }
        if let project = run.server.project?.root { detail["project"] = project }
        return detail
    }
}
