import Foundation
import Testing
@testable import DevTidyCore

@Suite struct ServerClassifierTests {
    private let xcodePython = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"

    private func classify(_ snapshot: ProcessSnapshot, projects: S1FakeProjects = S1Fixtures.projectDetector(),
                          home: String = S1Fixtures.home) async -> ServerScan {
        await ServerClassifier(projects: projects, homeDirectory: home).classify(snapshot)
    }

    private func node(_ pid: Int32, ppid: Int32, pgid: Int32? = nil, name: String, exe: String? = nil, args: [String]? = nil,
                      cwd: String? = nil, tty: Bool = false) -> ProcessNode {
        S1SnapshotBuilder.node(pid, ppid: ppid, pgid: pgid, name: name, exe: exe, args: args, cwd: cwd, tty: tty)
    }

    // MARK: (a) Next :3000

    @Test func nextOnPort3000IsOneServerRootedAtNpmExec() async throws {
        let scan = await classify(S1Fixtures.everything())
        let server = try #require(scan.servers.first { $0.mainPort == 3000 })
        #expect(server.root.pid == 77527)
        #expect(server.members.map(\.pid) == [77527, 77557, 77578])
        #expect(server.command == "next dev -p 3000")
        #expect(server.kind == .next)
        #expect(server.confidence == .high)
        #expect(server.project?.name == "backoffice")
        #expect(server.project?.groupName == "rentacarsaas")
        #expect(server.ports.map(\.port) == [3000])
        #expect(server.groupKillEligible)
        #expect(server.hints == ServerHints(orphaned: false, noControllingTTY: true, lanExposed: true, noConnections: true))
    }

    // MARK: (b) four Next trees under one broker

    @Test func fourNextTreesUnderOneBrokerAreFourServersAndNoneContainsTheBroker() async throws {
        let scan = await classify(S1Fixtures.everything())
        let next = scan.servers.filter { $0.kind == .next }
        #expect(next.map(\.root.pid) == [77534, 77527, 77539, 77531])      // admin, backoffice, marketing, storefront
        #expect(next.map(\.mainPort) == [3002, 3000, 3010, 3001])
        for server in scan.servers {
            #expect(!server.members.map(\.pid).contains(74501))
            #expect(!server.members.map(\.pid).contains(3100))
        }
        #expect(next.allSatisfy { $0.groupKillEligible })
    }

    // MARK: (c) vite + workerd

    @Test func viteAndItsWorkerdChildAreOneServerWithInternalPortsCounted() async throws {
        let scan = await classify(S1Fixtures.everything())
        let vite = try #require(scan.servers.first { $0.mainPort == 5174 })
        #expect(vite.root.pid == 9402)
        #expect(vite.members.map(\.pid) == [9402, 9422, 9425])
        #expect(vite.ports.map(\.port) == [5174, 9229, 54592, 54594, 54595, 54599])
        #expect(vite.displayPorts.map(\.port) == [5174])
        #expect(vite.internalPortCount == 5)
        #expect(vite.kind == .vite)
        #expect(vite.command == "vite --port 5174 --strictPort")
        #expect(vite.project?.name == "roblox-pet")
        #expect(vite.hints.lanExposed == false)
        let second = try #require(scan.servers.first { $0.mainPort == 5175 })
        #expect(second.root.pid == 9333)
        #expect(second.members.map(\.pid) == [9333, 9346])
        #expect(second.command == "vite --config src/ui/sandbox/vite.config.ts --port 5175 --strictPort")
    }

    // MARK: (d) not servers

