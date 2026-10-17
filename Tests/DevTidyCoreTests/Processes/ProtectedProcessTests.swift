import Foundation
import Testing
@testable import DevTidyCore

/// F-3 (never-root tables) and QA F6 (browsers / app bundles are never signalled): the pure predicates behind
/// `TreeRootResolver`, `TreeScope` and `TreeTerminator`.
@Suite struct ProtectedProcessTests {
    private func node(name: String, exe: String? = nil, args: [String]? = nil) -> ProcessNode {
        S1SnapshotBuilder.node(900, ppid: 1, name: name, exe: exe, args: args)
    }

    private let nodeExe = S1Fixtures.nodeExe

    @Test(arguments: [
        "codex", "aider", "cursor-agent", "gemini", "opencode", "amp", "claude", "omp",
        "idea", "webstorm", "pycharm", "zed", "nvim", "vim", "emacs", "xcode", "Xcode", "sublime_text",
        "tmux", "screen", "ssh", "zellij", "wezterm-gui", "iTerm2", "Terminal", "claude-code", "kiro-cli",
    ])
    func widenedToolNamesAreNeverKillRoots(name: String) {
        #expect(ProcessNames.isShellTerminalIDEOrAgent(node(name: name)), "\(name)")
    }

    @Test func nodeAndPythonHostedAgentsAreRecognisedByScriptOrPackage() {
        let codex = node(name: "node", exe: nodeExe, args: [nodeExe, "/lib/node_modules/@openai/codex/bin/codex.js"])
        #expect(ProcessNames.isAgent(codex))
        #expect(ProcessNames.hostedAgentName(codex) == "codex")
        #expect(ProcessNames.isAgent(node(name: "node", exe: nodeExe, args: [nodeExe, "--no-warnings", "/opt/homebrew/bin/gemini"])))
        #expect(ProcessNames.isAgent(node(name: "node", exe: nodeExe, args: ["node /opt/homebrew/bin/opencode run"])))
        #expect(ProcessNames.isAgent(node(name: "Python", exe: "/opt/homebrew/bin/python3.12", args: ["python3.12", "-m", "aider"])))
        #expect(ProcessNames.isAgent(node(name: "Python", exe: "/opt/homebrew/bin/python3.12", args: ["python3.12", "/u/.local/bin/aider"])))
        #expect(ProcessNames.isAgent(node(name: "node", exe: nodeExe, args: [nodeExe, "/u/.local/bin/kiro-cli"])))
    }

    @Test func ordinaryServersAreNotMistakenForAgents() {
        let servers: [ProcessNode] = [
            node(name: "node", exe: nodeExe, args: [nodeExe, "server.js", "--name", "codex"]),     // only the first non-option argument counts
            node(name: "node", exe: nodeExe, args: [nodeExe, "/p/node_modules/.bin/next", "dev", "-p", "3000"]),
            node(name: "node", exe: nodeExe, args: ["next-server (v16.3.4)", ""]),
            node(name: "node", exe: nodeExe, args: ["npm exec vite --port 5174"]),
            node(name: "Python", exe: "/opt/homebrew/bin/python3.12", args: ["python3.12", "-m", "http.server", "8000"]),
            node(name: "workerd", exe: "/p/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd", args: ["workerd", "serve"]),
            node(name: "php", exe: "/opt/homebrew/bin/php", args: ["php", "artisan", "serve"]),
            // P3-3: a project's own script or module that merely shares an agent's name is a server, not a tool.
            node(name: "node", exe: nodeExe, args: [nodeExe, "gemini.js"]),
            node(name: "node", exe: nodeExe, args: [nodeExe, "./scripts/codex.mjs", "--port", "4000"]),
            node(name: "node", exe: nodeExe, args: [nodeExe, "--watch", "amp.js"]),
            node(name: "Python", exe: "/opt/homebrew/bin/python3.12", args: ["python3.12", "-m", "copilot"]),
            node(name: "Python", exe: "/opt/homebrew/bin/python3.12", args: ["python3.12", "crush.py"]),
        ]
        for server in servers {
            #expect(!ProcessNames.isAgent(server), "\(server.arguments ?? [])")
            #expect(!ProcessNames.isShellTerminalIDEOrAgent(server), "\(server.arguments ?? [])")
        }
    }

    @Test func launcherShellsWithDashCRemainAllowedRoots() {
        #expect(!ProcessNames.isShellTerminalIDEOrAgent(node(name: "sh", exe: "/bin/sh", args: ["sh", "-c", "vite"])))
        #expect(ProcessNames.isShellTerminalIDEOrAgent(node(name: "zsh", exe: "/bin/zsh", args: ["-zsh"])))
    }

