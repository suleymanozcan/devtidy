import Darwin
import Foundation

/// Thin wrappers over libproc / sysctl (probe.swift generalized, design §4.2). Every reader returns nil / empty on
/// failure and never throws. No shell, no `ps`, no `lsof`, no localized text (K9, ENV G1).
enum Libproc {

    // MARK: Result types

    struct ListeningSocket: Sendable, Equatable {
        let port: UInt16
        let scope: BindScope
    }

    struct SocketScan: Sendable, Equatable {
        var listening: [ListeningSocket] = []
        /// ESTABLISHED TCP sockets by local port.
        var established: [UInt16: Int] = [:]
    }

    // MARK: Constants

    /// `SZOMB` from `<sys/proc.h>` (not exported to Swift): an exited, not yet reaped process.
    static let zombieStatus: UInt32 = 5

    /// `p_stat` of `pid` from `sysctl(KERN_PROC_PID)`, all uids. Unlike `proc_pidinfo(PROC_PIDTBSDINFO)`, which returns nothing for
    /// an exited-but-unreaped zombie on current macOS, this still answers (`SZOMB`). nil = no such process / unreadable.
    static func kernelStatus(_ pid: Int32) -> UInt32? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return UInt32(truncatingIfNeeded: info.kp_proc.p_stat)
    }

    // MARK: Clock / units

    @inline(__always)
    static func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// `proc_taskinfo` times are mach absolute time units on Apple Silicon. Overflow-safe `ticks × numer / denom`.
    static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        return (ticks / denom) &* numer &+ (ticks % denom) &* numer / denom
    }

    // MARK: Process list

    static func listPids() -> [Int32] {
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        return pids[0..<count].filter { $0 > 0 }
    }

    /// Every pid (ALL uids) currently in process group `pgid` (`PROC_PGRP_ONLY`).
    static func groupPIDs(_ pgid: Int32) -> [Int32] {
        guard pgid > 0 else { return [] }
        let capacity = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 32)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        return pids[0..<count].filter { $0 > 0 }.sorted()
    }

    // MARK: Per-pid info

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Kernel `comm` (≤ 16 bytes, not necessarily NUL-terminated).
    static func comm(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// `ri_phys_footprint` (Activity Monitor "Memory"); nil when rusage is unavailable.
    static func rusageFootprint(_ pid: Int32) -> UInt64? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    static func pidPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4097)
        let length = proc_pidpath(pid, &buffer, 4096)
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: Sockets

    /// Listening TCP sockets (with bind scope) and per-local-port ESTABLISHED counts of one process.
    static func sockets(pid: Int32) -> SocketScan {
        var result = SocketScan()
        let listBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listBytes > 0 else { return result }
        let fdStride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listBytes) / fdStride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdStride))
        guard got > 0 else { return result }
        let count = min(Int(got) / fdStride, fds.count)

        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        var info = socket_fdinfo()
        for index in 0..<count where fds[index].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            let status = proc_pidfdinfo(pid, fds[index].proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize)
            guard status == infoSize, info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if tcp.tcpsi_state == Int32(TSI_S_LISTEN) {
                let vflag = tcp.tcpsi_ini.insi_vflag
                let scope = withUnsafeBytes(of: tcp.tcpsi_ini.insi_laddr) { bindScope(vflag: vflag, address: $0) }
                result.listening.append(ListeningSocket(port: port, scope: scope))
            } else if tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED) {
                result.established[port, default: 0] += 1
            }
        }
        return result
    }

    /// `insi_vflag` bits from `<sys/proc_info.h>`: INI_IPV4 = 0x1, INI_IPV6 = 0x2 (dual-stack sockets carry both).
    /// `address` is the 16-byte `insi_laddr` union: an `in6_addr`, or an `in4in6_addr` whose IPv4 address is bytes 12…15.
    static func bindScope(vflag: UInt8, address: UnsafeRawBufferPointer) -> BindScope {
        guard address.count >= 16 else { return .other }
        func ipv4Scope(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> BindScope {
            if a == 127 { return .loopback }
            if a == 0 && b == 0 && c == 0 && d == 0 { return .allInterfaces }
            return .other
        }
        if vflag & 0x2 != 0 {
            var leadingZeros = 0
            while leadingZeros < 16, address[leadingZeros] == 0 { leadingZeros += 1 }
            if leadingZeros == 16 { return .allInterfaces }
            if leadingZeros == 15, address[15] == 1 { return .loopback }
            if leadingZeros == 10, address[10] == 0xFF, address[11] == 0xFF {
                return ipv4Scope(address[12], address[13], address[14], address[15])   // ::ffff:a.b.c.d
            }
            return .other
        }
        if vflag & 0x1 != 0 { return ipv4Scope(address[12], address[13], address[14], address[15]) }
        return .other
    }

    // MARK: argv (KERN_PROCARGS2)

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    private static let initialArgvCapacity = 128 * 1024

    /// argv of an own-uid process. Failure ⇒ `[]` (fetched but unreadable), never nil. The environment block that
    /// follows argv in the same buffer is never decoded.
    static func argv(_ pid: Int32) -> [String] {
        var capacities = [initialArgvCapacity]
        if argMax > initialArgvCapacity { capacities.append(argMax) }
        for (attempt, capacity) in capacities.enumerated() {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var written = capacity
            var succeeded = false
            var failure: Int32 = 0
            let data = [UInt8](unsafeUninitializedCapacity: capacity) { buffer, count in
                if sysctl(&mib, 3, buffer.baseAddress, &written, nil, 0) == 0 {
                    succeeded = true
                    count = min(written, capacity)
                } else {
                    failure = errno
                    count = 0
                }
            }
            if succeeded {
                // A completely filled first buffer may be truncated; retry once with the system maximum.
                if data.count == capacity, attempt + 1 < capacities.count { continue }
                return parseArguments(data)
            }
            if failure != ENOMEM { return [] }
        }
        return []
    }

    /// Layout: `Int32 argc | exec_path NUL | NUL padding | argv[0] NUL … argv[argc-1] NUL | env…`.
    static func parseArguments(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let declared = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard declared > 0 else { return [] }
        let argc = min(declared, 1024)
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // exec_path
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // padding
        var out: [String] = []
        out.reserveCapacity(min(argc, 64))
        while out.count < argc, index < bytes.count {
            var end = index
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            out.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return out
    }
}
