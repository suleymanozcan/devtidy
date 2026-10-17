import Darwin
import Foundation

/// Turns a `ProcessSnapshot` into a `ServerScan` (design §4.3, ENV §3). Ordered rules, first match wins:
/// self → Docker proxy → agent CLI (always a tool) → browser / app bundle (never a server) → runtime by name (before any
/// app rule, ENV G5) → system/app exclude → project association → tool-in-project → confidence → grouping by tree root.
/// Browser / app-bundle subtrees below a root are cut out of the server (`DevServer.sparedRoots`). Never mutates or
/// signals anything.
public struct ServerClassifier: ServerClassifying {
    private let projects: any ProjectDetecting
    /// `homeDirectory` and its realpath (without trailing slash). A cwd equal to either is "no project" (ENV §3.4).
    private let homeDirectories: [String]

    public init(projects: any ProjectDetecting, homeDirectory: String = NSHomeDirectory()) {
        self.projects = projects
        var homes = [Self.trimmingTrailingSlash(homeDirectory)]
        if let real = Self.realPath(homeDirectory), !homes.contains(real) { homes.append(real) }
        self.homeDirectories = homes
    }

    public func classify(_ snapshot: ProcessSnapshot) async -> ServerScan {
        classifySynchronously(snapshot)
    }

    // MARK: Internal model

    private struct Candidate {
        let node: ProcessNode
        let ports: [ListeningPort]
        let project: Project?
        let confidence: Confidence
        /// Effective argv tokens (ENV G4: the parent's argv when this process rewrote its title).
        let tokens: [String]
    }

    // MARK: Classification

