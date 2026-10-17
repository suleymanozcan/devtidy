import Foundation
import Testing
@testable import DevTidyCore

struct ServerGroupingTests {
    @Test func projectlessServersAreAlwaysTheLastSection() {
        // "Proje bulunamadı" would sort between "alpha" and "zeta" in a plain title sort.
        let alpha = S4.project(S4.home + "/developer/alpha")
        let zeta = S4.project(S4.home + "/developer/zeta")
        let servers = [S4.server(pid: 1, project: alpha),
                       S4.server(pid: 2, project: nil, port: 4000),
                       S4.server(pid: 3, project: zeta, port: 3001)]
        let groups = ServerGrouping.groups(of: servers)
        #expect(groups.map(\.title) == ["alpha", "zeta", ServerGrouping.projectlessTitle])
        #expect(groups.map(\.isProjectless) == [false, false, true])
        #expect(groups.last?.servers.map(\.root.pid) == [2])
    }

    @Test func eachProjectRootIsItsOwnSectionAndServersKeepScannerOrder() {
        // Two apps under one parent folder are two projects now: each has its own repo/path and its own branch.
        let storefront = S4.project(S4.home + "/developer/shop/storefront", group: "shop")
        let backoffice = S4.project(S4.home + "/developer/shop/backoffice", group: "shop")
        let solo = S4.project(S4.home + "/developer/aaa")
        let servers = [S4.server(pid: 1, project: storefront, port: 3001),
                       S4.server(pid: 2, project: backoffice, port: 3000),
                       S4.server(pid: 3, project: solo, port: 3002),
                       S4.server(pid: 4, project: storefront, port: 3003)]
        let groups = ServerGrouping.groups(of: servers)
        #expect(groups.map(\.title) == ["aaa", "backoffice", "storefront"])
        #expect(groups.last?.servers.map(\.root.pid) == [1, 4])             // scanner order inside the project
        #expect(groups.map(\.projectRoot) == [solo.root, backoffice.root, storefront.root])
    }

    @Test func twoCheckoutsWithTheSameFolderNameAreTwoSectionsToldApartByTheirIdentity() {
        // The "client" / "client" screenshot: same folder name, different projects.
        let a = S4.project(S4.home + "/developer/redalert/packages/client")
        let b = S4.project(S4.home + "/Projects/client")
        let servers = [S4.server(pid: 1, project: a, port: 5182), S4.server(pid: 2, project: b, port: 5184)]
        let identities = [
            a.root: S4.identity(a.root, repoRoot: S4.home + "/developer/redalert", pathInRepo: "packages/client", head: .branch("main")),
            b.root: S4.identity(b.root),
        ]
        let groups = ServerGrouping.groups(of: servers, identities: identities)
        #expect(groups.map(\.title) == ["client", "redalert › packages/client"])
        #expect(Set(groups.map(\.id)).count == 2)                          // distinct ids: no duplicate rows in a ForEach
        #expect(groups.last?.identity?.head == .branch("main"))
    }

    @Test func noServersMeansNoSections() {
        #expect(ServerGrouping.groups(of: []).isEmpty)
    }

    @Test func aWorktreeSectionIsHeadedByItsMainRepositoryAndItsOwnFolder() {
        let project = S4.project(S4.home + "/dev/feature-x")
        var identity = S4.identity(project.root, repoRoot: S4.home + "/dev/redalert", head: .branch("feature-x"))
        identity.worktreeName = "feature-x"
        let groups = ServerGrouping.groups(of: [S4.server(pid: 1, project: project)], identities: [project.root: identity])
        #expect(groups.map(\.title) == ["redalert (wt feature-x)"])
    }

    @Test func aSectionWithoutAnIdentityIsTitledWithTheCleanedProjectName() {
        let project = S4.project(S4.home + "/dev/x", name: "my\u{202E}app\u{200B}")
        #expect(ServerGrouping.groups(of: [S4.server(pid: 1, project: project)]).map(\.title) == ["myapp"])
    }

    @MainActor
    @Test func theStoreExposesTheSameSections() async {
        let rig = S4Rig()
        let project = S4.project(S4.home + "/developer/alpha")
        rig.classifier.state.with {
            $0.servers = [S4.server(pid: 1, project: nil, port: 4000), S4.server(pid: 2, project: project)]
        }
        await rig.store.refreshNow()
        #expect(rig.store.serverGroups.map(\.title) == ["alpha", ServerGrouping.projectlessTitle])
    }

    @MainActor
    @Test func theStoreTitlesSectionsWithTheResolvedIdentity() async {
        let rig = S4Rig()
        let project = S4.project(S4.home + "/developer/redalert/packages/client")
        rig.identities.table.with {
            $0[project.root] = S4.identity(project.root, repoRoot: S4.home + "/developer/redalert",
                                           pathInRepo: "packages/client", head: .detached("a1b2c3d"))
        }
        rig.classifier.state.with { $0.servers = [S4.server(pid: 1, project: project)] }
        await rig.store.refreshNow()
        let group = rig.store.serverGroups.first
        #expect(group?.title == "redalert › packages/client")
        #expect(group?.identity?.head == .detached("a1b2c3d"))
    }
}
