import SwiftUI
import AppKit
import DevTidyCore

struct ServersTab: View {
    let store: DevTidyStore

    /// Grouping and order (one section per project, project-less bucket last) are decided by the store.
    private var groups: [ServerGroup] { store.serverGroups }

    private var others: [OtherListener] {
        store.settings.showOtherListeners ? store.serverScan.others : []
    }

    var body: some View {
        let allGroups = groups
        let qualifiers = store.rowQualifiers
        if allGroups.isEmpty && others.isEmpty {
            EmptyState(title: "Çalışan geliştirme sunucusu yok",
                       message: "Yerel bir sunucu başlattığınızda burada görünür.",
                       systemImage: "server.rack")
        } else {
            VStack(spacing: 0) {
                ForEach(allGroups) { group in
                    ServerGroupHeader(group: group)
                    ForEach(group.servers) { server in
                        ServerRow(store: store, server: server, qualifier: qualifiers[server.id])
                        Divider().padding(.leading, 12)
                    }
                }
                if !others.isEmpty {
                    DisclosureGroup {
                        ForEach(others) { other in
                            OtherListenerRow(other: other)
                        }
                    } label: {
                        Text("Diğer dinleyiciler (\(others.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
        }
    }
}

/// `repo › packages/client` (the folder name without a repo) with the git branch as a chip.
private struct ServerGroupHeader: View {
    let group: ServerGroup

    /// `Git dalı: main` (tooltip) / `Git dalı, main` (VoiceOver). A String, never a literal with an interpolation: the branch name
    /// is text from the repository and must not be read as a localized key.
    private func branchDescription(_ head: GitHead, joiner: String) -> String {
        (head.isDetached ? "Ayrık HEAD" : "Git dalı") + joiner + head.label
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let head = group.identity?.head {
                // A long branch name shrinks (middle-truncated, the full name in the tooltip) instead of pushing the count out of
                // the popover.
                Chip(text: head.label, systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: 200, alignment: .leading)
                    .help(branchDescription(head, joiner: ": "))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(branchDescription(head, joiner: ", "))
            }
            Spacer(minLength: 4)
            Text("\(group.servers.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .help(group.identity.map { Formatting.displayPath($0.path) } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct ServerRow: View {
    let store: DevTidyStore
    let server: DevServer
    /// Where this row lives and on which port, when another row has the same title (`ServerRowQualifier`).
    let qualifier: String?
    @Environment(\.requestConfirmation) private var requestConfirmation
    @State private var showsDetails = false

    private var isBusy: Bool { store.busyKeys.contains("server:\(server.root.pid)") }
    private var isLowConfidence: Bool { server.confidence == .low }

    /// `qualifier · name@version · framework`, e.g. `redalert-perf › packages/client (perf-fx) · :5182 · client@0.0.0 · Vite`.
    private func subtitle(for presentation: ServerPresentation) -> String? {
        presentation.subtitle(framework: Formatting.frameworkName(presentation.kind), qualifier: qualifier)
    }

    var body: some View {
        let presentation = store.presentation(for: server)
        let command = DisplayText.literal(server.command, scalarLimit: 400)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isLowConfidence ? .secondary : .primary)
                    .lineLimit(1)
                IdleBadge(state: store.serverIdle[server.id])
                Spacer(minLength: 4)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .help(isLowConfidence ? "Proje bulunamadı" : presentation.title)

            if let subtitle = subtitle(for: presentation) {
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 5) {
                ForEach(server.displayPorts) { port in
                    PortChip(port: port.port, scope: port.scope, url: store.url(forPort: port.port))
                }
                if server.internalPortCount > 0 {
                    Text("+\(server.internalPortCount) dahili")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(verbatim: command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(command)

            HStack(spacing: 6) {
                Text("CPU \(Formatting.cpu(server.cpuPercent)) · \(Formatting.bytes(server.memoryBytes)) · \(Formatting.uptime(server.uptime(at: Date())))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                Button("Durdur + Temizle…") {
                    Task { await store.beginStopAndClean(server) }
                }
                .disabled(server.project == nil || isBusy)
                Button("Durdur") { confirmStop() }
                    .disabled(isBusy)
            }
            .controlSize(.small)

            DisclosureGroup(isExpanded: $showsDetails) {
                ServerDetailsView(store: store, server: server)
                    .padding(.top, 4)
            } label: {
                Text("Ayrıntılar")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Klasörü Finder'da Göster") {
                if let root = server.project?.root { revealInFinder(root) }
            }
            .disabled(server.project == nil)
            Button("Komutu Kopyala") { copyToPasteboard(server.command) }
            Button("Portu Kopyala") {
                if let port = server.mainPort { copyToPasteboard(String(port)) }
            }
            .disabled(server.mainPort == nil)
        }
        .accessibilityElement(children: .contain)
    }

    private func confirmStop() {
        // Root command line, every merged server / project, every process to signal and the processes that are spared.
        let preview = KillPreview(server, identity: store.identity(for: server))
        requestConfirmation(ConfirmationRequest(
            title: "Sunucu durdurulsun mu?",
            message: preview.message,
            details: preview.details,
            confirmTitle: "Durdur",
            action: { [store, server] in await store.stop(server) }))
    }
}

// MARK: - Ayrıntılar ---------------------------------------------------------------------

/// Everything known about one server. Built only while the section is expanded.
private struct ServerDetailsView: View {
    let store: DevTidyStore
    let server: DevServer

    /// Past this many processes the list ends with "+N daha"; the kill card lists them all.
    private static let maxProcessesShown = 24

    var body: some View {
        let details = store.details(for: server)
        VStack(alignment: .leading, spacing: 6) {
            DetailRow("Tam yol") {
                if let path = details.path {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: Formatting.displayPath(path))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(Formatting.displayPath(path))
                        Spacer(minLength: 2)
                        Button("Finder'da Göster") { revealInFinder(path) }
                            .controlSize(.mini)
                    }
                } else {
                    DetailValue("—")
                }
            }
            DetailRow("Git dalı") {
                DetailValue(details.head.map(Formatting.branchText) ?? "—")
            }
            DetailRow("Paket") {
                if let manifest = details.manifest {
                    DetailValue("\(manifest.label) · \(manifest.source.fileName)")
                } else {
                    DetailValue("—")
                }
            }
            if let workspace = details.workspaceName {
                DetailRow("Çalışma alanı") { DetailValue(workspace) }
            }
            DetailRow("Sayfa başlığı") {
                DetailValue(pageTitleText(store.pageTitleStatus(for: server)))
            }
            DetailRow("Framework") {
                DetailValue(Formatting.frameworkName(details.kind) ?? "—")
            }
            DetailRow("PID'ler") {
                DetailValue(processesText(details.processes), monospaced: true)
            }
            DetailRow("Başlangıç") {
                DetailValue(Formatting.startText(details.startedAt))
            }
            DetailRow("Komut satırı") {
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: details.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        copyToPasteboard(details.commandLine)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Komut satırını kopyala")
                    .accessibilityLabel("Komut satırını kopyala")
                }
            }
            DetailRow("Portlar") {
                DetailValue(portsText(details.ports), monospaced: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pageTitleText(_ status: PageTitleStatus) -> String {
        switch status {
        case .disabled: "kapalı (Ayarlar > Genel)"
        case .notApplicable: "—"
        case .pending: "okunuyor…"
        case .title(let title): title
        case .noTitle: "yok"
        case .failed: "okunamadı (sunucu yanıt vermedi; HTTPS kullanıyor olabilir)"
        case .skippedIdle: "okunmadı (sunucu boşta; etkinleşince okunur)"
        case .portShared: "okunmadı (aynı portu başka bir süreç de dinliyor)"
        }
    }

    private func processesText(_ processes: [ServerDetails.ProcessLine]) -> String {
        let shown = processes.prefix(Self.maxProcessesShown).map { "\($0.pid) \($0.name)" }.joined(separator: ", ")
        let hidden = processes.count - Self.maxProcessesShown
        return hidden > 0 ? shown + " +\(hidden) daha" : shown
    }

    /// `:5182 ana · :9229 denetleyici · :51234 dahili`; a port open to the network says so.
    private func portsText(_ ports: [ServerDetails.PortLine]) -> String {
        ports.map { port in
            var text = ":\(port.port)"
            if let role = Formatting.portRoleText(port.role) { text += " " + role }
            if port.scope != .loopback { text += " (" + Formatting.scopeText(port.scope) + ")" }
            return text
        }.joined(separator: " · ")
    }
}

private struct DetailRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct DetailValue: View {
    let text: String
    var monospaced = false

    init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }

    var body: some View {
        Text(verbatim: text)
            .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Helpers --------------------------------------------------------------------------

@MainActor
private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct OtherListenerRow: View {
    let other: OtherListener

    private var reasonText: String {
        switch other.reason {
        case .tool: "Araç"
        case .app: "Uygulama"
        case .system: "Sistem"
        case .unknown: "Bilinmiyor"
        }
    }

    var body: some View {
        HStack {
            Text(verbatim: DisplayText.label(other.node.name, limit: 64)).font(.caption)
            Text(other.ports.map { ":\($0.port)" }.joined(separator: " "))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(reasonText).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
