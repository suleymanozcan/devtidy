import Foundation
import Testing
@testable import DevTidyCore

/// CodeReview P1-5: the kill confirmation must reveal the root's command line, every process that will be signalled, the
/// merged servers and the spared processes.
@Suite struct KillPreviewTests {
    private func server(root: Int32, snapshot: ProcessSnapshot = S1Fixtures.everything()) -> DevServer {
        S1Servers.make(from: snapshot, root: root, groupKillEligible: true)
    }

    @Test func aSingleServerListsItsRootCommandEveryProcessAndTheGroupSignal() async throws {
        let scan = await ServerClassifier(projects: S1Fixtures.projectDetector(), homeDirectory: S1Fixtures.home)
            .classify(S1Fixtures.everything())
        let backoffice = try #require(scan.servers.first { $0.root.pid == 77527 })
        let preview = backoffice.killPreview

        #expect(preview.message == "backoffice (:3000) ve alt süreçleri sonlandırılacak (önce SIGTERM, kapanmazsa SIGKILL).")
        #expect(preview.details.first == "Proje: backoffice")                              // the folder the server runs from, then...
        #expect(preview.details.contains { $0.hasPrefix("Kök süreç: PID 77527  node") })
        #expect(preview.details.contains("  npm exec next dev -p 3000"))                  // the root's full command line
        #expect(preview.details.contains("Sinyal: süreç grubuna (pgid 77527) tek seferde gönderilir"))
        #expect(preview.details.contains("Sonlandırılacak süreçler (3):"))
        #expect(preview.details.contains("PID 77527  node  (kök)"))
        #expect(preview.details.contains("PID 77557  node"))
        #expect(preview.details.contains("PID 77578  node"))
        #expect(!preview.details.contains { $0.hasPrefix("Dokunulmayacak") })
        #expect(!preview.details.contains { $0.hasPrefix("Sunucu:") })                    // one server: no per-server lines
    }

    @Test func aTreeWithoutGroupEligibilityStatesThatEveryProcessIsSignalledOnItsOwn() {
        let individual = S1Servers.make(from: S1Fixtures.everything(), root: 77527, groupKillEligible: false)
        #expect(individual.killPreview.details.contains("Sinyal: her sürece tek tek gönderilir"))
    }

    @Test func sparedProcessesAreNamedSoTheUserKnowsTheyStay() {
        var withChrome = server(root: 77527)
        let chrome = S1SnapshotBuilder.node(810, ppid: 77527, name: "Google Chrome fo")
        let editor = S1SnapshotBuilder.node(811, ppid: 77527, name: "nvim")
        withChrome.sparedRoots = [chrome, editor]
        let details = withChrome.killPreview.details
        let header = details.firstIndex(of: "Dokunulmayacak (tarayıcı / uygulama / editör / terminal / ajan, alt süreçleriyle):")
        #expect(header != nil)
        #expect(header.map { Array(details[($0 + 1)...]) } == ["PID 810  Google Chrome fo", "PID 811  nvim"])
    }

    @Test func aLongCommandLineIsShownInFullUpToTheLimitAndOnlyTheOversizedWordIsCut() {
        let argument = String(repeating: "a", count: 3_000)
        let root = S1SnapshotBuilder.node(600, ppid: 1, name: "node", exe: S1Fixtures.nodeExe,
                                          args: [S1Fixtures.nodeExe, "/p/some-cli.js", "--flag", argument])
        let snapshot = S1SnapshotBuilder.snapshot(nodes: [root])
        let details = server(root: 600, snapshot: snapshot).killPreview.details

        let full = KillPreview.commandLine(of: root)
        #expect(full.count == KillPreview.commandLimit)
        #expect(full.hasSuffix("…"))
        let prefix = "\(S1Fixtures.nodeExe) /p/some-cli.js --flag "
        #expect(full.hasPrefix(prefix + "aaa"))
        let rows = details.filter { $0.hasPrefix("  ") }.map { String($0.dropFirst(2)) }
        #expect(rows.allSatisfy { $0.count <= KillPreview.chunkWidth })
        // Rows break at spaces: the words before the huge argument are never split, the argument starts a row of its own...
        #expect(rows[0] == "\(S1Fixtures.nodeExe) /p/some-cli.js")
        #expect(rows[1] == "--flag")
        // ... and it is the only thing cut, with nothing lost between its pieces.
        #expect(rows.dropFirst(2).joined() == String(full.dropFirst(prefix.count)))
    }