    @Test func browsersAndAppBundleProcessesAreSparedButRuntimesInsideBundlesAreNot() {
        let chrome = node(name: "Google Chrome", exe: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let helper = node(name: "Google Chrome He")                                   // comm only: exe not readable
        let headless = node(name: "chrome-headless-shell", exe: "/u/.cache/puppeteer/chrome-headless-shell-mac-arm64/chrome-headless-shell")
        let firefox = node(name: "firefox", exe: "/opt/homebrew/bin/firefox")
        let electron = node(name: "Electron", exe: "/p/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")
        let xcodebuild = node(name: "xcodebuild", exe: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
        for spared in [chrome, helper, headless, firefox, electron, xcodebuild] {
            #expect(ProcessNames.isBrowserOrAppBundle(spared), "\(spared.name)")
        }

        let xcodePython = node(name: "Python", exe: "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python")
        let bundledNode = node(name: "node", exe: "/Applications/Cursor.app/Contents/Resources/app/resources/helpers/node")
        let plainServer = node(name: "node", exe: nodeExe, args: [nodeExe, "server.js"])
        for kept in [xcodePython, bundledNode, plainServer] {
            #expect(!ProcessNames.isBrowserOrAppBundle(kept), "\(kept.name)")
        }
    }

    @Test func theTreeScopeCutsEveryBrowserSubtreeAndKeepsTheRest() {
        let python = S1SnapshotBuilder.node(800, ppid: 1, name: "Python", exe: "/opt/homebrew/bin/python3.12", args: ["python3.12", "driver.py"])
        let worker = S1SnapshotBuilder.node(801, ppid: 800, pgid: 800, name: "node", exe: nodeExe, args: [nodeExe, "w.js"])
        let chrome = S1SnapshotBuilder.node(810, ppid: 800, pgid: 800, name: "Google Chrome",
                                            exe: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let renderer = S1SnapshotBuilder.node(811, ppid: 810, pgid: 800, name: "Google Chrome He")
        let grandchildOfWorker = S1SnapshotBuilder.node(802, ppid: 801, pgid: 800, name: "sleep", exe: "/bin/sleep", args: ["sleep", "1"])
        let snapshot = S1SnapshotBuilder.snapshot(nodes: [python, worker, chrome, renderer, grandchildOfWorker])
        let scope = TreeScope.of(root: python, in: snapshot, serving: [])
        #expect(scope.members.map(\.pid) == [800, 801, 802])
        #expect(scope.spared.map(\.pid) == [810])
    }

    // MARK: N-5 — terminals, IDEs and agents below the root are spared too

    @Test func anAgentOrEditorBelowTheRootIsSparedWithEverythingUnderIt() {
        let dev = S1SnapshotBuilder.node(800, ppid: 1, name: "node", exe: nodeExe, args: ["npm run dev"])
        let server = S1SnapshotBuilder.node(801, ppid: 800, pgid: 800, name: "node", exe: nodeExe, args: [nodeExe, "server.js"])
        let agent = S1SnapshotBuilder.node(810, ppid: 800, pgid: 800, name: "claude", exe: "/u/.local/bin/claude", args: ["claude"])
        let agentsShell = S1SnapshotBuilder.node(811, ppid: 810, pgid: 810, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "ls"])
        let editor = S1SnapshotBuilder.node(820, ppid: 800, pgid: 800, name: "nvim", exe: "/opt/homebrew/bin/nvim", args: ["nvim"])
        let hosted = S1SnapshotBuilder.node(830, ppid: 800, pgid: 800, name: "node", exe: nodeExe,
                                            args: [nodeExe, "/opt/homebrew/bin/gemini"])
        let snapshot = S1SnapshotBuilder.snapshot(nodes: [dev, server, agent, agentsShell, editor, hosted])
        let scope = TreeScope.of(root: dev, in: snapshot, serving: [801])
        #expect(scope.members.map(\.pid) == [800, 801])
        #expect(scope.spared.map(\.pid) == [810, 820, 830])         // 811 hangs below the agent and is not listed on its own
    }

    @Test func aListeningServerKeepsItsPlaceEvenWhenItsNameIsAnEditorsName() {
        // A project binary called `fleet` / `hx` is the server being stopped, not an editor session below it.
        let dev = S1SnapshotBuilder.node(800, ppid: 1, name: "node", exe: nodeExe, args: ["npm run dev"])
        let binary = S1SnapshotBuilder.node(801, ppid: 800, pgid: 800, name: "fleet", exe: "/p/target/debug/fleet", args: ["/p/target/debug/fleet"])
        let snapshot = S1SnapshotBuilder.snapshot(nodes: [dev, binary])
        #expect(TreeScope.of(root: dev, in: snapshot, serving: [801]).members.map(\.pid) == [800, 801])
        #expect(TreeScope.of(root: dev, in: snapshot, serving: []).spared.map(\.pid) == [801])
    }
}
