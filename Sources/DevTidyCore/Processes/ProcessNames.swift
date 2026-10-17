import Foundation

/// Static name / path tables and the small predicates built on them (design §4.3, §4.4). Pure: no syscalls.
///
/// Names are compared lowercased. Kernel `comm` is truncated to 16 characters and several runtimes rewrite their
/// process title (`npm exec next dev -p 3000`, `next-server (v16.3.4)`), so every predicate looks at three
/// *identifiers* of a node: `comm`, the executable's basename and `argv[0]` (first word when it is a rewritten title).
enum ProcessNames {

    // MARK: Tables

    /// Runtime / dev-tool names (ENV §3 rule 2). `python*` and `/Python.app/` are handled in `isRuntime`.
    static let runtimes: Set<String> = [
        "node", "bun", "deno", "ruby", "php", "php-fpm", "java", "uvicorn", "gunicorn", "puma", "rails", "hugo", "vite",
        "next-server", "webpack", "webpack-dev-server", "wrangler", "workerd", "esbuild", "nodemon", "tsx", "ts-node",
        "dotnet", "flask", "hypercorn", "daphne",
    ]

    /// Docker / VM backends whose listeners are published container ports. `com.docker.*` is matched by prefix because
    /// `pbi_comm` is cut at 16 characters (`com.docker.backe`).
    static let dockerBackendNames: Set<String> = ["orbstack", "limactl", "colima"]
    static let dockerBackendNamePrefix = "com.docker."
    static let dockerAppPrefix = "/Applications/Docker.app/"

    /// Process launchers a dev server is commonly started through.
    static let launchers: Set<String> = [
        "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx", "corepack", "turbo", "nx", "concurrently", "nodemon",
        "foreman", "overmind", "honcho",
    ]
    /// Shells that count as launchers only when invoked with `-c`.
    static let launcherShells: Set<String> = ["sh", "bash", "zsh", "dash"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]
    static let terminals: Set<String> = [
        "login", "launchd", "iterm2", "itermserver", "terminal", "ghostty", "warp", "wezterm", "wezterm-gui", "alacritty", "kitty",
        "hyper", "tabby", "tmux", "screen", "zellij", "tmate", "ssh", "sshd", "mosh", "mosh-server", "mosh-client",
    ]
    /// Editors and IDEs (kernel `comm` / executable basename / argv[0]). JetBrains launchers are named after the product.
    static let ides: Set<String> = [
        "code", "cursor", "windsurf", "trae", "kiro", "xcode", "zed", "fleet", "sublime_text", "subl", "nova",
        "idea", "idea-ce", "webstorm", "pycharm", "pycharm-ce", "phpstorm", "goland", "rider", "clion", "rubymine",
        "datagrip", "dataspell", "appcode", "studio", "nvim", "vim", "vi", "emacs", "helix", "hx", "nano",
    ]
    /// AI / coding agent CLIs. Several are Node or Python scripts (comm `node` / `Python`), see `hostedAgentName`.
    static let agents: Set<String> = [
        "omp", "claude", "claude-code", "codex", "aider", "cursor-agent", "gemini", "opencode", "amp", "goose", "crush",
        "droid", "copilot", "qwen", "kiro-cli", "cline", "plandex", "auggie", "devin",
    ]
    /// Agents shipped as a Python package and started with `python -m <module>`. A module name cannot be told from a
    /// project's own module (`python -m copilot`), so only names no ordinary project is likely to call a module are listed.
    static let pythonModuleAgents: Set<String> = ["aider", "goose"]
    /// Package directories of agent CLIs that run as a script under a runtime.
    static let agentPackageMarkers = [
        "/@openai/codex", "/@google/gemini-cli", "/@anthropic-ai/claude-code", "/opencode-ai", "/@sourcegraph/amp",
        "/@github/copilot", "/@qwen-code", "/aider-chat", "/@augmentcode/auggie",
    ]
    /// argv fragment of the omp agent daemon broker (ENV §2.1); anything carrying it is never a kill root.
    static let agentBrokerMarker = "__omp_worker_daemon_broker"

    /// Browsers that are not (only) recognisable by an app bundle path: Playwright / Puppeteer headless builds, Linux-style
    /// layouts. Compared against the node's identifiers, lowercased.
    static let browserNames: Set<String> = [
        "chrome", "chromium", "chrome-headless-shell", "headless_shell", "firefox", "firefox-bin", "msedge", "brave",
        "opera", "vivaldi", "safari",
    ]
    /// `comm` is cut at 16 characters (`Google Chrome He`), so the long browser names are matched by prefix.
    static let browserNamePrefixes = ["google chrome", "chromium", "microsoft edge", "brave browser", "firefox"]

    /// Executable prefixes that mark a non-candidate listener as a system component (`OtherListenerReason.system`).
    static let systemExecutablePrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/Library/"]
    /// Executable prefixes that mark a non-candidate listener as an app (`OtherListenerReason.app`).
    static let appExecutablePrefixes = ["/Applications/"]
    static let appBundleMarker = ".app/Contents/"

