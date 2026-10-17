import Foundation
import Testing
@testable import DevTidyCore

struct ServerPresentationTests {
    private let root = S4.home + "/developer/redalert/packages/client"
    private var project: Project { S4.project(root) }

    private func manifest(_ name: String, version: String? = "1.0.0") -> ProjectManifest {
        ProjectManifest(name: name, version: version, source: .packageJSON)
    }

    // MARK: Title and subtitle

    @Test func theTitleIsThePageTitleThenTheManifestNameThenTheFolder() {
        let server = S4.server(pid: 10, project: project, port: 5182)
        let withManifest = S4.identity(root, manifest: manifest("@red/client", version: "2.0.1"))
        let bare = S4.identity(root)

        let page = ServerPresentation(server: server, identity: withManifest, pageTitle: "Red Alert · Admin")
        #expect(page.title == "Red Alert · Admin")
        #expect(page.titleSource == .pageTitle)
        #expect(page.manifestLabel == "@red/client@2.0.1")                      // differs from the title: shown as the subtitle

        let named = ServerPresentation(server: server, identity: withManifest, pageTitle: nil)
        #expect(named.title == "@red/client")
        #expect(named.titleSource == .manifestName)
        #expect(named.manifestLabel == nil)                                      // it IS the title: nothing to add

        let folder = ServerPresentation(server: server, identity: bare, pageTitle: nil)
        #expect(folder.title == "client")
        #expect(folder.titleSource == .folderName)
        #expect(folder.manifestLabel == nil)

        let unresolved = ServerPresentation(server: server, identity: nil, pageTitle: nil)
        #expect(unresolved.title == "client")                                    // the project's own name until the identity lands
        #expect(unresolved.titleSource == .folderName)

        let loose = ServerPresentation(server: S4.server(pid: 11, project: nil), identity: nil, pageTitle: nil)
        #expect(loose.title == "node")
        #expect(loose.titleSource == .processName)
    }

    @Test func aPageTitleEqualToTheManifestNameLeavesNoSubtitle() {
        let server = S4.server(pid: 10, project: project)
        let identity = S4.identity(root, manifest: manifest("Red Alert"))
        let presentation = ServerPresentation(server: server, identity: identity, pageTitle: "red alert")
        #expect(presentation.manifestLabel == nil)
    }

    @Test func anEmptyPageTitleIsNotATitle() {
        let presentation = ServerPresentation(server: S4.server(pid: 10, project: project), identity: S4.identity(root), pageTitle: "")
        #expect(presentation.titleSource == .folderName)
    }

    @Test func untrustedNamesAreCleanedOnTheirWayIntoARow() {
        let evilFolder = "pro\u{202E}ject\u{200B}"
        let server = S4.server(pid: 10, project: S4.project(S4.home + "/developer/x", name: evilFolder))
        let identity = S4.identity(S4.home + "/developer/x")
        // a project name without an identity, the process name of a project-less server, a page title and a manifest name
        #expect(ServerPresentation(server: server, identity: nil, pageTitle: nil).title == "project")
        let loose = S4.server(pid: 11, project: nil)
        #expect(ServerPresentation(server: loose, identity: nil, pageTitle: nil).title == "node")
        #expect(ServerPresentation(server: server, identity: identity, pageTitle: "Ad\u{200B}min\u{202E}").title == "Admin")
        let manifestOnly = S4.identity(S4.home + "/developer/x", manifest: manifest("na\u{202E}me", version: "1\u{200B}.0"))
        let presentation = ServerPresentation(server: server, identity: manifestOnly, pageTitle: "\u{200B}")
        #expect(presentation.title == "name")                                  // an invisible-only page title is no title
        #expect(presentation.titleSource == .manifestName)
    }

    // MARK: Rows that read the same (two checkouts of one repository)

    private func row(_ pid: Int32, title: String = "Kızıl Alarm — Prototip", location: String?, branch: String?,
                     port: UInt16?) -> ServerRowInfo {
        ServerRowInfo(id: S4.identity(pid), title: title, location: location, branch: branch, port: port)
    }

