import Foundation
import Darwin
import CDevTidyShim

/// Outcome of the pre-walk that guards every directory deletion (R12 / Security F-2).
enum NestedRepositoryScan: Sendable, Equatable {
    /// No `.git` entry (in any letter case) anywhere below the target.
    case clean
    /// An entry named `.git` in any letter case (directory, gitlink file of a worktree/submodule, or a symlink) exists below
    /// the target; the payload is its path relative to the target, with the entry's own spelling.
    case found(String)
    /// Fail closed: a cost bound was hit, a subdirectory could not be read, or the task was cancelled.
    case inconclusive
    /// The directory at the path is not the one that was validated (`(dev, ino)` mismatch).
    case identityChanged
    /// The target could not be opened as a real directory (gone, symlinked, permission).
    case unreadable
}

/// A cleanup target that contains another repository or worktree would take unpushed commits (or a checked-out
/// branch) with it, and the outer repository's git gate cannot see them: an ignored directory is never descended.
/// The walk is fd-relative (`O_NOFOLLOW_ANY` on every level), never follows a symlink, never leaves the target's
/// device, and is bounded by entry count, depth and wall time; every bound fails closed.
enum RepositoryScanner {
    struct Limits: Sendable {
        var maxEntries = 2_000_000
        var maxSeconds = 20.0
        var maxDepth = SafeFS.maxDepth
        init(maxEntries: Int = 2_000_000, maxSeconds: Double = 20, maxDepth: Int = SafeFS.maxDepth) {
            self.maxEntries = maxEntries
            self.maxSeconds = maxSeconds
            self.maxDepth = maxDepth
        }
    }

    /// Off the caller's executor; honors task cancellation (reported as `.inconclusive`).
    @concurrent
    static func scanOffActor(path: String, expected: FileIdentity, rootDev: dev_t,
                             limits: Limits = Limits()) async -> NestedRepositoryScan {
        scan(path: path, expected: expected, rootDev: rootDev, limits: limits)
    }

    static func scan(path: String, expected: FileIdentity, rootDev: dev_t, limits: Limits = Limits()) -> NestedRepositoryScan {
        let fd = SafeFS.openDirAbsolute(path)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }
        guard let st = SafeFS.statOfFD(fd) else { return .unreadable }
        guard st.identity == expected else { return .identityChanged }
        var state = State(limits: limits)
        return walk(dirFD: fd, relative: "", rootDev: rootDev, depth: 0, state: &state)
    }

    private struct State {
        let limits: Limits
        let startNanos = DispatchTime.now().uptimeNanoseconds
        var entries = 0

        init(limits: Limits) { self.limits = limits }

        var overBudget: Bool {
            if entries > limits.maxEntries { return true }
            let limit = UInt64(max(0, limits.maxSeconds) * 1_000_000_000)
            return DispatchTime.now().uptimeNanoseconds &- startNanos > limit
        }
    }

    /// `.git` in ANY letter case (Security N-9): the default APFS/HFS+ volume is case-insensitive, so a directory that is
    /// literally named `.GIT` or `.Git` is the repository's `.git` for git there. Compared on the raw bytes (ASCII fold only:
    /// no non-ASCII character case-folds to `g`, `i` or `t`), so a name that is not valid UTF-8 cannot hide it either.
    static func isRepositoryMarker(_ rawName: [CChar]) -> Bool {
        let expected: [UInt8] = [0x2E, 0x67, 0x69, 0x74]            // ".git"
        guard rawName.count == expected.count + 1, rawName[expected.count] == 0 else { return false }
        for (i, want) in expected.enumerated() {
            var byte = UInt8(bitPattern: rawName[i])
            if byte >= 0x41 && byte <= 0x5A { byte += 0x20 }
            if byte != want { return false }
        }
        return true
    }

    private static func walk(dirFD: Int32, relative: String, rootDev: dev_t, depth: Int, state: inout State) -> NestedRepositoryScan {
        guard depth <= state.limits.maxDepth, let names = SafeFS.readRawNames(dirFD: dirFD) else { return .inconclusive }
        // The marker is looked for in the whole listing first: a hit never costs a descent.
        if let hit = names.first(where: isRepositoryMarker) {
            let name = SafeFS.decodeExact(hit) ?? ".git"
            return .found(relative.isEmpty ? name : relative + "/" + name)
        }
        for n in names {
            state.entries += 1
            if state.entries & 0x3FF == 0, Task.isCancelled || state.overBudget { return .inconclusive }
            if state.entries > state.limits.maxEntries { return .inconclusive }
            var st = stat()
            if devtidy_fstatat_nofollow(dirFD, n, &st) != 0 {
                if errno == ENOENT { continue }
                return .inconclusive
            }
            // Only real directories on the target's device are walked; everything else cannot hold a repository that
            // `removeTree` would delete (it unlinks links as names and refuses to cross devices).
            guard (st.st_mode & 0o170000) == 0o040000, st.st_dev == rootDev else { continue }
            let child = devtidy_openat_dir(dirFD, n)
            if child < 0 {
                if errno == ENOENT { continue }
                return .inconclusive
            }
            let name = SafeFS.decodeExact(n) ?? "?"
            let result = walk(dirFD: child, relative: relative.isEmpty ? name : relative + "/" + name,
                              rootDev: rootDev, depth: depth + 1, state: &state)
            close(child)
            if result != .clean { return result }
        }
        return .clean
    }
}
