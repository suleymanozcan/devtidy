import Darwin
import Foundation
@testable import DevTidyCore

/// Builds `ProcessSnapshot`s from compact tuples. Fixtures reproduce `recon-env.md` §2 / §5 (names, pids, pgids, argv).
enum S1SnapshotBuilder {
    static let home = "/Users/suleymanozcan"
    static let nodeExecutable = home + "/.local/share/node/v22.23.3/bin/node"
    static let ownUID: UInt32 = getuid()

    static func node(_ pid: Int32, ppid: Int32, pgid: Int32? = nil, name: String, exe: String? = nil,
                     args: [String]? = nil, cwd: String? = nil, tty: Bool = false, uid: UInt32 = getuid(),
                     start: Int64? = nil, memory: UInt64 = 10_000_000, cpu: Double? = nil) -> ProcessNode {
        ProcessNode(
            identity: ProcessIdentity(pid: pid, startSeconds: start ?? (1_760_000_000 + Int64(pid)), startMicroseconds: 0),
            parentPID: ppid,
            pgid: pgid ?? pid,
            uid: uid,
            name: name,
            executablePath: exe,
            arguments: args,
            workingDirectory: cwd,
            hasControllingTTY: tty,
            memoryBytes: memory,
            cpuTimeNanoseconds: 0,
            cpuPercent: cpu)
    }

    static func port(_ port: UInt16, owner: Int32, scope: BindScope = .loopback, established: Int = 0) -> ListeningPort {
        ListeningPort(port: port, ownerPID: owner, scope: scope, establishedConnections: established)
    }

    static func snapshot(selfPID: Int32 = S1Fixtures.selfPID, nodes: [ProcessNode], listeners: [ListeningPort] = []) -> ProcessSnapshot {
        var byPID: [Int32: ProcessNode] = [:]
        for node in nodes { byPID[node.pid] = node }
        var ports: [Int32: [ListeningPort]] = [:]
        for listener in listeners { ports[listener.ownerPID, default: []].append(listener) }
        return ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 1_760_000_000), selfPID: selfPID, nodes: byPID, listeners: ports)
    }
}

/// Fixtures. Pids are the real ones from ENV; DevTidy itself is `selfPID` under its own zsh / login / iTermServer / iTerm2.
enum S1Fixtures {
    static let selfPID: Int32 = 5000
    static let home = S1SnapshotBuilder.home
    static let nodeExe = S1SnapshotBuilder.nodeExecutable
    static let ompExe = home + "/.local/bin/omp"
    static let developer = home + "/developer"

    private static func node(_ pid: Int32, ppid: Int32, pgid: Int32? = nil, name: String, exe: String? = nil,
                             args: [String]? = nil, cwd: String? = nil, tty: Bool = false) -> ProcessNode {
        S1SnapshotBuilder.node(pid, ppid: ppid, pgid: pgid, name: name, exe: exe, args: args, cwd: cwd, tty: tty)
    }

    // MARK: Projects

    static let projectRoots: [(root: String, name: String, group: String?, kinds: [ProjectKind])] = [
        (developer + "/roblox-pet", "roblox-pet", "developer", [.vite, .cloudflareWorkers]),
        (developer + "/rentacarsaas/backoffice", "backoffice", "rentacarsaas", [.next, .cloudflareWorkers]),
        (developer + "/rentacarsaas/storefront", "storefront", "rentacarsaas", [.next, .cloudflareWorkers]),
        (developer + "/rentacarsaas/admin", "admin", "rentacarsaas", [.next, .cloudflareWorkers]),
        (developer + "/rentacarsaas/marketing", "marketing", "rentacarsaas", [.next, .cloudflareWorkers]),
        (developer + "/tunahan-monorepo-eski", "tunahan-monorepo-eski", "developer", [.unknown]),
        (developer + "/pyproj", "pyproj", "developer", [.python]),
    ]