    @Test func theScreenshotCaseTwoCheckoutsServingTheSamePageAreToldApart() {
        // Two checkouts of redalert, both `packages/client`, both serving "Kızıl Alarm — Prototip" with the manifest
        // "@redalert/client": the rows are textually identical but for what the qualifier adds.
        let rootA = S4.home + "/tmp/redalert-perf/packages/client"
        let rootB = S4.home + "/tmp/redalert-perf-base/packages/client"
        let release = ProjectManifest(name: "@redalert/client", version: "0.1.0", source: .packageJSON)
        let servers = [
            S4.server(pid: 10, project: S4.project(rootA), port: 5182),
            S4.server(pid: 11, project: S4.project(rootB), port: 5184),
        ]
        let identities = [
            S4.identity(rootA, repoRoot: S4.home + "/tmp/redalert-perf", pathInRepo: "packages/client", head: .branch("perf-fx"),
                        manifest: release),
            S4.identity(rootB, repoRoot: S4.home + "/tmp/redalert-perf-base", pathInRepo: "packages/client", head: .branch("main"),
                        manifest: release),
        ]
        let presentations = zip(servers, identities).map {
            ServerPresentation(server: $0, identity: $1, pageTitle: "Kızıl Alarm — Prototip")
        }
        #expect(presentations[0].title == presentations[1].title)                // what the screenshot showed
        #expect(presentations[0].subtitle(framework: "Vite") == presentations[1].subtitle(framework: "Vite"))

        let rows = (0..<2).map { ServerRowInfo(server: servers[$0], presentation: presentations[$0], identity: identities[$0]) }
        let qualifiers = ServerRowQualifier.qualifiers(for: rows)
        #expect(qualifiers[servers[0].id] == "redalert-perf › packages/client (perf-fx) · :5182")
        #expect(qualifiers[servers[1].id] == "redalert-perf-base › packages/client (main) · :5184")
        let subtitles = (0..<2).map { presentations[$0].subtitle(framework: "Vite", qualifier: qualifiers[servers[$0].id]) }
        #expect(subtitles[0] == "redalert-perf › packages/client (perf-fx) · :5182 · @redalert/client@0.1.0 · Vite")
        #expect(subtitles[1] == "redalert-perf-base › packages/client (main) · :5184 · @redalert/client@0.1.0 · Vite")
        #expect(subtitles[0] != subtitles[1])
    }

    @Test func rowsWithATitleOfTheirOwnGetNoQualifier() {
        let rows = [row(10, title: "Admin", location: "a", branch: "main", port: 3000),
                    row(11, title: "Storefront", location: "b", branch: "main", port: 3001)]
        #expect(ServerRowQualifier.qualifiers(for: rows).isEmpty)
        #expect(ServerRowQualifier.qualifiers(for: []).isEmpty)
    }

    @Test func onlyWhatDiffersIsAddedAndThePortAlwaysIs() {
        // same repository and branch, different apps: the location tells them apart, the branch is not repeated
        let apps = ServerRowQualifier.qualifiers(for: [row(10, location: "shop › apps/a", branch: "main", port: 3000),
                                                       row(11, location: "shop › apps/b", branch: "main", port: 3001)])
        #expect(apps[S4.identity(10)] == "shop › apps/a · :3000")
        #expect(apps[S4.identity(11)] == "shop › apps/b · :3001")

        // same location, different branch (two checkouts of one path over time never coexist, but a detached HEAD can)
        let branches = ServerRowQualifier.qualifiers(for: [row(10, location: "shop", branch: "main", port: 3000),
                                                           row(11, location: "shop", branch: "a1b2c3d", port: 3001)])
        #expect(branches[S4.identity(10)] == "(main) · :3000")
        #expect(branches[S4.identity(11)] == "(a1b2c3d) · :3001")

        // one checkout, two servers with the same title: only the ports differ
        let ports = ServerRowQualifier.qualifiers(for: [row(10, location: "shop", branch: "main", port: 3000),
                                                        row(11, location: "shop", branch: "main", port: 3001)])
        #expect(ports[S4.identity(10)] == ":3000")
        #expect(ports[S4.identity(11)] == ":3001")
    }

