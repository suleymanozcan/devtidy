import Foundation
import Darwin
import CDevTidyShim

/// `lstat`-style facts about one directory entry (never follows symlinks).
struct FileStat: Sendable, Equatable {
    struct MTime: Sendable, Equatable, Hashable {
        let seconds: Int
        let nanoseconds: Int
    }
    let dev: dev_t
    let ino: ino_t
    let mode: mode_t
    let flags: UInt32
    let size: Int64
    let blocks: Int64
    let nlink: UInt64
    let mtime: MTime

    init(_ st: stat) {
        dev = st.st_dev
        ino = st.st_ino
        mode = st.st_mode
        flags = st.st_flags
        size = Int64(st.st_size)
        blocks = Int64(st.st_blocks)
        nlink = UInt64(st.st_nlink)
        mtime = MTime(seconds: Int(st.st_mtimespec.tv_sec), nanoseconds: Int(st.st_mtimespec.tv_nsec))
    }

    var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
    var isRegularFile: Bool { (mode & 0o170000) == 0o100000 }
    var isSymlink: Bool { (mode & 0o170000) == 0o120000 }

    /// UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND (D6). Declared literally; never cleared by DevTidy.
    static let protectedFlagMask: UInt32 = 0x0000_0002 | 0x0000_0004 | 0x0002_0000 | 0x0004_0000
    var hasProtectedFlags: Bool { flags & FileStat.protectedFlagMask != 0 }

    /// Identity used for the TOCTOU recheck (D11).
    var identity: FileIdentity { FileIdentity(dev: UInt64(bitPattern: Int64(dev)), ino: UInt64(ino)) }
}

struct FileIdentity: Sendable, Hashable {
    let dev: UInt64
    let ino: UInt64
}

struct DirEntry: Sendable {
    let name: String
    let stat: FileStat
}

enum SafeFSFailure: Error, Equatable, Sendable {
    case errno(Int32)
    case crossesDevice
    /// The name was not a real directory at open time (symlink at the leaf, or a non-directory).
    case notDirectory(Int32)
    case tooDeep
    /// The directory opened at depth 0 is not the one that was validated (`(dev, ino)` mismatch, D11).
    case identityChanged

    var text: String {
        switch self {
        case .errno(let e), .notDirectory(let e): return String(cString: strerror(e))
        case .crossesDevice: return "başka bir aygıta geçiliyor"
        case .tooDeep: return "dizin ağacı çok derin"
        case .identityChanged: return "dizin doğrulamadan sonra değişti"
        }
    }
}

/// fd-relative filesystem primitives. Nothing here follows a symlink: absolute opens use `O_NOFOLLOW_ANY`
/// (a symlink at ANY component fails), relative opens use `O_NOFOLLOW_ANY` on the single component, and
/// every stat is `AT_SYMLINK_NOFOLLOW_ANY`.
enum SafeFS {
    static let maxDepth = 512

    // MARK: Open / stat

    /// `-1` + errno on failure (ELOOP for a symlink at any component).
    static func openDirAbsolute(_ path: String) -> Int32 {
        devtidy_open_dir_abs(path)
    }

    static func openDirAt(_ dirFD: Int32, _ name: String) -> Int32 {
        devtidy_openat_dir(dirFD, name)
    }

    /// `nil` + errno on failure.
    static func statNoFollow(dirFD: Int32, name: String) -> FileStat? {
        var st = stat()
        guard devtidy_fstatat_nofollow(dirFD, name, &st) == 0 else { return nil }
        return FileStat(st)
    }

    static func statOfFD(_ fd: Int32) -> FileStat? {
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { return nil }
        return FileStat(st)
    }

