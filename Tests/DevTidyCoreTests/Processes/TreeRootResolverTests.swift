import Foundation
import Testing
@testable import DevTidyCore

@Suite struct TreeRootResolverTests {
    private func node(_ pid: Int32, ppid: Int32, pgid: Int32? = nil, name: String, exe: String? = nil,
                      args: [String]? = nil, cwd: String? = nil) -> ProcessNode {
        S1SnapshotBuilder.node(pid, ppid: ppid, pgid: pgid, name: name, exe: exe, args: args, cwd: cwd)
    }

    private func resolve(_ listener: Int32, _ nodes: [ProcessNode]) -> TreeRootResolver.Resolution? {
        TreeRootResolver.resolve(listenerPID: listener, snapshot: S1SnapshotBuilder.snapshot(nodes: nodes))
    }

    /// DevTidy chain + `extra`.
    private func resolveWithDevTidy(_ listener: Int32, _ extra: [ProcessNode]) -> TreeRootResolver.Resolution? {
        resolve(listener, S1Fixtures.devTidyChain() + extra)
    }

    // MARK: ENV §5 trees

    @Test func nextTreeRootsAtTheNpmExecGroupLeaderAndIsEligible() throws {
        let snapshot = S1Fixtures.everything()
        for (listener, root) in [(77578, 77527), (77579, 77531), (77592, 77534), (77593, 77539)] as [(Int32, Int32)] {
            let resolution = try #require(TreeRootResolver.resolve(listenerPID: listener, snapshot: snapshot))
            #expect(resolution.root.pid == root)
            #expect(resolution.groupKillEligible)
        }
    }

    @Test func viteTreeRootsAtNpmExecAndWorkerdSharesTheRoot() throws {
        let snapshot = S1Fixtures.everything()
        let vite = try #require(TreeRootResolver.resolve(listenerPID: 9422, snapshot: snapshot))
        let workerd = try #require(TreeRootResolver.resolve(listenerPID: 9425, snapshot: snapshot))
        #expect(vite.root.pid == 9402)
        #expect(workerd.root.pid == 9402)
        #expect(vite.groupKillEligible && workerd.groupKillEligible)
        let second = try #require(TreeRootResolver.resolve(listenerPID: 9346, snapshot: snapshot))
        #expect(second.root.pid == 9333)
        #expect(second.groupKillEligible)
    }

    @Test func theSharedBrokerIsNeverPartOfAnyRoot() throws {
        let snapshot = S1Fixtures.everything()
        for listener: Int32 in [77578, 77579, 77592, 77593, 9422, 9425, 9346] {
            let resolution = try #require(TreeRootResolver.resolve(listenerPID: listener, snapshot: snapshot))
            let tree = [resolution.root.pid] + snapshot.descendants(of: resolution.root.pid).map(\.pid)
            #expect(!tree.contains(74501) && !tree.contains(3100))
        }
    }

    // MARK: Shared process groups

