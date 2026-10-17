import Foundation
import Testing
@testable import DevTidyCore

@MainActor
struct ActivityCheckerTests {
    private let root = "/tmp/s4home/developer/proj"

    private struct Fixture {
        let log = S4Log()
        let clock = S4Clock()
        let scanner: S4Scanner
        let classifier: S4Classifier
        let docker: S4Docker
        let checker: LiveActivityChecker

        init() {
            scanner = S4Scanner(log: log, clock: clock)
            classifier = S4Classifier(log: log, clock: clock)
            docker = S4Docker(log: log, clock: clock)
            checker = LiveActivityChecker(scanner: scanner, docker: docker, classifier: classifier)
            // A reachable daemon with nothing running; tests that care about Docker replace the snapshot.
            docker.state.with { $0.snapshot = S4.dockerSnapshot() }
        }

        func nodes(_ nodes: [ProcessNode], listeners: [Int32: [ListeningPort]] = [:]) {
            scanner.state.with { $0.nodes = nodes; $0.listeners = listeners }
        }
        func containers(_ containers: [DockerContainer]) {
            docker.state.with { $0.snapshot = S4.dockerSnapshot(standalone: containers) }
        }
    }

    @Test func hardNamedProcessInsideRootIsAHardBlocker() async {
        let f = Fixture()
        f.nodes([S4.node(100, name: "node", cwd: root + "/apps/web")])
        let blockers = await f.checker.blockers(for: root)
        #expect(blockers.count == 1)
        #expect(blockers.first?.severity == .hard)
        #expect(blockers.first?.pid == 100)
        #expect(blockers.first?.label == "node (PID 100)")
        #expect(f.log.events.contains("scan:full"))   // a full scan, every time
    }

    @Test func prefixedHardNamesAreRecognised() async {
        let f = Fixture()
        f.nodes([S4.node(1, name: "python3.12", cwd: root), S4.node(2, name: "php-fpm", cwd: root),
                 S4.node(3, name: "webpack-dev-serv", cwd: root), S4.node(4, name: "gradle-daemon", cwd: root)])
        let blockers = await f.checker.blockers(for: root)
        #expect(blockers.count == 4)
        #expect(blockers.allSatisfy { $0.severity == .hard })
    }

    @Test func otherProcessInsideRootIsSoft() async {
        let f = Fixture()
        f.nodes([S4.node(100, name: "tail", cwd: root)])
        let blockers = await f.checker.blockers(for: root)
        #expect(blockers.count == 1)
        #expect(blockers.first?.severity == .soft)
    }

    @Test func listenerOwnerWithUnknownNameIsHard() async {
        let f = Fixture()
        f.nodes([S4.node(100, name: "mystery", cwd: root)], listeners: [100: [S4.port(8080, owner: 100)]])
        let blockers = await f.checker.blockers(for: root)
        #expect(blockers.first?.severity == .hard)
        #expect(blockers.first?.kind == .listener)
    }

    @Test func shellsTerminalsAndEditorsWithCwdInRootAreIgnored() async {
        let f = Fixture()
        f.nodes(["zsh", "bash", "fish", "sh", "dash", "login", "iTerm2", "Terminal", "Ghostty", "Warp", "Code", "Cursor",
                 "Xcode", "Zed", "Finder", "Dock", "mds_stores"].enumerated().map { index, name in
            S4.node(Int32(200 + index), name: name, cwd: root)
        })
        #expect(await f.checker.blockers(for: root).isEmpty)
    }

    @Test func devTidyItselfAndItsChildrenAreIgnored() async {
        let f = Fixture()
        f.nodes([S4.node(4242, name: "DevTidy", cwd: root),
                 S4.node(4300, ppid: 4242, name: "git", cwd: root),
                 S4.node(4301, ppid: 4300, name: "node", cwd: root)])
        #expect(await f.checker.blockers(for: root).isEmpty)
    }

    @Test func processWithoutCwdOrOutsideRootIsIgnored() async {
        let f = Fixture()
        f.nodes([S4.node(1, name: "node", cwd: nil), S4.node(2, name: "node", cwd: "/tmp/s4home/developer/other"),
                 S4.node(3, name: "node", cwd: "/")])
        #expect(await f.checker.blockers(for: root).isEmpty)
    }

