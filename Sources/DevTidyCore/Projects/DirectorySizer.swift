import Foundation
import Darwin

/// R21: allocated bytes (`st_blocks * 512`) of a tree, never following links, never leaving the device,
/// hard links counted once, errors and cost bounds ⇒ `isPartial`. Never reads file contents.
enum DirectorySizer {
    struct Bounds: Sendable {
        var maxEntries: Int = 2_000_000
        var maxSeconds: Double = 10
        init(maxEntries: Int = 2_000_000, maxSeconds: Double = 10) {
            self.maxEntries = maxEntries
            self.maxSeconds = maxSeconds
        }
    }

    /// Runs the walk off the caller's executor; honors task cancellation (returns the partial figure promptly).
    @concurrent
    static func sizeOffActor(of path: String, bounds: Bounds = Bounds()) async -> SizeResult {
        size(of: path, bounds: bounds)
    }

    /// Synchronous walk. Checks `Task.isCancelled` every 4096 entries.
    static func size(of path: String, bounds: Bounds = Bounds()) -> SizeResult {
        guard let cPath = strdup(path) else { return SizeResult(bytes: 0, isPartial: true, itemCount: nil) }
        defer { free(cPath) }
        var pathVector: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&pathVector, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return SizeResult(bytes: 0, isPartial: true, itemCount: nil)
        }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var partial = false
        var visited = 0
        var items = 0
        var seenLinks = Set<FileIdentity>()
        let start = DispatchTime.now().uptimeNanoseconds
        let limitNanos = UInt64(max(0, bounds.maxSeconds) * 1_000_000_000)

        while let entry = fts_read(fts) {
            visited += 1
            if visited % 4096 == 0 {
                if Task.isCancelled { partial = true; break }
                if DispatchTime.now().uptimeNanoseconds &- start > limitNanos { partial = true; break }
            }
            if visited > bounds.maxEntries { partial = true; break }

            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_DP:
                continue                       // post-order visit of a directory already counted at FTS_D
            case FTS_DNR, FTS_ERR, FTS_NS:
                partial = true
                // An unreadable directory (FTS_DNR) still has valid stat data and its own allocation; for FTS_ERR / FTS_NS
                // `fts_statp` is undefined and is never read.
                if info == FTS_DNR, let st = entry.pointee.fts_statp { total &+= allocated(st.pointee, &seenLinks) }
                continue
            default:
                guard let st = entry.pointee.fts_statp else { partial = true; continue }
                total &+= allocated(st.pointee, &seenLinks)
                if info != FTS_D { items += 1 }
            }
        }
        return SizeResult(bytes: total, isPartial: partial, itemCount: items)
    }

    /// Allocated bytes of one stat, counting a multiply-linked inode once.
    private static func allocated(_ st: stat, _ seen: inout Set<FileIdentity>) -> Int64 {
        if st.st_nlink > 1 {
            let id = FileIdentity(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino))
            if !seen.insert(id).inserted { return 0 }
        }
        return Int64(st.st_blocks) * 512
    }
}