    @Test func rowsBreakAtSpacesAndANormalCommandNeverLosesAWord() {
        let words = (1...40).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let rows = KillPreview.chunks(of: text, width: 30)
        #expect(rows.count > 1)
        #expect(rows.allSatisfy { $0.count <= 30 })
        #expect(rows.joined(separator: " ") == text)                            // only spaces were consumed by the breaks
        #expect(rows.flatMap { $0.split(separator: " ") }.map(String.init) == words)   // no word was split
        // A word that fits exactly is not cut; one more character moves it to the next row.
        #expect(KillPreview.chunks(of: "aaaa bbbb", width: 9) == ["aaaa bbbb"])
        #expect(KillPreview.chunks(of: "aaaa bbbb", width: 8) == ["aaaa", "bbbb"])
        // A word longer than a row is cut only at the row width, and the text after it continues on the last piece's row.
        #expect(KillPreview.chunks(of: "x abcdefghij y", width: 4) == ["x", "abcd", "efgh", "ij y"])
    }

    @Test func aShortCommandIsOneLineAndAnUnreadableArgvFallsBackToTheExecutable() {
        #expect(KillPreview.commandLine(of: S1SnapshotBuilder.node(1, ppid: 0, name: "node", exe: "/x/node", args: ["/x/node", "a", "b"])) == "/x/node a b")
        #expect(KillPreview.commandLine(of: S1SnapshotBuilder.node(1, ppid: 0, name: "node", exe: "/x/node", args: nil)) == "/x/node")
        #expect(KillPreview.commandLine(of: S1SnapshotBuilder.node(1, ppid: 0, name: "node", exe: nil, args: [])) == "node")
        #expect(KillPreview.chunks(of: "abcdef", width: 4) == ["abcd", "ef"])
    }

    // MARK: I-4 — what the card prints from argv

    @Test func secretsAndInvisibleCharactersInTheCommandLineAreNotPrinted() {
        let node = S1SnapshotBuilder.node(
            600, ppid: 1, name: "node", exe: S1Fixtures.nodeExe,
            args: [S1Fixtures.nodeExe, "server.js", "--token", "abc123", "--api-key=zzz999", "--name", "x\u{202E}y\nz",
                   "https://user:hunter2@example.com/path", "--port", "3000"])
        let line = KillPreview.commandLine(of: node)
        #expect(!line.contains("abc123") && !line.contains("zzz999") && !line.contains("hunter2"))
        #expect(line.contains("--token \(ArgvRedaction.mask) --api-key=\(ArgvRedaction.mask)"))
        #expect(line.contains("https://\(ArgvRedaction.mask)@example.com/path"))
        #expect(line.contains("x\(ArgvRedaction.replacement)y\(ArgvRedaction.replacement)z"))      // bidi override and newline
        #expect(line.hasSuffix("--port 3000"))                                                   // ordinary arguments are untouched
        #expect(!line.unicodeScalars.contains { $0.value == 0x202E || $0 == "\n" })
    }

    @Test func theCardMasksEnvironmentStyleSecretsAndShellPayloadsLikeEveryOtherSurface() {
        // F3-3: `NAME=value`, `--pass`, `--auth` and the script of `sh -c` were not hidden before.
        let args = ["/bin/sh", "-c", "API_KEY=zzz999 vite --pass hunter2 --auth=s3cret --port 3000"]
        let node = S1SnapshotBuilder.node(600, ppid: 1, name: "sh", exe: "/bin/sh", args: args)
        let line = KillPreview.commandLine(of: node)
        #expect(line == "/bin/sh -c API_KEY=\(ArgvRedaction.mask) vite --pass \(ArgvRedaction.mask) --auth=\(ArgvRedaction.mask) --port 3000")
        // The card wraps exactly that text, so no wrapped row can show what the line hides.
        let details = server(root: 600, snapshot: S1SnapshotBuilder.snapshot(nodes: [node])).killPreview.details.joined(separator: "\n")
        #expect(!details.contains("zzz999") && !details.contains("hunter2") && !details.contains("s3cret"))
    }

