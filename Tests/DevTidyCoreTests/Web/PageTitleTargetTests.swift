import Foundation
import Testing
@testable import DevTidyCore

/// Which loopback addresses a title request may go to. Pure: a `DevServer` and the scan's listener table in, addresses out. The
/// rule: only sockets of the server itself, and none that another process's more specific socket on the same port would answer.
@Suite("PageTitleTarget (which addresses are asked)")
struct PageTitleTargetTests {
    private let port: UInt16 = 5173
    private let root = S4.home + "/developer/redalert/packages/client"
    private var project: Project { S4.project(root) }

    private let v4 = BindAddress.ipv4(127, 0, 0, 1)
    private let v6 = BindAddress.ipv6Loopback
    private let wildcard4 = BindAddress.ipv4Wildcard
    private let wildcard6 = BindAddress.ipv6Wildcard(dualStack: false)
    private let dualStack = BindAddress.ipv6Wildcard(dualStack: true)

    private func server(_ binds: Set<BindAddress>, pid: Int32 = 39_467, port: UInt16? = nil,
                        extraMembers: [ProcessNode] = []) -> DevServer {
        S4.server(pid: pid, project: project, port: port ?? self.port, extraMembers: extraMembers, binds: binds)
    }

    /// The socket of another process (Docker's `com.docker.backend`, another server, anything) on `port`.
    private func rival(_ pid: Int32, _ binds: Set<BindAddress>, port: UInt16? = nil) -> ListeningPort {
        S4.port(port ?? self.port, owner: pid, binds: binds)
    }

    private func selection(_ server: DevServer, rivals: [ListeningPort] = []) -> PageTitleTarget.Selection {
        PageTitleTarget.select(for: server, in: S4.scan([server], rivals: rivals))
    }

    /// The addresses that would be asked; nil when the server is not asked at all.
    private func addresses(_ server: DevServer, rivals: [ListeningPort] = []) -> [LoopbackAddress]? {
        guard case .ask(let target) = selection(server, rivals: rivals) else { return nil }
        return target.addresses
    }

    private let loopback4 = LoopbackAddress.ipv4(127, 0, 0, 1)

    // MARK: A server's own sockets decide the addresses

    @Test func theRedAlertCaseAsksOnlyIPv6WhileDockerHoldsTheSamePortOnIPv4() {
        // node 39467 listens on [::1]:5173 only; com.docker.backend 19200 publishes the container on 127.0.0.1:5173.
        let node = server([v6])
        let docker = rival(19_200, [v4])
        #expect(addresses(node, rivals: [docker]) == [.ipv6])
        #expect(PageTitleTarget.make(for: node, in: S4.scan([node], rivals: [docker]))?.addresses == [.ipv6])
    }

    @Test func anIPv6OnlyServerBesideAnotherProcessOnIPv4IsAskedOnIPv6Only() {
        #expect(addresses(server([v6]), rivals: [rival(100, [v4])]) == [.ipv6])
        #expect(addresses(server([v6]), rivals: [rival(100, [wildcard4])]) == [.ipv6])
    }

    @Test func anIPv4OnlyServerIsAskedOnIPv4Only() {
        #expect(addresses(server([v4])) == [loopback4])
        #expect(addresses(server([v4]), rivals: [rival(100, [v6])]) == [loopback4])
    }

    @Test func aServerOwningBothLoopbackSocketsIsAskedOnBothIPv4First() {
        #expect(addresses(server([v6, v4])) == [loopback4, .ipv6])
    }

    @Test func aSpecificLoopbackBindIsAskedAtExactlyThatAddress() {
        #expect(addresses(server([.ipv4(127, 0, 0, 2)])) == [.ipv4(127, 0, 0, 2)])
        #expect(addresses(server([.ipv4(127, 0, 0, 2), v6])) == [.ipv4(127, 0, 0, 2), .ipv6])
    }

    @Test func anIPv4WildcardIsAskedAt127001() {
        #expect(addresses(server([wildcard4])) == [loopback4])
    }

    @Test func anIPv6WildcardIsAskedAtTheIPv6LoopbackAndAtIPv4OnlyWhenDualStack() {
        #expect(addresses(server([wildcard6])) == [.ipv6])
        #expect(addresses(server([dualStack])) == [loopback4, .ipv6])
    }

    @Test func aBindToOneNonLoopbackAddressIsNeverAsked() {
        #expect(selection(server([.ipv4(192, 168, 1, 20)])) == .notApplicable)
        #expect(selection(server([.ipv6(high: 0xFE80_0000_0000_0000, low: 2, dualStack: false)])) == .notApplicable)
        #expect(selection(server([])) == .notApplicable)                                  // libproc gave no decodable address
        // a loopback socket next to a LAN one is still asked on the loopback one
        #expect(addresses(server([.ipv4(192, 168, 1, 20), v4])) == [loopback4])
    }

    // MARK: Another process's more specific socket captures the connection