    /// `lstat` of an absolute path (the final component is not followed; parents are resolved normally).
    static func lstatAbsolute(_ path: String) -> FileStat? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return FileStat(st)
    }

    // MARK: Listing

    /// Raw NUL-terminated names of `dirFD` (excluding `.` and `..`). Works on a `dup` so `dirFD` stays usable.
    /// `nil` + errno on failure.
    static func readRawNames(dirFD: Int32) -> [[CChar]]? {
        let dupFD = dup(dirFD)
        guard dupFD >= 0 else { return nil }
        guard let dir = fdopendir(dupFD) else {
            let e = errno
            close(dupFD)
            errno = e
            return nil
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var out: [[CChar]] = []
        while let ent = readdir(dir) {
            let len = Int(ent.pointee.d_namlen)
            var name: [CChar] = withUnsafePointer(to: &ent.pointee.d_name) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: len + 1) { p in
                    Array(UnsafeBufferPointer(start: p, count: len))
                }
            }
            if name == [46] || name == [46, 46] { continue }
            name.append(0)
            out.append(name)
        }
        return out
    }

    /// Decoded names for names that are valid UTF-8; names that are not are dropped (they can never match a catalog literal).
    static func readNames(dirFD: Int32) -> [String]? {
        guard let raw = readRawNames(dirFD: dirFD) else { return nil }
        return raw.compactMap(decodeExact)
    }

    /// Round-trip-checked decode: nil when the bytes are not valid UTF-8.
    static func decodeExact(_ raw: [CChar]) -> String? {
        let bytes = raw.dropLast().map { UInt8(bitPattern: $0) }
        let s = String(decoding: bytes, as: UTF8.self)
        return Array(s.utf8) == bytes ? s : nil
    }

    /// D4 / R7: byte-for-byte match of `name` against the directory listing.
    static func directoryContains(dirFD: Int32, name: String) -> Bool {
        let wanted = Array(name.utf8CString)
        guard let raw = readRawNames(dirFD: dirFD) else { return false }
        return raw.contains(wanted)
    }

    /// Entries with their no-follow stat. Entries that vanish between listing and stat are skipped.
    static func enumerate(dirFD: Int32) -> [DirEntry]? {
        guard let names = readNames(dirFD: dirFD) else { return nil }
        var out: [DirEntry] = []
        out.reserveCapacity(names.count)
        for n in names {
            guard let st = statNoFollow(dirFD: dirFD, name: n) else { continue }
            out.append(DirEntry(name: n, stat: st))
        }
        return out
    }

    // MARK: Removal

    /// R18. Removes `parentFD/name` (a real directory on `rootDev`) and everything below it.
    /// Symlinks and special files inside are unlinked as names, never followed. No chmod/chflags.
    /// `expected` (D11): when set, the directory opened at depth 0 must have exactly this `(dev, ino)`; otherwise nothing is
    /// removed and `.identityChanged` is thrown, so a swap between validation and the walk can never be followed.
    /// Reports the first failure after attempting every sibling.
    static func removeTree(parentFD: Int32, name: String, rootDev: dev_t, expected: FileIdentity? = nil,
                           beforeRemovingTopDirectory hook: ((_ attempt: Int) -> Void)? = nil) throws {
        try removeTree(parentFD: parentFD, rawName: Array(name.utf8CString), rootDev: rootDev, expected: expected,
                       depth: 0, hook: hook)
    }

    private static func removeTree(parentFD: Int32, rawName: [CChar], rootDev: dev_t, expected: FileIdentity?, depth: Int,
                                   hook: ((_ attempt: Int) -> Void)?) throws {
        guard depth <= maxDepth else { throw SafeFSFailure.tooDeep }
        var attempt = 0
        while true {
            let fd = devtidy_openat_dir(parentFD, rawName)
            if fd < 0 {
                let e = errno
                if e == ELOOP || e == ENOTDIR { throw SafeFSFailure.notDirectory(e) }
                throw SafeFSFailure.errno(e)
            }
            guard let dirStat = statOfFD(fd) else {
                let e = errno
                close(fd)
                throw SafeFSFailure.errno(e)
            }
            if dirStat.dev != rootDev {
                close(fd)
                throw SafeFSFailure.crossesDevice
            }
            if let expected, dirStat.identity != expected {
                close(fd)
                throw SafeFSFailure.identityChanged
            }
            guard let names = readRawNames(dirFD: fd) else {
                let e = errno
                close(fd)
                throw SafeFSFailure.errno(e)
            }
            var firstError: SafeFSFailure?
            for n in names {
                var st = stat()
                if devtidy_fstatat_nofollow(fd, n, &st) != 0 {
                    if errno != ENOENT && firstError == nil { firstError = .errno(errno) }
                    continue
                }
                if (st.st_mode & 0o170000) == 0o040000 {
                    do {
                        try removeTree(parentFD: fd, rawName: n, rootDev: rootDev, expected: nil, depth: depth + 1, hook: hook)
                    } catch let f as SafeFSFailure {
                        if firstError == nil { firstError = f }
                    } catch {
                        if firstError == nil { firstError = .errno(EIO) }
                    }
                } else if unlinkat(fd, n, 0) != 0 {
                    if errno != ENOENT && firstError == nil { firstError = .errno(errno) }
                }
            }
            close(fd)
            if let e = firstError { throw e }
            if depth == 0 { hook?(attempt) }
            if unlinkat(parentFD, rawName, AT_REMOVEDIR) == 0 { return }
            let e = errno
            if e == ENOENT { return }
            if e == ENOTEMPTY && attempt == 0 {
                attempt += 1
                continue
            }
            throw SafeFSFailure.errno(e)
        }
    }

    /// `unlinkat(dirFD, name, 0)` for one non-directory entry (contents-only rules). Throws the errno.
    static func unlinkFile(dirFD: Int32, name: String) throws {
        if unlinkat(dirFD, name, 0) != 0 { throw SafeFSFailure.errno(errno) }
    }

    // MARK: Small reads (D13)

    /// Reads a regular file of at most `maxBytes` from an ABSOLUTE path (anything else ⇒ nil). Nothing is followed:
    /// * the parent directory is opened with `O_NOFOLLOW_ANY`, so a symlink at ANY component of it fails (Security F3-5);
    /// * the file itself is stat-ed and opened relative to that descriptor with `O_NOFOLLOW`, so a symlink, FIFO, device or
    ///   directory in the last position fails too.
    /// Used for the manifests the catalog and the detector read and, for the project identity, the `.git` pointer file and
    /// `HEAD` (whose `gitdir:` target is free text from the repository owner).
    static func readSmallFile(_ path: String, maxBytes: Int = 1 << 20) -> Data? {
        guard let (parent, name) = splitAbsolute(path) else { return nil }
        let parentFD = openDirAbsolute(parent)
        guard parentFD >= 0 else { return nil }
        defer { close(parentFD) }
        guard let pre = statNoFollow(dirFD: parentFD, name: name), pre.isRegularFile, pre.size <= Int64(maxBytes) else { return nil }
        // O_NONBLOCK: a FIFO swapped in between the stat and the open fails the type check below instead of blocking the scan.
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let st = statOfFD(fd), st.isRegularFile, st.size <= Int64(maxBytes) else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxBytes {
            let n = read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            data.append(buf, count: n)
        }
        return data.count <= maxBytes ? data : nil
    }

    /// `/a/b/c.json` → (`/a/b`, `c.json`); `/c.json` → (`/`, `c.json`). `nil` for a relative path or one without a file name
    /// (`/a/b/`, `/a/..`).
    private static func splitAbsolute(_ path: String) -> (parent: String, name: String)? {
        guard path.utf8.first == UInt8(ascii: "/"), let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return nil }
        let name = String(path[path.utf8.index(after: slash)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let parent = String(path[..<slash])
        return (parent.isEmpty ? "/" : parent, name)
    }
}

