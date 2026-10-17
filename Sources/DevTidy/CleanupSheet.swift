import SwiftUI
import DevTidyCore

/// The cleanup flow, presented by `PopoverRoot` in place of the tabs while `store.cleanup != nil`.
/// Review stage = the confirmation step: every entry shows its exact absolute path, size and whether it is
/// deleted permanently or moved to the Trash. Nothing is touched until the primary button is pressed.
struct CleanupSheet: View {
    @Bindable var store: DevTidyStore

    var body: some View {
        VStack(spacing: 0) {
            switch store.cleanup {
            case .planning(_, let projectRoot)?:
                PlanningStage(projectRoot: projectRoot) { store.dismissCleanup() }
            case .review(let plan, let selections, let stopFirst)?:
                ReviewStage(store: store, plan: plan, selections: selections, stopFirst: stopFirst)
            case .executing(_, let stopping)?:
                ExecutingStage(stopping: stopping, progress: store.cleanupProgress)
            case .finished(let result, let terminated)?:
                FinishedStage(result: result, terminated: terminated) { store.dismissCleanup() }
            case .failed(let error)?:
                FailedStage(error: error) { store.dismissCleanup() }
            case nil:
                EmptyView()
            }
        }
        .background(.background)
    }
}

// MARK: - Stages -------------------------------------------------------------------