    @Test func siblingPrefixIsNotABlocker() async {
        let f = Fixture()
        f.nodes([S4.node(1, name: "node", cwd: root + "-evil"), S4.node(2, name: "node", cwd: root + "-evil/sub")])
        f.containers([S4.container("evil", mounts: [root + "-evil"])])
        #expect(await f.checker.blockers(for: root).isEmpty)
    }

    @Test func ceilingHoistingCoversSubPackages() async {
        // The cleaner passes the ceiling (repo root); a server in a nested workspace package still blocks.
        let f = Fixture()
        f.nodes([S4.node(7, name: "node", cwd: root + "/packages/api/src")])
        #expect(await f.checker.blockers(for: root).count == 1)
        // …and a process in a different repo does not.
        #expect(await f.checker.blockers(for: "/tmp/s4home/developer/another").isEmpty)
    }

    @Test func containerMountEqualBelowOrAboveRootIsSoft() async {
        let f = Fixture()
        f.containers([S4.container("equal", mounts: [root]),
                      S4.container("below", mounts: [root + "/src"]),
                      S4.container("above", mounts: ["/tmp/s4home/developer"]),
                      S4.container("compose", workingDir: root),
                      S4.container("elsewhere", mounts: ["/tmp/other"])])
        let blockers = await f.checker.blockers(for: root)
        #expect(Set(blockers.map(\.label)) == ["equal", "below", "above", "compose"])
        #expect(blockers.allSatisfy { $0.kind == .container && $0.severity == .soft && $0.pid == nil && $0.containerID != nil })
    }

    @Test func stoppedContainersDoNotBlock() async {
        let f = Fixture()
        f.containers([S4.container("old", state: .exited, mounts: [root])])
        #expect(await f.checker.blockers(for: root).isEmpty)
    }

    @Test func classifiedServerBecomesOneHardBlockerAndItsMembersAreFolded() async {
        let f = Fixture()
        let project = S4.project(root)
        let child = S4.node(31, ppid: 30, name: "node", cwd: root)
        let server = S4.server(pid: 30, project: project, port: 3000, extraMembers: [child])
        f.nodes([server.root, child])
        f.classifier.state.with { $0.servers = [server] }
        let blockers = await f.checker.blockers(for: root)
        #expect(blockers.count == 1)
        #expect(blockers.first?.pid == 30)
        #expect(blockers.first?.severity == .hard)
        #expect(blockers.first?.label == "proj :3000 (PID 30)")
    }

    /// Security F3-4: the label is built from a folder, process or container name and reaches the cleanup sheet and its error
    /// messages: no bidirectional or invisible scalar, no line break, bounded.
    @Test func blockerLabelsAreCleanedAndBounded() async {
        let f = Fixture()
        let server = S4.server(pid: 30, project: S4.project(root + "/apps/web", name: "we\u{202E}b\u{200B}"), port: 3000)
        f.nodes([server.root,
                 S4.node(40, name: "ta\u{202E}il\u{0007}x\n", cwd: root),
                 S4.node(41, name: String(repeating: "w", count: 5_000), cwd: root)])
        f.classifier.state.with { $0.servers = [server] }
        f.containers([S4.container("db\u{2028}INJECTED\u{0007}", mounts: [root])])
        let labels = await f.checker.blockers(for: root).map(\.label)

        #expect(labels.contains("web :3000 (PID 30)"))
        #expect(labels.contains("tailx (PID 40)"))
        #expect(labels.contains("db INJECTED"))
        let long = labels.first { $0.hasSuffix(" (PID 41)") }
        #expect(long != nil)
        #expect((long?.count ?? .max) <= LiveActivityChecker.maxBlockerNameLength + " (PID 41)".count)
        #expect(labels.count == 4)
    }

    @Test func serverOfAnotherProjectIsNotABlocker() async {
        let f = Fixture()
        let server = S4.server(pid: 30, project: S4.project("/tmp/s4home/developer/other"))
        f.nodes([S4.node(30, name: "node", cwd: "/tmp/s4home/developer/other")])
        f.classifier.state.with { $0.servers = [server] }
        #expect(await f.checker.blockers(for: root).isEmpty)
    }

    @Test func hardBlockersSortBeforeSoftOnes() async {
        let f = Fixture()
        f.nodes([S4.node(1, name: "tail", cwd: root), S4.node(2, name: "node", cwd: root)])
        f.containers([S4.container("db", mounts: [root])])
        let blockers = await f.checker.blockers(for: root)
        #expect(blockers.map(\.severity) == [.hard, .soft, .soft])
    }

