import Foundation

/// QA F1: the paths a package publishes or resolves through its own `package.json`. A build-output directory that any of
/// these fields points into (`dist` behind `module`/`types`/`exports`, `build/cli.js` behind `bin`, `files: ["dist"]`) is
/// the package's artefact, not a regenerable by-product, and is never offered nor deleted.
enum PackageEntryPaths {
    /// Fields whose string values are file or directory references. `exports` keys (subpaths / conditions) are NOT
    /// references; only values are collected.
    static let fields = ["main", "module", "types", "typings", "browser", "unpkg", "jsdelivr", "exports", "bin", "files",
                         "directories", "typesVersions"]
    static let maxReferences = 4096
    static let maxNesting = 32

    static func collect(from manifest: [String: Any]) -> [[String]] {
        var strings: [String] = []
        for field in fields { gather(manifest[field], into: &strings, depth: 0) }
        var out: [[String]] = []
        var seen = Set<[String]>()
        for s in strings.prefix(maxReferences) {
            if let comps = components(ofReference: s), seen.insert(comps).inserted { out.append(comps) }
        }
        return out
    }

    private static func gather(_ value: Any?, into out: inout [String], depth: Int) {
        guard depth <= maxNesting, out.count < maxReferences else { return }
        switch value {
        case let s as String:
            out.append(s)
        case let list as [Any]:
            for item in list { gather(item, into: &out, depth: depth + 1) }
        case let map as [String: Any]:
            for item in map.values { gather(item, into: &out, depth: depth + 1) }
        default:
            break
        }
    }

    /// `./dist/index.js` → `["dist", "index.js"]`; `/dist` → `["dist"]`; `a/../b` → `["b"]`; a negation (`!dist/x`), a
    /// reference that climbs out of the package, and an empty path → nil.
    static func components(ofReference raw: String) -> [String]? {
        if raw.hasPrefix("!") { return nil }
        var comps: [String] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if comps.isEmpty { return nil }
                comps.removeLast()
                continue
            }
            comps.append(String(part))
        }
        return comps.isEmpty ? nil : comps
    }

    /// One path is a prefix of the other, comparing component by component (case-insensitively: the default APFS volume
    /// resolves `Dist` and `dist` to the same directory). A glob component (`*`, `**`, `*.js`, `{a,b}`, `[ab]`) matches
    /// any directory name that fits it; a pattern that cannot be evaluated exactly (`{}` / `[]`) matches everything.
    static func overlaps(reference: [String], target: [String]) -> Bool {
        for (r, t) in zip(reference, target) where !componentMatches(r, t) { return false }
        return true
    }

    static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        if pattern.lowercased() == name.lowercased() { return true }
        guard pattern.contains(where: { "*?[{".contains($0) }) else { return false }
        if pattern.contains(where: { "[{".contains($0) }) { return true }
        return wildcard(Array(pattern.lowercased()), Array(name.lowercased()))
    }

    /// `*` = any run (also empty), `?` = one character.
    private static func wildcard(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0, si = 0
        var star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

extension PackageManifest {
    /// True when an entry field of this package points at `target` (a package-relative component list), at something
    /// inside it, or at a directory that contains it.
    func referencesPath(_ target: [String]) -> Bool {
        !target.isEmpty && entryPaths.contains { PackageEntryPaths.overlaps(reference: $0, target: target) }
    }
}
