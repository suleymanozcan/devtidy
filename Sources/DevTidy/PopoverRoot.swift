import SwiftUI
import AppKit
import DevTidyCore

struct PopoverRoot: View {
    @Bindable var store: DevTidyStore
    @State private var confirmation: ConfirmationRequest?
    /// User-chosen height of the tab list, dragged with the grip under the footer; 0 = automatic (fits the content
    /// between 200 and 470 pt). Persisted, so the popover reopens at the size it was left at.
    @AppStorage("devtidy.popover.listHeight") private var listHeight: Double = 0
    @State private var measuredListHeight: CGFloat = 0
    @State private var dragStartHeight: Double?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            if store.cleanup != nil {
                // The cleanup flow replaces the tabs while it is open: modal by construction.
                CleanupSheet(store: store)
                    .frame(width: 400, height: 560)
            } else {
                mainContent
            }
            if let request = confirmation {
                ConfirmationOverlay(
                    request: request,
                    onCancel: { confirmation = nil },
                    onConfirm: {
                        confirmation = nil
                        Task { await request.action() }
                    })
                .transition(.opacity)
            }
        }
        .frame(width: 400)
        .background(PopoverVisibilityObserver { visible in store.isPopoverVisible = visible })
        .environment(\.requestConfirmation, { confirmation = $0 })
        .onAppear { store.isPopoverVisible = true }
        .animation(.easeOut(duration: 0.12), value: confirmation?.id)
        // An armed confirmation never outlives the popover: what it was armed against may have changed by the next look.
        .onChange(of: store.isPopoverVisible) { _, visible in
            if !visible { confirmation = nil }
        }
    }

    // MARK: Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.lastError {
                errorBanner(error)
                Divider()
            }
            ScrollView {
                tabBody
                    .frame(maxWidth: .infinity)
            }
            // A chosen height pins min and max to it; automatic keeps the 200…470 fit. One frame, so dragging never
            // swaps the ScrollView's identity (and its scroll position).
            .frame(minHeight: listHeight > 0 ? clampedListHeight(listHeight) : 200,
                   maxHeight: listHeight > 0 ? clampedListHeight(listHeight) : 470)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredListHeight = $0 }
            Divider()
            footer
            resizeGrip
        }
    }

    // MARK: Resizing

    private static let minimumListHeight: Double = 200

    /// Tallest list that still keeps header, footer and grip on the screen the popover hangs from.
    private var maximumListHeight: Double {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(Self.minimumListHeight, Double(screen) - 170)
    }

    private func clampedListHeight(_ height: Double) -> Double {
        min(max(height, Self.minimumListHeight), maximumListHeight)
    }

    /// Drag down to grow, up to shrink; double-click returns to the automatic size. The global coordinate space keeps the
    /// translation stable while the panel grows under the pointer (its top edge stays pinned to the menu bar).
    private var resizeGrip: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? (listHeight > 0 ? clampedListHeight(listHeight) : Double(measuredListHeight))
                        dragStartHeight = start
                        listHeight = clampedListHeight(start + Double(value.translation.height))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .onTapGesture(count: 2) { listHeight = 0 }
            .help("Yüksekliği değiştirmek için sürükleyin · çift tıklayınca varsayılan boyut")
            .accessibilityElement()
            .accessibilityLabel("Pencere yüksekliği")
            .accessibilityAdjustableAction { direction in
                let current = listHeight > 0 ? clampedListHeight(listHeight) : Double(measuredListHeight)
                switch direction {
                case .increment: listHeight = clampedListHeight(current + 60)
                case .decrement: listHeight = clampedListHeight(current - 60)
                @unknown default: break
                }
            }
    }

    @ViewBuilder
    private var tabBody: some View {
        switch store.selectedTab {
        case .servers: ServersTab(store: store)
        case .docker: DockerTab(store: store)
        case .builds: BuildsTab(store: store)
        }
    }

    private var header: some View {
        Picker("Bölüm", selection: $store.selectedTab) {
            Text("Sunucular \(serverBadge)").tag(DevTidyTab.servers)
            Text("Docker \(dockerBadge)").tag(DevTidyTab.docker)
            Text("Derlemeler \(buildsBadge)").tag(DevTidyTab.builds)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)
    }

    private var serverBadge: String {
        let count = store.serverScan.servers.count
        return count > 0 ? "\(count)" : ""
    }

    private var dockerBadge: String {
        switch store.dockerSnapshot.status {
        case .notRunning, .notInstalled, .unsupported: return "—"
        default:
            let count = store.dockerSnapshot.allContainers.filter(\.isRunning).count
            return count > 0 ? "\(count)" : ""
        }
    }

    private var buildsBadge: String {
        store.buildReports.isEmpty ? "" : "\(store.buildReports.count)"
    }

    private func errorBanner(_ error: UserFacingError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: error.title).font(.callout.weight(.semibold))
                Text(verbatim: DisplayText.literal(error.message, scalarLimit: 1_200, keepingLineBreaks: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button("Kapat") { store.dismissError() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.red.opacity(0.10))
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Yenile") { Task { await refresh() } }
                .keyboardShortcut("r")
            Spacer()
            Button("Ayarlar…") {
                openSettings()
                NSApp.activate()
            }
            .keyboardShortcut(",")
            Button("Çıkış") {
                store.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .disabled(!store.canQuit)
            .help(store.canQuit ? "" : "Bir işlem sürerken çıkılamaz")
        }
        .controlSize(.small)
        .padding(10)
    }

    private func refresh() async {
        switch store.selectedTab {
        case .servers:
            await store.refreshNow()
        case .docker:
            await store.refreshNow()
            await store.refreshBuildCache()
        case .builds:
            await store.scanBuilds()
        }
    }
}
