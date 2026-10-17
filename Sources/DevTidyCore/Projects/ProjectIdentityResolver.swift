import Foundation

/// Builds a `ProjectIdentity` from the filesystem. Pure function of the tree: no process is spawned, no file larger than
/// `maxFileBytes` is read, and every file is read without following a symlink in its final position OR in any directory of its
/// path (`SafeFS.readSmallFile`), so a manifest that is a symlink is ignored rather than followed out of the project.
///
/// Every name that reaches the UI from here (folder, repo, path below the repo, workspace, manifest, branch) went through
/// `DisplayText`: a directory called `a<RLO>b` or `x<ZWSP>` is never shown as is.
enum ProjectIdentityResolver {
    static let maxFileBytes = 256 * 1024
    static let maxWalkLevels = 12
    private static let maxNameLength = 120

    static func resolve(projectRoot rawRoot: String, home: String) -> ProjectIdentity {
        let path = rawRoot.count > 1 && rawRoot.hasSuffix("/") ? String(rawRoot.dropLast()) : rawRoot
        let repoRoot = findRepoRoot(from: path, home: home)
        var pathInRepo: String?
        if let repoRoot, let components = PathPolicy.components(of: path, below: repoRoot) {
            pathInRepo = components.map { DisplayText.label($0, limit: maxNameLength) }.joined(separator: "/")
        }
        let gitDir = repoRoot.flatMap(gitDirectory(forRepoRoot:))
        // A linked worktree is named after its main repository, with the worktree's own folder in the header.
        let mainRoot = gitDir.flatMap(mainRepositoryRoot(ofWorktreeGitDirectory:))
        let repoName = (mainRoot ?? repoRoot).map { displayName(of: $0) }
        return ProjectIdentity(
            path: path,
            folderName: displayName(of: path),
            repoRoot: repoRoot,
            repoName: repoName,
            pathInRepo: pathInRepo,
            workspaceName: workspaceName(above: path, repoRoot: repoRoot, home: home),
            head: gitDir.flatMap(readHead(gitDirectory:)),
            manifest: readManifest(in: path),
            worktreeName: mainRoot == nil ? nil : repoRoot.map { displayName(of: $0) })
    }

    private static func lastComponent(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// The last path component, cleaned for display.
    private static func displayName(of path: String) -> String {
        DisplayText.label(lastComponent(of: path), limit: maxNameLength)
    }

    // MARK: Repository

    /// Nearest ancestor-or-self with a `.git` directory or `.git` file. A symlinked `.git` is not a marker. Stops before home.
    static func findRepoRoot(from path: String, home: String) -> String? {
        var dir = path
        var levels = 0
        while dir != home, dir != "/", levels <= maxWalkLevels {
            if let st = SafeFS.lstatAbsolute(dir + "/.git"), st.isDirectory || st.isRegularFile { return dir }
            let parent = PathPolicy.parent(of: dir)
            if parent == dir { break }
            dir = parent
            levels += 1
        }
        return nil
    }

    /// `<repo>/.git` itself, or the directory a worktree / submodule `.git` file points at (`gitdir: <path>`, relative paths
    /// resolve against the repo root). The pointer is data from the repo owner; all it can do is name a directory whose `HEAD`
    /// we then read with the same bounded, no-follow read.
    static func gitDirectory(forRepoRoot repoRoot: String) -> String? {
        let dotGit = repoRoot + "/.git"
        guard let st = SafeFS.lstatAbsolute(dotGit) else { return nil }
        if st.isDirectory { return dotGit }
        guard st.isRegularFile, let data = SafeFS.readSmallFile(dotGit, maxBytes: 4096) else { return nil }
        guard let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first else { return nil }
        let line = first.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let absolute = target.hasPrefix("/") ? target : repoRoot + "/" + target
        return lexicallyNormalized(absolute: absolute)
    }

    /// `/a/./b/../c` → `/a/c`: purely textual, no file system access and no symlink resolution. (Foundation's path
    /// standardizing can also rewrite `/private/tmp` to `/tmp`; that path crosses a symlink and the no-follow read refuses it.)
    static func lexicallyNormalized(absolute path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `<main>` for a linked worktree whose git directory is `<main>/.git/worktrees/<name>`; nil for anything else (an ordinary
    /// repository, a submodule's `.git/modules/…`). Text only: nothing is read.
    static func mainRepositoryRoot(ofWorktreeGitDirectory gitDir: String) -> String? {
        guard let marker = gitDir.range(of: "/.git/worktrees/", options: .backwards), marker.lowerBound > gitDir.startIndex else {
            return nil
        }
        return String(gitDir[..<marker.lowerBound])
    }

    static func readHead(gitDirectory gitDir: String) -> GitHead? {
        guard let data = SafeFS.readSmallFile(gitDir + "/HEAD", maxBytes: 4096) else { return nil }
        return parseHead(String(decoding: data, as: UTF8.self))
    }

    /// `ref: refs/heads/feature/x` → branch `feature/x`; a bare 40- or 64-digit hex object name → detached, first 7 digits.
    static func parseHead(_ text: String) -> GitHead? {
        guard let first = text.split(whereSeparator: \.isNewline).first else { return nil }
        let line = first.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            let name: String
            if ref.hasPrefix("refs/heads/") {
                name = String(ref.dropFirst("refs/heads/".count))
            } else if ref.hasPrefix("refs/") {
                name = String(ref.dropFirst("refs/".count))
            } else {
                name = ref
            }
            // A reftable repository writes this stub into `HEAD` (the real branch is in the table): no branch to show.
            if name == ".invalid" { return nil }
            return DisplayText.clean(name, limit: 80).map(GitHead.branch)
        }
        let isObjectName = (line.utf8.count == 40 || line.utf8.count == 64) && line.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) || (byte >= 0x41 && byte <= 0x46)
        }
        return isObjectName ? .detached(String(line.lowercased().prefix(7))) : nil
    }

