import SwiftUI
import DevTidyCore

struct BuildsTab: View {
    let store: DevTidyStore

    private var roots: [String] { store.effectiveScanRoots }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Taranan klasörler: " + roots.map(Formatting.displayPath).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(roots.map(Formatting.displayPath).joined(separator: "\n"))
            Spacer(minLength: 4)
            Button("Yeniden Tara") { Task { await store.scanBuilds() } }
                .controlSize(.small)
                .disabled(isScanning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isScanning: Bool {
        if case .scanning = store.buildsScan { return true }
        return false
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.buildsScan {
        case .idle:
            EmptyState(title: "Derlemeler henüz taranmadı", systemImage: "hammer")
        case .failed(let message):
            EmptyState(title: "Tarama başarısız", message: message, systemImage: "exclamationmark.triangle")
        case .scanning(let directories):
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Taranıyor… (\(directories) klasör)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                reportList
            }
        case .finished(let summary):
            VStack(spacing: 0) {
                notices(for: summary)
                if store.buildReports.isEmpty && store.orphanedDerivedData.isEmpty {
                    EmptyState(title: "Temizlenebilir önbellek bulunamadı", systemImage: "checkmark.circle")
                } else {
                    reportList
                }
            }
        }
    }

    @ViewBuilder
    private func notices(for summary: BuildsScanSummary) -> some View {
        if summary.truncated {
            notice("Tarama sınırına ulaşıldı", systemImage: "exclamationmark.circle", color: .orange)
        }
        ForEach(summary.permissionDeniedRoots, id: \.self) { root in
            notice("\(Formatting.displayPath(root)) için izin gerekli — Sistem Ayarları › Gizlilik ve Güvenlik › Dosyalar ve Klasörler",
                   systemImage: "lock", color: .orange)
        }
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
            Text(verbatim: text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var reportList: some View {
        VStack(spacing: 0) {
            ForEach(store.buildReports) { report in
                ReportRow(store: store, report: report)
                Divider().padding(.leading, 12)
            }
            if !store.orphanedDerivedData.isEmpty {
                orphanRow
            }
        }
    }

    private var orphanRow: some View {
        let total = store.orphanedDerivedData.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let partial = store.orphanedDerivedData.contains { $0.sizeIsPartial || $0.sizeBytes == nil }
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sahipsiz DerivedData (\(store.orphanedDerivedData.count), \(Formatting.size(total, partial: partial)))")
                    .font(.subheadline.weight(.semibold))
                Text("Projesi silinmiş Xcode derleme klasörleri")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Temizle…") { Task { await store.beginCleanOrphanedDerivedData() } }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

private struct ReportRow: View {
    let store: DevTidyStore
    let report: ProjectCacheReport

    private var isRunning: Bool { store.isRunning(report) }
    private var partial: Bool { report.entries.contains { $0.sizeIsPartial || $0.sizeBytes == nil } }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: DisplayText.label(report.project.name)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isRunning { Chip(text: "Çalışıyor", systemImage: "play.fill") }
                }
                HStack(spacing: 6) {
                    if let group = report.project.groupName {
                        Text(verbatim: DisplayText.label(group)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(report.entries.count) öğe").font(.caption).foregroundStyle(.secondary)
                }
                PathText(path: Formatting.tildePath(report.project.root)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            SizeText(bytes: report.knownBytes, partial: partial)
                .font(.callout.weight(.medium))
            Button("Temizle…") {
                Task { await store.beginClean(projectRoot: report.project.root) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(isRunning ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }
}