    @Test func sharedPgidWithAnInteractiveShellIsNotEligibleAndTheRootIsTheListener() throws {
        // `node server.js &` typed into a non-job-control shell: pgid == the shell's pid, the shell is an ancestor.
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"])
        let server = node(800, ppid: 700, pgid: 700, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let resolution = try #require(resolveWithDevTidy(800, [zsh, server]))
        #expect(resolution.root.pid == 800)
        #expect(!resolution.groupKillEligible)
    }

    @Test func aLauncherInFrontOfASharedGroupIsClimbedButTheGroupStaysForbidden() throws {
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"])
        let npm = node(710, ppid: 700, pgid: 700, name: "node", exe: S1Fixtures.nodeExe, args: ["npm run dev"])
        let server = node(720, ppid: 710, pgid: 700, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let resolution = try #require(resolveWithDevTidy(720, [zsh, npm, server]))
        #expect(resolution.root.pid == 710)
        #expect(!resolution.groupKillEligible)
    }

    @Test func aPgidContainingAForeignNonDescendantIsNotEligible() throws {
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"])
        let leader = node(800, ppid: 700, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let stray = node(801, ppid: 700, pgid: 800, name: "tail", exe: "/usr/bin/tail", args: ["tail", "-f", "log"])
        let resolution = try #require(resolveWithDevTidy(800, [zsh, leader, stray]))
        #expect(resolution.root.pid == 800)
        #expect(!resolution.groupKillEligible)
    }

    @Test func aListenerThatIsAlreadyALeaderIsItsOwnRoot() throws {
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"])
        let leader = node(900, ppid: 700, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let resolution = try #require(resolveWithDevTidy(900, [zsh, leader]))
        #expect(resolution.root.pid == 900)
        #expect(resolution.groupKillEligible)
    }

    @Test func theGroupOfDevTidyItselfIsNeverEligible() throws {
        // K11 as far as the snapshot can tell: the candidate leads the very group DevTidy belongs to.
        var nodes = S1Fixtures.devTidyChain().filter { $0.pid != S1Fixtures.selfPID }
        nodes.append(node(S1Fixtures.selfPID, ppid: 4999, pgid: 900, name: "DevTidy", exe: "/x/DevTidy", args: ["/x/DevTidy"]))
        let leader = node(900, ppid: 4999, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let resolution = try #require(resolve(900, nodes + [leader]))
        #expect(resolution.root.pid == 900)
        #expect(!resolution.groupKillEligible)
    }

    // MARK: Never-roots

    @Test(arguments: [
        ("zsh", "/bin/zsh", ["-zsh"]),
        ("login", "/usr/bin/login", ["login", "-fp", "me"]),
        ("iTerm2", "/Applications/iTerm.app/Contents/MacOS/iTerm2", ["/Applications/iTerm.app/Contents/MacOS/iTerm2"]),
        ("omp", "/Users/suleymanozcan/.local/bin/omp", ["/Users/suleymanozcan/.local/bin/omp"]),
        ("node", "/Users/suleymanozcan/.local/share/node/v22.23.3/bin/node", ["omp __omp_worker_daemon_broker"]),
        // F-3: agents that run as a script under a runtime keep comm `node` / `Python`; zero signals may start from them.
        ("node", "/Users/suleymanozcan/.local/share/node/v22.23.3/bin/node",
         ["/Users/suleymanozcan/.local/share/node/v22.23.3/bin/node",
          "/Users/suleymanozcan/.local/share/node/v22.23.3/lib/node_modules/@openai/codex/bin/codex.js"]),
        ("node", "/Users/suleymanozcan/.local/share/node/v22.23.3/bin/node",
         ["/Users/suleymanozcan/.local/share/node/v22.23.3/bin/node", "--no-warnings", "/opt/homebrew/bin/gemini"]),
        ("Python", "/opt/homebrew/bin/python3.12", ["python3.12", "/Users/suleymanozcan/.local/bin/aider", "--model", "x"]),
        ("Python", "/opt/homebrew/bin/python3.12", ["python3.12", "-m", "aider"]),
        ("cursor-agent", "/Users/suleymanozcan/.local/bin/cursor-agent", ["cursor-agent"]),
        ("idea", "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea", ["/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"]),
        ("nvim", "/opt/homebrew/bin/nvim", ["nvim", "server.js"]),
        ("tmux", "/opt/homebrew/bin/tmux", ["tmux", "new"]),
        ("ssh", "/usr/bin/ssh", ["ssh", "dev-box"]),
    ] as [(String, String, [String])])
    func shellTerminalAgentAndBrokerNeverBecomeThePgidLeaderRoot(name: String, exe: String, args: [String]) throws {
        let leader = node(600, ppid: 3184, name: name, exe: exe, args: args)
        let server = node(620, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let resolution = try #require(resolveWithDevTidy(620, [leader, server]))
        #expect(resolution.root.pid == 620, "\(name) must never be chosen as the kill root")
        #expect(!resolution.groupKillEligible)
    }

    @Test func anInteractiveShellBetweenTheListenerAndItsGroupLeaderPreventsTheLeaderChoice() throws {
        let npm = node(600, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe, args: ["npm run dev"])
        let shell = node(610, ppid: 600, pgid: 600, name: "zsh", exe: "/bin/zsh", args: ["zsh"])
        let server = node(620, ppid: 610, pgid: 600, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let resolution = try #require(resolveWithDevTidy(620, [npm, shell, server]))
        #expect(resolution.root.pid == 620)
        #expect(!resolution.groupKillEligible)
    }

    // MARK: Browsers and app bundles (QA F6)

    @Test func aBrowserBelowTheRootIsCutOutOfTheTreeAndTheGroupIsNoLongerEligible() throws {
        // A Python test driver (own group) that launched Chrome in the same group.
        let python = node(800, ppid: 4999, name: "Python", exe: "/opt/homebrew/bin/python3.12", args: ["python3.12", "driver.py"])
        let chrome = node(810, ppid: 800, pgid: 800, name: "Google Chrome", exe: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                          args: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"])
        let helper = node(811, ppid: 810, pgid: 800, name: "Google Chrome He",
                          exe: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
        let resolution = try #require(resolveWithDevTidy(800, [python, chrome, helper]))
        #expect(resolution.root.pid == 800)
        #expect(resolution.scope.members.map(\.pid) == [800])
        #expect(resolution.scope.spared.map(\.pid) == [810])          // the helper is below a spared root, not listed on its own
        #expect(!resolution.groupKillEligible)                         // kill(-800) would reach Chrome
    }

    @Test func anAppBundleBetweenTheListenerAndTheGroupLeaderPreventsTheLeaderChoice() throws {
        let npm = node(600, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe, args: ["npm run dev"])
        let electron = node(610, ppid: 600, pgid: 600, name: "Electron",
                            exe: "/Users/suleymanozcan/developer/app/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")
        let server = node(620, ppid: 610, pgid: 600, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let resolution = try #require(resolveWithDevTidy(620, [npm, electron, server]))
        #expect(resolution.root.pid == 620)
        #expect(!resolution.groupKillEligible)
    }

    // MARK: Launchers

    @Test func concurrentlyWithTwoListenersIsOneServer() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let concurrently = node(500, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe, args: ["concurrently next dev vite"], cwd: dir)
        let shellA = node(510, ppid: 500, pgid: 500, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "next dev"], cwd: dir)
        let nextA = node(511, ppid: 510, pgid: 500, name: "node", exe: S1Fixtures.nodeExe,
                         args: [S1Fixtures.nodeExe, dir + "/node_modules/.bin/next", "dev", "-p", "3000"], cwd: dir)
        let shellB = node(520, ppid: 500, pgid: 500, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "vite"], cwd: dir)
        let viteB = node(521, ppid: 520, pgid: 500, name: "node", exe: S1Fixtures.nodeExe,
                         args: [S1Fixtures.nodeExe, dir + "/node_modules/.bin/vite", "--port", "5173"], cwd: dir)
        let nodes = S1Fixtures.devTidyChain() + [concurrently, shellA, nextA, shellB, viteB]
        let ports = [S1SnapshotBuilder.port(3000, owner: 511), S1SnapshotBuilder.port(5173, owner: 521)]
        let snapshot = S1SnapshotBuilder.snapshot(nodes: nodes, listeners: ports)

        let a = try #require(TreeRootResolver.resolve(listenerPID: 511, snapshot: snapshot))
        let b = try #require(TreeRootResolver.resolve(listenerPID: 521, snapshot: snapshot))
        #expect(a.root.pid == 500 && b.root.pid == 500)
        #expect(a.groupKillEligible)

        let scan = await ServerClassifier(projects: S1Fixtures.projectDetector(), homeDirectory: S1Fixtures.home).classify(snapshot)
        #expect(scan.servers.count == 1)
        #expect(scan.servers.first?.ports.map(\.port).sorted() == [3000, 5173])
        #expect(scan.servers.first?.members.map(\.pid) == [500, 510, 520, 511, 521])
    }

    @Test func shDashCLauncherIsClimbedButTheInteractiveZshAboveItIsNot() throws {
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"])
        let launcher = node(710, ppid: 700, pgid: 700, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "next dev"])
        let server = node(720, ppid: 710, pgid: 700, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "next", "dev"])
        let resolution = try #require(resolveWithDevTidy(720, [zsh, launcher, server]))
        #expect(resolution.root.pid == 710)
        #expect(!resolution.groupKillEligible)
    }

    @Test func aPlainShellWithoutDashCIsNotALauncher() throws {
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["zsh"])
        let server = node(720, ppid: 700, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "next", "dev"])
        let resolution = try #require(resolveWithDevTidy(720, [zsh, server]))
        #expect(resolution.root.pid == 720)
    }

    // MARK: N-6 — a runtime that leads the group must belong to the listener's project

    private let project = S1Fixtures.developer + "/pyproj"

    private func resolve(_ listener: Int32, devTidyAnd extra: [ProcessNode], projectRoot: String?,
                         repoRoot: String? = nil) -> TreeRootResolver.Resolution? {
        TreeRootResolver.resolve(listenerPID: listener,
                                 snapshot: S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + extra),
                                 projectAnchors: [projectRoot, repoRoot].compactMap { $0 })
    }

    @Test func aRuntimeThatLeadsTheGroupFromAnotherDirectoryIsNotTheRoot() throws {
        // An agent we have no name for (`node …/some-cli.js`, started from the folder above the project) spawned the server
        // without its own process group, so it leads the group. It must not become the kill root.
        let tool = node(600, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe,
                        args: [S1Fixtures.nodeExe, "/opt/tools/some-cli/cli.js"], cwd: S1Fixtures.developer)
        let server = node(620, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, project + "/server.js"], cwd: project)
        let resolution = try #require(resolve(620, devTidyAnd: [tool, server], projectRoot: project))
        #expect(resolution.root.pid == 620)
        #expect(!resolution.groupKillEligible)
        #expect(resolution.scope.members.map(\.pid) == [620])
    }

    @Test func aRuntimeLeaderInsideTheProjectIsStillTheRootAndTheGroupStaysEligible() throws {
        // Django's autoreloader: the parent `manage.py runserver` leads the group, the child listens.
        let args = ["python3.12", "manage.py", "runserver"]
        let parent = node(600, ppid: 3184, name: "Python", exe: "/opt/homebrew/bin/python3.12", args: args, cwd: project)
        let child = node(620, ppid: 600, pgid: 600, name: "Python", exe: "/opt/homebrew/bin/python3.12", args: args, cwd: project)
        let resolution = try #require(resolve(620, devTidyAnd: [parent, child], projectRoot: project))
        #expect(resolution.root.pid == 600)
        #expect(resolution.groupKillEligible)
    }

    @Test func aLeaderBelowTheProjectRootBelongsToTheProject() throws {
        // Laravel's `artisan serve` starts `php -S` in `public/` while the leader runs in the project root.
        let artisan = node(600, ppid: 3184, name: "php", exe: "/opt/homebrew/bin/php", args: ["php", "artisan", "serve"], cwd: project)
        let builtIn = node(620, ppid: 600, pgid: 600, name: "php", exe: "/opt/homebrew/bin/php",
                           args: ["php", "-S", "127.0.0.1:8000"], cwd: project + "/public")
        let resolution = try #require(resolve(620, devTidyAnd: [artisan, builtIn], projectRoot: project))
        #expect(resolution.root.pid == 600)
        #expect(resolution.groupKillEligible)
    }

    @Test func aLeadersOwnExecutableInsideTheProjectIsEnoughWhateverItsWorkingDirectory() throws {
        let tsx = node(610, ppid: 3184, name: "tsx", exe: project + "/node_modules/.bin/tsx", args: ["tsx", "watch", "server.ts"], cwd: "/")
        let server = node(630, ppid: 610, pgid: 610, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, project + "/server.ts"], cwd: project)
        let resolution = try #require(resolve(630, devTidyAnd: [tsx, server], projectRoot: project))
        #expect(resolution.root.pid == 610)
        #expect(resolution.groupKillEligible)
    }