    @Test func aWildcardServerLosesTheAddressAnotherProcessBindsMoreSpecifically() {
        // node on `::` (dual-stack) and Docker on 127.0.0.1: IPv4 would be Docker's, IPv6 is the server's.
        #expect(addresses(server([dualStack]), rivals: [rival(19_200, [v4])]) == [.ipv6])
        // the same for a server on the IPv4 wildcard: its only address is Docker's
        #expect(selection(server([wildcard4]), rivals: [rival(19_200, [v4])]) == .shared)
        // a server on the IPv6 wildcard (not dual-stack) is not reachable on IPv4 anyway
        #expect(addresses(server([wildcard6]), rivals: [rival(19_200, [v4])]) == [.ipv6])
        // and IPv6 is taken when the other process binds ::1
        #expect(addresses(server([dualStack]), rivals: [rival(19_200, [v6])]) == [loopback4])
        #expect(selection(server([wildcard6]), rivals: [rival(19_200, [v6])]) == .shared)
    }

    @Test func aDualStackServerLosesIPv4ToAnIPv4WildcardOfAnotherProcess() {
        #expect(addresses(server([dualStack]), rivals: [rival(100, [wildcard4])]) == [.ipv6])
    }

    @Test func aServerWithSpecificBindsKeepsThemAgainstAnotherProcessWildcard() {
        #expect(addresses(server([v4]), rivals: [rival(100, [wildcard4])]) == [loopback4])
        #expect(addresses(server([v4, v6]), rivals: [rival(100, [dualStack])]) == [loopback4, .ipv6])
        #expect(addresses(server([v6]), rivals: [rival(100, [wildcard6])]) == [.ipv6])
    }

    @Test func anEquallySpecificSocketOfAnotherProcessIsNotTrusted() {
        // Two sockets on the very same address (SO_REUSEPORT): the kernel picks either, so neither answer is known to be ours.
        #expect(selection(server([v4]), rivals: [rival(100, [v4])]) == .shared)
        #expect(selection(server([wildcard4]), rivals: [rival(100, [wildcard4])]) == .shared)
        #expect(addresses(server([v4, v6]), rivals: [rival(100, [v6])]) == [loopback4])
    }

    @Test func everyAddressTakenByAnotherProcessMeansNoTarget() {
        let node = server([v4, v6])
        let rivals = [rival(100, [v4]), rival(101, [v6])]
        #expect(selection(node, rivals: rivals) == .shared)
        #expect(PageTitleTarget.make(for: node, in: S4.scan([node], rivals: rivals)) == nil)
    }

    @Test func socketsOnOtherPortsAndTheServersOwnProcessesAreNotRivals() {
        // another process on another port
        #expect(addresses(server([wildcard4]), rivals: [rival(100, [v4], port: 5174)]) == [loopback4])
        // a child of the server (a member) holding the same listening socket is the server itself
        let child = S4.node(39_468, ppid: 39_467, name: "node")
        let shared = rival(39_468, [v4])
        #expect(addresses(server([wildcard4], extraMembers: [child]), rivals: [shared]) == [loopback4])
        // the same pid and port as the server's own never counts against it either
        #expect(addresses(server([wildcard4]), rivals: [rival(39_467, [v4])]) == [loopback4])
    }

    @Test func anotherDevServerOnTheSamePortIsAnotherProcessToo() {
        let first = server([dualStack], pid: 10)
        let second = server([v4], pid: 11)
        let scan = S4.scan([first, second])
        #expect(PageTitleTarget.make(for: first, in: scan)?.addresses == [.ipv6])
        #expect(PageTitleTarget.make(for: second, in: scan)?.addresses == [loopback4])
    }

    // MARK: Not asked at all

    @Test(arguments: [UInt16(9229), 9230, 9231])
    func aTargetOnAnInspectorPortIsNeverBuilt(inspector: UInt16) {
        #expect(selection(server([v4], port: inspector)) == .notApplicable)
    }

    // MARK: Identity

    @Test func theAddressesArePartOfTheTargetIdentity() throws {
        let node = server([v6, v4])
        let both = try #require(PageTitleTarget.make(for: node, in: S4.scan([node])))
        let dockerOnV4 = S4.scan([node], rivals: [rival(19_200, [v4])])
        let narrowed = try #require(PageTitleTarget.make(for: node, in: dockerOnV4))
        // a title read before the other process appeared is not reused for what is asked now
        #expect(both != narrowed)
        #expect(both.server == narrowed.server && both.port == narrowed.port)
        #expect(both == PageTitleTarget.make(for: node, in: S4.scan([node])))
        #expect(Set([both, narrowed]).count == 2)
    }

    @Test func aRestartedServerIsAnotherTargetEvenOnTheSameAddresses() throws {
        let before = server([v6], pid: 39_467)
        let after = S4.server(pid: 39_467, project: project, port: port, started: S4.t0.addingTimeInterval(-5), binds: [v6])
        let first = try #require(PageTitleTarget.make(for: before, in: S4.scan([before])))
        let second = try #require(PageTitleTarget.make(for: after, in: S4.scan([after])))
        #expect(first.addresses == second.addresses)
        #expect(first != second)
    }
}