    // MARK: String helpers

    static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `"pnpm.cjs"` → `"pnpm"`; nil when there is no extension of 1…4 characters.
    static func strippingExtension(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard (1...4).contains(ext.count) else { return nil }
        return String(name[..<dot])
    }

    /// Lowercased, without the login-shell marker (`-zsh` → `zsh`).
    private static func clean(_ raw: String) -> String {
        var s = Substring(raw.lowercased())
        while s.first == "-" { s = s.dropFirst() }
        return String(s)
    }

    // MARK: Arguments

    /// `arguments` with trailing empty strings removed (a rewritten title leaves `["title", ""]`).
    static func trimmedArguments(_ node: ProcessNode) -> [String] {
        var args = node.arguments ?? []
        while args.last?.isEmpty == true { args.removeLast() }
        return args
    }

    /// Argv as a token list. A single non-path argument containing spaces is a rewritten process title and is split.
    static func tokens(of node: ProcessNode) -> [String] {
        let args = trimmedArguments(node)
        if args.count == 1, !args[0].hasPrefix("/"), args[0].contains(" ") {
            return args[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }
        return args
    }

    /// True for `-c`, `-lc`, `-ic` … appearing before the first non-flag token (`sh script.sh -c x` is not a command shell).
    static func hasCommandFlag(_ node: ProcessNode) -> Bool {
        guard let args = node.arguments, args.count > 1 else { return false }
        var skipNext = false
        for arg in args.dropFirst() {
            if skipNext { skipNext = false; continue }
            guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 1 else { return false }
            if arg == "-o" || arg == "-O" { skipNext = true; continue }
            if arg.dropFirst().contains("c") { return true }
        }
        return false
    }

    // MARK: Identity

    /// `comm`, executable basename and `argv[0]` (basename if absolute, else first word), lowercased.
    static func identifiers(of node: ProcessNode) -> [String] {
        var out = [clean(node.name)]
        if let exe = node.executablePath, !exe.isEmpty { out.append(clean(basename(exe))) }
        if let first = node.arguments?.first, !first.isEmpty {
            if first.hasPrefix("/") {
                out.append(clean(basename(first)))
            } else if let word = first.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first {
                out.append(clean(String(word)))
            }
        }
        return out
    }

    /// `identifiers` plus the script name of `node <script>` (`npm-cli.js` → `npm`, `pnpm.cjs` → `pnpm`).
    /// Used only for launcher detection so a project script called `code.js` never looks like an IDE.
    private static func launcherIdentifiers(of node: ProcessNode) -> [String] {
        var ids = identifiers(of: node)
        if ids.contains("node"), let args = node.arguments, args.count >= 2, args[1].hasPrefix("/") {
            var script = basename(args[1]).lowercased()
            script = strippingExtension(script) ?? script
            if script == "npm-cli" { script = "npm" } else if script == "npx-cli" { script = "npx" }
            ids.append(script)
        }
        return ids
    }

    // MARK: Predicates

    /// Runtime by name only (the `/node_modules/` part of the candidate rule lives in the classifier).
    static func isRuntime(_ node: ProcessNode) -> Bool {
        let name = node.name.lowercased()
        if runtimes.contains(name) || name.hasPrefix("python") { return true }
        if let exe = node.executablePath {
            let base = basename(exe).lowercased()
            if runtimes.contains(base) || base.hasPrefix("python") || exe.contains("/Python.app/") { return true }
        }
        return false
    }

    static func isDockerBackend(_ node: ProcessNode) -> Bool {
        if let exe = node.executablePath, exe.hasPrefix(dockerAppPrefix) { return true }
        let name = node.name.lowercased()
        return name.hasPrefix(dockerBackendNamePrefix) || dockerBackendNames.contains(name)
    }

    static func isLauncher(_ node: ProcessNode) -> Bool {
        let ids = launcherIdentifiers(of: node)
        if ids.contains(where: { launchers.contains($0) }) { return true }
        return ids.contains(where: { launcherShells.contains($0) }) && hasCommandFlag(node)
    }

    /// Any shell, with or without `-c`.
    static func isShell(_ node: ProcessNode) -> Bool {
        identifiers(of: node).contains { shells.contains($0) }
    }

    /// Agent CLI by name, by the agent broker marker, or as a script hosted by a runtime (`node …/codex.js`,
    /// `python …/bin/aider`, `python -m aider`) whose comm / executable / argv[0] only say `node` / `Python`.
    static func isAgent(_ node: ProcessNode) -> Bool {
        if identifiers(of: node).contains(where: { agents.contains($0) }) { return true }
        if (node.arguments ?? []).contains(where: { $0.contains(agentBrokerMarker) }) { return true }
        return hostedAgentName(node) != nil
    }

    /// The agent a runtime process is hosting, nil when it is not running one. Installed agents are started through an
    /// absolute path (a shebang shim such as `/opt/homebrew/bin/gemini`, a package under `node_modules`); a *relative* script
    /// (`node gemini.js`) is a file of the project being run and never an agent. `python -m <module>` counts only for the
    /// modules in `pythonModuleAgents`.
    static func hostedAgentName(_ node: ProcessNode) -> String? {
        let hosts: Set<String> = ["node", "bun", "deno"]
        guard identifiers(of: node).contains(where: { hosts.contains($0) || $0.hasPrefix("python") }) else { return nil }
        let args = tokens(of: node)
        for arg in args where arg.hasPrefix("/") {
            if let marker = agentPackageMarkers.first(where: { arg.contains($0 + "/") }) {
                return String(marker.split(separator: "/").last ?? "")
            }
        }
        // The first non-option argument after argv[0] is the script (or the module after `-m`).
        var index = 1
        while index < args.count, index <= 8 {
            let arg = args[index]
            if arg == "-m", index + 1 < args.count { return pythonModuleAgent(args[index + 1]) }
            if arg.hasPrefix("-") { index += 1; continue }
            return agentName(forScript: arg)
        }
        return nil
    }

    private static func agentName(forScript script: String) -> String? {
        guard script.hasPrefix("/") else { return nil }
        var name = basename(script).lowercased()
        name = strippingExtension(name) ?? name
        return agents.contains(name) ? name : nil
    }

    private static func pythonModuleAgent(_ module: String) -> String? {
        let name = module.lowercased()
        return pythonModuleAgents.contains(name) ? name : nil
    }

    static func isTerminalIDEOrAgent(_ node: ProcessNode) -> Bool {
        let ids = identifiers(of: node)
        if ids.contains(where: { terminals.contains($0) || $0.hasPrefix("iterm") || ides.contains($0) }) { return true }
        return isAgent(node)
    }

    /// Web browsers: never part of a server tree's kill set, whatever they are parented to (a test driver that launches
    /// Chrome must not take the browser with it when the driver is stopped).
    static func isBrowser(_ node: ProcessNode) -> Bool {
        identifiers(of: node).contains { id in
            browserNames.contains(id) || browserNamePrefixes.contains(where: { id.hasPrefix($0) })
        }
    }

    /// A non-runtime process running out of an application bundle (`….app/Contents/…`): Electron apps, Xcode tools, IDE
    /// helpers. Runtimes inside a bundle (Xcode's `Python.app`) are the servers themselves and stay eligible.
    static func isAppBundleProcess(_ node: ProcessNode) -> Bool {
        guard !isRuntime(node), let exe = node.executablePath else { return false }
        return exe.contains(appBundleMarker)
    }

    /// Browsers and app-bundle processes are never signalled as part of a server tree (QA F6).
    static func isBrowserOrAppBundle(_ node: ProcessNode) -> Bool {
        isBrowser(node) || isAppBundleProcess(node)
    }

    /// Processes below a server's root that are never signalled with it: browsers and app-bundle processes (QA F6) and
    /// terminals, IDEs and agents (N-5), whatever they were started from — a live session of somebody's is not part of the
    /// dev server. `serving` are the pids of the listening processes being stopped: such a process is the server itself even
    /// when a project binary shares its name with an editor (`fleet`, `hx`), so only the browser / app-bundle rule applies to it.
    static func isSparedBelowRoot(_ node: ProcessNode, serving: Set<Int32>) -> Bool {
        if isBrowserOrAppBundle(node) { return true }
        return !serving.contains(node.pid) && isTerminalIDEOrAgent(node)
    }

    /// The name rule for a kill ROOT (F-3): terminals, IDEs and agents are never one. A root that is itself the listening
    /// server (`serving`) is exempt from the EDITOR / IDE names only: a project binary called `fleet`, `hx`, `nova` or `studio`
    /// is the server being stopped. Terminals, multiplexers and remote shells (`tmux`, `ssh`, `iTerm2`…) and agents stay
    /// refused even when a model claims that they serve: an agent never serves (the classifier lists it as a tool) and a
    /// terminal does not listen on a dev port, so such a claim is a forged one.
    static func isRefusedRootName(_ node: ProcessNode, serving: Bool) -> Bool {
        guard serving else { return isTerminalIDEOrAgent(node) }
        if identifiers(of: node).contains(where: { terminals.contains($0) || $0.hasPrefix("iterm") }) { return true }
        return isAgent(node)
    }

    /// Never a kill root (design §4.4): interactive shells (no `-c`), terminals, IDEs, agents and the agent broker.
    static func isShellTerminalIDEOrAgent(_ node: ProcessNode) -> Bool {
        (isShell(node) && !hasCommandFlag(node)) || isTerminalIDEOrAgent(node)
    }

    /// Ancestor that raises confidence for a listener without a project (design §4.3 step 6).
    static func isContextAncestor(_ node: ProcessNode) -> Bool {
        isLauncher(node) || isShell(node) || isTerminalIDEOrAgent(node)
    }
}