    @Test func aPathInTheLeadersArgumentsAloneDoesNotMakeItBelongToTheProject() throws {
        // F3-7: any tool can be pointed at a project's script. Only where the leader runs from or what it is counts.
        let tool = node(610, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe,
                        args: [S1Fixtures.nodeExe, "/opt/tools/some-cli/cli.js", project + "/node_modules/.bin/vite"], cwd: "/")
        let workerd = node(630, ppid: 610, pgid: 610, name: "workerd", exe: "/opt/tools/workerd", args: ["workerd", "serve"], cwd: "/")
        let resolution = try #require(resolve(630, devTidyAnd: [tool, workerd], projectRoot: project))
        #expect(resolution.root.pid == 630)
        #expect(!resolution.groupKillEligible)
        #expect(resolution.scope.members.map(\.pid) == [630])
    }

    @Test func aMonorepoOrchestratorAtTheRepoRootIsAcceptedOnlyWhenTheRepoIsAnAnchor() throws {
        let repo = S1Fixtures.developer + "/mono"
        let package = repo + "/packages/client"
        let deno = node(600, ppid: 3184, name: "deno", exe: "/opt/homebrew/bin/deno", args: ["deno", "task", "dev"], cwd: repo)
        let vite = node(620, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                        args: [S1Fixtures.nodeExe, package + "/node_modules/.bin/vite"], cwd: package)

        // Anchored on the package alone the orchestrator is a stranger (the second-pass rule).
        let alone = try #require(resolve(620, devTidyAnd: [deno, vite], projectRoot: package))
        #expect(alone.root.pid == 620)
        #expect(!alone.groupKillEligible)

        // With the repository as an anchor it is the root again and the group may be signalled.
        let anchored = try #require(resolve(620, devTidyAnd: [deno, vite], projectRoot: package, repoRoot: repo))
        #expect(anchored.root.pid == 600)
        #expect(anchored.groupKillEligible)

        // An orchestrator that runs from a sibling repository is still no root.
        let elsewhere = node(601, ppid: 3184, name: "deno", exe: "/opt/homebrew/bin/deno", args: ["deno", "task", "dev"],
                             cwd: S1Fixtures.developer + "/other")
        let vite2 = node(621, ppid: 601, pgid: 601, name: "node", exe: S1Fixtures.nodeExe,
                         args: [S1Fixtures.nodeExe, package + "/node_modules/.bin/vite"], cwd: package)
        #expect(try #require(resolve(621, devTidyAnd: [elsewhere, vite2], projectRoot: package, repoRoot: repo)).root.pid == 621)
    }