    @Test func ompChromeSafeAndRapportdAreOthersWithTheirReasons() async throws {
        let scan = await classify(S1Fixtures.everything())
        let reasons = Dictionary(uniqueKeysWithValues: scan.others.map { ($0.node.pid, $0.reason) })
        #expect(reasons[18852] == .tool)          // omp, cwd inside a project
        #expect(reasons[64795] == .tool)          // omp with no project marker: still a tool (QA F3), same as 18852
        #expect(reasons[77380] == .app)           // Chrome for Testing: .app/Contents beats the project cwd (ENV G6)
        #expect(reasons[2539] == .app)            // Safe
        #expect(reasons[1065] == .system)         // rapportd
        let serverPIDs = Set(scan.servers.flatMap { $0.members.map(\.pid) })
        for pid: Int32 in [18852, 64795, 77380, 2539, 1065] { #expect(!serverPIDs.contains(pid)) }
        #expect(scan.others.map(\.node.name) == scan.others.map(\.node.name).sorted())
    }

    // MARK: (e) Docker proxy

    @Test func dockerBackendListenersAreNeitherServersNorOthers() async throws {
        let scan = await classify(S1Fixtures.everything())
        #expect(!scan.servers.contains { $0.members.map(\.pid).contains(19200) })
        #expect(!scan.others.contains { $0.node.pid == 19200 })
    }

    // MARK: (f) / (g) Python

    @Test func pythonFromThePythonAppBundleInAProjectIsAServer() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], cwd: dir, tty: true)
        let python = node(800, ppid: 700, name: "Python", exe: xcodePython,
                          args: [xcodePython, "-u", "-m", "http.server", "0", "--bind", "127.0.0.1"], cwd: dir, tty: true)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [zsh, python],
                                                  listeners: [S1SnapshotBuilder.port(8765, owner: 800)])
        let scan = await classify(snapshot)
        let server = try #require(scan.servers.first)
        #expect(scan.servers.count == 1 && scan.others.isEmpty)     // the Xcode path is under /Applications — G5
        #expect(server.root.pid == 800)
        #expect(server.kind == .python)
        #expect(server.project?.name == "pyproj")
        #expect(server.confidence == .high)
        #expect(server.mainPort == 8765)
        #expect(server.command.contains("http.server"))
    }

    @Test func pythonHttpServerWithoutAProjectUnderAShellIsMediumConfidence() async throws {
        let downloads = S1Fixtures.home + "/Downloads"
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], cwd: downloads, tty: true)
        let python = node(800, ppid: 700, name: "Python", exe: xcodePython,
                          args: [xcodePython, "-m", "http.server", "8000"], cwd: downloads, tty: true)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [zsh, python],
                                                  listeners: [S1SnapshotBuilder.port(8000, owner: 800)])
        let scan = await classify(snapshot)
        let server = try #require(scan.servers.first)
        #expect(server.project == nil)
        #expect(server.confidence == .medium)
        #expect(server.kind == .python)
        #expect(server.root.pid == 800)
    }

    @Test func pythonWithoutProjectOrContextIsLowConfidence() async throws {
        let downloads = S1Fixtures.home + "/Downloads"
        let python = node(800, ppid: 1, name: "Python", exe: xcodePython,
                          args: [xcodePython, "-m", "http.server", "8000"], cwd: downloads)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [python],
                                                  listeners: [S1SnapshotBuilder.port(8000, owner: 800)])
        let server = try #require(await classify(snapshot).servers.first)
        #expect(server.confidence == .low)
        #expect(server.hints.orphaned)
    }

    // MARK: (h) self

    @Test func devTidyItselfAndItsAncestorsAreDroppedEntirely() async throws {
        let base = S1Fixtures.everything()
        var listeners = base.listeners.values.flatMap { $0 }
        for pid: Int32 in [S1Fixtures.selfPID, 4999, 3178] { listeners.append(S1SnapshotBuilder.port(7000 + UInt16(pid % 1000), owner: pid)) }
        let snapshot = S1SnapshotBuilder.snapshot(nodes: Array(base.nodes.values), listeners: listeners)
        let scan = await classify(snapshot)
        let seen = Set(scan.servers.flatMap { $0.members.map(\.pid) } + scan.others.map(\.node.pid))
        for pid: Int32 in [S1Fixtures.selfPID, 4999, 3178] { #expect(!seen.contains(pid)) }
        #expect(scan.servers.count == 6)
    }

    // MARK: (i) rewritten title / empty argv

    @Test func nextServerWithEmptyArgvUsesTheParentsArgv() async throws {
        let parts = S1Fixtures.nextTree(npm: 77527, node: 77557, server: 77578, app: "backoffice", port: 3000)
        let nodes = parts.nodes.map { n -> ProcessNode in
            guard n.pid == 77578 else { return n }
            return S1SnapshotBuilder.node(77578, ppid: 77557, pgid: 77527, name: "node", exe: S1Fixtures.nodeExe, args: [],
                                          cwd: n.workingDirectory)
        }
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + S1Fixtures.ompBrokerChain().nodes + nodes,
                                                  listeners: parts.listeners)
        let server = try #require(await classify(snapshot).servers.first)
        #expect(server.command == "next dev -p 3000")
        #expect(server.mainPort == 3000)
        #expect(server.kind == .next)
    }

    @Test func rewrittenNpmExecTitleIsTokenisedWhenItIsTheNearestMatch() async throws {
        // Listener title-rewritten, parent also title-rewritten (`npm exec …`): tokens come from the title.
        let dir = S1Fixtures.developer + "/rentacarsaas/admin"
        let npm = node(300, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe, args: ["npm exec next dev --port 3002"], cwd: dir)
        let server = node(310, ppid: 300, pgid: 300, name: "node", exe: S1Fixtures.nodeExe, args: ["next-server (v16.3.4)"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [npm, server],
                                                  listeners: [S1SnapshotBuilder.port(3002, owner: 310, scope: .allInterfaces)])
        let result = try #require(await classify(snapshot).servers.first)
        #expect(result.command == "npm exec next dev --port 3002")
        #expect(result.mainPort == 3002)
        #expect(result.kind == .next)
        #expect(result.root.pid == 300)
    }

    // MARK: (j) hints

    @Test func hintsReflectOrphanTtyBindAndConnections() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        func scan(ppid: Int32, tty: Bool, scope: BindScope, established: Int) async -> DevServer? {
            let python = node(800, ppid: ppid, name: "Python", exe: xcodePython, args: [xcodePython, "-m", "http.server"], cwd: dir, tty: tty)
            let snapshot = S1SnapshotBuilder.snapshot(
                nodes: S1Fixtures.devTidyChain() + [python],
                listeners: [S1SnapshotBuilder.port(8000, owner: 800, scope: scope, established: established)])
            return await classify(snapshot).servers.first
        }
        let orphan = try #require(await scan(ppid: 1, tty: false, scope: .allInterfaces, established: 0))
        #expect(orphan.hints == ServerHints(orphaned: true, noControllingTTY: true, lanExposed: true, noConnections: true))
        let attached = try #require(await scan(ppid: 4999, tty: true, scope: .loopback, established: 3))
        #expect(attached.hints == ServerHints(orphaned: false, noControllingTTY: false, lanExposed: false, noConnections: false))
        #expect(attached.establishedConnections == 3)
    }

    @Test func metricsAreSummedOverMembersAndCpuIsNilWhenEveryMemberIsNil() async throws {
        let parts = S1Fixtures.nextTree(npm: 77527, node: 77557, server: 77578, app: "backoffice", port: 3000)
        func nodes(cpu: [Int32: Double]) -> [ProcessNode] {
            parts.nodes.map { n in
                S1SnapshotBuilder.node(n.pid, ppid: n.parentPID, pgid: n.pgid, name: n.name, exe: n.executablePath, args: n.arguments,
                                       cwd: n.workingDirectory, memory: 1_000, cpu: cpu[n.pid])
            }
        }
        let withCPU = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + nodes(cpu: [77557: 1.5, 77578: 2.0]), listeners: parts.listeners)
        let server = try #require(await classify(withCPU).servers.first)
        #expect(server.cpuPercent == 3.5)
        #expect(server.memoryBytes == 3_000)
        let noCPU = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + nodes(cpu: [:]), listeners: parts.listeners)
        #expect(try #require(await classify(noCPU).servers.first).cpuPercent == nil)
    }

    // MARK: (k) determinism

    @Test func orderingIsDeterministicAndIndependentOfInputOrder() async throws {
        let snapshot = S1Fixtures.everything()
        let first = await classify(snapshot)
        let shuffled = S1SnapshotBuilder.snapshot(nodes: Array(snapshot.nodes.values.reversed()),
                                                  listeners: Array(snapshot.listeners.values.flatMap { $0 }.reversed()))
        let second = await classify(shuffled)
        #expect(first.servers.map(\.id) == second.servers.map(\.id))
        #expect(first.others.map(\.id) == second.others.map(\.id))
        // Servers by (group, project, main port): developer/roblox-pet ×2 first, then rentacarsaas by project name.
        #expect(first.servers.map(\.mainPort) == [5174, 5175, 3002, 3000, 3010, 3001])
    }

    // MARK: (l) project lookup rules

    @Test func aCwdEqualToHomeNeverReachesTheDetectorAndYieldsNoProject() async throws {
        // The fake would happily resolve `home` to a project if it were asked.
        let homeProject = Project(root: S1Fixtures.home, name: "suleymanozcan", groupName: "Users", kinds: [.unknown], repoRoot: nil)
        let detector = S1FakeProjects([homeProject])
        let zsh = node(700, ppid: 3184, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], cwd: S1Fixtures.home, tty: true)
        let python = node(800, ppid: 700, name: "Python", exe: xcodePython, args: [xcodePython, "-m", "http.server"], cwd: S1Fixtures.home)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [zsh, python],
                                                  listeners: [S1SnapshotBuilder.port(8000, owner: 800)])
        let server = try #require(await classify(snapshot, projects: detector).servers.first)
        #expect(server.project == nil)
        #expect(!detector.calls.contains(S1Fixtures.home))
        #expect(!detector.calls.contains(S1Fixtures.home + "/"))
    }

    @Test func aTrailingSlashOnTheHomeDirectoryIsTolerated() async throws {
        let detector = S1FakeProjects([Project(root: S1Fixtures.home, name: "h", groupName: nil, kinds: [.unknown], repoRoot: nil)])
        let python = node(800, ppid: 1, name: "Python", exe: xcodePython, args: [xcodePython, "-m", "http.server"], cwd: S1Fixtures.home)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [python],
                                                  listeners: [S1SnapshotBuilder.port(8000, owner: 800)])
        let server = try #require(await classify(snapshot, projects: detector, home: S1Fixtures.home + "/").servers.first)
        #expect(server.project == nil)
        #expect(detector.calls.isEmpty)
    }

    @Test func projectIsFoundThroughANodeModulesPathWhenTheCwdHasNone() async throws {
        let dir = S1Fixtures.developer + "/roblox-pet"
        let vite = node(900, ppid: 1, name: "node", exe: S1Fixtures.nodeExe,
                        args: [S1Fixtures.nodeExe, dir + "/node_modules/.bin/vite", "--port", "5200"], cwd: S1Fixtures.home + "/Documents")
        let detector = S1Fixtures.projectDetector()
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [vite],
                                                  listeners: [S1SnapshotBuilder.port(5200, owner: 900)])
        let server = try #require(await classify(snapshot, projects: detector).servers.first)
        #expect(server.project?.name == "roblox-pet")
        #expect(server.confidence == .high)
        #expect(detector.calls == [S1Fixtures.home + "/Documents", dir])
    }

    @Test func aBinaryInsideTheProjectBecomesACandidate() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let rust = node(900, ppid: 1, name: "server", exe: dir + "/target/debug/server", args: [dir + "/target/debug/server"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [rust],
                                                  listeners: [S1SnapshotBuilder.port(8080, owner: 900)])
        let scan = await classify(snapshot)
        #expect(scan.servers.count == 1 && scan.others.isEmpty)
        #expect(scan.servers.first?.kind == .unknown)
    }

    @Test func aListenerOutsideEveryProjectWithoutARuntimeIsUnknown() async throws {
        let tool = node(900, ppid: 1, name: "mytool", exe: S1Fixtures.home + "/.local/bin/mytool",
                        args: [S1Fixtures.home + "/.local/bin/mytool"], cwd: S1Fixtures.home + "/Documents")
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [tool],
                                                  listeners: [S1SnapshotBuilder.port(8080, owner: 900)])
        let scan = await classify(snapshot)
        #expect(scan.servers.isEmpty)
        #expect(scan.others.map(\.reason) == [.unknown])
    }

    @Test func cwdUnderTheLibraryFolderMarksAnAppEvenWithoutAnAppBundlePath() async throws {
        let helper = node(900, ppid: 1, name: "helper", exe: S1Fixtures.home + "/bin/helper", args: ["helper"],
                          cwd: S1Fixtures.home + "/Library/Application Support/Thing")
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [helper],
                                                  listeners: [S1SnapshotBuilder.port(8080, owner: 900)])
        #expect(await classify(snapshot).others.map(\.reason) == [.app])
    }

    // MARK: Kinds

    @Test func frameworkDetectionCoversTheDocumentedRuntimes() async throws {
        func kind(name: String, exe: String, args: [String], projectKinds: [ProjectKind] = [.unknown]) async throws -> ProjectKind {
            let dir = S1Fixtures.developer + "/kinds"
            let project = Project(root: dir, name: "kinds", groupName: "developer", kinds: projectKinds, repoRoot: dir)
            let process = node(900, ppid: 1, name: name, exe: exe, args: args, cwd: dir)
            let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [process],
                                                      listeners: [S1SnapshotBuilder.port(8080, owner: 900)])
            return try #require(await classify(snapshot, projects: S1FakeProjects([project])).servers.first).kind
        }
        let nodeExe = S1Fixtures.nodeExe
        #expect(try await kind(name: "node", exe: nodeExe, args: [nodeExe, "/p/node_modules/.bin/nuxt", "dev"]) == .nuxt)
        #expect(try await kind(name: "node", exe: nodeExe, args: [nodeExe, "/p/node_modules/.bin/astro", "dev"]) == .astro)
        #expect(try await kind(name: "node", exe: nodeExe, args: [nodeExe, "/p/node_modules/.bin/remix", "dev"]) == .remix)
        #expect(try await kind(name: "node", exe: nodeExe, args: [nodeExe, "/p/node_modules/.bin/react-router", "dev"]) == .reactRouter)
        #expect(try await kind(name: "node", exe: nodeExe, args: [nodeExe, "/p/node_modules/.bin/gatsby", "develop"]) == .gatsby)
        #expect(try await kind(name: "node", exe: nodeExe, args: [nodeExe, "/p/node_modules/wrangler/bin/wrangler.js", "dev"]) == .cloudflareWorkers)
        #expect(try await kind(name: "php", exe: "/opt/homebrew/bin/php", args: ["php", "artisan", "serve"]) == .php)
        #expect(try await kind(name: "php", exe: "/opt/homebrew/bin/php", args: ["php", "artisan", "serve"], projectKinds: [.laravel]) == .laravel)
        #expect(try await kind(name: "python3", exe: "/usr/local/bin/python3", args: ["python3", "-m", "uvicorn", "app:app"]) == .python)
        #expect(try await kind(name: "ruby", exe: "/usr/bin/ruby", args: ["ruby", "bin/rails", "server"]) == .ruby)
        #expect(try await kind(name: "java", exe: "/usr/bin/java", args: ["java", "-jar", "app.jar"]) == .java)
        #expect(try await kind(name: "node", exe: nodeExe, args: [nodeExe, "server.js"], projectKinds: [.expo]) == .expo)
        #expect(try await kind(name: "bun", exe: "/usr/local/bin/bun", args: ["bun", "run", "server.ts"], projectKinds: [.node]) == .node)
    }

    @Test func commandIsShortenedAndTruncatedTo80Characters() {
        let tokens = ["/usr/local/bin/node", "/a/b/c/d/server.js", "--flag", String(repeating: "x", count: 120)]
        let command = ServerClassifier.displayCommand(tokens: tokens, fallback: "node")
        #expect(command.count == 80)
        #expect(command.hasPrefix("d/server.js --flag "))
        #expect(command.hasSuffix("…"))
        #expect(ServerClassifier.displayCommand(tokens: [], fallback: "node") == "node")
        #expect(ServerClassifier.displayCommand(tokens: ["/x/bin/vite", "--port", "1"], fallback: "node") == "vite --port 1")
    }

    @Test func declaredPortsAreParsedWithoutLocaleInvolvement() {
        #expect(ServerClassifier.declaredPorts(in: ["next", "dev", "-p", "3000"]) == [3000])
        #expect(ServerClassifier.declaredPorts(in: ["vite", "--port", "5174"]) == [5174])
        #expect(ServerClassifier.declaredPorts(in: ["vite", "--port=5175", "-p=3001"]) == [5175, 3001])
        #expect(ServerClassifier.declaredPorts(in: ["-p", "٣٠٠٠", "--port", "99999", "--port"]) == [])
    }

    @Test func mainPortFallsBackToTheLowestRegularPortThenToTheFirst() {
        let ports = [S1SnapshotBuilder.port(9229, owner: 1), S1SnapshotBuilder.port(5174, owner: 1), S1SnapshotBuilder.port(54592, owner: 1)]
            .sorted { $0.port < $1.port }
        #expect(ServerClassifier.chooseMainPort(tokens: [], ports: ports) == 5174)
        #expect(ServerClassifier.chooseMainPort(tokens: ["--port", "9229"], ports: ports) == 9229)       // declared and present
        #expect(ServerClassifier.chooseMainPort(tokens: ["--port", "4000"], ports: ports) == 5174)       // declared but absent
        let internalOnly = [S1SnapshotBuilder.port(9229, owner: 1), S1SnapshotBuilder.port(54592, owner: 1)]
        #expect(ServerClassifier.chooseMainPort(tokens: [], ports: internalOnly) == 9229)
        #expect(ServerClassifier.chooseMainPort(tokens: [], ports: []) == nil)
    }

    // MARK: QA F6 — browsers below a server

    @Test func aPythonDriverWithChromeChildrenIsOneServerWithoutTheBrowserAndStoppingItNeverSignalsChrome() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let chromeExe = S1Fixtures.home + "/.omp/puppeteer/chrome/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let python = S1SnapshotBuilder.node(800, ppid: 4999, name: "Python", exe: xcodePython,
                                            args: [xcodePython, "qa/driver.py", "chrome"], cwd: dir, memory: 10_000_000)
        let chrome = S1SnapshotBuilder.node(810, ppid: 800, pgid: 800, name: "Google Chrome fo", exe: chromeExe, args: [chromeExe],
                                            cwd: dir, memory: 500_000_000)
        let renderer = S1SnapshotBuilder.node(811, ppid: 810, pgid: 800, name: "Google Chrome He", memory: 300_000_000)
        let snapshot = S1SnapshotBuilder.snapshot(
            nodes: S1Fixtures.devTidyChain() + [python, chrome, renderer],
            listeners: [S1SnapshotBuilder.port(9400, owner: 800), S1SnapshotBuilder.port(9222, owner: 810)])
        let scan = await classify(snapshot)

        let server = try #require(scan.servers.first)
        #expect(scan.servers.count == 1)
        #expect(server.root.pid == 800)
        #expect(server.members.map(\.pid) == [800])                 // no Chrome in the tree that would be signalled
        #expect(server.sparedRoots.map(\.pid) == [810])
        #expect(server.ports.map(\.port) == [9400])                 // Chrome's debugging port is not the server's
        #expect(server.memoryBytes == 10_000_000)                   // and its 800 MB are not counted against the server
        #expect(!server.groupKillEligible)                          // kill(-800) would reach Chrome
        #expect(scan.others.contains { $0.node.pid == 810 && $0.reason == .app })

        // End to end: stopping the server leaves the browser alone.
        let world = S1World(nodes: Array(snapshot.nodes.values))
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: S1RecordingAudit(), sleep: world.sleepClosure)
        let report = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)
        #expect(world.signalEvents == [.signal(SIGTERM, pid: 800)])
        #expect(report.terminated == [800])
        #expect(world.isAlive(810) && world.isAlive(811))
    }

    // MARK: Merged trees (P1-5)

    @Test func serversFoldedIntoOneTreeKeepEveryProjectAndPort() async throws {
        let adminDir = S1Fixtures.developer + "/rentacarsaas/admin"
        let robloxDir = S1Fixtures.developer + "/roblox-pet"
        let nodeExe = S1Fixtures.nodeExe
        let concurrently = node(500, ppid: 4999, name: "node", exe: nodeExe, args: ["concurrently next dev vite"], cwd: S1Fixtures.developer)
        let shellA = node(510, ppid: 500, pgid: 500, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "next dev"], cwd: adminDir)
        let next = node(511, ppid: 510, pgid: 500, name: "node", exe: nodeExe,
                        args: [nodeExe, adminDir + "/node_modules/.bin/next", "dev", "-p", "3002"], cwd: adminDir)
        let shellB = node(520, ppid: 500, pgid: 500, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "vite"], cwd: robloxDir)
        let vite = node(521, ppid: 520, pgid: 500, name: "node", exe: nodeExe,
                        args: [nodeExe, robloxDir + "/node_modules/.bin/vite", "--port", "5174"], cwd: robloxDir)
        let snapshot = S1SnapshotBuilder.snapshot(
            nodes: S1Fixtures.devTidyChain() + [concurrently, shellA, next, shellB, vite],
            listeners: [S1SnapshotBuilder.port(3002, owner: 511), S1SnapshotBuilder.port(5174, owner: 521)])
        let scan = await classify(snapshot)

        let server = try #require(scan.servers.first)
        #expect(scan.servers.count == 1)
        #expect(server.root.pid == 500)
        #expect(server.listeners.map(\.pid) == [511, 521])
        #expect(server.listeners.map { $0.project?.name } == ["admin", "roblox-pet"])
        #expect(server.listeners.map { $0.ports.map(\.port) } == [[3002], [5174]])

        let preview = server.killPreview
        #expect(preview.message.hasPrefix("2 sunucu ve toplam 5 süreç"))
        #expect(preview.details.contains("Sunucu: admin :3002  (PID 511)"))
        #expect(preview.details.contains("Sunucu: roblox-pet :5174  (PID 521)"))
    }

    // MARK: QA F3 — agents are tools

    @Test func agentListenersAreToolsWhateverTheirWorkingDirectory() async throws {
        let nodeExe = S1Fixtures.nodeExe
        let agents = [
            node(900, ppid: 1, name: "omp", exe: S1Fixtures.ompExe, args: [S1Fixtures.ompExe], cwd: "/"),
            node(901, ppid: 1, name: "omp", exe: S1Fixtures.ompExe, args: [S1Fixtures.ompExe], cwd: S1Fixtures.home + "/Documents"),
            node(902, ppid: 1, name: "omp", exe: S1Fixtures.ompExe, args: [S1Fixtures.ompExe], cwd: S1Fixtures.developer + "/pyproj"),
            node(903, ppid: 1, name: "node", exe: nodeExe,
                 args: [nodeExe, "/lib/node_modules/@openai/codex/bin/codex.js"], cwd: S1Fixtures.developer + "/pyproj"),
        ]
        let snapshot = S1SnapshotBuilder.snapshot(
            nodes: S1Fixtures.devTidyChain() + agents,
            listeners: agents.enumerated().map { S1SnapshotBuilder.port(UInt16(8100 + $0.offset), owner: $0.element.pid) })
        let scan = await classify(snapshot)
        #expect(scan.servers.isEmpty)
        #expect(scan.others.map(\.reason) == [.tool, .tool, .tool, .tool])
    }

    // MARK: QA2 N1 — a declared inspector port is never the main port

    @Test func aDeclaredInspectorPortIsNotTheMainPortEvenWhenItIsTheLowestPort() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let forms: [[String]] = [["--inspect-port=9333", "--inspect"], ["--inspect=127.0.0.1:9333"],
                                 ["--inspect-port", "9333", "--inspect"], ["--inspector-port=9333"]]
        for flags in forms {
            let server = node(800, ppid: 1, name: "node", exe: S1Fixtures.nodeExe,
                              args: [S1Fixtures.nodeExe] + flags + ["server.js", "28397"], cwd: dir)
            let snapshot = S1SnapshotBuilder.snapshot(
                nodes: S1Fixtures.devTidyChain() + [server],
                listeners: [S1SnapshotBuilder.port(9333, owner: 800), S1SnapshotBuilder.port(28397, owner: 800)])
            let found = try #require(await classify(snapshot).servers.first)
            #expect(found.mainPort == 28397, "\(flags)")
            #expect(found.ports.map(\.port) == [28397, 9333], "\(flags)")      // main port first
            #expect(found.displayPorts.map(\.port) == [28397], "\(flags)")
            #expect(found.internalPortCount == 1, "\(flags)")
        }
    }

    @Test func anExplicitPortStillWinsAndAnInspectorOnlyListenerKeepsItsPort() {
        let ports = [S1SnapshotBuilder.port(9333, owner: 1), S1SnapshotBuilder.port(28397, owner: 1)]
        #expect(ServerClassifier.chooseMainPort(tokens: ["--port", "28397"], inspectorPorts: [9333], ports: ports) == 28397)
        #expect(ServerClassifier.chooseMainPort(tokens: [], inspectorPorts: [9333], ports: ports) == 28397)
        #expect(ServerClassifier.chooseMainPort(tokens: [], inspectorPorts: [9333], ports: [ports[0]]) == 9333)   // nothing else listens
    }

    // MARK: N-5 — an agent below the server is spared and the group signal is not used

    @Test func anAgentSessionBelowTheServerIsSparedAndStopNeverSignalsIt() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let npm = node(600, ppid: 4999, name: "node", exe: S1Fixtures.nodeExe, args: ["npm run dev"], cwd: dir)
        let server = node(610, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, "server.js"], cwd: dir)
        let agent = node(620, ppid: 600, pgid: 600, name: "claude", exe: S1Fixtures.home + "/.local/bin/claude",
                         args: ["claude"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [npm, server, agent],
                                                  listeners: [S1SnapshotBuilder.port(8100, owner: 610)])
        let found = try #require(await classify(snapshot).servers.first)
        #expect(found.root.pid == 600)
        #expect(found.members.map(\.pid) == [600, 610])
        #expect(found.sparedRoots.map(\.pid) == [620])
        #expect(!found.groupKillEligible)                           // kill(-600) would reach the agent
        #expect(found.killPreview.details.contains("PID 620  claude"))

        let world = S1World(nodes: Array(snapshot.nodes.values))
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: S1RecordingAudit(), sleep: world.sleepClosure)
        let report = try await terminator.terminate(found, policy: S1Fixtures.fastPolicy)
        #expect(world.signalEvents == [.signal(SIGTERM, pid: 600), .signal(SIGTERM, pid: 610)])
        #expect(world.isAlive(620))
        #expect(report.skipped.contains(SignalSkip(pid: 620, reason: "protected-role")))
    }

    @Test func theTerminatorRefusesATerminalOrAgentThatAppearsBelowAForgedServerToo() async throws {
        // Same rule at signal time, whatever the classifier decided: the server below knows nothing about 620.
        let npm = node(600, ppid: 4999, name: "node", exe: S1Fixtures.nodeExe, args: ["npm run dev"])
        let agent = node(620, ppid: 600, pgid: 600, name: "codex", exe: S1Fixtures.home + "/.local/bin/codex", args: ["codex"])
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [npm, agent])
        let forged = S1Servers.make(from: snapshot, root: 600, groupKillEligible: false, extraMembers: [])
        let world = S1World(nodes: Array(snapshot.nodes.values))
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: S1RecordingAudit(), sleep: world.sleepClosure)
        _ = try await terminator.terminate(forged, policy: S1Fixtures.fastPolicy)
        #expect(world.signalEvents == [.signal(SIGTERM, pid: 600)])
        #expect(world.isAlive(620))
    }

    // MARK: P3-3 — a project's own script that shares an agent's name is a server

    @Test func aProjectScriptNamedLikeAnAgentIsStillAServer() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let gemini = node(800, ppid: 1, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "gemini.js"], cwd: dir)
        let copilot = node(801, ppid: 1, name: "Python", exe: xcodePython, args: [xcodePython, "-m", "copilot"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(
            nodes: S1Fixtures.devTidyChain() + [gemini, copilot],
            listeners: [S1SnapshotBuilder.port(8200, owner: 800), S1SnapshotBuilder.port(8201, owner: 801)])
        let scan = await classify(snapshot)
        #expect(scan.servers.map(\.root.pid) == [800, 801])
        #expect(scan.others.isEmpty)
    }

    // MARK: N-6 — an unlisted tool that leads the group from another folder is not a root

    @Test func anUnlistedToolLeadingTheServersGroupFromAnotherFolderIsNotTheRoot() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let tool = node(600, ppid: 4999, name: "node", exe: S1Fixtures.nodeExe,
                        args: [S1Fixtures.nodeExe, "/opt/tools/some-cli/cli.js"], cwd: S1Fixtures.developer)
        let server = node(610, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, dir + "/server.js", "--port", "8300"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [tool, server],
                                                  listeners: [S1SnapshotBuilder.port(8300, owner: 610)])
        let found = try #require(await classify(snapshot).servers.first)
        #expect(found.root.pid == 610)
        #expect(found.members.map(\.pid) == [610])
        #expect(!found.groupKillEligible)
    }

    @Test func aMonorepoOrchestratorAtTheRepoRootIsTheRootOfThePackagesServer() async throws {
        // `deno task dev` at the repository root starts Vite in `packages/client`: the orchestrator is not inside the package.
        let repo = S1Fixtures.developer + "/mono"
        let package = repo + "/packages/client"
        let deno = node(600, ppid: 4999, name: "deno", exe: "/opt/homebrew/bin/deno", args: ["deno", "task", "dev"], cwd: repo)
        let vite = node(610, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                        args: [S1Fixtures.nodeExe, package + "/node_modules/.bin/vite", "--port", "8400"], cwd: package)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [deno, vite],
                                                  listeners: [S1SnapshotBuilder.port(8400, owner: 610)])

        // The repository is an anchor of the package's project: the orchestrator belongs to it, the group may be signalled.
        let inRepo = S1FakeProjects([Project(root: package, name: "client", groupName: "packages", kinds: [.vite], repoRoot: repo)])
        let anchored = try #require(await classify(snapshot, projects: inRepo).servers.first)
        #expect(anchored.root.pid == 600)
        #expect(anchored.members.map(\.pid) == [600, 610])
        #expect(anchored.groupKillEligible)

        // Without a repository only the package is an anchor: the same orchestrator is a stranger and is left alone.
        let alone = S1FakeProjects([Project(root: package, name: "client", groupName: "packages", kinds: [.vite], repoRoot: nil)])
        let strangerRoot = try #require(await classify(snapshot, projects: alone).servers.first)
        #expect(strangerRoot.root.pid == 610)
        #expect(strangerRoot.members.map(\.pid) == [610])
        #expect(!strangerRoot.groupKillEligible)
    }

    @Test func aLeaderThatOnlyNamesAProjectFileInItsArgumentsIsNotTheRoot() async throws {
        // F3-7: an unlisted tool run from elsewhere, merely pointed at the project's script, must not become the kill root.
        let dir = S1Fixtures.developer + "/pyproj"
        let tool = node(600, ppid: 4999, name: "node", exe: S1Fixtures.nodeExe,
                        args: [S1Fixtures.nodeExe, "/opt/tools/some-cli/cli.js", dir + "/server.js"], cwd: S1Fixtures.home)
        let server = node(610, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, dir + "/server.js", "--port", "8310"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [tool, server],
                                                  listeners: [S1SnapshotBuilder.port(8310, owner: 610)])
        let found = try #require(await classify(snapshot).servers.first)
        #expect(found.root.pid == 610)
        #expect(!found.groupKillEligible)
    }

    // MARK: F3-3 — the row text is redacted where it is built

    @Test func theServerRowCommandNeverCarriesASecret() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let server = node(800, ppid: 1, name: "node", exe: S1Fixtures.nodeExe,
                          args: [S1Fixtures.nodeExe, dir + "/node_modules/.bin/vite", "--token", "abc123", "API_KEY=zzz999",
                                 "--port", "8500"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [server],
                                                  listeners: [S1SnapshotBuilder.port(8500, owner: 800)])
        let found = try #require(await classify(snapshot).servers.first)
        #expect(found.command == "vite --token \(ArgvRedaction.mask) API_KEY=\(ArgvRedaction.mask) --port 8500")
    }

    // MARK: R3-P3-1 — a project binary named like an editor is a server and Stop works on it

    @Test func aProjectBinaryNamedLikeAnEditorIsAServerAndItsRootCanBeStopped() async throws {
        let dir = S1Fixtures.developer + "/pyproj"
        let fleet = node(800, ppid: 4999, name: "fleet", exe: dir + "/target/debug/fleet", args: [dir + "/target/debug/fleet"], cwd: dir)
        let snapshot = S1SnapshotBuilder.snapshot(nodes: S1Fixtures.devTidyChain() + [fleet],
                                                  listeners: [S1SnapshotBuilder.port(8080, owner: 800)])
        let found = try #require(await classify(snapshot).servers.first)
        #expect(found.root.pid == 800)
        #expect(found.listeners.map(\.pid) == [800])

        let world = S1World(nodes: Array(snapshot.nodes.values))
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: S1RecordingAudit(), sleep: world.sleepClosure)
        let report = try await terminator.terminate(found, policy: S1Fixtures.fastPolicy)
        #expect(world.signalEvents == [.group(SIGTERM, pgid: 800)])
        #expect(report.terminated == [800])
    }

    // MARK: Scale

    @Test func threeHundredServersAreClassifiedIndividually() async {
        var nodes = S1Fixtures.devTidyChain()
        var listeners: [ListeningPort] = []
        for index in 0..<300 {
            let pid = Int32(10_000 + index * 3)
            nodes.append(S1SnapshotBuilder.node(pid, ppid: 3184, name: "node", exe: S1Fixtures.nodeExe,
                                                args: ["npm exec vite --port \(5000 + index)"], cwd: S1Fixtures.developer + "/roblox-pet"))
            nodes.append(S1SnapshotBuilder.node(pid + 1, ppid: pid, pgid: pid, name: "node", exe: S1Fixtures.nodeExe,
                                                args: [S1Fixtures.nodeExe, S1Fixtures.developer + "/roblox-pet/node_modules/.bin/vite", "--port", "\(5000 + index)"],
                                                cwd: S1Fixtures.developer + "/roblox-pet"))
            listeners.append(S1SnapshotBuilder.port(UInt16(5000 + index), owner: pid + 1))
        }
        let scan = await classify(S1SnapshotBuilder.snapshot(nodes: nodes, listeners: listeners))
        #expect(scan.servers.count == 300)
        #expect(Set(scan.servers.compactMap(\.mainPort)).count == 300)
    }
}
