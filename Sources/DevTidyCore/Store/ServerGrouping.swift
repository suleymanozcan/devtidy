import Foundation

/// One section of the Servers tab: the servers of ONE project root.
public struct ServerGroup: Identifiable, Sendable {
    /// `repo › packages/client`, or the folder name when there is no repo (`ProjectIdentity.headerTitle`).
    public let title: String
    /// Nil only for the project-less bucket, and for a project whose identity has not been resolved yet.
    public let identity: ProjectIdentity?
    /// Canonical project root; nil for the project-less bucket.
    public let projectRoot: String?
    /// Scanner order within the section.
    public let servers: [DevServer]
    /// The bucket of servers no project was found for; always the last section.
    public let isProjectless: Bool
    public var id: String { projectRoot.map { "project:" + $0 } ?? "projectless" }
}

public enum ServerGrouping {
    public static let projectlessTitle = "Proje bulunamadı"

    /// One section per project root (two checkouts that share a folder name are two sections, told apart by their repo and
    /// path), titled by the project's identity, sorted by title then path. Servers keep scanner order. Servers without a
    /// project form one trailing section: the classifier already sorts them last, and a title sort would put them among real
    /// projects.
    public static func groups(of servers: [DevServer], identities: [String: ProjectIdentity] = [:]) -> [ServerGroup] {
        var order: [String] = []
        var buckets: [String: [DevServer]] = [:]
        var projectNames: [String: String] = [:]
        var projectless: [DevServer] = []
        for server in servers {
            guard let project = server.project else {
                projectless.append(server)
                continue
            }
            if buckets[project.root] == nil {
                order.append(project.root)
                projectNames[project.root] = DisplayText.label(project.name)
            }
            buckets[project.root, default: []].append(server)
        }
        var groups = order.map { root -> ServerGroup in
            let identity = identities[root]
            return ServerGroup(title: identity?.headerTitle ?? projectNames[root] ?? DisplayText.literal(root, scalarLimit: 256),
                               identity: identity, projectRoot: root, servers: buckets[root] ?? [], isProjectless: false)
        }
        groups.sort { lhs, rhs in
            let byTitle = lhs.title.localizedStandardCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return (lhs.projectRoot ?? "") < (rhs.projectRoot ?? "")
        }
        if !projectless.isEmpty {
            groups.append(ServerGroup(title: projectlessTitle, identity: nil, projectRoot: nil, servers: projectless, isProjectless: true))
        }
        return groups
    }
}
