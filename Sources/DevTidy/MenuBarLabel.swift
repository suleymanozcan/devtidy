import SwiftUI
import DevTidyCore

/// Menu bar item: symbol, plus `N · MEM` when something runs and `· 💤n` when idle resources are flagged.
/// (Menu bar images are template-tinted, so the emoji is the colour cue.)
struct MenuBarLabel: View {
    let store: DevTidyStore

    var body: some View {
        let summary = store.summary
        let running = summary.runningServers + summary.runningContainers
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
            if running > 0 {
                Text(Self.text(summary: summary, running: running, showsMemory: store.settings.menuBarShowsMemory))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(summary: summary))
    }

    @MainActor static func text(summary: MenuBarSummary, running: Int, showsMemory: Bool) -> String {
        var parts = ["\(running)"]
        if showsMemory { parts.append(Formatting.bytes(summary.totalMemoryBytes)) }
        var text = parts.joined(separator: " · ")
        if summary.flaggedIdleCount > 0 { text += " · 💤\(summary.flaggedIdleCount)" }
        return text
    }

    static func accessibilityText(summary: MenuBarSummary) -> String {
        var text = "DevTidy: \(summary.runningServers) sunucu, \(summary.runningContainers) konteyner çalışıyor"
        if summary.flaggedIdleCount > 0 { text += ", \(summary.flaggedIdleCount) boşta" }
        return text
    }
}