    @Test func withoutAProjectTheListenersOwnDirectoryIsTheAnchorAndUnknownDirectoriesFailSafe() throws {
        let sameDirectory = node(600, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe,
                                 args: [S1Fixtures.nodeExe, "watcher.js"], cwd: "/tmp/site")
        let child = node(620, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                         args: [S1Fixtures.nodeExe, "server.js"], cwd: "/tmp/site")
        #expect(try #require(resolve(620, devTidyAnd: [sameDirectory, child], projectRoot: nil)).root.pid == 600)

        let elsewhere = node(601, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe,
                             args: [S1Fixtures.nodeExe, "watcher.js"], cwd: "/tmp/other")
        let child2 = node(621, ppid: 601, pgid: 601, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, "server.js"], cwd: "/tmp/site")
        #expect(try #require(resolve(621, devTidyAnd: [elsewhere, child2], projectRoot: nil)).root.pid == 621)

        let unreadable = node(602, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "watcher.js"])
        let child3 = node(622, ppid: 602, pgid: 602, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, "server.js"], cwd: "/tmp/site")
        #expect(try #require(resolve(622, devTidyAnd: [unreadable, child3], projectRoot: nil)).root.pid == 622)
    }

    @Test func aLauncherLeaderNeedsNoProjectRelation() throws {
        let npm = node(600, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe, args: ["npm run dev"], cwd: S1Fixtures.developer)
        let server = node(620, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, project + "/server.js"], cwd: project)
        let resolution = try #require(resolve(620, devTidyAnd: [npm, server], projectRoot: project))
        #expect(resolution.root.pid == 600)
        #expect(resolution.groupKillEligible)
    }

    // MARK: Protected processes

    @Test func devTidyItselfAndItsAncestorsResolveToNothing() {
        let snapshot = S1Fixtures.everything()
        for pid: Int32 in [S1Fixtures.selfPID, 4999, 4998, 3184, 3178] {
            #expect(TreeRootResolver.resolve(listenerPID: pid, snapshot: snapshot) == nil)
        }
    }

    @Test func aLauncherThatIsAnAncestorOfDevTidyIsNeverClimbed() throws {
        // `npm test` runs DevTidy's tests; the server spawned by a test must not resolve to DevTidy's own npm.
        let npm = node(300, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe, args: ["npm test"])
        var nodes = S1Fixtures.devTidyChain().filter { $0.pid != S1Fixtures.selfPID && $0.pid != 4999 }
        nodes.append(node(4999, ppid: 300, pgid: 300, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "swift test"]))
        nodes.append(node(S1Fixtures.selfPID, ppid: 4999, pgid: 300, name: "DevTidy", exe: "/x/DevTidy", args: ["/x/DevTidy"]))
        let child = node(6000, ppid: S1Fixtures.selfPID, pgid: 300, name: "Python",
                         exe: "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
                         args: ["python3", "-m", "http.server"])
        let resolution = try #require(resolve(6000, nodes + [npm, child]))
        #expect(resolution.root.pid == 6000)
        #expect(!resolution.groupKillEligible)
    }

    @Test func protectedPIDsCoverReservedDevTidyAndAncestors() {
        let snapshot = S1Fixtures.everything()
        let protected = TreeRootResolver.protectedPIDs(in: snapshot)
        #expect(protected.isSuperset(of: [0, 1, S1Fixtures.selfPID, 4999, 4998, 3184, 3178]))
        #expect(!protected.contains(74501))
        #expect(!protected.contains(77527))
    }
}
