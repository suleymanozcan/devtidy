import SwiftUI
import AppKit
import DevTidyCore

// MARK: - Confirmation ---------------------------------------------------------

/// Everything the popover needs to ask before a destructive action. Presented inline (not as a system alert):
/// alerts and sheets attached to a `MenuBarExtra(.window)` panel are unreliable, an in-popover card is not.
struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Names / paths the action will touch, shown verbatim.
    var details: [String] = []
    let confirmTitle: String
    var isDestructive = true
    let action: @MainActor () async -> Void
}

private struct RequestConfirmationKey: EnvironmentKey {
    static var defaultValue: @MainActor (ConfirmationRequest) -> Void { { _ in } }
}

extension EnvironmentValues {
    /// Rows call this instead of acting directly; `PopoverRoot` shows the card and runs `action` only on confirm.
    var requestConfirmation: @MainActor (ConfirmationRequest) -> Void {
        get { self[RequestConfirmationKey.self] }
        set { self[RequestConfirmationKey.self] = newValue }
    }
}

struct ConfirmationOverlay: View {
    let request: ConfirmationRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 10) {
                // Everything on the card may carry text from outside (a project folder, a process name, a container): shown as
                // plain text, with invisible characters replaced and the length bounded.
                Text(verbatim: DisplayText.literal(request.title, scalarLimit: 200)).font(.headline)
                Text(verbatim: DisplayText.literal(request.message, scalarLimit: 800)).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !request.details.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(request.details.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: DisplayText.literal(line, scalarLimit: 400))
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Spacer()
                    Button("İptal", action: onCancel).keyboardShortcut(.cancelAction)
                    confirmButton
                }
            }
            .padding(14)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// A destructive request has no default action: a stray Return (the card appears while the user is typing or planning
    /// takes seconds) must never confirm a kill, a `down` or a delete. Only a click does; Escape cancels.
    @ViewBuilder
    private var confirmButton: some View {
        let button = Button(request.confirmTitle, role: request.isDestructive ? .destructive : nil, action: onConfirm)
        if request.isDestructive {
            button
        } else {
            button.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Small pieces -----------------------------------------------------------

struct PortChip: View {
    let port: UInt16
    let scope: BindScope?
    let url: URL
    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: ":\(port)").font(.system(.caption, design: .monospaced).weight(.medium))
                if scope == .allInterfaces {
                    Image(systemName: "network").font(.caption2).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(scope == .allInterfaces ? "\(url.absoluteString) — Tüm arayüzlere açık" : url.absoluteString)
        .accessibilityLabel(scope == .allInterfaces
                            ? "Port \(port), tüm arayüzlere açık, tarayıcıda aç"
                            : "Port \(port), tarayıcıda aç")
    }
}

struct IdleBadge: View {
    let state: IdleState?
    var body: some View {
        switch state {
        case .idle:
            badge("Boşta")
        case .probablyIdle:
            badge("Muhtemelen boşta")
        case .active, nil:
            EmptyView()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(.orange.opacity(0.6), lineWidth: 1))
            .accessibilityLabel(text)
    }
}

struct SizeText: View {
    let bytes: Int64?
    var partial = false
    var body: some View {
        Text(Formatting.size(bytes, partial: partial))
            .monospacedDigit()
            .accessibilityLabel(bytes == nil ? "Boyut hesaplanıyor" : Formatting.size(bytes, partial: partial))
    }
}

struct StateDot: View {
    let color: Color
    let label: String
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.caption2).accessibilityHidden(true) }
            Text(verbatim: text).font(.caption2.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyState: View {
    let title: String
    var message: String?
    var systemImage = "tray"
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// Monospaced path, middle-truncated, with the full path as tooltip and selectable.
struct PathText: View {
    let path: String
    var body: some View {
        Text(verbatim: shown)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(shown)
            .textSelection(.enabled)
    }

    /// The real path is for Finder; the screen gets it with invisible characters replaced.
    private var shown: String { DisplayText.literal(path, scalarLimit: 1_024) }
}

// MARK: - Popover visibility ------------------------------------------------------------

/// Reports whether the hosting window is actually on screen. `onAppear`/`onDisappear` are unreliable for
/// `MenuBarExtra(.window)`, so the signal is the window's occlusion state (and key-state changes re-evaluate it).
struct PopoverVisibilityObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    /// Removes its notification observers when it goes away (nonisolated `deinit`, hence the separate box).
    private final class ObserverBag: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        func removeAll() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
        }
        deinit { removeAll() }
    }

    final class TrackingView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private let bag = ObserverBag()
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bag.removeAll()
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                }
                bag.tokens.append(token)
            }
            evaluate()
        }

        func evaluate() {
            guard let window else { report(false); return }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard lastReported != visible else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}
