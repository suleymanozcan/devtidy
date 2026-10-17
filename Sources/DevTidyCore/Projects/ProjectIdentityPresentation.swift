import Foundation

/// What a Servers-tab row says about itself, decided in one place so it is testable: the title (page `<title>` > manifest name
/// > folder name), and the manifest label for the subtitle.
///
/// Everything here is display text and has been through `DisplayText`: the inputs were cleaned where they were read (page,
/// manifest, directory name), and the names that come from the process table or a directory are cleaned again on the way in,
/// so a row can never show an invisible character, a newline or a runaway combining sequence.
public struct ServerPresentation: Sendable, Equatable {
    public enum TitleSource: Sendable, Equatable { case pageTitle, manifestName, folderName, processName }

    static let maxTitleLength = 120

    public let title: String
    public let titleSource: TitleSource
    /// `name@version` of the manifest, only when its name is not already the title.
    public let manifestLabel: String?
    public let kind: ProjectKind

    public init(server: DevServer, identity: ProjectIdentity?, pageTitle: String?) {
        let manifest = identity?.manifest
        if let page = pageTitle.flatMap({ DisplayText.clean($0, limit: Self.maxTitleLength) }) {
            title = page
            titleSource = .pageTitle
        } else if let manifest {
            title = DisplayText.label(manifest.name, limit: Self.maxTitleLength)
            titleSource = .manifestName
        } else if let folder = identity?.folderName ?? server.project?.name {
            title = DisplayText.label(folder, limit: Self.maxTitleLength)
            titleSource = .folderName
        } else {
            title = DisplayText.label(server.root.name, limit: Self.maxTitleLength)
            titleSource = .processName
        }
        if let manifest, manifest.name.caseInsensitiveCompare(title) != .orderedSame {
            manifestLabel = DisplayText.label(manifest.label, limit: 2 * Self.maxTitleLength)
        } else {
            manifestLabel = nil
        }
        kind = server.kind
    }

