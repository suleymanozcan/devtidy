import Foundation
import Testing
@testable import DevTidyCore

/// QA F2: Node / workerd inspector ports (9229, then 9230, 9231 when taken) must not become clickable chips.
struct InspectorPortTests {
    private func shown(_ server: DevServer) -> [UInt16] { server.displayPorts.map(\.port) }

    @Test func theWholeInspectorRangeAndEphemeralPortsAreHidden() {
        let server = S4.server(pid: 10, project: nil, port: 5190, extraPorts: [9229, 9230, 9231, 9232, 54_592])
        #expect(shown(server) == [5190, 9232])
        #expect(server.internalPortCount == 4)
    }

    @Test func portsDeclaredByInspectFlagsAreHidden() {
        let server = S4.server(
            pid: 10, project: nil, port: 3000, extraPorts: [9500, 9501, 9600, 9700, 9800, 9900],
            arguments: ["node", "--inspect-brk=0.0.0.0:9500", "--inspect=[::1]:9501", "--inspect-port=9600",
                        "--inspect-port", "9700", "--inspector-port=9800", "server.js"])
        #expect(server.declaredInspectorPorts == [9500, 9501, 9600, 9700, 9800])
        #expect(shown(server) == [3000, 9900])                              // 9900 is a regular port nobody declared as inspector
    }

    @Test func declaredPortsInAnyMemberOfTheTreeAreHidden() {
        let child = S4.node(11, ppid: 10, args: ["node", "--inspect-wait=9500"])
        let server = S4.server(pid: 10, project: nil, port: 3000, extraMembers: [child], extraPorts: [9500])
        #expect(shown(server) == [3000])
    }

    @Test func flagsWithoutAPortAndUnrelatedFlagsHideNothingExtra() {
        let server = S4.server(pid: 10, project: nil, port: 3000, extraPorts: [9500, 9501],
                               arguments: ["node", "--inspect", "--port=9500", "--inspect-foo=9501", "--inspect=notaport"])
        #expect(server.declaredInspectorPorts.isEmpty)
        #expect(shown(server) == [3000, 9500, 9501])
    }

    @Test func theMainPortIsNeverHidden() {
        let inRange = S4.server(pid: 10, project: nil, port: 9230)
        #expect(shown(inRange) == [9230])
        let declared = S4.server(pid: 11, project: nil, port: 3000, arguments: ["node", "--inspect=3000"])
        #expect(shown(declared) == [3000])
    }
}
