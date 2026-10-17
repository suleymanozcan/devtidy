import Foundation

/// The display name a project's own manifest gives it.
public struct ProjectManifest: Hashable, Sendable {
    public enum Source: String, Sendable {
        case packageJSON, composerJSON, expoAppJSON, cargoToml, pyproject, xcodeProject, gradleSettings

        /// What the user would open to change it.
        public var fileName: String {
            switch self {
            case .packageJSON: "package.json"
            case .composerJSON: "composer.json"
            case .expoAppJSON: "app.json"
            case .cargoToml: "Cargo.toml"
            case .pyproject: "pyproject.toml"
            case .xcodeProject: ".xcodeproj"
            case .gradleSettings: "settings.gradle"
            }
        }
    }

    public let name: String
    public let version: String?
    public let source: Source

    /// `name@version`, or just `name` when the manifest has no version.
    public var label: String { version.map { "\(name)@\($0)" } ?? name }
}

/// What `HEAD` points at.
public enum GitHead: Hashable, Sendable {
    case branch(String)
    /// Detached HEAD: the abbreviated (7-character) commit.
    case detached(String)

    public var label: String {
        switch self {
        case .branch(let name): name
        case .detached(let sha): sha
        }
    }

    public var isDetached: Bool {
        if case .detached = self { return true }
        return false
    }
}

/// Who a project is, from the filesystem alone (no process is spawned; every file read is a regular file of at most 256 KB
/// that is not a symlink, in a directory path none of whose components is a symlink). See `ProjectIdentifying`.
///
/// Every name here (`folderName`, `repoName`, `pathInRepo`, `workspaceName`, the manifest, the branch) has been through
/// `DisplayText`; `path` and `repoRoot` are the real paths and are for the file system, not for display.
public struct ProjectIdentity: Hashable, Sendable {
    /// Absolute path of the project root (the canonical `Project.root`).
    public let path: String
    /// Last component of `path`.
    public let folderName: String
    /// Nearest ancestor-or-self containing a `.git` directory or `.git` file (worktree / submodule `gitdir:`).
    public let repoRoot: String?
    /// The repository's folder name. For a linked worktree it is the MAIN repository's (`<main>/.git/worktrees/<name>`), not
    /// the worktree folder's, so a worktree of `redalert` is still headed `redalert`.
    public let repoName: String?
    /// The project's path below the repo root (`packages/client`); nil when there is no repo or the project IS the repo root.
    public let pathInRepo: String?
    /// Package name of the monorepo / workspace root above the project (a `package.json` with `workspaces`, or a directory
    /// with `pnpm-workspace.yaml`; the folder name when that package.json has no name); nil when the project is not inside one.
    public let workspaceName: String?
    /// Read from `HEAD` directly, never by running git.
    public let head: GitHead?
    public let manifest: ProjectManifest?
    /// The folder of a linked worktree (`feature-x`); nil for an ordinary repository and for a submodule.
    public var worktreeName: String? = nil

    /// `repo › packages/client`, `repo` when the project is the repo root, the folder name when there is no repo. A linked
    /// worktree reads `repo (wt feature-x) › packages/client`.
    public var headerTitle: String {
        guard let repoName else { return folderName }
        let repo = worktreeName.map { "\(repoName) (wt \($0))" } ?? repoName
        guard let pathInRepo else { return repo }
        return repo + " › " + pathInRepo
    }
}