    @Test func titlesAreComparedIgnoringCase() {
        let qualifiers = ServerRowQualifier.qualifiers(for: [row(10, title: "Admin", location: "a", branch: nil, port: 1),
                                                             row(11, title: "ADMIN", location: "b", branch: nil, port: 2),
                                                             row(12, title: "Other", location: "c", branch: nil, port: 3)])
        #expect(Set(qualifiers.keys) == [S4.identity(10), S4.identity(11)])      // the third has a title of its own
    }

    @Test func projectlessRowsAreToldApartByPortAlone() {
        let qualifiers = ServerRowQualifier.qualifiers(for: [row(10, location: nil, branch: nil, port: 4000),
                                                             row(11, location: nil, branch: nil, port: 4001)])
        #expect(qualifiers[S4.identity(10)] == ":4000")
        #expect(qualifiers[S4.identity(11)] == ":4001")
        // nothing to say about a row that has no port and no difference
        #expect(ServerRowQualifier.qualifiers(for: [row(10, location: nil, branch: nil, port: nil),
                                                    row(11, location: nil, branch: nil, port: nil)]).isEmpty)
    }

    @Test func theSubtitleJoinsTheQualifierTheManifestLabelAndTheFramework() {
        let server = S4.server(pid: 10, project: project)
        let named = ServerPresentation(server: server, identity: S4.identity(root, manifest: manifest("@red/client", version: "2.0.1")),
                                       pageTitle: "Admin")
        #expect(named.subtitle(framework: "Vite") == "@red/client@2.0.1 · Vite")
        #expect(named.subtitle(framework: nil) == "@red/client@2.0.1")
        #expect(named.subtitle(framework: "Vite", qualifier: ":5182") == ":5182 · @red/client@2.0.1 · Vite")
        let bare = ServerPresentation(server: server, identity: S4.identity(root), pageTitle: nil)
        #expect(bare.subtitle(framework: nil) == nil)
        #expect(bare.subtitle(framework: nil, qualifier: ":5182") == ":5182")
    }

    // MARK: Details

    /// `npm run dev` (pid 10) → `node vite --port 5182` (pid 11, owns the port) → `esbuild` (pid 12).
    private func viteTree(arguments: [String]? = ["node", "/x/node_modules/.bin/vite", "--port", "5182", "--strictPort"],
                          ports: [ListeningPort]? = nil, rootArguments: [String]? = ["npm", "run", "dev"],
                          command: String = "vite --port 5182") -> DevServer {
        let npm = S4.node(10, name: "npm", args: rootArguments ?? [], cwd: root)
        let vite = ProcessNode(identity: S4.identity(11), parentPID: 10, pgid: 10, uid: 501, name: "node", executablePath: nil,
                               arguments: arguments, workingDirectory: root, hasControllingTTY: false, memoryBytes: 0,
                               cpuTimeNanoseconds: 0, cpuPercent: nil)
        let esbuild = S4.node(12, ppid: 11, pgid: 10, name: "esbuild", args: ["esbuild", "--service"])
        return DevServer(root: npm, members: [npm, vite, esbuild],
                         ports: ports ?? [S4.port(5182, owner: 11), S4.port(9229, owner: 11), S4.port(50_001, owner: 12)],
                         mainPort: 5182, project: project, kind: .vite, confidence: .high, command: command,
                         cpuPercent: 0, memoryBytes: 0, establishedConnections: 0,
                         hints: ServerHints(orphaned: false, noControllingTTY: true, lanExposed: false, noConnections: true),
                         groupKillEligible: true)
    }

    @Test func theCommandLineIsTheFullArgvOfTheProcessThatOwnsTheMainPort() {
        let details = ServerDetails(server: viteTree(), identity: nil, pageTitle: nil)
        #expect(details.commandLine == "node /x/node_modules/.bin/vite --port 5182 --strictPort")
    }

    @Test func theCommandLineFallsBackToTheRootThenToTheDisplayCommand() {
        #expect(ServerDetails(server: viteTree(arguments: nil), identity: nil, pageTitle: nil).commandLine == "npm run dev")
        #expect(ServerDetails(server: viteTree(arguments: [], rootArguments: nil), identity: nil, pageTitle: nil).commandLine
                == "vite --port 5182")
    }

    @Test func aCommandLineIsSanitizedAndBounded() {
        let evil = ["node", "a\u{202E}b", "line1\nline2\tx\u{1B}[31m"]
        let shown = ServerDetails(server: viteTree(arguments: evil), identity: nil, pageTitle: nil).commandLine
        #expect(shown.hasPrefix("node a\u{FFFD}b "))
        #expect(shown.contains("\u{FFFD}[31m"))
        #expect(!shown.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })

        let huge = ["node", String(repeating: "z", count: 10_000)]
        let line = ServerDetails(server: viteTree(arguments: huge), identity: nil, pageTitle: nil).commandLine
        #expect(line.unicodeScalars.count == ServerDetails.maxCommandLineLength)
        #expect(line.hasSuffix("…"))
    }

    @Test func aRunOfCombiningMarksInTheCommandLineIsBounded() {
        let bomb = ["node", "x" + String(repeating: "\u{0301}", count: 100_000)]
        let line = ServerDetails(server: viteTree(arguments: bomb), identity: nil, pageTitle: nil).commandLine
        #expect(line.unicodeScalars.count == "node x".count + DisplayText.maxMarksPerBase)
    }

    @Test(arguments: [
        ["node", "vite", "--token", "s3cr3t"],
        ["node", "vite", "--token=s3cr3t"],
        ["node", "vite", "--pass", "s3cr3t"],
        ["node", "vite", "--pass=s3cr3t"],
        ["node", "vite", "--auth", "s3cr3t"],
        ["node", "vite", "--auth=s3cr3t"],
        ["cross-env", "API_KEY=s3cr3t", "next", "dev"],
        ["env", "TOKEN=s3cr3t", "node", "vite"],
        ["env", "SECRET=s3cr3t", "node", "vite"],
        ["env", "PASSWORD=s3cr3t", "node", "vite"],
        ["env", "PASS=s3cr3t", "node", "vite"],
        ["env", "KEY=s3cr3t", "node", "vite"],
        ["env", "AUTH=s3cr3t", "node", "vite"],
        ["env", "CREDENTIAL=s3cr3t", "node", "vite"],
        ["sh", "-c", "vite --token s3cr3t --port 5182"],
        ["bash", "-lc", "API_KEY=s3cr3t vite"],
        ["node", "vite", "--api", "https://user:s3cr3t@example.test/x"],
    ])
    func aSecretNeverReachesTheCommandLineThatIsShownAndCopied(arguments: [String]) {
        // `commandLine` is what the row shows AND what its copy button puts on the pasteboard.
        let line = ServerDetails(server: viteTree(arguments: arguments), identity: nil, pageTitle: nil).commandLine
        #expect(!line.contains("s3cr3t"), "\(line)")
        #expect(line.contains(ArgvRedaction.mask), "\(line)")
        #expect(line.hasPrefix(arguments[0]), "\(line)")                         // the rest of the line is still there
    }

    @Test func whatIsNotASecretStaysReadableInTheCommandLine() {
        let arguments = ["node", "vite", "--port", "5182", "--bypass", "x", "--author", "me", "AUTHOR=me", "KEYBOARD=us", "--strictPort"]
        let line = ServerDetails(server: viteTree(arguments: arguments), identity: nil, pageTitle: nil).commandLine
        #expect(line == arguments.joined(separator: " "))
    }

    @Test func theDisplayCommandFallbackIsRedactedToo() {
        let server = viteTree(arguments: [], rootArguments: nil, command: "vite --token s3cr3t --port 5182")
        let line = ServerDetails(server: server, identity: nil, pageTitle: nil).commandLine
        #expect(!line.contains("s3cr3t"))
        #expect(line.contains(ArgvRedaction.mask))
        #expect(line.contains("--port 5182"))
    }

    @Test func processNamesAreCleanedForTheList() {
        let evil = S4.node(11, ppid: 10, pgid: 10, name: "evil\u{202E}name\u{200B}")
        let server = S4.server(pid: 10, project: project, extraMembers: [evil])
        #expect(ServerDetails(server: server, identity: nil, pageTitle: nil).processes.map(\.name) == ["node", "evilname"])
    }

    @Test func detailsListEveryPortWithItsRoleAndEveryProcessRootFirst() {
        let details = ServerDetails(server: viteTree(), identity: S4.identity(root, head: .branch("main"),
                                                                               manifest: manifest("client")), pageTitle: "Admin")
        #expect(details.ports.map(\.port) == [5182, 9229, 50_001])
        #expect(details.ports.map(\.role) == [.main, .inspector, .ephemeral])
        #expect(details.processes.map(\.pid) == [10, 11, 12])
        #expect(details.processes.map(\.name) == ["npm", "node", "esbuild"])
        #expect(details.path == root)
        #expect(details.head == .branch("main"))
        #expect(details.manifest?.label == "client@1.0.0")
        #expect(details.pageTitle == "Admin")
        #expect(details.kind == .vite)
        #expect(details.startedAt == S4.t0.addingTimeInterval(-3_600))
    }

    @Test func aDeclaredInspectorPortIsAnInspectorEvenOutsideTheDefaultRange() {
        let server = S4.server(pid: 10, project: project, port: 3000, extraPorts: [9400, 3001],
                               arguments: ["node", "--inspect=127.0.0.1:9400"])
        let roles = ServerDetails(server: server, identity: nil, pageTitle: nil).ports.map(\.role)
        #expect(roles == [.main, .inspector, .regular])
    }

    @Test func theDetailsFallBackToTheProjectRootWithoutAnIdentity() {
        #expect(ServerDetails(server: viteTree(), identity: nil, pageTitle: nil).path == root)
        #expect(ServerDetails(server: S4.server(pid: 1, project: nil), identity: nil, pageTitle: nil).path == nil)
    }

    // MARK: Which listener is asked for a title

    @Test func theTargetIsTheMainPortOfADevServer() {
        let server = S4.server(pid: 10, project: project, port: 5182)
        let target = PageTitleTarget.make(for: server)
        #expect(target?.port == 5182)
        #expect(target?.server == server.id)
    }

    @Test(arguments: [UInt16(9229), 9230, 9231])
    func inspectorPortsAreNeverAsked(port: UInt16) {
        #expect(PageTitleTarget.make(for: S4.server(pid: 10, project: project, port: port)) == nil)
    }

    @Test func aServerBoundToOneNonLoopbackAddressIsNeverAsked() {
        #expect(PageTitleTarget.make(for: S4.server(pid: 10, project: project, port: 5182, scope: .other)) == nil)
        #expect(PageTitleTarget.make(for: S4.server(pid: 10, project: project, port: 5182, scope: .allInterfaces)) != nil)
        #expect(PageTitleTarget.make(for: S4.server(pid: 10, project: project, port: 5182, scope: .loopback)) != nil)
    }

    @Test func aServerWithoutAMainPortIsNeverAsked() {
        let base = S4.server(pid: 10, project: project, port: 5182)
        let portless = DevServer(root: base.root, members: base.members, ports: [], mainPort: nil, project: project, kind: .node,
                                 confidence: .high, command: "x", cpuPercent: nil, memoryBytes: 0, establishedConnections: 0,
                                 hints: base.hints, groupKillEligible: true)
        #expect(PageTitleTarget.make(for: portless) == nil)
    }
}
