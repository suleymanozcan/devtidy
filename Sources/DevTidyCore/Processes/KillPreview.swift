import Foundation

/// Everything the kill confirmation shows for one `DevServer` (CodeReview P1-5): the root the signals start from with its
/// full command line, every server / project folded into the tree when nested roots were merged, every process that will be
/// signalled, and the browser / app / editor / terminal / agent processes that will be left alone. Pure text built from the
/// model; the UI only renders it.
public struct KillPreview: Sendable, Equatable {
    /// One sentence: what is about to be stopped.
    public let message: String
    /// Lines for the card's detail list.
    public let details: [String]

    /// Width of one command-line row: the card shows at most two wrapped lines per detail row.
    static let chunkWidth = 72
    /// Upper bound for the displayed command line (longer ones end in "…").
    static let commandLimit = 1_000

    /// `identity`: what the project's own files say about it (repository, branch); with it the card names the checkout the
    /// server belongs to, not only the folder, so two `client` folders of two checkouts are told apart (R3-P3-3).
    public init(_ server: DevServer, identity: ProjectIdentity? = nil) {
        self.init(server, identity: identity, home: NSHomeDirectory())
    }

    init(_ server: DevServer, identity: ProjectIdentity?, home: String) {
        let root = server.root
        let signalled = server.members.count
        // Every name below comes from a folder, a manifest or the kernel: none of it is trusted to be free of line breaks,
        // bidi overrides or an absurd length (F3-4).
        let title = DisplayText.label(server.project?.name ?? root.name)
        let port = server.mainPort.map { " (:\($0))" } ?? ""
        // A listener is a server of its own only when it serves a port somebody uses. A child that listens on inspector /
        // ephemeral ports alone (Cloudflare's workerd below Vite) is one of the processes of the server above it (QA2 N2).
        let inspectorPorts = server.declaredInspectorPorts
        let servers = server.listeners.filter { Self.isServing($0, inspectorPorts: inspectorPorts) }
        let merged = servers.count > 1

        if merged {
            message = "\(servers.count) sunucu ve toplam \(signalled) süreç sonlandırılacak "
                + "(önce SIGTERM, kapanmazsa SIGKILL)."
        } else {
            message = "\(title)\(port) ve alt süreçleri sonlandırılacak "
                + "(önce SIGTERM, kapanmazsa SIGKILL)."
        }

        var lines: [String] = []
        if merged {
            for listener in servers {
                lines.append("Sunucu: " + Self.label(of: listener, inspectorPorts: inspectorPorts))
                if let project = listener.project { Self.appendPath(project.root, home: home, to: &lines) }
            }
        } else if let project = server.project {
            var line = "Proje: " + DisplayText.label(identity?.headerTitle ?? project.name)
            if let head = identity?.head { line += "  ⎇ " + DisplayText.label(head.label, limit: 80) }
            lines.append(line)
            Self.appendPath(project.root, home: home, to: &lines)
        }

        lines.append("Kök süreç: PID \(root.pid)  \(DisplayText.label(root.name))  — tüm ağaç buradan durdurulur")
        for chunk in Self.chunks(of: Self.commandLine(of: root), width: Self.chunkWidth) { lines.append("  " + chunk) }
        if server.groupKillEligible {
            lines.append("Sinyal: süreç grubuna (pgid \(root.pgid)) tek seferde gönderilir")
        } else {
            lines.append("Sinyal: her sürece tek tek gönderilir")
        }

        lines.append("Sonlandırılacak süreçler (\(signalled)):")
        for member in server.members {
            lines.append("PID \(member.pid)  \(DisplayText.label(member.name))" + (member.pid == root.pid ? "  (kök)" : ""))
        }

        if !server.sparedRoots.isEmpty {
            lines.append("Dokunulmayacak (tarayıcı / uygulama / editör / terminal / ajan, alt süreçleriyle):")
            for spared in server.sparedRoots { lines.append("PID \(spared.pid)  \(DisplayText.label(spared.name))") }
        }
        details = lines
    }

    /// The project folder as `~/…`, wrapped like a command line and indented the same way.
    private static func appendPath(_ path: String, home: String, to lines: inout [String]) {
        var shown = path
        if !home.isEmpty, home != "/" {
            if path == home {
                shown = "~"
            } else if path.hasPrefix(home + "/") {
                shown = "~" + path.dropFirst(home.count)
            }
        }
        for chunk in chunks(of: ArgvRedaction.sanitized(shown), width: chunkWidth) { lines.append("  " + chunk) }
    }

    /// Ports a person would call "the server's port": not ephemeral, not an inspector (default or declared).
    private static func servingPorts(of listener: ServerListener, inspectorPorts: Set<UInt16>) -> [ListeningPort] {
        listener.ports.filter { !$0.isEphemeral && !$0.isInspector && !inspectorPorts.contains($0.port) }
    }

    private static func isServing(_ listener: ServerListener, inspectorPorts: Set<UInt16>) -> Bool {
        !servingPorts(of: listener, inspectorPorts: inspectorPorts).isEmpty
    }

    /// `name :3000 :3001  (PID 12)` — project name when known, the listener's own name otherwise.
    private static func label(of listener: ServerListener, inspectorPorts: Set<UInt16>) -> String {
        let name = DisplayText.label(listener.project?.name ?? listener.name)
        let ports = servingPorts(of: listener, inspectorPorts: inspectorPorts).map { ":\($0.port)" }
        let portText = ports.isEmpty ? "" : " " + ports.joined(separator: " ")
        return "\(name)\(portText)  (PID \(listener.pid))"
    }

    // MARK: Command line

    /// Full argv of `node`, joined with spaces, for display: secrets hidden and invisible characters replaced by
    /// `ArgvRedaction` (the same rules as every other place that prints a command line). The executable path when argv was
    /// not readable; at most `commandLimit` characters.
    static func commandLine(of node: ProcessNode) -> String {
        var text = ArgvRedaction.redactedLine(arguments: ProcessNames.tokens(of: node))
        if text.isEmpty { text = ArgvRedaction.sanitized(node.executablePath ?? node.name) }
        guard text.count > commandLimit else { return text }
        return String(text.prefix(commandLimit - 1)) + "…"
    }

    /// Greedy word wrap at `width` characters. Rows break at spaces; a single word longer than a row is the only thing that
    /// is cut, and only at the row width. Joining the rows with a space (and the pieces of a cut word with nothing)
    /// reproduces `text`.
    static func chunks(of text: String, width: Int) -> [String] {
        guard width > 0, !text.isEmpty else { return [text] }
        var rows: [String] = []
        var current = ""
        var started = false
        for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
            if started, current.count + 1 + piece.count <= width {
                current += " "
                current += piece
                continue
            }
            if started { rows.append(current) }
            var rest = piece
            while rest.count > width {
                rows.append(String(rest.prefix(width)))
                rest = rest.dropFirst(width)
            }
            current = String(rest)
            started = true
        }
        if started { rows.append(current) }
        return rows
    }
}

extension DevServer {
    public var killPreview: KillPreview { KillPreview(self) }
}