    static func projectDetector() -> S1FakeProjects {
        S1FakeProjects(projectRoots.map {
            Project(root: $0.root, name: $0.name, groupName: $0.group, kinds: $0.kinds, repoRoot: $0.root)
        })
    }

    // MARK: DevTidy and its ancestors

    /// iTerm2 3178 → iTermServer 3184 → login 4998 → zsh 4999 → DevTidy 5000.
    static func devTidyChain() -> [ProcessNode] {
        [
            node(3178, ppid: 1, name: "iTerm2", exe: "/Applications/iTerm.app/Contents/MacOS/iTerm2",
                 args: ["/Applications/iTerm.app/Contents/MacOS/iTerm2"], cwd: "/"),
            node(3184, ppid: 3178, name: "iTermServer", exe: "/Applications/iTerm.app/Contents/MacOS/iTermServer",
                 args: ["iTermServer"], cwd: "/"),
            node(4998, ppid: 3184, name: "login", exe: "/usr/bin/login", args: ["login", "-fp", "suleymanozcan"], cwd: "/", tty: true),
            node(4999, ppid: 4998, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], cwd: developer + "/devtidy", tty: true),
            node(selfPID, ppid: 4999, name: "DevTidy", exe: home + "/Applications/DevTidy.app/Contents/MacOS/DevTidy",
                 args: [home + "/Applications/DevTidy.app/Contents/MacOS/DevTidy"], cwd: "/", tty: true),
        ]
    }

    // MARK: omp agent chains (ENV §2.1)

    /// 64471 login → 64472 -zsh → 64795 omp (listener 65449) → 74501 omp broker (shared by every Next tree and Chrome 77380).
    static func ompBrokerChain() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        let nodes = [
            node(64471, ppid: 3184, name: "login", exe: "/usr/bin/login", args: ["login", "-fp", "suleymanozcan"], cwd: "/", tty: true),
            node(64472, ppid: 64471, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], cwd: developer + "/rentacarsaas", tty: true),
            node(64795, ppid: 64472, name: "omp", exe: ompExe, args: [ompExe], cwd: developer + "/rentacarsaas", tty: true),
            node(74501, ppid: 64795, name: "omp", exe: ompExe, args: [ompExe, "__omp_worker_daemon_broker"],
                 cwd: developer + "/rentacarsaas"),
        ]
        return (nodes, [S1SnapshotBuilder.port(65449, owner: 64795)])
    }

    /// Second omp (18852, cwd in a project ⇒ `.tool`) plus the broker 3100 that parents the vite trees.
    static func secondOmpChain() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        let nodes = [
            node(18845, ppid: 3184, name: "login", exe: "/usr/bin/login", args: ["login", "-fp", "suleymanozcan"], cwd: "/", tty: true),
            node(18846, ppid: 18845, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], cwd: developer + "/tunahan-monorepo-eski", tty: true),
            node(18852, ppid: 18846, name: "omp", exe: ompExe, args: [ompExe], cwd: developer + "/tunahan-monorepo-eski", tty: true),
            node(2771, ppid: 3184, name: "login", exe: "/usr/bin/login", args: ["login", "-fp", "suleymanozcan"], cwd: "/", tty: true),
            node(2772, ppid: 2771, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], cwd: developer + "/roblox-pet", tty: true),
            node(2834, ppid: 2772, name: "omp", exe: ompExe, args: [ompExe], cwd: developer + "/roblox-pet", tty: true),
            node(3100, ppid: 2834, name: "omp", exe: ompExe, args: [ompExe, "__omp_worker_daemon_broker"], cwd: developer + "/roblox-pet"),
        ]
        return (nodes, [S1SnapshotBuilder.port(50914, owner: 18852)])
    }

    // MARK: Next (npm exec → next dev → next-server)

    /// `npm exec next dev <flag> <port>` (title rewritten, comm `node`) → `node …/node_modules/.bin/next dev …` → `next-server`.
    static func nextTree(npm: Int32, node nodePID: Int32, server: Int32, app: String, port: UInt16,
                         portFlag: String = "-p", parent: Int32 = 74501) -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        let dir = developer + "/rentacarsaas/" + app
        let nodes = [
            node(npm, ppid: parent, pgid: npm, name: "node", exe: nodeExe, args: ["npm exec next dev \(portFlag) \(port)"], cwd: dir),
            node(nodePID, ppid: npm, pgid: npm, name: "node", exe: nodeExe,
                 args: [nodeExe, dir + "/node_modules/.bin/next", "dev", portFlag, String(port)], cwd: dir),
            node(server, ppid: nodePID, pgid: npm, name: "node", exe: nodeExe, args: ["next-server (v16.3.4)", ""], cwd: dir),
        ]
        return (nodes, [S1SnapshotBuilder.port(port, owner: server, scope: .allInterfaces)])
    }

    static func allNextTrees() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        let trees = [
            nextTree(npm: 77527, node: 77557, server: 77578, app: "backoffice", port: 3000),
            nextTree(npm: 77531, node: 77564, server: 77579, app: "storefront", port: 3001),
            nextTree(npm: 77534, node: 77577, server: 77592, app: "admin", port: 3002, portFlag: "--port"),
            nextTree(npm: 77539, node: 77591, server: 77593, app: "marketing", port: 3010),
        ]
        return (trees.flatMap(\.nodes), trees.flatMap(\.listeners))
    }

    // MARK: Vite (+ Cloudflare workerd child)

    static func viteTrees() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        let dir = developer + "/roblox-pet"
        let workerd = dir + "/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd"
        let nodes = [
            node(9402, ppid: 3100, pgid: 9402, name: "node", exe: nodeExe, args: ["npm exec vite --port 5174 --strictPort"], cwd: dir, tty: true),
            node(9422, ppid: 9402, pgid: 9402, name: "node", exe: nodeExe,
                 args: [nodeExe, dir + "/node_modules/.bin/vite", "--port", "5174", "--strictPort"], cwd: dir, tty: true),
            node(9425, ppid: 9422, pgid: 9402, name: "workerd", exe: workerd,
                 args: [workerd, "serve", "--binary", "--experimental", "--socket-addr=entry=127.0.0.1:0",
                        "--external-addr=loopback=127.0.0.1:54592", "--control-fd=3", "-"], cwd: dir, tty: true),
            node(9333, ppid: 3100, pgid: 9333, name: "node", exe: nodeExe,
                 args: ["npm exec vite --config src/ui/sandbox/vite.config.ts --port 5175 --strictPort"], cwd: dir, tty: true),
            node(9346, ppid: 9333, pgid: 9333, name: "node", exe: nodeExe,
                 args: [nodeExe, dir + "/node_modules/.bin/vite", "--config", "src/ui/sandbox/vite.config.ts", "--port", "5175", "--strictPort"],
                 cwd: dir, tty: true),
        ]
        let ports = [
            S1SnapshotBuilder.port(5174, owner: 9422), S1SnapshotBuilder.port(9229, owner: 9422), S1SnapshotBuilder.port(54592, owner: 9422),
            S1SnapshotBuilder.port(54594, owner: 9425), S1SnapshotBuilder.port(54595, owner: 9425), S1SnapshotBuilder.port(54599, owner: 9425),
            S1SnapshotBuilder.port(5175, owner: 9346),
        ]
        return (nodes, ports)
    }

    // MARK: Listeners that are NOT dev servers (ENV G6)

    static func chromeForTesting() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        let exe = home + "/.omp/puppeteer/chrome/mac_arm-150.0.7871.24/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        return ([node(77380, ppid: 74501, name: "Google Chrome fo", exe: exe, args: [exe, "--remote-debugging-port=0"],
                      cwd: developer + "/rentacarsaas")],
                [S1SnapshotBuilder.port(50105, owner: 77380)])
    }

    static func safeApp() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        ([node(2539, ppid: 1, name: "Safe", exe: "/Applications/Safe.app/Contents/MacOS/Safe",
               args: ["/Applications/Safe.app/Contents/MacOS/Safe"],
               cwd: home + "/Library/Containers/com.safeincloud.Safe-In-Cloud.OSX/Data")],
         [S1SnapshotBuilder.port(19756, owner: 2539, scope: .allInterfaces)])
    }

    static func rapportd() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        ([node(1065, ppid: 1, name: "rapportd", exe: "/usr/libexec/rapportd", args: ["/usr/libexec/rapportd"], cwd: "/")],
         [S1SnapshotBuilder.port(49668, owner: 1065, scope: .allInterfaces)])
    }

    /// `com.docker.backend` with its 8 published ports; comm is cut at 16 characters like the kernel does.
    static func dockerBackend() -> (nodes: [ProcessNode], listeners: [ListeningPort]) {
        let exe = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
        let ports: [UInt16] = [8787, 5173, 5432, 6379, 8000, 8001, 8888, 9999]
        return ([node(19200, ppid: 19199, name: "com.docker.backe", exe: exe, args: [exe, "services"],
                      cwd: home + "/Library/Containers/com.docker.docker/Data")],
                ports.map { S1SnapshotBuilder.port($0, owner: 19200) })
    }

    // MARK: Whole machine

    static func everything() -> ProcessSnapshot {
        let parts = [ompBrokerChain(), secondOmpChain(), allNextTrees(), viteTrees(), chromeForTesting(), safeApp(), rapportd(), dockerBackend()]
        return S1SnapshotBuilder.snapshot(nodes: devTidyChain() + parts.flatMap(\.nodes), listeners: parts.flatMap(\.listeners))
    }

    /// DevTidy chain + broker chain + the :3000 Next tree: the terminator scenario.
    static func nextScenarioNodes() -> [ProcessNode] {
        devTidyChain() + ompBrokerChain().nodes + nextTree(npm: 77527, node: 77557, server: 77578, app: "backoffice", port: 3000).nodes
    }

    static let fastPolicy: TerminationPolicy = {
        var policy = TerminationPolicy()
        policy.graceSeconds = 1
        policy.killWaitSeconds = 0.5
        policy.pollMilliseconds = 100
        return policy
    }()
}