extension SafeFS {
    /// Names (valid UTF-8 only) of a directory addressed by absolute path; `nil` when it cannot be opened
    /// (missing, not a directory, a symlink at any component, EPERM/TCC).
    static func listNames(atAbsolutePath path: String) -> [String]? {
        let fd = openDirAbsolute(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readNames(dirFD: fd)
    }
}

enum ExpectedType: Sendable { case directory, regularFile }

enum TargetOpen {
    /// `parentFD` is open and owned by the caller (must `close`).
    case ok(parentFD: Int32, stat: FileStat)
    case skip(SkipReason)
}

extension SafeFS {
    /// R5–R9 (D3–D6): opens `parent` with `O_NOFOLLOW_ANY` (a symlink at ANY component fails), stats `name` without
    /// following, requires the expected type (a symlink is never accepted), a byte-exact directory-listing match, the
    /// root's device and no immutable/append flags.
    static func openTarget(parent: String, name: String, expect: ExpectedType, rootDev: dev_t) -> TargetOpen {
        let parentFD = openDirAbsolute(parent)
        if parentFD < 0 {
            let e = errno
            return .skip(e == ELOOP || e == ENOTDIR ? .symlink : .notFound)
        }
        guard let st = statNoFollow(dirFD: parentFD, name: name) else {
            close(parentFD)
            return .skip(.notFound)
        }
        if st.isSymlink {
            close(parentFD)
            return .skip(.symlink)
        }
        let typeOK = (expect == .directory && st.isDirectory) || (expect == .regularFile && st.isRegularFile)
        guard typeOK else {
            close(parentFD)
            return .skip(.notFound)
        }
        guard directoryContains(dirFD: parentFD, name: name) else {
            close(parentFD)
            return .skip(.nameMismatch)
        }
        guard st.dev == rootDev else {
            close(parentFD)
            return .skip(.crossesDevice)
        }
        guard !st.hasProtectedFlags else {
            close(parentFD)
            return .skip(.immutable)
        }
        return .ok(parentFD: parentFD, stat: st)
    }
}
