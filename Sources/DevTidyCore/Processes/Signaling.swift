import Darwin
import Foundation

/// S1-private seam between `TreeTerminator` and the kernel. Fakes in tests record every signal; production uses
/// `DarwinSignaler`. The ONLY places a signal can leave DevTidy are `send` and `sendToGroup` (`isDefinitelyGone` probes with
/// signal 0, which delivers nothing).
protocol Signaling: Sendable {
    /// Live identity (pid + start time) and uid of `pid`; nil = gone (also nil for an exited-but-unreaped zombie) OR
    /// alive but unreadable. Callers that must tell the two apart ask `isDefinitelyGone`.
    func identity(of pid: Int32) -> (identity: ProcessIdentity, uid: UInt32)?
    /// True only when `pid` provably no longer exists (ESRCH) or is an unreaped zombie. A live process whose info cannot
    /// be read is NOT gone (K5: it may be a foreign member of the group).
    func isDefinitelyGone(_ pid: Int32) -> Bool
    /// Parent pid of ANY process, whatever its uid; nil when unreadable or gone. Used to walk DevTidy's ancestry past
    /// processes the own-uid snapshot cannot see (`login`, `sudo`).
    func parentPID(of pid: Int32) -> Int32?
    /// `kill(pid, signal)`; returns 0 or errno. Never called with pid ≤ 1 (K7).
    func send(_ signal: Int32, to pid: Int32) -> Int32
    /// `kill(-pgid, signal)`; returns 0 or errno. Never called with pgid ≤ 1 (K7).
    func sendToGroup(_ signal: Int32, pgid: Int32) -> Int32
    /// Every pid in the group, ALL uids (`proc_listpids(PROC_PGRP_ONLY)`).
    func groupPIDs(_ pgid: Int32) -> [Int32]
    /// `getpgrp()`: DevTidy's own process group (K11).
    var ownPGID: Int32 { get }
}

struct DarwinSignaler: Signaling {
    func identity(of pid: Int32) -> (identity: ProcessIdentity, uid: UInt32)? {
        guard pid > 0, let info = Libproc.bsdInfo(pid), info.pbi_status != Libproc.zombieStatus else { return nil }
        let identity = ProcessIdentity(pid: pid,
                                       startSeconds: Int64(truncatingIfNeeded: info.pbi_start_tvsec),
                                       startMicroseconds: Int64(truncatingIfNeeded: info.pbi_start_tvusec))
        return (identity, info.pbi_uid)
    }

    func isDefinitelyGone(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        // An unreaped zombie is invisible to `proc_pidinfo` and still answers `kill(pid, 0)`, so ask the kernel's process table.
        if let status = Libproc.kernelStatus(pid) { return status == Libproc.zombieStatus }
        // Not in the table (or unreadable): only ESRCH proves absence. Signal 0 performs the existence/permission check and sends nothing.
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    func parentPID(of pid: Int32) -> Int32? {
        guard pid > 0, let info = Libproc.bsdInfo(pid) else { return nil }
        return Int32(truncatingIfNeeded: info.pbi_ppid)
    }

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        // K7: 0 (own group), -1 (everything) and launchd can never be reached through here.
        guard pid > 1 else { return EINVAL }
        // K1 backstop: DevTidy never signals itself, whatever the caller computed.
        guard pid != getpid() else { return EPERM }
        return Darwin.kill(pid, signal) == 0 ? 0 : errno
    }

    func sendToGroup(_ signal: Int32, pgid: Int32) -> Int32 {
        // K7: the only negative argument ever passed to kill(2) is -pgid with pgid > 1.
        guard pgid > 1 else { return EINVAL }
        // K11 backstop: never DevTidy's own group.
        guard pgid != getpgrp() else { return EPERM }
        return Darwin.kill(-pgid, signal) == 0 ? 0 : errno
    }

    func groupPIDs(_ pgid: Int32) -> [Int32] { Libproc.groupPIDs(pgid) }

    var ownPGID: Int32 { getpgrp() }
}
