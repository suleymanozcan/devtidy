import Foundation

/// Name lists for R15/R17. Deliberately duplicated from the process slice (not imported): this file is the only
/// place the activity checker's notion of "hard" and "benign" lives.
enum ActivityPolicy {
    /// Exact names (lowercased) that make a process a hard blocker when its cwd is inside the root.
    static let hardNames: Set<String> = [
        "node", "bun", "deno", "ruby", "java", "uvicorn", "gunicorn", "puma", "rails", "hugo", "vite",
        "next-server", "wrangler", "workerd", "esbuild", "nodemon", "tsx", "ts-node", "dotnet",
        "cargo", "go", "mvn",
    ]
    /// Prefixes (lowercased): `python*`, `php*`, `webpack*`, `gradle*`.
    static let hardPrefixes: [String] = ["python", "php", "webpack", "gradle"]

    /// Shells, terminals, IDEs, Finder and the Spotlight indexer never block a cleanup. Matching is on the exact name
    /// (or the exact helper prefix): `xcodebuild`, `xcodeproj`-driven tools and the like are NOT benign — a running
    /// `xcodebuild` is exactly the activity that class B/C Xcode entries must wait for (F-6).
    static let benignNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "login",
        "iterm2", "terminal", "ghostty", "warp", "code", "cursor", "xcode", "zed", "finder", "dock", "mds_stores",
    ]
    static let benignPrefixes: [String] = ["code helper", "cursor helper", "xcode helper"]

    static func isHardName(_ node: ProcessNode) -> Bool {
        candidateNames(of: node).contains { name in
            hardNames.contains(name) || hardPrefixes.contains { name.hasPrefix($0) }
        }
    }

    static func isBenign(_ node: ProcessNode) -> Bool {
        candidateNames(of: node).contains { name in
            benignNames.contains(name) || benignPrefixes.contains { name.hasPrefix($0) }
        }
    }
    /// Lowercased kernel name and executable basename (the kernel name is truncated to 16 chars).
    private static func candidateNames(of node: ProcessNode) -> [String] {
        var out = [node.name.lowercased()]
        if let path = node.executablePath, let base = path.split(separator: "/").last {
            out.append(String(base).lowercased())
        }
        return out
    }
}

/// Segment-aware path relations: `/a/proj` is never "inside" `/a/proj-evil`.
enum PathRelation {
    static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `path == root` or `path` is below `root`.
    static func isInside(_ path: String, root: String) -> Bool {
        let p = normalized(path), r = normalized(root)
        if p == r { return true }
        if r == "/" { return p.hasPrefix("/") }
        return p.hasPrefix(r + "/")
    }

    /// Equal, ancestor, or descendant.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        isInside(a, root: b) || isInside(b, root: a)
    }
}

/// R15/R17: who is using `root` right now? Fresh scan on every call, never cached.
public struct LiveActivityChecker: ActivityChecking {
    private let scanner: any ProcessScanning
    private let docker: any DockerControlling
    private let classifier: any ServerClassifying

    public init(scanner: any ProcessScanning, docker: any DockerControlling, classifier: any ServerClassifying) {
        self.scanner = scanner
        self.docker = docker
        self.classifier = classifier
    }

    public func blockers(for root: String) async -> [ActivityBlocker] {
        let snapshot = await scanner.snapshot(.full)
        let scan = await classifier.classify(snapshot)
        let dockerSnapshot = await docker.snapshot(stats: .reuse)
        return Self.evaluate(root: root, snapshot: snapshot, scan: scan, containers: dockerSnapshot.allContainers,
                             dockerStatus: dockerSnapshot.status)
    }

    static let dockerUnverifiedLabel = "Docker durumu doğrulanamadı"