    func classifySynchronously(_ snapshot: ProcessSnapshot) -> ServerScan {
        var protectedSelf: Set<Int32> = [snapshot.selfPID]
        for ancestor in snapshot.ancestors(of: snapshot.selfPID, maxHops: 64) { protectedSelf.insert(ancestor.pid) }

        var candidates: [Candidate] = []
        var others: [OtherListener] = []

        for pid in snapshot.listeners.keys.sorted() {
            guard let node = snapshot.nodes[pid], let ports = snapshot.listeners[pid], !ports.isEmpty else { continue }
            // 0. Self: DevTidy and everything above it is never listed.
            if protectedSelf.contains(pid) { continue }
            // 1. Docker proxy: its listeners are published container ports, never a server or an "other".
            if ProcessNames.isDockerBackend(node) { continue }
            // 1b. Agent CLIs (omp, claude, codex, …) are tools wherever they run: the reason must not depend on the cwd (QA F3).
            if ProcessNames.isAgent(node) {
                others.append(OtherListener(node: node, ports: ports, reason: .tool))
                continue
            }
            // 1c. Browsers and app-bundle processes are never servers (and never signalled); runtimes inside a bundle
            //     (Xcode's `Python.app`) are not affected (ENV G5).
            if !ProcessNames.isRuntime(node), ProcessNames.isBrowserOrAppBundle(node) {
                others.append(OtherListener(node: node, ports: ports, reason: .app))
                continue
            }

            let tokens = Self.effectiveTokens(of: node, in: snapshot)
            // 2. Runtime by name (or a /node_modules/ path) — candidate, before any app-bundle rule.
            var isCandidate = ProcessNames.isRuntime(node) || Self.mentionsNodeModules(node)
            // 3. System / app exclude (non-candidates only).
            if !isCandidate, let reason = exclusionReason(for: node) {
                others.append(OtherListener(node: node, ports: ports, reason: reason))
                continue
            }
            // 4. Project association.
            let project = lookupProject(for: node, tokens: tokens)
            if !isCandidate, let project, let exe = node.executablePath, exe.hasPrefix(project.root + "/") {
                isCandidate = true   // Rust `target/debug/x`, Go `./bin/server`
            }
            // 5. Tool-in-project.
            guard isCandidate else {
                others.append(OtherListener(node: node, ports: ports, reason: project != nil ? .tool : .unknown))
                continue
            }
            // 6. Confidence.
            let confidence: Confidence
            if project != nil {
                confidence = .high
            } else if snapshot.ancestors(of: pid, maxHops: 8).contains(where: { ProcessNames.isContextAncestor($0) }) {
                confidence = .medium
            } else {
                confidence = .low
            }
            candidates.append(Candidate(node: node, ports: ports, project: project, confidence: confidence, tokens: tokens))
        }

        // 7. Grouping by tree root.
        var resolutionByListener: [Int32: TreeRootResolver.Resolution] = [:]
        let servingPIDs = Set(candidates.map(\.node.pid))
        for candidate in candidates {
            // N-6 anchors: the project folder and, for a monorepo, the repository it sits in (an orchestrator at the repo root
            // that started the package's server belongs to it). Without a project the resolver anchors on the listener's cwd.
            let anchors = [candidate.project?.root, candidate.project?.repoRoot].compactMap { $0 }
            if let resolution = TreeRootResolver.resolve(listenerPID: candidate.node.pid, snapshot: snapshot,
                                                         servingPIDs: servingPIDs, projectAnchors: anchors) {
                resolutionByListener[candidate.node.pid] = resolution
            }
        }
        var resolutionByRoot: [Int32: TreeRootResolver.Resolution] = [:]
        for resolution in resolutionByListener.values { resolutionByRoot[resolution.root.pid] = resolution }
        let rootPIDs = Set(resolutionByRoot.keys)

        /// Roots nested inside another root's tree merge into the outermost one (one tree ⇒ one server).
        func outermostRoot(_ rootPID: Int32) -> Int32 {
            var best = rootPID
            for ancestor in snapshot.ancestors(of: rootPID, maxHops: 64) where rootPIDs.contains(ancestor.pid) { best = ancestor.pid }
            return best
        }

        let scopePIDs: [Int32: Set<Int32>] = resolutionByRoot.mapValues { Set($0.scope.members.map(\.pid)) }
        var groups: [Int32: [Candidate]] = [:]
        for candidate in candidates {
            guard let resolution = resolutionByListener[candidate.node.pid] else { continue }
            // Merge into the outermost root only while the listener is still inside that root's signalable scope (a browser
            // or app-bundle process between the two roots cuts the tree).
            let outer = outermostRoot(resolution.root.pid)
            let target = scopePIDs[outer]?.contains(candidate.node.pid) == true ? outer : resolution.root.pid
            groups[target, default: []].append(candidate)
        }

        var servers: [DevServer] = []
        for (rootPID, group) in groups {
            guard let resolution = resolutionByRoot[rootPID] else { continue }
            servers.append(Self.makeServer(group: group, resolution: resolution, snapshot: snapshot))
        }

        // 11. Deterministic output order.
        servers.sort { Self.sortKey($0) < Self.sortKey($1) }
        others.sort { ($0.node.name, $0.node.pid) < ($1.node.name, $1.node.pid) }
        return ServerScan(takenAt: snapshot.takenAt, servers: servers, others: others)
    }

    // MARK: Exclusion & project association

    private func exclusionReason(for node: ProcessNode) -> OtherListenerReason? {
        if let exe = node.executablePath {
            if ProcessNames.systemExecutablePrefixes.contains(where: { exe.hasPrefix($0) }) { return .system }
            if ProcessNames.appExecutablePrefixes.contains(where: { exe.hasPrefix($0) }) || exe.contains(ProcessNames.appBundleMarker) {
                return .app
            }
        }
        if let cwd = node.workingDirectory {
            if cwd == "/" { return .system }
            if homeDirectories.contains(where: { cwd.hasPrefix($0 + "/Library/") }) { return .app }
        }
        return nil
    }

    private func isHome(_ path: String) -> Bool {
        homeDirectories.contains(Self.trimmingTrailingSlash(path))
    }