    /// The row's second line: `qualifier · name@version · framework`, the pieces that exist. `qualifier` is
    /// `ServerRowQualifier`'s text for a row whose title another row shares.
    public func subtitle(framework: String?, qualifier: String? = nil) -> String? {
        let parts = [qualifier, manifestLabel, framework].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Rows that read the same --------------------------------------------------------------------

/// What `ServerRowQualifier` needs to know about one row.
public struct ServerRowInfo: Sendable, Equatable {
    public let id: ProcessIdentity
    public let title: String
    /// `repo › packages/client`, or the folder name without a repo; nil without a project.
    public let location: String?
    /// The git branch (or the abbreviated commit of a detached HEAD).
    public let branch: String?
    public let port: UInt16?

    public init(id: ProcessIdentity, title: String, location: String?, branch: String?, port: UInt16?) {
        self.id = id
        self.title = title
        self.location = location
        self.branch = branch
        self.port = port
    }

    public init(server: DevServer, presentation: ServerPresentation, identity: ProjectIdentity?) {
        self.init(id: server.id, title: presentation.title,
                  location: identity?.headerTitle ?? server.project.map { DisplayText.label($0.name) },
                  branch: identity?.head.map(\.label), port: server.mainPort)
    }
}

/// Two checkouts of one repository serve the same page and carry the same manifest name, so their rows read the same
/// (`Kızıl Alarm — Prototip` twice). A row whose title another row shares says what tells it apart: where it lives
/// (`repo › path`) when the locations differ, its branch when the branches differ, and always its port, which is unique.
public enum ServerRowQualifier {
    /// `repo-a › packages/client (perf-fx) · :5182` for every row that shares its title (case-insensitive) with another. Rows
    /// with a title of their own are not in the result.
    public static func qualifiers(for rows: [ServerRowInfo]) -> [ProcessIdentity: String] {
        var byTitle: [String: [ServerRowInfo]] = [:]
        for row in rows { byTitle[row.title.lowercased(), default: []].append(row) }

        var result: [ProcessIdentity: String] = [:]
        for (_, siblings) in byTitle where siblings.count > 1 {
            let locationsDiffer = Set(siblings.map { $0.location ?? "" }).count > 1
            let branchesDiffer = Set(siblings.map { $0.branch ?? "" }).count > 1
            for row in siblings {
                var place: [String] = []
                if locationsDiffer, let location = row.location { place.append(location) }
                if branchesDiffer, let branch = row.branch { place.append("(\(branch))") }
                var parts: [String] = []
                if !place.isEmpty { parts.append(place.joined(separator: " ")) }
                if let port = row.port { parts.append(":\(port)") }
                if !parts.isEmpty { result[row.id] = parts.joined(separator: " · ") }
            }
        }
        return result
    }
}

// MARK: - Details ------------------------------------------------------------------------------------

/// Everything the "Ayrıntılar" section shows, as plain values.
public struct ServerDetails: Sendable, Equatable {
    public struct ProcessLine: Sendable, Equatable, Identifiable {
        public let pid: Int32
        /// Cleaned for display (`DisplayText`).
        public let name: String
        public var id: Int32 { pid }
    }

    public struct PortLine: Sendable, Equatable, Identifiable {
        public enum Role: Sendable, Equatable { case main, inspector, ephemeral, regular }
        public let port: UInt16
        public let ownerPID: Int32
        public let scope: BindScope
        public let role: Role
        public var id: String { "\(ownerPID):\(port)" }
    }

    /// Absolute project path (the identity's, else the project root). The real path, for Finder; show it through
    /// `DisplayText.literal`.
    public let path: String?
    public let head: GitHead?
    public let manifest: ProjectManifest?
    public let workspaceName: String?
    public let pageTitle: String?
    public let kind: ProjectKind
    /// The tree root first, then every member.
    public let processes: [ProcessLine]
    /// When the tree root started.
    public let startedAt: Date
    /// The argv of the process that owns the main port (the root's when that is unreadable; the display command as a last
    /// resort) as it is SHOWN AND COPIED: secrets masked exactly like the stop card (`ArgvRedaction`), control and format
    /// characters replaced, at most 4000 scalars. The raw argv never leaves the model through this property.
    public let commandLine: String
    /// Every listener of the server, inspector and ephemeral ports included; the main port first.
    public let ports: [PortLine]

    public static let maxCommandLineLength = 4_000
    static let maxProcessNameLength = 64

    public init(server: DevServer, identity: ProjectIdentity?, pageTitle: String?) {
        path = identity?.path ?? server.project?.root
        head = identity?.head
        manifest = identity?.manifest
        workspaceName = identity?.workspaceName
        self.pageTitle = pageTitle
        kind = server.kind
        processes = server.members.map {
            ProcessLine(pid: $0.pid, name: DisplayText.label($0.name, limit: Self.maxProcessNameLength))
        }
        startedAt = server.root.identity.startDate
        commandLine = Self.commandLine(of: server)
        let inspectors = server.declaredInspectorPorts
        ports = server.ports.map { port in
            let role: PortLine.Role
            if port.port == server.mainPort {
                role = .main
            } else if port.isInspector || inspectors.contains(port.port) {
                role = .inspector
            } else if port.isEphemeral {
                role = .ephemeral
            } else {
                role = .regular
            }
            return PortLine(port: port.port, ownerPID: port.ownerPID, scope: port.scope, role: role)
        }
    }

    static func commandLine(of server: DevServer) -> String {
        let owner = server.members.first { member in
            server.ports.contains { $0.ownerPID == member.pid && $0.port == server.mainPort }
        }
        for node in [owner, server.root].compactMap({ $0 }) {
            let arguments = ProcessNames.trimmedArguments(node)
            if !arguments.isEmpty {
                return DisplayText.literal(ArgvRedaction.redactedLine(arguments: arguments), scalarLimit: maxCommandLineLength)
            }
        }
        return DisplayText.literal(ArgvRedaction.redactedLine(commandLine: server.command), scalarLimit: maxCommandLineLength)
    }
}