    /// F-6: only the Xcode IDE (and its exact helpers) is benign; a running `xcodebuild` is activity that the class B/C
    /// Xcode entries (`xcode.build`, `xcode.derived`, `swiftpm.build`) must wait for.
    @Test func xcodebuildInsideTheRootBlocksClassBButTheXcodeAppDoesNot() async throws {
        let f = Fixture()
        f.nodes([S4.node(10, name: "xcodebuild", cwd: root), S4.node(11, name: "Xcode", cwd: root),
                 S4.node(12, name: "Xcode Helper", cwd: root)])
        let blockers = await f.checker.blockers(for: root)
        #expect(blockers.map(\.pid) == [10])
        let b = try #require(blockers.first)
        #expect(b.severity == .soft)
        #expect(b.blocks(.conditional) && b.blocks(.optIn))
        #expect(!b.blocks(.always))
    }

    /// F-6: a Docker list that failed (or was cancelled) carries no containers; "none running" must not be assumed.
    @Test(arguments: [DockerStatus.unknown, DockerStatus.failed("timeout")])
    func aFailedDockerListIsAnUnverifiedSoftBlocker(_ status: DockerStatus) async throws {
        let f = Fixture()
        f.docker.state.with { $0.snapshot = S4.dockerSnapshot(status: status) }
        let blockers = await f.checker.blockers(for: root)
        let b = try #require(blockers.first)
        #expect(blockers.count == 1)
        #expect(b.kind == .container && b.severity == .soft && b.pid == nil && b.containerID == nil)
        #expect(b.label == LiveActivityChecker.dockerUnverifiedLabel)
        #expect(b.blocks(.conditional) && b.blocks(.optIn), "class B/C wait until Docker can be verified")
        #expect(!b.blocks(.always), "class A is never held up by containers")
        #expect(b.isDockerUnverified)
    }

    /// The review sheet words the unverified blocker differently from something that is running: only that one is flagged.
    @Test func onlyTheUnverifiedDockerBlockerIsFlaggedAsUnverified() async {
        let unverified = Fixture()
        unverified.nodes([S4.node(100, name: "node", cwd: root)])
        unverified.docker.state.with { $0.snapshot = S4.dockerSnapshot(status: .unknown) }
        let mixed = await unverified.checker.blockers(for: root)
        #expect(mixed.count == 2)
        #expect(mixed.filter(\.isDockerUnverified).map(\.label) == [LiveActivityChecker.dockerUnverifiedLabel])
        #expect(mixed.filter { !$0.isDockerUnverified }.map(\.kind) == [.process])

        let running = Fixture()
        running.containers([S4.container("db", mounts: [root])])
        let blockers = await running.checker.blockers(for: root)
        #expect(blockers.count == 1 && blockers.allSatisfy { !$0.isDockerUnverified }, "a running container is not the unverified notice")
    }

    @Test(arguments: [DockerStatus.running(DockerEngineInfo(version: "1", apiVersion: "1")), DockerStatus.notRunning,
                      DockerStatus.notInstalled, DockerStatus.unsupported("remote context")])
    func aDockerStateThatCannotHoldALocalBindMountAddsNoBlocker(_ status: DockerStatus) async {
        let f = Fixture()
        f.docker.state.with { $0.snapshot = S4.dockerSnapshot(status: status) }
        #expect(await f.checker.blockers(for: root).isEmpty)
    }

    @Test func blocksTruthTable() {
        let hard = S4.blocker("h", severity: .hard)
        let soft = S4.blocker("s", severity: .soft)
        #expect(hard.blocks(.always) && hard.blocks(.conditional) && hard.blocks(.optIn))
        #expect(!soft.blocks(.always))
        #expect(soft.blocks(.conditional) && soft.blocks(.optIn))
    }

    @Test func pathRelationNeverMatchesSiblingPrefixes() {
        #expect(PathRelation.isInside("/a/proj", root: "/a/proj"))
        #expect(PathRelation.isInside("/a/proj/x", root: "/a/proj"))
        #expect(PathRelation.isInside("/a/proj/x", root: "/a/proj/"))
        #expect(!PathRelation.isInside("/a/proj-evil", root: "/a/proj"))
        #expect(!PathRelation.isInside("/a", root: "/a/proj"))
        #expect(PathRelation.overlaps("/a", "/a/proj"))
        #expect(PathRelation.overlaps("/a/proj/x", "/a/proj"))
        #expect(!PathRelation.overlaps("/a/proj-evil", "/a/proj"))
    }
}