    /// Pure core; see §7.2 "LiveActivityChecker.blockers(for root)".
    /// `dockerStatus` (F-6): a list that failed or was cancelled carries no containers, which must not read as "none run" —
    /// it adds a soft blocker (stops class B/C, never class A). `.notRunning` / `.notInstalled` mean there is no daemon to
    /// hold a bind mount; `.unsupported` is a remote/ssh/override configuration DevTidy never targets, where retrying cannot
    /// help and a permanent block would make every class B/C cleanup impossible.
    static func evaluate(root rawRoot: String, snapshot: ProcessSnapshot, scan: ServerScan,
                         containers: [DockerContainer], dockerStatus: DockerStatus) -> [ActivityBlocker] {
        let root = PathRelation.normalized(rawRoot)
        var blockers: [ActivityBlocker] = []

        // DevTidy and everything DevTidy itself spawned (e.g. a git probe) never block.
        var ignoredPIDs: Set<Int32> = [snapshot.selfPID]
        for node in snapshot.descendants(of: snapshot.selfPID) { ignoredPIDs.insert(node.pid) }

        // Classified dev servers whose project lives at/inside the root: one hard blocker per server, and its
        // member processes are folded into it.
        var foldedPIDs: Set<Int32> = []
        for server in scan.servers {
            guard let projectRoot = server.project?.root, PathRelation.isInside(projectRoot, root: root) else { continue }
            guard !ignoredPIDs.contains(server.root.pid) else { continue }
            for member in server.members { foldedPIDs.insert(member.pid) }
            let port = server.mainPort.map { " :\($0)" } ?? ""
            blockers.append(ActivityBlocker(kind: .listener, severity: .hard,
                                            label: "\(blockerName(server.project?.name ?? server.root.name))\(port) (PID \(server.root.pid))",
                                            pid: server.root.pid, containerID: nil))
        }

        for node in snapshot.nodes.values.sorted(by: { $0.pid < $1.pid }) {
            guard !ignoredPIDs.contains(node.pid), !foldedPIDs.contains(node.pid) else { continue }
            guard let cwd = node.workingDirectory, PathRelation.isInside(cwd, root: root) else { continue }
            guard !ActivityPolicy.isBenign(node) else { continue }
            let ownsListener = !(snapshot.listeners[node.pid] ?? []).isEmpty
            let severity: ActivityBlocker.Severity = (ActivityPolicy.isHardName(node) || ownsListener) ? .hard : .soft
            blockers.append(ActivityBlocker(kind: ownsListener ? .listener : .process, severity: severity,
                                            label: "\(blockerName(node.name)) (PID \(node.pid))", pid: node.pid, containerID: nil))
        }

        // Running containers whose bind mounts / compose working dir touch the root: always soft.
        for container in containers where container.isRunning {
            var paths = container.bindMountSources
            if let wd = container.composeWorkingDir { paths.append(wd) }
            guard paths.contains(where: { PathRelation.overlaps($0, root) }) else { continue }
            blockers.append(ActivityBlocker(kind: .container, severity: .soft, label: blockerName(container.name),
                                            pid: nil, containerID: container.id))
        }

        switch dockerStatus {
        case .unknown, .failed:
            blockers.append(ActivityBlocker(kind: .container, severity: .soft, label: dockerUnverifiedLabel,
                                            pid: nil, containerID: nil))
        case .running, .notRunning, .notInstalled, .unsupported:
            break
        }

        return blockers.sorted { a, b in
            if a.severity != b.severity { return a.severity == .hard }
            return a.label < b.label
        }
    }

    /// Process, container and folder names reach the cleanup sheet and its error messages through the blocker label, so they
    /// are cleaned here (Security F3-4): no invisible or bidirectional scalar, no line break, bounded.
    static func blockerName(_ raw: String) -> String {
        DisplayText.label(raw, limit: maxBlockerNameLength)
    }

    static let maxBlockerNameLength = 60
}

public extension ActivityBlocker {
    /// The soft blocker that reports "Docker could not be asked" (F-6), as opposed to a process or container that is
    /// running. The sheet words it differently: nothing here is "çalışıyor".
    var isDockerUnverified: Bool {
        kind == .container && containerID == nil && label == LiveActivityChecker.dockerUnverifiedLabel
    }
}