    @Test func namesFromFoldersAndTheKernelCannotInjectLinesOrOverrideTheCard() {
        // F3-4: a folder name with a line break and a bidi override, a process name with a newline.
        let evil = "api\u{202E}\nINJECTED"
        let root = S1SnapshotBuilder.node(600, ppid: 1, name: "no\nde", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let child = S1SnapshotBuilder.node(610, ppid: 600, pgid: 600, name: "wor\u{202E}ker", exe: S1Fixtures.nodeExe,
                                           args: [S1Fixtures.nodeExe, "w.js"])
        let project = Project(root: "/p/\(evil)", name: evil, groupName: nil, kinds: [.node], repoRoot: nil)
        var server = S1Servers.make(from: S1SnapshotBuilder.snapshot(nodes: [root, child]), root: 600, groupKillEligible: true,
                                    project: project)
        server.sparedRoots = [S1SnapshotBuilder.node(620, ppid: 600, name: "chro\nme")]
        let preview = server.killPreview
        for text in [preview.message] + preview.details {
            #expect(!text.unicodeScalars.contains { $0.value == 0x202E || $0 == "\n" }, "\(text)")
        }
        #expect(!preview.details.contains { $0.hasPrefix("INJECTED") })                       // nothing starts a line of its own
        #expect(preview.message.hasPrefix("api"))
    }

    @Test func theCardNamesTheFolderAndTheCheckoutSoTwoSameNamedProjectsAreToldApart() {
        let home = "/Users/someone"
        let root = S1SnapshotBuilder.node(600, ppid: 1, name: "node", exe: S1Fixtures.nodeExe, args: [S1Fixtures.nodeExe, "server.js"])
        let project = Project(root: home + "/work/redalert-perf/packages/client", name: "client", groupName: nil,
                              kinds: [.vite], repoRoot: home + "/work/redalert-perf")
        let server = S1Servers.make(from: S1SnapshotBuilder.snapshot(nodes: [root]), root: 600, groupKillEligible: true,
                                    project: project)

        // Without identity: the folder name and the folder.
        let plain = KillPreview(server, identity: nil, home: home)
        #expect(Array(plain.details.prefix(2)) == ["Proje: client", "  ~/work/redalert-perf/packages/client"])

        // With identity: the repository, the path inside it and the branch.
        let identity = ProjectIdentity(path: project.root, folderName: "client", repoRoot: home + "/work/redalert-perf",
                                       repoName: "redalert-perf", pathInRepo: "packages/client", workspaceName: nil,
                                       head: .branch("perf-fx"), manifest: nil)
        let named = KillPreview(server, identity: identity, home: home)
        #expect(Array(named.details.prefix(2)) == ["Proje: redalert-perf › packages/client  ⎇ perf-fx",
                                                    "  ~/work/redalert-perf/packages/client"])
        // A server without a project gets no such line.
        let projectless = S1Servers.make(from: S1SnapshotBuilder.snapshot(nodes: [root]), root: 600, groupKillEligible: true)
        #expect(!KillPreview(projectless, identity: nil, home: home).details.contains { $0.hasPrefix("Proje:") })
    }

    // MARK: QA2 N2 — a port-less child is a process of the server, not a second server

    @Test func aChildThatOnlyListensOnInternalPortsIsNotCountedAsASecondServer() async throws {
        let scan = await ServerClassifier(projects: S1Fixtures.projectDetector(), homeDirectory: S1Fixtures.home)
            .classify(S1Fixtures.everything())
        let vite = try #require(scan.servers.first { $0.root.pid == 9402 })
        // vite 9422 (:5174) and its workerd child 9425 (ephemeral ports only) are both listeners of this tree.
        #expect(vite.listeners.map(\.pid).sorted() == [9422, 9425])
        let preview = vite.killPreview
        #expect(preview.message == "roblox-pet (:5174) ve alt süreçleri sonlandırılacak (önce SIGTERM, kapanmazsa SIGKILL).")
        #expect(!preview.details.contains { $0.hasPrefix("Sunucu:") })
        #expect(preview.details.contains("Sonlandırılacak süreçler (3):"))
        #expect(preview.details.contains("PID 9425  workerd"))
    }

    @Test func aDeclaredInspectorPortDoesNotMakeAListenerAServer() {
        let app = ServerListener(pid: 700, name: "node", project: nil,
                                 ports: [S1SnapshotBuilder.port(3000, owner: 700)])
        let debugger = ServerListener(pid: 701, name: "node", project: nil,
                                      ports: [S1SnapshotBuilder.port(9333, owner: 701)])
        let root = S1SnapshotBuilder.node(700, ppid: 1, name: "node", exe: S1Fixtures.nodeExe,
                                          args: [S1Fixtures.nodeExe, "--inspect-port=9333", "server.js"])
        var server = S1Servers.make(from: S1SnapshotBuilder.snapshot(nodes: [root]), root: 700, groupKillEligible: true)
        server.listeners = [app, debugger]
        #expect(!server.killPreview.details.contains { $0.hasPrefix("Sunucu:") })
        #expect(server.killPreview.message.hasSuffix("ve alt süreçleri sonlandırılacak (önce SIGTERM, kapanmazsa SIGKILL)."))
    }
}