private struct StageHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle { PathText(path: subtitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct PlanningStage: View {
    let projectRoot: String
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            StageHeader(title: "Önbellekleri Temizle", subtitle: projectRoot)
            Divider()
            Spacer()
            VStack(spacing: 10) {
                ProgressView()
                Text("Plan hazırlanıyor…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Divider()
            HStack {
                Spacer()
                Button("İptal", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }
}

private struct ExecutingStage: View {
    let stopping: Bool
    let progress: [CleanupOutcome]
    var body: some View {
        VStack(spacing: 0) {
            StageHeader(title: stopping ? "Durduruluyor ve temizleniyor…" : "Temizleniyor…")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(progress) { outcome in OutcomeRow(outcome: outcome) }
                }
                .padding(12)
            }
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stopping ? "Sunucu durduruluyor, ardından seçilenler temizlenecek." : "Seçilen öğeler siliniyor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
    }
}

private struct OutcomeRow: View {
    let outcome: CleanupOutcome

    private var color: Color {
        switch outcome.status {
        case .deleted, .movedToTrash: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: DisplayText.label(Formatting.statusText(outcome.status), limit: 400))
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
            PathText(path: outcome.path).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct FinishedStage: View {
    let result: CleanupResult
    let terminated: TerminationReport?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StageHeader(title: "Temizlik tamamlandı")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let terminated {
                        Label(terminated.wasAlreadyGone ? "Sunucu zaten kapanmıştı" : "Sunucu durduruldu",
                              systemImage: "stop.circle")
                            .font(.callout)
                    }
                    if result.outcomes.isEmpty {
                        Text("Temizlenecek bir şey kalmadı.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(result.outcomes) { outcome in OutcomeRow(outcome: outcome) }
                }
                .padding(12)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    if result.freedBytes > 0 {
                        Text("\(Formatting.bytes(result.freedBytes)) boşaldı").font(.callout.weight(.semibold))
                    }
                    if result.trashedBytes > 0 {
                        Text("\(Formatting.bytes(result.trashedBytes)) Çöp Kutusu'na taşındı; Çöp Kutusu'nu boşaltınca boşalır")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Kapat", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

private struct FailedStage: View {
    let error: UserFacingError
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            StageHeader(title: error.title)
            Divider()
            ScrollView {
                Text(verbatim: DisplayText.literal(error.message, scalarLimit: 1_200, keepingLineBreaks: true))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            Divider()
            HStack {
                Spacer()
                Button("Kapat", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

// MARK: - Review -------------------------------------------------------------------

private struct ReviewStage: View {
    @Bindable var store: DevTidyStore
    let plan: CleanupPlan
    let selections: [String: CleanupSelection]
    let stopFirst: DevServer?

    private struct SafetySection: Identifiable {
        let title: String
        let safety: CacheSafety
        let entries: [CacheEntry]
        var id: CacheSafety { safety }
    }

    private var sections: [SafetySection] {
        let order: [(String, CacheSafety)] = [("Her zaman güvenli", .always), ("Koşullu", .conditional), ("Bağımlılıklar", .optIn)]
        var out: [SafetySection] = []
        for (title, safety) in order {
            let entries = plan.entries.filter { $0.safety == safety }
            if entries.isEmpty { continue }
            if safety == .optIn && !store.settings.includeDependencies { continue }
            out.append(SafetySection(title: title, safety: safety, entries: entries))
        }
        return out
    }

    private var unresolved: [ActivityBlocker] {
        CleanupRules.unresolvedBlockers(plan: plan, selections: selections, stopFirst: stopFirst)
    }

    private var dependenciesSelected: Bool {
        plan.entries.contains { $0.safety == .optIn && selections[$0.id] != nil }
    }

    private var canConfirm: Bool {
        !selections.isEmpty
            && unresolved.isEmpty
            && (!dependenciesSelected || store.acknowledgedDependencies)
    }

    var body: some View {
        VStack(spacing: 0) {
            StageHeader(title: "Önbellekleri Temizle", subtitle: plan.project?.root ?? plan.rootPath)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let stopFirst { stopBanner(stopFirst) }
                    if store.xcodeRunning && plan.entries.contains(where: { $0.instance != nil }) { xcodeNotice }
                    if !plan.blockers.isEmpty { blockersBox }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(section.entries) { entry in
                                EntryRow(store: store, entry: entry, selection: selections[entry.id])
                            }
                            if section.safety == .conditional {
                                Toggle("Koşullu öğeleri kalıcı sil (Çöp Kutusu yerine)",
                                       isOn: $store.settings.deleteConditionalPermanently)
                                    .font(.caption)
                                    .toggleStyle(.checkbox)
                            }
                            if section.safety == .optIn {
                                Toggle("Anladım: bağımlılıklar silinecek, yeniden kurulum ağ gerektirir",
                                       isOn: $store.acknowledgedDependencies)
                                    .font(.caption)
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
    }

    // MARK: Pieces

    /// The same card content the plain "Durdur" shows (Security N-1): root process with its full command line, signal path,
    /// every PID that will be signalled and the browser / app processes that are left alone. "Durdur ve Temizle" is the
    /// confirmation, so all of it is on screen before the button that sends the first signal.
    private func stopBanner(_ server: DevServer) -> some View {
        let preview = server.killPreview
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "stop.circle").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Önce sunucu durdurulacak").font(.callout.weight(.semibold))
                    Text(verbatim: DisplayText.literal(preview.message, scalarLimit: 800))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            KillPreviewList(lines: preview.details)
        }
    }

    private var xcodeNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "hammer").foregroundStyle(.orange).accessibilityHidden(true)
            Text("Xcode açık: silinen derleme klasörleri yeniden oluşturulur, açık projeler yeniden dizinlenebilir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var blockersBox: some View {
        let unresolvedSet = Set(unresolved)
        let running = plan.blockers.filter { !$0.isDockerUnverified }
        let dockerUnverified = plan.blockers.first(where: \.isDockerUnverified)
        let mustClose = unresolved.contains { !$0.isDockerUnverified }
        return VStack(alignment: .leading, spacing: 3) {
            if !running.isEmpty {
                Text(verbatim: "Çalışıyor: " + running.map { blockerText($0, blocking: unresolvedSet.contains($0)) }.joined(separator: ", "))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Not a process: Docker could not be asked, so containers that bind-mount the project are unknown (F-6).
            if let dockerUnverified {
                Text(unresolvedSet.contains(dockerUnverified)
                     ? "Docker durumu doğrulanamadı: koşullu ve bağımlılık öğeleri şimdi temizlenemez, Docker yanıt verince planı yenileyin."
                     : "Docker durumu doğrulanamadı: yalnızca her zaman güvenli öğeler temizlenebilir.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mustClose {
                Text("Bunlar kapanmadan seçili öğeler temizlenemez.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private func blockerText(_ blocker: ActivityBlocker, blocking: Bool) -> String {
        if CleanupRules.isBeingStopped(blocker, stopFirst: stopFirst) { return "\(blocker.label) (durdurulacak)" }
        return blocking ? "\(blocker.label) (engelliyor)" : blocker.label
    }

    private var footer: some View {
        let totals = CleanupRules.totals(plan: plan, selections: selections)
        let total = totals.permanent + totals.trash
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Toplam: \(Formatting.size(total, partial: totals.hasPartial))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if totals.trash > 0 {
                    Text("Çöp Kutusu'nu boşaltınca \(Formatting.size(totals.trash, partial: totals.hasPartial)) boşalır")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("İptal") { store.dismissCleanup() }
                    .keyboardShortcut(.cancelAction)
                Button(stopFirst == nil ? "Temizle" : "Durdur ve Temizle") {
                    Task { await store.confirmCleanup() }
                }
                .buttonStyle(.borderedProminent)
                // No `.defaultAction`: a stray Return while the review stage appears must never start a deletion (P2-9).
                .disabled(!canConfirm)
            }
        }
        .padding(12)
    }
}

// MARK: - Kill preview -------------------------------------------------------------

/// The detail rows of a `KillPreview`, styled like the list on the confirmation card (`ConfirmationOverlay`) so both ways
/// to a kill read the same: monospaced, selectable, two lines per row, scrollable beyond a bounded height.
private struct KillPreviewList: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: DisplayText.literal(line, scalarLimit: 400))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Durdurulacak süreçlerin ayrıntıları")
    }
}

// MARK: - Entry row ----------------------------------------------------------------

private struct EntryRow: View {
    @Bindable var store: DevTidyStore
    let entry: CacheEntry
    let selection: CleanupSelection?

    private var isSelected: Bool { selection != nil }

    /// Paths shown right under the title; the rest sit behind a disclosure so a long list never pushes the sheet around.
    private static let inlinePathCount = 8

    /// Discovered rules list up to a cap; the cleaner removes only listed paths, so the rest wait for the next run.
    private var unlistedCount: Int {
        guard !entry.isContentsOnly, entry.instance == nil, let count = entry.itemCount else { return 0 }
        return max(0, count - entry.targetPaths.count)
    }

    @ViewBuilder
    private var pathList: some View {
        let paths = entry.targetPaths
        ForEach(paths.prefix(Self.inlinePathCount), id: \.self) { path in
            PathText(path: path)
                .padding(.leading, 20)
        }
        if paths.count > Self.inlinePathCount {
            DisclosureGroup("+\(paths.count - Self.inlinePathCount) yol daha") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(paths.dropFirst(Self.inlinePathCount)), id: \.self) { path in PathText(path: path) }
                }
            }
            .font(.caption)
            .padding(.leading, 20)
        }
        if unlistedCount > 0 {
            Text("\(unlistedCount) klasör daha var; bu temizlikte silinmez, yalnızca yukarıda listelenenler silinir")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle(isOn: Binding(get: { isSelected }, set: { store.setSelected(entry.id, $0) })) {
                    Text(entry.title).font(.callout.weight(.medium))
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 4)
                SizeText(bytes: entry.sizeBytes, partial: entry.sizeIsPartial)
                    .font(.callout)
            }
            pathList
            HStack(spacing: 6) {
                modeLabel
                if entry.isContentsOnly {
                    Text("Klasörün içeriği silinir, klasör kalır").font(.caption2).foregroundStyle(.secondary)
                }
                if let count = entry.itemCount, count > 1 {
                    Text("\(count) öğe").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 20)
            ForEach(entry.notes, id: \.self) { note in
                Text(note).font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
            }
            if !entry.qualifiedBecause.isEmpty {
                Text("Neden uygun: " + entry.qualifiedBecause.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if entry.safety == .optIn, let command = entry.reinstallCommand {
                Text(verbatim: "Yeniden kurulum: " + DisplayText.label(command, limit: 120) + " (ağ gerekir)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(isSelected ? 0.6 : 0.25), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    /// Always visible, so the permanent-vs-Trash decision is never implicit. Selected rows can switch.
    @ViewBuilder
    private var modeLabel: some View {
        let mode = selection?.mode ?? CleanupRules.defaultMode(for: entry, deleteConditionalPermanently: store.settings.deleteConditionalPermanently)
        if isSelected {
            Menu {
                Button(Formatting.modeLabel(.trash)) { store.setMode(entry.id, .trash) }
                Button(Formatting.modeLabel(.permanent)) { store.setMode(entry.id, .permanent) }
            } label: {
                Text(Formatting.modeLabel(mode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mode == .permanent ? Color.red : Color.green)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Silme biçimi: \(Formatting.modeLabel(mode))")
        } else {
            Text(Formatting.modeLabel(mode))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