    private func lookupProject(for node: ProcessNode, tokens: [String]) -> Project? {
        if let cwd = node.workingDirectory, !cwd.isEmpty, cwd != "/", !isHome(cwd),
           let project = projects.project(containing: cwd) {
            return project
        }
        // Fallback: the first absolute path that runs through /node_modules/ names the project it belongs to.
        var paths = tokens.filter { $0.hasPrefix("/") }
        if let exe = node.executablePath { paths.append(exe) }
        guard let path = paths.first(where: { $0.contains("/node_modules/") }),
              let range = path.range(of: "/node_modules/") else { return nil }
        let prefix = String(path[..<range.lowerBound])
        guard !prefix.isEmpty, !isHome(prefix) else { return nil }
        return projects.project(containing: prefix)
    }

    private static func mentionsNodeModules(_ node: ProcessNode) -> Bool {
        if node.executablePath?.contains("/node_modules/") == true { return true }
        return (node.arguments ?? []).contains { $0.contains("/node_modules/") }
    }

    // MARK: Effective argv (ENV G4)

    /// argv of the listener as a token list; when the process rewrote its title (`next-server (v16.3.4)`, empty argv) the
    /// argv of the nearest sensible ancestor is used instead.
    static func effectiveTokens(of node: ProcessNode, in snapshot: ProcessSnapshot) -> [String] {
        let own = ProcessNames.trimmedArguments(node)
        let rewritten = own.isEmpty || (own.count == 1 && !own[0].hasPrefix("/") && node.name == "node")
        guard rewritten else { return ProcessNames.tokens(of: node) }
        let nearby = snapshot.ancestors(of: node.pid, maxHops: 3)
        let sameBinaryOrBin = nearby.first { ancestor in
            guard !ProcessNames.tokens(of: ancestor).isEmpty else { return false }
            if let exe = ancestor.executablePath, exe == node.executablePath { return true }
            return (ancestor.arguments ?? []).contains { $0.contains("node_modules/.bin/") }
        }
        if let ancestor = sameBinaryOrBin { return ProcessNames.tokens(of: ancestor) }
        if let launcher = snapshot.ancestors(of: node.pid, maxHops: 8).first(where: {
            ProcessNames.isLauncher($0) && !ProcessNames.tokens(of: $0).isEmpty
        }) {
            return ProcessNames.tokens(of: launcher)
        }
        return ProcessNames.tokens(of: node)
    }

    // MARK: Server assembly

    private static func makeServer(group: [Candidate], resolution: TreeRootResolver.Resolution,
                                   snapshot: ProcessSnapshot) -> DevServer {
        let root = resolution.root
        // Browser / app-bundle subtrees are not part of the server: not listed, not counted, never signalled (QA F6).
        let members = resolution.scope.members
        let allPorts = members
            .flatMap { snapshot.listeners[$0.pid] ?? [] }
            .sorted { ($0.port, $0.ownerPID) < ($1.port, $1.ownerPID) }

        let ordered = orderedCandidates(of: group)
        let primary = ordered[0]
        let project = primary.project ?? group.compactMap(\.project).first
        let confidence = group.map(\.confidence).max() ?? primary.confidence
        let mainPort = chooseMainPort(tokens: primary.tokens,
                                      inspectorPorts: declaredInspectorPorts(of: members, tokens: primary.tokens),
                                      ports: allPorts)
        let ports = allPorts.sorted { lhs, rhs in
            let lhsMain = lhs.port == mainPort, rhsMain = rhs.port == mainPort
            if lhsMain != rhsMain { return lhsMain }
            return (lhs.port, lhs.ownerPID) < (rhs.port, rhs.ownerPID)
        }
        let listeners = ordered.map {
            ServerListener(pid: $0.node.pid, name: $0.node.name, project: $0.project, ports: $0.ports.sorted { $0.port < $1.port })
        }

        let cpuValues = members.compactMap(\.cpuPercent)
        let established = ports.reduce(0) { $0 + $1.establishedConnections }
        let hints = ServerHints(orphaned: root.parentPID == 1,
                                noControllingTTY: !root.hasControllingTTY,
                                lanExposed: ports.contains { $0.scope == .allInterfaces },
                                noConnections: established == 0)
        return DevServer(
            root: root,
            members: members,
            ports: ports,
            mainPort: mainPort,
            project: project,
            kind: detectKind(tokens: primary.tokens, node: primary.node, project: project),
            confidence: confidence,
            command: displayCommand(tokens: primary.tokens, fallback: primary.node.name),
            cpuPercent: cpuValues.isEmpty ? nil : cpuValues.reduce(0, +),
            memoryBytes: members.reduce(0) { $0 + $1.memoryBytes },
            establishedConnections: established,
            hints: hints,
            groupKillEligible: resolution.groupKillEligible,
            listeners: listeners,
            sparedRoots: resolution.scope.spared)
    }

