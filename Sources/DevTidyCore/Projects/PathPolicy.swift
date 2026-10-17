import Foundation
import Darwin

/// Canonicalization, depth, denyRoots and same-device rules (CAT §2, R1/R2/R4).
/// All paths handled here are absolute. "Prefix" always means `root + "/"`.
struct PathPolicy: Sendable {
    /// `realpath(homeDirectory)`.
    let home: String

    init(homeDirectory: String) {
        self.home = PathPolicy.canonical(homeDirectory)
    }

    // MARK: Canonicalization

    /// `realpath(p)`; when the path does not exist, the standardized lexical path.
    static func canonical(_ p: String) -> String {
        if let r = realpathString(p) { return r }
        let url = URL(fileURLWithPath: p).standardizedFileURL
        var s = url.path
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func realpathString(_ p: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(p, &buf) != nil else { return nil }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // MARK: Containment

    /// `child` is strictly below `root` (never equal). Sibling prefixes (`/a/proj-evil`) never match.
    static func isStrictlyInside(_ child: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return child.hasPrefix(prefix) && child.count > prefix.count
    }

    /// `child == root` or strictly below it.
    static func isInsideOrEqual(_ child: String, root: String) -> Bool {
        child == root || isStrictlyInside(child, root: root)
    }

    /// Path components after `root + "/"`; nil when `path` is not strictly inside `root`.
    static func components(of path: String, below root: String) -> [String]? {
        guard isStrictlyInside(path, root: root) else { return nil }
        let rel = path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1)
        return rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    func isUnderHome(_ path: String) -> Bool { PathPolicy.isStrictlyInside(path, root: home) }

    /// Number of path components of `path` after `home/`; 0 for home itself; nil when not under home.
    func depthBelowHome(_ path: String) -> Int? {
        if path == home { return 0 }
        return PathPolicy.components(of: path, below: home)?.count
    }

    // MARK: Deny roots (R1)

    /// `~/Library, ~/.Trash, ~/Applications, ~/Public` + every depth-1 dot-dir (checked by name, not by listing).
    func isDenied(_ path: String) -> Bool {
        guard let comps = PathPolicy.components(of: path, below: home), let first = comps.first else { return false }
        if first.hasPrefix(".") { return true }
        return first == "Library" || first == "Applications" || first == "Public"
    }

    /// R1 for project roots: under home, depth ≥ 2, not in denyRoots.
    func passesRootDepthAndDenyGate(_ root: String) -> Bool {
        guard isUnderHome(root), let d = depthBelowHome(root), d >= 2 else { return false }
        return !isDenied(root)
    }

    // MARK: Device / type

    static func device(of path: String) -> dev_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_dev
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// R2: `root` is a real directory on the same device as home.
    func isRealDirectoryOnHomeDevice(_ root: String) -> Bool {
        guard PathPolicy.isRealDirectory(root),
              let rd = PathPolicy.device(of: root),
              let hd = PathPolicy.device(of: home) else { return false }
        return rd == hd
    }

    // MARK: Parents

    /// `[start, parent, …, ceiling]`, at most `limit` entries; the ceiling is always the last element
    /// (when the chain is longer than `limit`, intermediate dirs are dropped, not the ceiling).
    static func packageDirs(start: String, ceiling: String, limit: Int = 8) -> [String] {
        guard start != ceiling, PathPolicy.isStrictlyInside(start, root: ceiling) else { return [start] }
        var chain: [String] = [start]
        var cur = start
        while cur != ceiling {
            let parent = (cur as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == cur { break }
            chain.append(parent)
            cur = parent
        }
        if chain.count > limit {
            chain = Array(chain.prefix(limit - 1)) + [ceiling]
        }
        return chain
    }

    static func parent(of path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}

extension PathPolicy {
    /// Parent folder name for grouping labels, unless the parent is `home` or a depth-1 container (`~/developer`).
    func groupName(forProjectRoot root: String) -> String? {
        let parent = PathPolicy.parent(of: root)
        guard parent != "/", parent != home, let depth = depthBelowHome(parent), depth >= 2 else { return nil }
        let last = (parent as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }
}