    // MARK: Workspace root

    /// Nearest directory above `path` (never above the repo root, never home) that is a JS workspace root.
    static func workspaceName(above path: String, repoRoot: String?, home: String) -> String? {
        var dir = PathPolicy.parent(of: path)
        var levels = 0
        while levels < maxWalkLevels, dir != "/", dir != home, dir != PathPolicy.parent(of: dir) {
            if let repoRoot, !PathPolicy.isInsideOrEqual(dir, root: repoRoot) { return nil }
            if let name = workspaceRootName(at: dir) { return name }
            dir = PathPolicy.parent(of: dir)
            levels += 1
        }
        return nil
    }

    /// The package name (or, without one, the folder name) when `dir` is a workspace root; nil otherwise.
    private static func workspaceRootName(at dir: String) -> String? {
        var isWorkspace = false
        if let st = SafeFS.lstatAbsolute(dir + "/pnpm-workspace.yaml"), st.isRegularFile { isWorkspace = true }
        var packageName: String?
        if let json = readJSONObject(dir + "/package.json") {
            if let workspaces = json["workspaces"], !(workspaces is NSNull) { isWorkspace = true }
            packageName = cleanName(json["name"])
        }
        guard isWorkspace else { return nil }
        return packageName ?? displayName(of: dir)
    }

    // MARK: Manifest name

    /// First source that yields a name wins: package.json (`displayName` > `productName` > `name`), composer.json, app.json
    /// `expo.name`, Cargo.toml `[package]`, pyproject `[project]`, `*.xcodeproj`, settings.gradle(.kts) `rootProject.name`.
    static func readManifest(in dir: String) -> ProjectManifest? {
        if let json = readJSONObject(dir + "/package.json") {
            let name = cleanName(json["displayName"]) ?? cleanName(json["productName"]) ?? cleanName(json["name"])
            if let name { return ProjectManifest(name: name, version: cleanName(json["version"]), source: .packageJSON) }
        }
        if let json = readJSONObject(dir + "/composer.json"), let name = cleanName(json["name"]) {
            return ProjectManifest(name: name, version: cleanName(json["version"]), source: .composerJSON)
        }
        if let json = readJSONObject(dir + "/app.json"), let expo = json["expo"] as? [String: Any],
           let name = cleanName(expo["name"]) {
            return ProjectManifest(name: name, version: cleanName(expo["version"]), source: .expoAppJSON)
        }
        if let text = readText(dir + "/Cargo.toml"),
           let name = TOMLLite.string(in: text, section: "package", key: "name").flatMap(cleanName) {
            return ProjectManifest(name: name, version: TOMLLite.string(in: text, section: "package", key: "version").flatMap(cleanName),
                                   source: .cargoToml)
        }
        if let text = readText(dir + "/pyproject.toml"),
           let name = TOMLLite.string(in: text, section: "project", key: "name").flatMap(cleanName) {
            return ProjectManifest(name: name, version: TOMLLite.string(in: text, section: "project", key: "version").flatMap(cleanName),
                                   source: .pyproject)
        }
        let names = SafeFS.listNames(atAbsolutePath: dir) ?? []
        if let project = names.sorted().first(where: { $0.hasSuffix(".xcodeproj") && $0.count > ".xcodeproj".count }),
           let name = cleanName(String(project.dropLast(".xcodeproj".count))) {
            return ProjectManifest(name: name, version: nil, source: .xcodeProject)
        }
        for file in ["settings.gradle", "settings.gradle.kts"] {
            if let text = readText(dir + "/" + file), let name = GradleSettings.rootProjectName(in: text).flatMap(cleanName) {
                return ProjectManifest(name: name, version: nil, source: .gradleSettings)
            }
        }
        return nil
    }

    // MARK: Bounded reads

    private static func readText(_ path: String) -> String? {
        SafeFS.readSmallFile(path, maxBytes: maxFileBytes).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func readJSONObject(_ path: String) -> [String: Any]? {
        guard let data = SafeFS.readSmallFile(path, maxBytes: maxFileBytes) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func cleanName(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return DisplayText.clean(text, limit: maxNameLength)
    }
}

// MARK: - Tiny format readers ---------------------------------------------------------------------

/// Reads `key = "value"` from one `[section]` of a TOML file. Not a TOML parser: comments, multi-line strings and anything
/// that is not a single-line quoted string are skipped (the answer is then nil, never a wrong name).
enum TOMLLite {
    static func string(in text: String, section wanted: String, key wantedKey: String) -> String? {
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[[") { current = "[[]]"; continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { continue }
                current = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                continue
            }
            guard current == wanted, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == wantedKey else { continue }
            return quotedValue(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func quotedValue(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'", !text.hasPrefix(String(repeating: quote, count: 3)) else { return nil }
        var value = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else if character == quote {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }
}

/// `rootProject.name = "x"` (Groovy or Kotlin DSL) from settings.gradle(.kts); commented-out lines are ignored.
enum GradleSettings {
    static func rootProjectName(in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("/*"),
                  let range = line.range(of: "rootProject.name") else { continue }
            var rest = line[range.upperBound...].drop { $0 == " " || $0 == "\t" }
            guard rest.first == "=" else { continue }
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard let quote = rest.first, quote == "\"" || quote == "'" else { continue }
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: quote) else { continue }
            return String(body[..<end])
        }
        return nil
    }
}