    /// Primary first: the listener owning the lowest "real" port (not ephemeral, not an inspector port, declared or default),
    /// then the lowest pid. vite 9422 (5174) wins over its workerd child (ephemeral ports only).
    private static func orderedCandidates(of group: [Candidate]) -> [Candidate] {
        func key(_ candidate: Candidate) -> (Int, Int, Int32) {
            let inspectors = InspectorFlags.ports(in: candidate.tokens)
            let display = candidate.ports.filter { !$0.isEphemeral && !$0.isInspector && !inspectors.contains($0.port) }
                .map { Int($0.port) }.min()
            return (display == nil ? 1 : 0, display ?? 0, candidate.node.pid)
        }
        return group.sorted { key($0) < key($1) }
    }

    /// Inspector ports named anywhere in the tree's argv (`--inspect[-brk|-wait][=[host:]port]`, `--inspect-port`,
    /// `--inspector-port`), the same set `DevServer.displayPorts` hides.
    static func declaredInspectorPorts(of members: [ProcessNode], tokens: [String]) -> Set<UInt16> {
        var out = InspectorFlags.ports(in: tokens)
        for member in members {
            if let arguments = member.arguments { out.formUnion(InspectorFlags.ports(in: arguments)) }
        }
        return out
    }

    private static func sortKey(_ server: DevServer) -> (Int, String, String, UInt16, Int32) {
        (server.project == nil ? 1 : 0,
         server.project?.groupName ?? "",
         server.project?.name ?? "",
         server.mainPort ?? 0,
         server.root.pid)
    }

    // MARK: Ports