/// Records every `project(containing:)` call. Resolves a path to the deepest registered project containing it.
final class S1FakeProjects: ProjectDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private let projects: [Project]
    private var recorded: [String] = []

    init(_ projects: [Project]) { self.projects = projects }

    var calls: [String] { snapshotCalls() }

    private func snapshotCalls() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(path)
    }

    func project(containing path: String) -> Project? {
        record(path)
        return projects
            .filter { path == $0.root || path.hasPrefix($0.root + "/") }
            .max { $0.root.count < $1.root.count }
    }

    func projectContext(for path: String) async -> ProjectContext? { nil }
}

/// Builds a `DevServer` straight from a snapshot (the terminator never reads its classification fields).
enum S1Servers {
    static func make(from snapshot: ProcessSnapshot, root: Int32, groupKillEligible: Bool,
                     extraMembers: [ProcessNode] = [], project: Project? = nil) -> DevServer {
        guard let rootNode = snapshot.nodes[root] else { preconditionFailure("root \(root) not in fixture") }
        return DevServer(
            root: rootNode,
            members: [rootNode] + snapshot.descendants(of: root) + extraMembers,
            ports: [],
            mainPort: nil,
            project: project,
            kind: .next,
            confidence: .high,
            command: "next dev",
            cpuPercent: nil,
            memoryBytes: 0,
            establishedConnections: 0,
            hints: ServerHints(orphaned: false, noControllingTTY: true, lanExposed: false, noConnections: true),
            groupKillEligible: groupKillEligible)
    }
}
