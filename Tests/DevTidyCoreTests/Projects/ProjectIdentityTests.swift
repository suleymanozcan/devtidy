import Foundation
import Testing
@testable import DevTidyCore

/// Identity is read from temp trees only: nothing under the real home, no git, no process.
@Suite("ProjectIdentity (repo, branch, workspace, manifest)")
struct ProjectIdentityTests {
    private func resolve(_ t: S2TempDir, at dir: String? = nil) -> ProjectIdentity {
        ProjectIdentityResolver.resolve(projectRoot: dir ?? t.project, home: t.home)
    }

    private let sha = "0123456789abcdef0123456789abcdef01234567"

    // MARK: Repo, relative path, workspace root, branch

    @Test func aMonorepoPackageKnowsItsRepoPathWorkspaceAndBranch() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let repo = t.home + "/dev/redalert"
        let app = repo + "/packages/client"
        try t.write(repo + "/.git/HEAD", "ref: refs/heads/feature/login\n")
        try t.write(repo + "/package.json", "{\"name\":\"redalert-root\",\"private\":true,\"workspaces\":[\"packages/*\"]}")
        try t.write(app + "/package.json", "{\"name\":\"@redalert/client\",\"version\":\"1.2.3\"}")

        let id = resolve(t, at: app)
        #expect(id.path == app)
        #expect(id.folderName == "client")
        #expect(id.repoRoot == repo)
        #expect(id.repoName == "redalert")
        #expect(id.pathInRepo == "packages/client")
        #expect(id.headerTitle == "redalert › packages/client")
        #expect(id.workspaceName == "redalert-root")
        #expect(id.head == .branch("feature/login"))
        #expect(id.manifest?.label == "@redalert/client@1.2.3")
        #expect(id.manifest?.source == .packageJSON)
    }

    @Test func aProjectThatIsTheRepoRootHasNoRelativePath() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.mkdir(t.project + "/.git")
        let id = resolve(t)
        #expect(id.repoRoot == t.project)
        #expect(id.pathInRepo == nil)
        #expect(id.headerTitle == "proj")
        #expect(id.workspaceName == nil)
    }

    @Test func withoutARepoTheHeaderIsTheFolderName() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let id = resolve(t)
        #expect(id.repoRoot == nil)
        #expect(id.repoName == nil)
        #expect(id.pathInRepo == nil)
        #expect(id.head == nil)
        #expect(id.headerTitle == "proj")
    }

    @Test func aRepoAboveHomeIsNeverUsed() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.mkdir(t.root + "/.git")                              // above `home`
        try t.mkdir(t.home + "/.git")                              // `home` itself (a dotfiles repo)
        #expect(resolve(t).repoRoot == nil)
    }

    @Test func aSymlinkedDotGitIsNotARepoMarker() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.root + "/elsewhere/.git/HEAD", "ref: refs/heads/stolen\n")
        try t.symlink(t.project + "/.git", to: t.root + "/elsewhere/.git")
        let id = resolve(t)
        #expect(id.repoRoot == nil)
        #expect(id.head == nil)
    }

    @Test func aDetachedHeadIsTheSevenCharacterCommit() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.project + "/.git/HEAD", sha + "\n")
        let head = try #require(resolve(t).head)
        #expect(head == .detached("0123456"))
        #expect(head.isDetached)
        #expect(head.label == "0123456")
    }

    @Test(arguments: [
        "ref: refs/heads/main\n", "ref: refs/heads/main\r\n", "ref:   refs/heads/main", "ref: refs/heads/main\nignored",
    ])
    func aBranchHeadIsParsedAnyWayItIsWritten(text: String) {
        #expect(ProjectIdentityResolver.parseHead(text) == .branch("main"))
    }

    @Test(arguments: ["", "\n", "garbage", "ref: ", "0123", String(repeating: "g", count: 40), "ref: refs/heads/\u{202E}\u{202E}"])
    func anUnreadableHeadIsNil(text: String) {
        #expect(ProjectIdentityResolver.parseHead(text) == nil)
    }

    @Test func aWorktreeGitFileIsFollowedToItsOwnHead() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let main = t.home + "/dev/main"
        try t.write(main + "/.git/HEAD", "ref: refs/heads/main\n")
        try t.write(main + "/.git/worktrees/wt/HEAD", "ref: refs/heads/hotfix\n")

        let absolute = t.home + "/dev/wt-abs"
        try t.write(absolute + "/.git", "gitdir: \(main)/.git/worktrees/wt\n")
        let a = resolve(t, at: absolute)
        #expect(a.repoRoot == absolute)
        #expect(a.head == .branch("hotfix"))

        let relative = t.home + "/dev/wt-rel"
        try t.write(relative + "/.git", "gitdir: ../main/.git/worktrees/wt\n")
        #expect(resolve(t, at: relative).head == .branch("hotfix"))

        // a detached worktree
        try t.write(main + "/.git/worktrees/wt/HEAD", sha + "\n")
        #expect(resolve(t, at: absolute).head == .detached("0123456"))
    }

    @Test func aBrokenGitFileOrMissingHeadMeansNoBranchButStillARepo() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.project + "/.git", "not a gitlink\n")
        let a = resolve(t)
        #expect(a.repoRoot == t.project)
        #expect(a.head == nil)

        try t.write(t.project + "/.git", "gitdir: /nonexistent-devtidy-test/gitdir\n")
        #expect(resolve(t).head == nil)
    }

    // MARK: Workspace root

    @Test func aPnpmWorkspaceRootWithoutAPackageNameIsNamedByItsFolder() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let root = t.home + "/dev/pnpmrepo"
        try t.mkdir(root + "/.git")
        try t.write(root + "/pnpm-workspace.yaml", "packages:\n  - 'apps/*'\n")
        let app = root + "/apps/web"
        try t.write(app + "/package.json", "{\"name\":\"web\"}")
        #expect(resolve(t, at: app).workspaceName == "pnpmrepo")
    }

    @Test func workspacesAsAnObjectCountToo() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let root = t.home + "/dev/yarnrepo"
        try t.write(root + "/package.json", "{\"name\":\"yarn-root\",\"workspaces\":{\"packages\":[\"p/*\"]}}")
        #expect(resolve(t, at: root + "/p/a").workspaceName == "yarn-root")
    }

    @Test func aPackageJsonWithoutWorkspacesIsNotAWorkspaceRoot() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let root = t.home + "/dev/plain"
        try t.mkdir(root + "/.git")
        try t.write(root + "/package.json", "{\"name\":\"plain\"}")
        #expect(resolve(t, at: root + "/sub/app").workspaceName == nil)
    }

    @Test func aWorkspaceRootAboveTheRepoIsNotThisProjectsWorkspace() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.home + "/dev/package.json", "{\"name\":\"outer\",\"workspaces\":[\"*\"]}")
        try t.mkdir(t.home + "/dev/inner/.git")
        #expect(resolve(t, at: t.home + "/dev/inner/app").workspaceName == nil)
    }

    // MARK: Manifest names

    private func manifest(_ t: S2TempDir) -> ProjectManifest? { resolve(t).manifest }

    @Test func packageJsonNamePriorityIsDisplayNameThenProductNameThenName() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.p("package.json"), "{\"name\":\"n\",\"productName\":\"P\",\"displayName\":\"D\",\"version\":\"1.0.0\"}")
        #expect(manifest(t)?.label == "D@1.0.0")
        try t.write(t.p("package.json"), "{\"name\":\"n\",\"productName\":\"P\"}")
        #expect(manifest(t)?.label == "P")
        try t.write(t.p("package.json"), "{\"name\":\"n\",\"version\":\"0.0.1\"}")
        #expect(manifest(t)?.label == "n@0.0.1")
    }

    @Test func composerAppJsonCargoPyprojectXcodeAndGradleNames() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let cases: [(String, [(String, String)], ProjectManifest.Source, String)] = [
            ("composer", [("composer.json", "{\"name\":\"vendor/shop\",\"require\":{}}")], .composerJSON, "vendor/shop"),
            ("expo", [("app.json", "{\"expo\":{\"name\":\"My App\",\"version\":\"2.0.0\"}}")], .expoAppJSON, "My App@2.0.0"),
            ("cargo", [("Cargo.toml", "[package]\nname = \"crab\"\nversion = \"0.3.1\"\n\n[dependencies]\nname = \"x\"\n")],
             .cargoToml, "crab@0.3.1"),
            ("py", [("pyproject.toml", "[build-system]\nrequires = []\n\n[project]\nname = 'snake'\nversion = \"1.0\"\n")],
             .pyproject, "snake@1.0"),
            ("gradle", [("settings.gradle.kts", "// rootProject.name = \"no\"\nrootProject.name = \"droid\"\n")],
             .gradleSettings, "droid"),
            ("gradle2", [("settings.gradle", "rootProject.name='old'\n")], .gradleSettings, "old"),
        ]
        for (folder, files, source, label) in cases {
            let dir = t.home + "/dev/\(folder)"
            for (name, text) in files { try t.write(dir + "/" + name, text) }
            let found = try #require(resolve(t, at: dir).manifest, "\(folder)")
            #expect(found.source == source, "\(folder)")
            #expect(found.label == label, "\(folder)")
        }
        try t.mkdir(t.home + "/dev/xc/Zed.xcodeproj")
        try t.mkdir(t.home + "/dev/xc/Alpha.xcodeproj")
        let xcode = try #require(resolve(t, at: t.home + "/dev/xc").manifest)
        #expect(xcode.source == .xcodeProject)
        #expect(xcode.name == "Alpha")
        #expect(xcode.version == nil)
    }

    @Test func theFirstSourceThatHasANameWins() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.p("package.json"), "{\"version\":\"1.0.0\"}")               // no name: falls through
        try t.write(t.p("composer.json"), "{\"name\":\"vendor/app\"}")
        try t.write(t.p("Cargo.toml"), "[package]\nname = \"crab\"\n")
        #expect(manifest(t)?.label == "vendor/app")
        try FileManager.default.removeItem(atPath: t.p("composer.json"))
        #expect(manifest(t)?.label == "crab")
    }

    @Test func noManifestMeansNoName() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.p("README.md"), "hi")
        try t.write(t.p("package.json"), "{ not json")
        #expect(manifest(t) == nil)
    }

    @Test func aSymlinkedManifestIsRefusedNotFollowed() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.root + "/outside/package.json", "{\"name\":\"evil\",\"version\":\"6.6.6\"}")
        try t.symlink(t.p("package.json"), to: t.root + "/outside/package.json")
        #expect(manifest(t) == nil)
        // …and the next source is used instead
        try t.write(t.p("Cargo.toml"), "[package]\nname = \"honest\"\n")
        #expect(manifest(t)?.name == "honest")
    }

    @Test func aManifestOverTheSizeCapIsIgnored() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let padding = String(repeating: "x", count: ProjectIdentityResolver.maxFileBytes)
        try t.write(t.p("package.json"), "{\"name\":\"big\",\"pad\":\"\(padding)\"}")
        #expect(manifest(t) == nil)
        try t.write(t.p("package.json"), "{\"name\":\"small\"}")
        #expect(manifest(t)?.name == "small")
    }

    @Test func namesAreCleanedBeforeTheyReachTheScreen() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        // an RTL override and a newline inside the name
        try t.write(t.p("package.json"), "{\"name\":\"a\\u202eb\\nc\"}")
        #expect(manifest(t)?.name == "ab c")
        try t.write(t.p("package.json"), "{\"name\":\"\(String(repeating: "n", count: 300))\"}")
        #expect(manifest(t)?.name.count == 120)
    }

    @Test func aCombiningMarkBombInAManifestNameIsBoundedAndAnInvisibleNameFallsThrough() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        // ~200 KB, under the 256 KB read cap: ONE grapheme cluster of 100 001 scalars
        try t.write(t.p("package.json"), "{\"name\":\"e" + String(repeating: "\u{0301}", count: 100_000) + "\",\"version\":\"1.0.0\"}")
        let bounded = try #require(manifest(t))
        #expect(bounded.name.unicodeScalars.count == 1 + DisplayText.maxMarksPerBase)
        #expect(bounded.version == "1.0.0")

        // a name of zero-width characters is no name: the next source speaks
        try t.write(t.p("package.json"), "{\"name\":\"\\u200b\\u2060\",\"version\":\"1.0.0\"}")
        try t.write(t.p("Cargo.toml"), "[package]\nname = \"honest\"\n")
        #expect(manifest(t)?.name == "honest")
        #expect(manifest(t)?.source == .cargoToml)
    }

    @Test func aDirectoryNamedWithInvisibleCharactersIsCleanedWhereverItIsShown() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        // The names a cloned archive can carry: a right-to-left override, a zero-width space, a newline.
        let repo = t.home + "/dev/my\u{202E}repo"
        let workspace = repo + "/ws\u{2066}x"
        let app = workspace + "/cl\u{200B}ient\nui"
        try t.mkdir(repo + "/.git")
        try t.write(workspace + "/pnpm-workspace.yaml", "packages:\n  - '*'\n")
        try t.write(app + "/package.json", "{}")

        let id = resolve(t, at: app)
        #expect(id.path == app)                                       // the real path is for the file system, untouched
        #expect(id.repoRoot == repo)
        #expect(id.folderName == "client ui")
        #expect(id.repoName == "myrepo")
        #expect(id.pathInRepo == "wsx/client ui")
        #expect(id.workspaceName == "wsx")                             // no package name: the (cleaned) folder name
        #expect(id.headerTitle == "myrepo › wsx/client ui")
        let shown = [id.folderName, id.repoName ?? "", id.pathInRepo ?? "", id.workspaceName ?? "", id.headerTitle].joined()
        #expect(!shown.unicodeScalars.contains { scalar in
            [.format, .control, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
        })
    }

    @Test func aFolderNameOfNothingVisibleIsShownAsACodePointPreviewNotAsBlank() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let id = resolve(t, at: t.home + "/dev/\u{200B}\u{2060}")
        #expect(id.folderName == "‹U+200B U+2060›")
        #expect(id.headerTitle == "‹U+200B U+2060›")
    }

    // MARK: Worktrees, submodules, reftable

    @Test func aLinkedWorktreeIsNamedAfterItsMainRepositoryWithItsOwnFolderInTheHeader() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let main = t.home + "/dev/redalert"
        try t.write(main + "/.git/HEAD", "ref: refs/heads/main\n")
        try t.write(main + "/.git/worktrees/feature-x/HEAD", "ref: refs/heads/feature-x\n")
        let worktree = t.home + "/dev/feature-x"
        try t.write(worktree + "/.git", "gitdir: \(main)/.git/worktrees/feature-x\n")
        try t.write(worktree + "/packages/client/package.json", "{}")

        let root = resolve(t, at: worktree)
        #expect(root.repoRoot == worktree)
        #expect(root.repoName == "redalert")
        #expect(root.worktreeName == "feature-x")
        #expect(root.headerTitle == "redalert (wt feature-x)")
        #expect(root.head == .branch("feature-x"))

        let nested = resolve(t, at: worktree + "/packages/client")
        #expect(nested.repoName == "redalert")
        #expect(nested.pathInRepo == "packages/client")
        #expect(nested.headerTitle == "redalert (wt feature-x) › packages/client")

        // a relative pointer names the same main repository
        let relative = t.home + "/dev/wt-rel"
        try t.write(relative + "/.git", "gitdir: ../redalert/.git/worktrees/feature-x\n")
        #expect(resolve(t, at: relative).repoName == "redalert")
        #expect(resolve(t, at: relative).worktreeName == "wt-rel")
    }

    @Test func anOrdinaryRepositoryAndASubmoduleAreNotWorktrees() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.mkdir(t.project + "/.git")
        let ordinary = resolve(t)
        #expect(ordinary.worktreeName == nil)
        #expect(ordinary.repoName == "proj")

        let super_ = t.home + "/dev/super"
        try t.write(super_ + "/.git/modules/sub/HEAD", "ref: refs/heads/sub-main\n")
        let sub = super_ + "/sub"
        try t.write(sub + "/.git", "gitdir: ../.git/modules/sub\n")
        let submodule = resolve(t, at: sub)
        #expect(submodule.repoName == "sub")
        #expect(submodule.worktreeName == nil)
        #expect(submodule.head == .branch("sub-main"))
    }

    @Test func aReftableHeadStubIsNoBranch() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        #expect(ProjectIdentityResolver.parseHead("ref: refs/heads/.invalid\n") == nil)
        try t.write(t.project + "/.git/HEAD", "ref: refs/heads/.invalid\n")
        let id = resolve(t)
        #expect(id.repoRoot == t.project)                              // still a repository
        #expect(id.head == nil)                                        // but `.invalid` is no branch to show
    }

    @Test func aGitDirectoryPointerThatCrossesASymlinkedDirectoryGivesNoBranch() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        // `<real>/wt/HEAD` is a regular file; `<alias>` is a symlink to `<real>`.
        let real = t.root + "/store/real"
        let alias = t.root + "/store/alias"
        try t.write(real + "/wt/HEAD", "ref: refs/heads/feature\n")
        try t.symlink(alias, to: real)

        try t.write(t.project + "/.git", "gitdir: \(real)/wt\n")                 // control: the real path is read
        #expect(resolve(t).head == .branch("feature"))

        try t.write(t.project + "/.git", "gitdir: \(alias)/wt\n")                // through the symlink: nothing is read
        let id = resolve(t)
        #expect(id.repoRoot == t.project)
        #expect(id.head == nil)
    }

    // MARK: The detector: cheap, cached, no process

    @Test func theDetectorCachesIdentitiesForTheTTLAndNeverSpawnsGit() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let git = S2FakeGit()
        let clock = S2Clock()
        let detector = ProjectDetector(homeDirectory: t.home, git: git, now: { clock.now })
        try t.write(t.project + "/.git/HEAD", "ref: refs/heads/main\n")
        #expect(detector.identity(ofProjectAt: t.project).head == .branch("main"))

        try t.write(t.project + "/.git/HEAD", "ref: refs/heads/other\n")
        #expect(detector.identity(ofProjectAt: t.project).head == .branch("main"), "served from the cache")
        clock.advance(ProjectDetector.cacheTTL - 1)
        #expect(detector.identity(ofProjectAt: t.project).head == .branch("main"))
        clock.advance(2)
        #expect(detector.identity(ofProjectAt: t.project).head == .branch("other"), "expired: read again")
        #expect(git.calls.isEmpty)
    }

    // MARK: One walker for the repo root (the detector's Project.repoRoot and the identity's repoRoot)

    @Test func aGitDirectoryPointerIsNormalizedTextuallyAndKeepsItsPrefix() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let main = t.home + "/dev/main"
        try t.write(main + "/.git/worktrees/wt/HEAD", "ref: refs/heads/hotfix\n")
        let relative = t.home + "/dev/wt-rel"
        try t.write(relative + "/.git", "gitdir: ../main/./.git/worktrees/../worktrees/wt\n")
        // The temp root is under /private/var: a Foundation "standardize" would rewrite it to /var, which crosses a symlink.
        #expect(ProjectIdentityResolver.gitDirectory(forRepoRoot: relative) == main + "/.git/worktrees/wt")
        #expect(resolve(t, at: relative).head == .branch("hotfix"))
        #expect(ProjectIdentityResolver.lexicallyNormalized(absolute: "/private/tmp/a/../b/./c") == "/private/tmp/b/c")
        #expect(ProjectIdentityResolver.lexicallyNormalized(absolute: "/a//b/") == "/a/b")
        #expect(ProjectIdentityResolver.lexicallyNormalized(absolute: "/../..") == "/")
    }

    @Test func theDetectorAndTheIdentityAgreeAboutWhatIsARepoRoot() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let detector = ProjectDetector(homeDirectory: t.home, git: S2FakeGit())
        try t.write(t.project + "/package.json", "{}")

        // a symlinked `.git` is no marker for either
        try t.write(t.root + "/elsewhere/.git/HEAD", "ref: refs/heads/stolen\n")
        try t.symlink(t.project + "/.git", to: t.root + "/elsewhere/.git")
        #expect(detector.project(containing: t.project)?.repoRoot == nil)
        #expect(resolve(t).repoRoot == nil)

        // a `.git` directory and a `.git` file are markers for both
        try FileManager.default.removeItem(atPath: t.project + "/.git")
        try t.mkdir(t.project + "/.git")
        let fresh = ProjectDetector(homeDirectory: t.home, git: S2FakeGit())
        #expect(fresh.project(containing: t.project)?.repoRoot == t.project)
        #expect(resolve(t).repoRoot == t.project)
    }

    @Test func theDetectorCleansProjectAndGroupNamesAtTheSource() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let evil = t.home + "/dev/my\u{202E}app\u{200B}"
        try t.write(evil + "/package.json", "{}")
        let project = try #require(ProjectDetector(homeDirectory: t.home, git: S2FakeGit()).project(containing: evil))
        #expect(project.root == evil)                                  // the real path is untouched
        #expect(project.name == "myapp")
    }

    // MARK: Header text

    @Test func theHeaderTitleFollowsRepoAndPath() {
        let withPath = S4.identity("/x/redalert/packages/client", repoRoot: "/x/redalert", pathInRepo: "packages/client")
        #expect(withPath.headerTitle == "redalert › packages/client")
        #expect(S4.identity("/x/redalert", repoRoot: "/x/redalert").headerTitle == "redalert")
        #expect(S4.identity("/x/loose").headerTitle == "loose")
        var worktree = S4.identity("/x/feature-x/packages/client", repoRoot: "/x/redalert", pathInRepo: "packages/client")
        worktree.worktreeName = "feature-x"
        #expect(worktree.headerTitle == "redalert (wt feature-x) › packages/client")
    }

    // MARK: Tiny readers

    @Test func tomlLiteReadsOnlyTheWantedSectionAndOnlySingleLineStrings() {
        let text = """
        [workspace]
        name = "not-this"
        [ package ]
        # name = "commented"
        name = "right" # trailing comment
        version = { workspace = true }
        [[bin]]
        name = "also-not"
        """
        #expect(TOMLLite.string(in: text, section: "package", key: "name") == "right")
        #expect(TOMLLite.string(in: text, section: "package", key: "version") == nil)
        #expect(TOMLLite.string(in: text, section: "bin", key: "name") == nil)
        #expect(TOMLLite.string(in: "[package]\nname = \"\"\"multi\nline\"\"\"\n", section: "package", key: "name") == nil)
    }
}