    /// `-p N`, `--port N`, `--port=N`, `-p=N` in order of appearance. Locale-independent integer parsing.
    static func declaredPorts(in tokens: [String]) -> [UInt16] {
        var found: [UInt16] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "-p" || token == "--port" {
                if index + 1 < tokens.count, let port = UInt16(tokens[index + 1]) { found.append(port) }
            } else if token.hasPrefix("--port="), let port = UInt16(token.dropFirst("--port=".count)) {
                found.append(port)
            } else if token.hasPrefix("-p="), let port = UInt16(token.dropFirst("-p=".count)) {
                found.append(port)
            }
            index += 1
        }
        return found
    }

    /// `ports` must be ascending. An explicit `--port` / `-p` that is listening wins; otherwise the lowest port that is not
    /// ephemeral and not an inspector (the 9229–9231 defaults or one declared in `inspectorPorts`), which is never the main
    /// port unless nothing else listens.
    static func chooseMainPort(tokens: [String], inspectorPorts: Set<UInt16> = [], ports: [ListeningPort]) -> UInt16? {
        let available = Set(ports.map(\.port))
        for declared in declaredPorts(in: tokens) where available.contains(declared) { return declared }
        let regular = ports.first { !$0.isEphemeral && !$0.isInspector && !inspectorPorts.contains($0.port) }
        if let regular { return regular.port }
        return ports.first?.port
    }

    // MARK: Display command

    /// Secrets hidden (`ArgvRedaction`, before anything is shortened or cut so a value is never half-visible), runtime prefix
    /// dropped (`node`), `…/node_modules/.bin/next` → `next`, other absolute paths shortened to their last two components
    /// (the executable itself to its basename), at most 80 characters.
    static func displayCommand(tokens rawTokens: [String], fallback: String) -> String {
        let tokens = ArgvRedaction.redact(tokens: rawTokens)
        guard !tokens.isEmpty else { return ArgvRedaction.sanitized(fallback) }
        var parts: [String] = []
        for (index, token) in tokens.enumerated() {
            if index == 0 {
                if token.hasPrefix("/") {
                    let base = ProcessNames.basename(token)
                    if base == "node", tokens.count > 1 { continue }
                    parts.append(base)
                } else if token == "node", tokens.count > 1 {
                    continue
                } else {
                    parts.append(token)
                }
            } else {
                parts.append(shorten(token))
            }
        }
        let joined = parts.joined(separator: " ")
        guard joined.count > 80 else { return joined }
        return String(joined.prefix(79)) + "…"
    }

    private static func shorten(_ token: String) -> String {
        guard token.hasPrefix("/") else { return token }
        if let range = token.range(of: "/node_modules/.bin/", options: .backwards) {
            return String(token[range.upperBound...])
        }
        let components = token.split(separator: "/", omittingEmptySubsequences: true)
        return components.suffix(2).joined(separator: "/")
    }

    // MARK: Framework detection

    /// First match over the first 8 argv tokens, the executable and `comm` (ENV §3, design §4.3 item 9).
    static func detectKind(tokens: [String], node: ProcessNode, project: Project?) -> ProjectKind {
        var probes = Array(tokens.prefix(8))
        if let exe = node.executablePath { probes.append(exe) }
        probes.append(node.name)
        for probe in probes {
            for word in words(of: probe) {
                if let kind = kind(forWord: word, project: project) { return kind }
            }
        }
        let nodeLike: Set<String> = ["node", "bun", "deno"]
        if ProcessNames.identifiers(of: node).contains(where: { nodeLike.contains($0) }) {
            return project?.kinds.first ?? .unknown
        }
        return .unknown
    }

    private static func kind(forWord word: String, project: Project?) -> ProjectKind? {
        switch word {
        case "next", "next-server": return .next
        case "vite": return .vite
        case "nuxt", "nuxi": return .nuxt
        case "astro": return .astro
        case "remix": return .remix
        case "react-router": return .reactRouter
        case "gatsby": return .gatsby
        case "wrangler", "workerd": return .cloudflareWorkers
        case "artisan", "php", "php-fpm": return (project?.kinds.contains(.laravel) ?? false) ? .laravel : .php
        case "uvicorn", "gunicorn", "flask", "manage.py", "http.server", "hypercorn", "daphne": return .python
        case "rails", "puma", "ruby": return .ruby
        case "java": return .java
        default: return word.hasPrefix("python") ? .python : nil
        }
    }

    /// Lowercased match words of one probe: for paths the package directory after the last `/node_modules/` and the
    /// basename (with and without extension); for plain tokens the token itself without surrounding punctuation.
    private static func words(of probe: String) -> [String] {
        let lower = probe.lowercased()
        var out: [String] = []
        if lower.contains("/") {
            if let range = lower.range(of: "/node_modules/", options: .backwards) {
                let components = lower[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
                if let first = components.first {
                    if first.hasPrefix("@"), components.count > 1 { out.append(String(components[1])) } else { out.append(String(first)) }
                }
            }
            let base = ProcessNames.basename(lower)
            out.append(base)
            if let stripped = ProcessNames.strippingExtension(base) { out.append(stripped) }
        } else {
            out.append(lower.trimmingCharacters(in: CharacterSet(charactersIn: ":,;()[]\"'")))
        }
        return out
    }

    // MARK: Paths

    private static func trimmingTrailingSlash(_ path: String) -> String {
        var s = path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return trimmingTrailingSlash(String(cString: resolved))
    }
}
