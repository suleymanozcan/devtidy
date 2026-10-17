import Darwin
import Foundation
import Testing
@testable import DevTidyCore

/// K1–K11 against a scripted process table: zero real signals. Every scenario is the ENV §5 Next tree
/// (npm exec 77527 → next 77557 → next-server 77578) under the omp broker 74501, with DevTidy at 5000 under zsh 4999.
@Suite struct ProcessTerminatorTests {
    private static let tree: [Int32] = [77527, 77557, 77578]
    private static let foreignUID: UInt32 = getuid() &+ 1

    private struct Rig {
        let world: S1World
        let audit: S1RecordingAudit
        let terminator: TreeTerminator
        let server: DevServer
    }

    private func makeRig(root: Int32 = 77527, groupKillEligible: Bool, reactions: [Int32: S1World.Reaction] = [:],
                         ownPGID: Int32? = nil, extraMembers: (ProcessSnapshot) -> [ProcessNode] = { _ in [] },
                         configure: (S1World) -> Void = { _ in }) -> Rig {
        let world = S1World(ownPGID: ownPGID, nodes: S1Fixtures.nextScenarioNodes(), reactions: reactions)
        configure(world)
        let audit = S1RecordingAudit()
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: audit, sleep: world.sleepClosure)
        let snapshot = world.peek()
        let server = S1Servers.make(from: snapshot, root: root, groupKillEligible: groupKillEligible, extraMembers: extraMembers(snapshot))
        return Rig(world: world, audit: audit, terminator: terminator, server: server)
    }

    // MARK: Helpers

    private func totalSleep(in events: ArraySlice<S1World.Event>) -> Int {
        var total = 0
        for event in events {
            if case .sleep(let milliseconds) = event { total += milliseconds }
        }
        return total
    }

    private func groupEvents(_ world: S1World) -> [S1World.Event] {
        world.signalEvents.filter {
            if case .group = $0 { return true }
            return false
        }
    }

    private func sleepEvents(_ world: S1World) -> [S1World.Event] {
        world.events.filter {
            if case .sleep = $0 { return true }
            return false
        }
    }

    private func expectOnlyTheTreeWasSignalled(_ world: S1World) {
        #expect(Set(world.signalledPIDs).isSubset(of: Set(Self.tree)))
        for event in world.signalEvents {
            if case .group(_, let pgid) = event { #expect(pgid > 1 && pgid == 77527) }       // K7
        }
        // The shared ancestor, the shells and DevTidy never appear (K1, K2).
        for protected: Int32 in [74501, 64795, 64472, 64471, 4999, 4998, 3184, 3178, S1Fixtures.selfPID] {
            #expect(!world.signalledPIDs.contains(protected))
        }
    }

    // MARK: Happy paths

    @Test func happyPathSendsOnlySigtermToTheWholeGroup() async throws {
        let rig = makeRig(groupKillEligible: true)
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(rig.world.signalEvents == [.group(SIGTERM, pgid: 77527)])                  // K5: one group SIGTERM, nothing else
        #expect(report.usedGroupSignal)
        #expect(report.terminated == Self.tree)
        #expect(report.forced.isEmpty && report.survivors.isEmpty && report.skipped.isEmpty)
        #expect(!report.wasAlreadyGone)
        #expect(report.root == rig.server.root.identity)
        #expect(rig.world.snapshotCalls == 1)
        #expect(sleepEvents(rig.world).isEmpty)                                            // everything died at once: no waiting
        expectOnlyTheTreeWasSignalled(rig.world)
    }

    @Test func individualPathSignalsRootFirstInTreeOrder() async throws {
        let rig = makeRig(groupKillEligible: false)
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(rig.world.signalEvents == [.signal(SIGTERM, pid: 77527), .signal(SIGTERM, pid: 77557), .signal(SIGTERM, pid: 77578)])
        #expect(!report.usedGroupSignal)
        #expect(report.terminated == Self.tree)
        #expect(report.survivors.isEmpty)
        expectOnlyTheTreeWasSignalled(rig.world)
    }

    @Test func anAlreadyGoneRootIsIdempotentAndSignalsNothing() async throws {
        let rig = makeRig(groupKillEligible: true)
        _ = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)
        let signalsAfterFirst = rig.world.signalEvents.count

        let second = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)
        #expect(second.wasAlreadyGone)
        #expect(second.terminated.isEmpty && second.forced.isEmpty && second.survivors.isEmpty)
        #expect(rig.world.signalEvents.count == signalsAfterFirst)
        #expect(rig.audit.events.map(\.result) == ["ok", "gone"])
    }

    // MARK: K3 — PID reuse

    @Test func aReusedRootPidIsTreatedAsGoneAndNothingIsSignalled() async throws {
        let rig = makeRig(groupKillEligible: true)
        rig.world.reusePID(77527, startSeconds: 42)         // same pid, different start time, after the server was recorded
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(report.wasAlreadyGone)
        #expect(rig.world.signalEvents.isEmpty)
        #expect(rig.world.isAlive(77527) && rig.world.isAlive(77557) && rig.world.isAlive(77578))
    }

    @Test(arguments: [false, true])
    func aMemberWhosePidIsReusedBetweenScanAndSignalIsSkipped(groupKillEligible: Bool) async throws {
        let rig = makeRig(groupKillEligible: groupKillEligible, configure: { $0.overrideIdentity(of: 77557, startSeconds: 42) })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(!rig.world.signalledPIDs.contains(77557))                                 // K3: no signal at all
        #expect(groupEvents(rig.world).isEmpty)                                           // the group path is off
        #expect(report.skipped.contains(SignalSkip(pid: 77557, reason: "identity-changed")))
        #expect(report.terminated == [77527, 77578])
        #expect(report.survivors.isEmpty)
        #expect(rig.world.isAlive(77557))
    }

    // MARK: K5 / K11 — group path gating

    @Test func aForeignProcessInTheGroupAtSignalTimeForcesIndividualSignals() async throws {
        let rig = makeRig(groupKillEligible: true, configure: { world in
            let stranger = S1SnapshotBuilder.node(99_999, ppid: 1, pgid: 77527, name: "stranger", uid: Self.foreignUID)
            world.add(stranger, reaction: .immortal)
        })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(groupEvents(rig.world).isEmpty)                                           // no -pgid recorded
        #expect(rig.world.signalledPIDs == Self.tree)
        #expect(!rig.world.signalledPIDs.contains(99_999))
        #expect(rig.world.isAlive(99_999))
        #expect(!report.usedGroupSignal)
        #expect(report.terminated == Self.tree)
    }

    @Test func anOwnUidNonMemberInTheGroupAlsoForcesIndividualSignals() async throws {
        // e.g. a respawned process the terminator has not seen yet: K5 requires EVERY group pid to be a verified member.
        let rig = makeRig(groupKillEligible: true, configure: { world in
            world.add(S1SnapshotBuilder.node(88_888, ppid: 74501, pgid: 77527, name: "node"), reaction: .immortal)
        })
        _ = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)
        #expect(groupEvents(rig.world).isEmpty)
        #expect(!rig.world.signalledPIDs.contains(88_888))
        #expect(rig.world.isAlive(88_888))
    }

    @Test func theGroupPathIsForbiddenWhenTheRootsGroupIsDevTidysOwnGroup() async throws {
        let rig = makeRig(groupKillEligible: true, ownPGID: 77527)       // K11
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)
        #expect(groupEvents(rig.world).isEmpty)
        #expect(!report.usedGroupSignal)
        #expect(report.terminated == Self.tree)
    }

    @Test func aRootThatDoesNotLeadItsOwnGroupNeverUsesTheGroupPath() async throws {
        // pid 50 with pgid 1: the eligibility flag lies; the re-check (root.pgid == root.pid, pgid > 1) must catch it (K5, K7).
        let world = S1World(nodes: S1Fixtures.devTidyChain() + [S1SnapshotBuilder.node(50, ppid: 4999, pgid: 1, name: "node")])
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: S1RecordingAudit(), sleep: world.sleepClosure)
        let server = S1Servers.make(from: world.peek(), root: 50, groupKillEligible: true)
        _ = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)
        #expect(world.signalEvents == [.signal(SIGTERM, pid: 50)])
    }

    // MARK: K8 — grace before SIGKILL

    @Test func escalatesToSigkillOnlyAfterTheGracePeriodForTheProcessThatIgnoredSigterm() async throws {
        let rig = makeRig(groupKillEligible: false, reactions: [77578: .diesOnKill])
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(rig.world.signalEvents == [.signal(SIGTERM, pid: 77527), .signal(SIGTERM, pid: 77557), .signal(SIGTERM, pid: 77578),
                                           .signal(SIGKILL, pid: 77578)])
        #expect(report.terminated == [77527, 77557])
        #expect(report.forced == [77578])
        #expect(report.survivors.isEmpty)

        let events = rig.world.events
        let term = try #require(events.firstIndex(of: .signal(SIGTERM, pid: 77578)))
        let kill = try #require(events.firstIndex(of: .signal(SIGKILL, pid: 77578)))
        #expect(totalSleep(in: events[term..<kill]) >= 1000)            // graceSeconds = 1
        expectOnlyTheTreeWasSignalled(rig.world)
    }

    @Test func groupEscalationUsesTheGroupAgainWhileItStaysVerifiable() async throws {
        let rig = makeRig(groupKillEligible: true, reactions: [77578: .diesOnKill])
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(rig.world.signalEvents == [.group(SIGTERM, pgid: 77527), .group(SIGKILL, pgid: 77527)])
        #expect(report.usedGroupSignal)
        #expect(report.terminated == [77527, 77557])
        #expect(report.forced == [77578])
        let events = rig.world.events
        let term = try #require(events.firstIndex(of: .group(SIGTERM, pgid: 77527)))
        let kill = try #require(events.firstIndex(of: .group(SIGKILL, pgid: 77527)))
        #expect(totalSleep(in: events[term..<kill]) >= 1000)
    }

    @Test func aProcessThatSurvivesSigkillIsReportedAsSurvivor() async throws {
        let rig = makeRig(groupKillEligible: false, reactions: [77578: .immortal])
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(report.survivors == [77578])
        #expect(report.terminated == [77527, 77557])
        #expect(report.forced.isEmpty)                                    // SIGKILL was sent but it did not exit
        #expect(rig.world.signalEvents.filter { $0 == .signal(SIGKILL, pid: 77578) }.count == 1)
        #expect(rig.audit.events.first?.result == "survivors")
    }

    // MARK: K6 / K10

    @Test func aMemberOwnedByAnotherUidIsNeverSignalled() async throws {
        let rig = makeRig(groupKillEligible: false, configure: { $0.overrideUID(of: 77557, to: Self.foreignUID) })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(!rig.world.signalledPIDs.contains(77557))
        #expect(report.skipped.contains(SignalSkip(pid: 77557, reason: "not-owned")))
        #expect(report.survivors == [77557])
        #expect(report.terminated == [77527, 77578])
    }

    @Test func epermIsReportedAndNeverRetriedOrEscalated() async throws {
        let rig = makeRig(groupKillEligible: false, configure: { $0.denyPermission(for: 77557) })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(report.skipped.contains(SignalSkip(pid: 77557, reason: "eperm")))
        #expect(rig.world.signalledPIDs.filter { $0 == 77557 }.count == 1)       // one attempt, no retry, no SIGKILL
        #expect(!rig.world.signalEvents.contains(.signal(SIGKILL, pid: 77557)))
        #expect(report.survivors == [77557])
        #expect(report.terminated == [77527, 77578])
    }

    // MARK: K1 / K2 — protected processes

    @Test func devTidyItsAncestorsAndReservedPidsAreRefusedBeforeAnySignal() async throws {
        let world = S1World(nodes: S1Fixtures.nextScenarioNodes() + [S1SnapshotBuilder.node(1, ppid: 0, name: "launchd")])
        let audit = S1RecordingAudit()
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: audit, sleep: world.sleepClosure)
        let snapshot = world.peek()

        let cases: [(Int32, String)] = [(1, "root-pid-reserved"), (S1Fixtures.selfPID, "root-is-self"),
                                        (4999, "root-is-self-ancestor"), (4998, "root-is-self-ancestor"),
                                        (3184, "root-is-self-ancestor"), (3178, "root-is-self-ancestor")]
        for (root, tag) in cases {
            let server = S1Servers.make(from: snapshot, root: root, groupKillEligible: true)
            do {
                _ = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)
                Issue.record("terminating pid \(root) must be refused")
            } catch {
                #expect(error as? ProcessTerminationError == ProcessTerminationError.refused(tag), "pid \(root)")
            }
        }
        #expect(world.signalEvents.isEmpty)
        #expect(audit.events.count == cases.count)
        #expect(audit.events.allSatisfy { $0.result.hasPrefix("refused:") })
    }

    @Test func aProtectedProcessListedAsAnOriginalMemberIsSkippedAndNeverSignalled() async throws {
        let rig = makeRig(groupKillEligible: false, extraMembers: { snapshot in
            [snapshot.nodes[4999]!, snapshot.nodes[S1Fixtures.selfPID]!]
        })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(report.skipped.contains(SignalSkip(pid: 4999, reason: "protected")))
        #expect(report.skipped.contains(SignalSkip(pid: S1Fixtures.selfPID, reason: "protected")))
        #expect(!rig.world.signalledPIDs.contains(4999))
        #expect(!rig.world.signalledPIDs.contains(S1Fixtures.selfPID))
        #expect(rig.world.isAlive(4999) && rig.world.isAlive(S1Fixtures.selfPID))
        expectOnlyTheTreeWasSignalled(rig.world)
    }

    @Test func theClassifiersServerNeverContainsTheBrokerSoItIsNeverSignalled() async throws {
        let snapshot = S1Fixtures.everything()
        let scan = await ServerClassifier(projects: S1Fixtures.projectDetector(), homeDirectory: S1Fixtures.home).classify(snapshot)
        let server = try #require(scan.servers.first { $0.root.pid == 77527 })
        let world = S1World(nodes: Array(snapshot.nodes.values))
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: S1RecordingAudit(), sleep: world.sleepClosure)
        _ = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)

        #expect(world.signalEvents == [.group(SIGTERM, pgid: 77527)])
        for pid: Int32 in [74501, 64795, 77380, 77531, 77534, 77539, 9402, 9422, 9425] { #expect(world.isAlive(pid)) }
        #expect(!world.isAlive(77527) && !world.isAlive(77557) && !world.isAlive(77578))
    }

    // MARK: K4 — respawn

    @Test func respawnedChildrenAreAddedOnlyWhileTheirParentIsALivingMember() async throws {
        let rig = makeRig(groupKillEligible: false, reactions: [77557: .diesOnKill], configure: { world in
            // Call 1 is the initial scan; call 2 is the first re-scan (~1 s later = 10 polls of 100 ms).
            world.spawn(S1SnapshotBuilder.node(80_000, ppid: 77557, pgid: 77527, name: "node"), atSnapshotCall: 2)   // child of a LIVING member
            world.spawn(S1SnapshotBuilder.node(80_001, ppid: 74501, name: "stranger"), atSnapshotCall: 2)            // child of the shared broker
            world.spawn(S1SnapshotBuilder.node(80_002, ppid: 77578, pgid: 77527, name: "node"), atSnapshotCall: 2)   // child of a member that already died
        })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(rig.world.signalEvents == [.signal(SIGTERM, pid: 77527), .signal(SIGTERM, pid: 77557), .signal(SIGTERM, pid: 77578),
                                           .signal(SIGTERM, pid: 80_000), .signal(SIGKILL, pid: 77557)])
        #expect(!rig.world.signalledPIDs.contains(80_001))
        #expect(!rig.world.signalledPIDs.contains(80_002))
        #expect(rig.world.isAlive(80_001) && rig.world.isAlive(80_002))
        #expect(report.terminated == [77527, 77578, 80_000])
        #expect(report.forced == [77557])
        #expect(report.survivors.isEmpty)
    }

    @Test func aRespawnedChildGetsItsOwnFullGraceBeforeSigkill() async throws {
        // 77527 and 77557 ignore SIGTERM; 80000 (spawned by living 77557 at the re-scan) does too.
        let rig = makeRig(groupKillEligible: false, reactions: [77527: .diesOnKill, 77557: .diesOnKill], configure: { world in
            world.spawn(S1SnapshotBuilder.node(80_000, ppid: 77557, pgid: 77527, name: "node"), atSnapshotCall: 2, reaction: .diesOnKill)
        })
        _ = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        let events = rig.world.events
        let spawnedTerm = try #require(events.firstIndex(of: .signal(SIGTERM, pid: 80_000)))
        let spawnedKill = try #require(events.firstIndex(of: .signal(SIGKILL, pid: 80_000)))
        #expect(totalSleep(in: events[spawnedTerm..<spawnedKill]) >= 1000)     // K8 is per process
    }

    // MARK: Audit

    @Test func oneTerminateAuditEventIsWrittenWithPidsAndSignalsButNoCommandLine() async throws {
        let rig = makeRig(groupKillEligible: true)
        _ = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        let event = try #require(rig.audit.events.first)
        #expect(rig.audit.events.count == 1)
        #expect(event.kind == .terminate)
        #expect(event.result == "ok")
        #expect(event.subject == "77527:\(1_760_000_000 + 77_527)")
        #expect(event.detail["path"] == "group")
        #expect(event.detail["signals"] == "TERM:-77527")
        #expect(event.detail["pids"] == "77527,77557,77578")
        #expect(event.detail["terminated"] == "77527,77557,77578")
        #expect(event.detail["survivors"] == "")
        #expect(!event.detail.values.contains { $0.contains("next dev") })
    }

    // MARK: F-3 — never-root defence in depth

    @Test(arguments: [
        ("node", S1Fixtures.nodeExe, [S1Fixtures.nodeExe, "/lib/node_modules/@openai/codex/bin/codex.js"], "root-is-shell-terminal-ide-agent"),
        ("node", S1Fixtures.nodeExe, [S1Fixtures.nodeExe, "/opt/homebrew/bin/gemini"], "root-is-shell-terminal-ide-agent"),
        ("idea", "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea", ["idea"], "root-is-shell-terminal-ide-agent"),
        ("nvim", "/opt/homebrew/bin/nvim", ["nvim"], "root-is-shell-terminal-ide-agent"),
        ("tmux", "/opt/homebrew/bin/tmux", ["tmux"], "root-is-shell-terminal-ide-agent"),
        ("zsh", "/bin/zsh", ["-zsh"], "root-is-shell-terminal-ide-agent"),
        ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["Google Chrome"], "root-is-browser-or-app-bundle"),
        ("Electron", "/p/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron", ["Electron", "."], "root-is-browser-or-app-bundle"),
    ] as [(String, String, [String], String)])
    func aRootThatIsAShellTerminalIDEAgentOrBrowserIsRefusedBeforeAnySignal(name: String, exe: String, args: [String],
                                                                            tag: String) async throws {
        // The resolver would never pick these; a forged or stale `DevServer` must not be able to make DevTidy signal them anyway.
        let target = S1SnapshotBuilder.node(600, ppid: 74501, pgid: 600, name: name, exe: exe, args: args)
        let child = S1SnapshotBuilder.node(610, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                                           args: [S1Fixtures.nodeExe, "server.js"])
        let world = S1World(nodes: S1Fixtures.nextScenarioNodes() + [target, child])
        let audit = S1RecordingAudit()
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: audit, sleep: world.sleepClosure)
        let server = S1Servers.make(from: world.peek(), root: 600, groupKillEligible: true)

        do {
            _ = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)
            Issue.record("\(name) must be refused as a kill root")
        } catch {
            #expect(error as? ProcessTerminationError == ProcessTerminationError.refused(tag), "\(name)")
        }
        #expect(world.signalEvents.isEmpty)
        #expect(audit.events.map(\.result) == ["refused:\(tag)"])
        #expect(world.isAlive(600) && world.isAlive(610))
    }

    @Test func aShellWithDashCIsStillAnAcceptableRoot() async throws {
        let shell = S1SnapshotBuilder.node(600, ppid: 74501, pgid: 600, name: "sh", exe: "/bin/sh", args: ["sh", "-c", "vite"])
        let child = S1SnapshotBuilder.node(610, ppid: 600, pgid: 600, name: "node", exe: S1Fixtures.nodeExe,
                                           args: [S1Fixtures.nodeExe, "server.js"])
        let world = S1World(nodes: S1Fixtures.nextScenarioNodes() + [shell, child])
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: S1RecordingAudit(), sleep: world.sleepClosure)
        let server = S1Servers.make(from: world.peek(), root: 600, groupKillEligible: true)
        let report = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)
        #expect(world.signalEvents == [.group(SIGTERM, pgid: 600)])
        #expect(report.terminated == [600, 610])
    }

    // MARK: R3-P3-1 — a project binary named like an editor is the server being stopped, not an editor session

    private func terminate(rootNamed name: String, exe: String, args: [String], listening: Bool) async throws
        -> (report: TerminationReport, world: S1World, audit: S1RecordingAudit) {
        let target = S1SnapshotBuilder.node(600, ppid: 74501, pgid: 600, name: name, exe: exe, args: args)
        let child = S1SnapshotBuilder.node(610, ppid: 600, pgid: 600, name: "worker", exe: "/p/target/debug/worker", args: ["worker"])
        let world = S1World(nodes: S1Fixtures.nextScenarioNodes() + [target, child])
        let audit = S1RecordingAudit()
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: audit, sleep: world.sleepClosure)
        var server = S1Servers.make(from: world.peek(), root: 600, groupKillEligible: true)
        if listening {
            server.listeners = [ServerListener(pid: 600, name: name, project: nil, ports: [S1SnapshotBuilder.port(8080, owner: 600)])]
        }
        let report = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)
        return (report, world, audit)
    }

    @Test(arguments: ["fleet", "hx", "nova", "studio"])
    func aListeningProjectBinaryNamedLikeAnEditorIsStoppedAsTheRoot(name: String) async throws {
        let run = try await terminate(rootNamed: name, exe: "/p/target/debug/\(name)", args: ["/p/target/debug/\(name)"], listening: true)
        #expect(run.world.signalEvents == [.group(SIGTERM, pgid: 600)])
        #expect(run.report.terminated == [600, 610])
        #expect(run.audit.events.map(\.result) == ["ok"])
    }

    @Test(arguments: [
        ("fleet", "/p/target/debug/fleet", ["fleet"], false, "root-is-shell-terminal-ide-agent"),    // same name, does not listen
        ("hx", "/opt/homebrew/bin/hx", ["hx"], false, "root-is-shell-terminal-ide-agent"),
        ("claude", "/u/.local/bin/claude", ["claude"], true, "root-is-shell-terminal-ide-agent"),    // an agent never serves
        ("tmux", "/opt/homebrew/bin/tmux", ["tmux"], true, "root-is-shell-terminal-ide-agent"),      // nor does a terminal
        ("zsh", "/bin/zsh", ["-zsh"], true, "root-is-shell-terminal-ide-agent"),                      // nor does an interactive shell
        ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["Google Chrome"], true,
         "root-is-browser-or-app-bundle"),
    ] as [(String, String, [String], Bool, String)])
    func theNameExemptionIsOnlyForARootThatListensAndOnlyForEditorNames(
        name: String, exe: String, args: [String], listening: Bool, tag: String) async throws {
        do {
            _ = try await terminate(rootNamed: name, exe: exe, args: args, listening: listening)
            Issue.record("\(name) must still be refused as a kill root")
        } catch {
            #expect(error as? ProcessTerminationError == ProcessTerminationError.refused(tag), "\(name)")
        }
    }

    // MARK: F-8 — ancestry behind a foreign-uid process

    @Test func ancestorsBehindARootOwnedLoginProcessStayProtected() async throws {
        // iTerm2 → iTermServer → login (uid 0, invisible to the own-uid snapshot) → zsh → DevTidy: the snapshot's ancestor walk
        // stops at `login`, so only the live parent chain protects iTermServer / iTerm2.
        let nodes = S1Fixtures.nextScenarioNodes().map { node -> ProcessNode in
            guard node.pid == 4998 else { return node }
            return S1SnapshotBuilder.node(4998, ppid: 3184, name: "login", exe: "/usr/bin/login", args: ["login", "-fp", "me"],
                                          tty: true, uid: Self.foreignUID)
        }
        let world = S1World(nodes: nodes)
        let audit = S1RecordingAudit()
        let terminator = TreeTerminator(scanner: world, signaler: world, audit: audit, sleep: world.sleepClosure)
        let snapshot = world.peek()
        #expect(snapshot.nodes[4998] == nil)                                   // the premise: login is not in the snapshot

        for root: Int32 in [3184, 3178] {
            let server = S1Servers.make(from: snapshot, root: root, groupKillEligible: false)
            do {
                _ = try await terminator.terminate(server, policy: S1Fixtures.fastPolicy)
                Issue.record("pid \(root) is an ancestor of DevTidy and must be refused")
            } catch {
                #expect(error as? ProcessTerminationError == ProcessTerminationError.refused("root-is-self-ancestor"), "pid \(root)")
            }
        }
        #expect(world.signalEvents.isEmpty)
    }

    // MARK: F-9 — unreadable live processes

    @Test func anUnreadableLiveForeignGroupMemberForcesIndividualSignalsInsteadOfBeingTreatedAsExited() async throws {
        let rig = makeRig(groupKillEligible: true, configure: { world in
            world.add(S1SnapshotBuilder.node(99_998, ppid: 1, pgid: 77527, name: "stranger", uid: Self.foreignUID), reaction: .immortal)
            world.makeUnreadable(99_998)       // alive, but proc_pidinfo cannot read it
        })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(groupEvents(rig.world).isEmpty)                  // kill(-77527) would have hit it
        #expect(rig.world.isAlive(99_998))
        #expect(!rig.world.signalledPIDs.contains(99_998))
        #expect(rig.world.signalledPIDs == Self.tree)
        #expect(report.terminated == Self.tree)
        #expect(!report.usedGroupSignal)
    }

    @Test func anUnreadableLiveMemberIsNeitherSignalledNorReportedAsExited() async throws {
        let rig = makeRig(groupKillEligible: true, configure: { $0.makeUnreadable(77557) })
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(groupEvents(rig.world).isEmpty)
        #expect(!rig.world.signalledPIDs.contains(77557))                           // identity cannot be verified (K3)
        #expect(report.skipped.contains(SignalSkip(pid: 77557, reason: "unverifiable")))
        #expect(report.survivors == [77557])                                        // alive, so not "terminated"
        #expect(report.terminated == [77527, 77578])
        #expect(rig.world.isAlive(77557))
    }

    // MARK: QA F6 — browsers and app bundles are never signalled

    @Test func aBrowserBelowAMemberIsNeverSignalledEvenWhenTheServerStillListsIt() async throws {
        let chromeExe = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let rig = makeRig(groupKillEligible: true, configure: { world in
            world.add(S1SnapshotBuilder.node(80_100, ppid: 77557, pgid: 77527, name: "Google Chrome", exe: chromeExe, args: [chromeExe]),
                      reaction: .immortal)
            world.add(S1SnapshotBuilder.node(80_101, ppid: 80_100, pgid: 77527, name: "Google Chrome He"), reaction: .immortal)
        })
        #expect(rig.server.members.map(\.pid).contains(80_100))        // a stale / forged server that still lists the browser
        let report = try await rig.terminator.terminate(rig.server, policy: S1Fixtures.fastPolicy)

        #expect(report.skipped.contains(SignalSkip(pid: 80_100, reason: "app-bundle")))
        #expect(!rig.world.signalledPIDs.contains(80_100) && !rig.world.signalledPIDs.contains(80_101))
        #expect(groupEvents(rig.world).isEmpty)                         // kill(-pgid) would have reached Chrome
        #expect(rig.world.isAlive(80_100) && rig.world.isAlive(80_101))
        #expect(rig.world.signalledPIDs == Self.tree)
        #expect(report.terminated == Self.tree)
    }

    // MARK: Virtual time

    @Test func anEscalationRunsOnTheInjectedSleepOnly() async throws {
        let rig = makeRig(groupKillEligible: false, reactions: [77578: .immortal])
        var policy = TerminationPolicy()
        policy.graceSeconds = 30
        policy.killWaitSeconds = 10
        policy.pollMilliseconds = 100
        let report = try await rig.terminator.terminate(rig.server, policy: policy)

        #expect(report.survivors == [77578])
        #expect(totalSleep(in: rig.world.events[...]) >= 30_000)            // the whole grace elapsed in recorded virtual time
    }
}
