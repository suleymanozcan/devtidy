import SwiftUI
import AppKit
import DevTidyCore

struct DockerTab: View {
    let store: DevTidyStore
    @Environment(\.requestConfirmation) private var requestConfirmation

    var body: some View {
        switch store.dockerSnapshot.status {
        case .unknown:
            VStack(spacing: 10) {
                ProgressView()
                Text("Docker kontrol ediliyor…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        case .notInstalled:
            EmptyState(title: "Docker kurulu değil", systemImage: "shippingbox")
        case .notRunning:
            VStack(spacing: 0) {
                EmptyState(title: "Docker çalışmıyor", systemImage: "shippingbox")
                Button("Docker Desktop'ı Aç") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app"))
                }
                .padding(.bottom, 20)
            }
        case .failed(let message):
            VStack(spacing: 0) {
                EmptyState(title: "Docker yanıt vermiyor", message: DisplayText.label(message, limit: 400),
                           systemImage: "exclamationmark.triangle")
                Button("Yeniden Dene") { Task { await store.refreshNow() } }
                    .padding(.bottom, 20)
            }
        case .unsupported(let message):
            // A configured socket that is missing is usually a daemon that is not started (a stopped Colima / OrbStack); a
            // remote context is refused on purpose. Either way DevTidy picks up a fixed configuration by itself.
            VStack(spacing: 0) {
                EmptyState(title: "Docker yapılandırması desteklenmiyor", message: DisplayText.label(message, limit: 400),
                           systemImage: "exclamationmark.triangle")
                Text("Docker'ı (ya da Colima / OrbStack gibi motorunu) başlatın veya yapılandırmayı düzeltin; DevTidy kendiliğinden algılar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                Button("Yeniden Dene") { Task { await store.refreshNow() } }
                    .padding(.bottom, 20)
            }
        case .running:
            runningContent
        }
    }

    // MARK: Running

    private var runningContent: some View {
        let snapshot = store.dockerSnapshot
        return VStack(spacing: 0) {
            toolbar
            Divider()
            buildCacheRow
            Divider()
            if snapshot.allContainers.isEmpty {
                EmptyState(title: "Konteyner yok", systemImage: "shippingbox")
            } else {
                ForEach(snapshot.projects) { project in
                    ComposeSection(store: store, project: project)
                }
                if !snapshot.standalone.isEmpty {
                    SectionHeader(title: "Tek başına", trailing: "\(snapshot.standalone.count)")
                    ForEach(snapshot.standalone) { container in
                        ContainerRow(store: store, container: container)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        let idleCount = store.idleContainers.count
        return HStack {
            Button("Boştakileri Durdur (\(idleCount))") { confirmStopIdle() }
                .disabled(idleCount == 0)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The card lists, and the confirmed action stops, exactly the containers that were idle when the card was armed.
    private func confirmStopIdle() {
        let idle = store.idleContainers
        guard !idle.isEmpty else { return }
        let ids = Set(idle.map(\.id))
        requestConfirmation(ConfirmationRequest(
            title: "Boşta olan \(idle.count) konteyner durdurulsun mu?",
            message: "Yalnızca uzun süredir boşta görünen çalışan konteynerler durdurulur; silinmez.",
            details: idle.map { DisplayText.label($0.name) },
            confirmTitle: "Durdur",
            action: { [store] in _ = await store.stopIdleContainers(ids: ids) }))
    }

    private var buildCacheRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                buildCacheSummary
                Spacer(minLength: 4)
                if store.busyKeys.contains("prune") {
                    ProgressView().controlSize(.small)
                } else {
                    Menu("Temizle…") {
                        Button("7 günden eskiler") { confirmPrune(.olderThan(hours: 168), label: "7 günden eski") }
                        Button("Tümü (kullanılmayan)") { confirmPrune(.allUnused, label: "kullanılmayan tüm") }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(store.buildCache == nil)
                }
            }
            .controlSize(.small)
            if let reclaimed = store.lastBuildCachePrune, !store.busyKeys.contains("prune") {
                Text("\(Formatting.bytes(reclaimed.reclaimedBytes)) geri kazanıldı")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "ölçülüyor…" only while a request is in flight; a failure is shown with the reason and a retry.
    @ViewBuilder
    private var buildCacheSummary: some View {
        if store.isMeasuringBuildCache {
            Text("Build önbelleği ölçülüyor…").font(.caption).foregroundStyle(.secondary)
        } else if let failure = store.buildCacheFailure {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Build önbelleği ölçülemedi: " + DisplayText.label(failure, limit: 400))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Yeniden Dene") { Task { await store.refreshBuildCache() } }
            }
        } else if let cache = store.buildCache {
            Text("Build önbelleği: \(Formatting.bytes(cache.totalBytes)) (en çok \(Formatting.bytes(cache.reclaimableBytes)) temizlenebilir)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button("Build önbelleğini ölç") { Task { await store.refreshBuildCache() } }
        }
    }

    private func confirmPrune(_ mode: BuildCachePruneMode, label: String) {
        requestConfirmation(ConfirmationRequest(
            title: "Build önbelleği temizlensin mi?",
            message: "Yalnızca \(label) build önbelleği temizlenir. İmajlar, konteynerler ve birimler (volume) silinmez.",
            confirmTitle: "Temizle",
            action: { [store] in await store.pruneBuildCache(mode) }))
    }
}

// MARK: - Compose section ----------------------------------------------------------

private struct ComposeSection: View {
    let store: DevTidyStore
    let project: ComposeProject
    @Environment(\.requestConfirmation) private var requestConfirmation

    private var isBusy: Bool { store.busyKeys.contains("compose:\(project.name)") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: DisplayText.label(project.name)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(project.runningCount)/\(project.containers.count) çalışıyor · \(Formatting.bytes(project.memoryBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                if isBusy { ProgressView().controlSize(.small) }
                Button("Durdur") { confirmStop() }
                    .disabled(isBusy || project.runningCount == 0)
                Button("Kaldır (down)") { confirmDown() }
                    .disabled(isBusy)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)

            ForEach(project.containers) { container in
                ContainerRow(store: store, container: container)
                Divider().padding(.leading, 12)
            }
        }
    }

    private func confirmStop() {
        requestConfirmation(ConfirmationRequest(
            title: "\(DisplayText.label(project.name)) durdurulsun mu?",
            message: "Çalışan konteynerler durdurulur; silinmez.",
            details: project.containers.filter(\.isRunning).map { DisplayText.label($0.name) },
            confirmTitle: "Durdur",
            action: { [store, project] in await store.perform(.stop, on: project) }))
    }

    private func confirmDown() {
        requestConfirmation(ConfirmationRequest(
            title: "\(DisplayText.label(project.name)) kaldırılsın mı?",
            message: "Konteynerler (yazılabilir katmanlarıyla) ve ağlar kaldırılır; birimler (volume) silinmez.",
            details: project.containers.map { DisplayText.label($0.name) },
            confirmTitle: "Kaldır",
            action: { [store, project] in await store.perform(.down, on: project) }))
    }
}

// MARK: - Container row ------------------------------------------------------------

struct ContainerRow: View {
    let store: DevTidyStore
    let container: DockerContainer
    @Environment(\.requestConfirmation) private var requestConfirmation

    private var isBusy: Bool { store.busyKeys.contains("container:\(container.id)") }
    private var idleState: IdleState? { store.containerIdle[container.id] }

    private var dotColor: Color {
        switch container.state {
        case .running: idleState?.isFlagged == true ? .orange : .green
        case .paused, .restarting: .yellow
        default: .gray
        }
    }

    private var stateText: String {
        switch container.state {
        case .running: "Çalışıyor"
        case .created: "Oluşturuldu"
        case .paused: "Duraklatıldı"
        case .restarting: "Yeniden başlıyor"
        case .removing: "Siliniyor"
        case .exited: "Durdu"
        case .dead: "Ölü"
        case .unknown: "Bilinmiyor"
        }
    }

    /// One chip per distinct tcp host port.
    private var chips: [PublishedPort] {
        var seen = Set<UInt16>()
        return container.publishedPorts.filter { $0.proto == "tcp" && seen.insert($0.hostPort).inserted }
    }

    private func scope(of port: PublishedPort) -> BindScope? {
        switch port.hostIP {
        case "127.0.0.1", "::1": .loopback
        case "0.0.0.0", "::", nil: .allInterfaces
        default: .other
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StateDot(color: dotColor, label: stateText)
                Text(verbatim: DisplayText.label(container.name)).font(.subheadline.weight(.semibold)).lineLimit(1)
                if container.health == .unhealthy {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help("Sağlık kontrolü başarısız")
                        .accessibilityLabel("Sağlıksız")
                }
                IdleBadge(state: container.isRunning ? idleState : nil)
                Spacer(minLength: 4)
                if isBusy { ProgressView().controlSize(.small) }
            }
            Text(verbatim: DisplayText.label(container.image))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(DisplayText.label(container.image))
            if !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chips, id: \.hostPort) { port in
                        PortChip(port: port.hostPort, scope: scope(of: port), url: store.url(forPort: port.hostPort))
                    }
                }
            }
            HStack(spacing: 6) {
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(DisplayText.label(container.statusText))
                Spacer(minLength: 4)
                actions
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var detailLine: String {
        guard container.isRunning else { return stateText }
        let mem = container.memoryBytes.map { Formatting.bytes($0) } ?? "—"
        let up = container.uptime(at: Date()).map { Formatting.uptime($0) } ?? "—"
        return "CPU \(Formatting.cpu(container.cpuPercent)) · \(mem) · \(up)"
    }

    @ViewBuilder
    private var actions: some View {
        switch container.state {
        case .running:
            Button("Durdur") { Task { await store.perform(.stop, on: container) } }
                .disabled(isBusy)
        case .exited, .created:
            Button("Başlat") { Task { await store.perform(.start, on: container) } }
                .disabled(isBusy)
            Button("Sil…") {
                requestConfirmation(ConfirmationRequest(
                    title: "Konteyner silinsin mi?",
                    message: "Konteyner ve yazılabilir katmanındaki veriler silinir; birimler (volume) korunur.",
                    details: [DisplayText.label(container.name)],
                    confirmTitle: "Sil",
                    action: { [store, container] in await store.perform(.remove, on: container) }))
            }
            .disabled(isBusy)
        default:
            EmptyView()
        }
    }
}
