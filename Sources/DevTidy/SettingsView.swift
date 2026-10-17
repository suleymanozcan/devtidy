import SwiftUI
import AppKit
import DevTidyCore

struct SettingsView: View {
    @Bindable var store: DevTidyStore

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettings(store: store)
                    .tabItem { Label("Genel", systemImage: "gearshape") }
                ScanSettings(store: store)
                    .tabItem { Label("Tarama", systemImage: "folder.badge.gearshape") }
                IdleSettings(store: store)
                    .tabItem { Label("Boşta", systemImage: "moon.zzz") }
                DockerSettings(store: store)
                    .tabItem { Label("Docker", systemImage: "shippingbox") }
            }
            Divider()
            HStack {
                Button("Denetim günlüğünü Finder'da göster") { revealAuditLog() }
                    .controlSize(.small)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 480, height: 380)
    }

    private func revealAuditLog() {
        let url = AuditLog.defaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var store: DevTidyStore
    var body: some View {
        Form {
            Toggle("Menü çubuğunda bellek kullanımını göster", isOn: $store.settings.menuBarShowsMemory)
            Toggle("Diğer dinleyicileri göster", isOn: $store.settings.showOtherListeners)
            Text("Araçlar, uygulamalar ve sistem süreçleri tarafından açılan portlar “Diğer dinleyiciler” altında listelenir.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Sayfa başlığını oku (localhost'a tek GET isteği)", isOn: $store.settings.fetchPageTitles)
            Text("Sunucular sekmesi açıkken, her sunucu için yalnızca kendi 127.0.0.1 / ::1 adresine bir kez `GET /` gönderilir ve sayfanın `<title>` değeri satır başlığı olarak gösterilir. Başka bir makineye istek gitmez; çerez ve önbellek kullanılmaz. Kapatınca hiç istek gönderilmez.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("İstek sunucunun kendi günlüğünde görünür; Next.js gibi çalışırken derleyen sunucularda ilk istek sayfa derlemesini başlatabilir. Bu yüzden boştaki sunuculara istek gönderilmez (etkinleşince okunur) ve okuma sırasındaki CPU ile bağlantı, sunucuyu “boşta” saymayı sıfırlamaz.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ScanSettings: View {
    @Bindable var store: DevTidyStore
    @State private var selectedRoot: String?

    var body: some View {
        Form {
            Section("Taranan klasörler") {
                List(selection: $selectedRoot) {
                    ForEach(store.effectiveScanRoots, id: \.self) { root in
                        Text(verbatim: Formatting.tildePath(root))
                            .font(.system(.body, design: .monospaced))
                            .tag(root)
                    }
                }
                .frame(height: 90)
                HStack {
                    Button { addRoots() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Klasör ekle")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Seçili klasörü kaldır")
                        .disabled(selectedRoot == nil || store.settings.scanRoots.isEmpty)
                    Spacer()
                }
            }
            Stepper("Tarama derinliği: \(store.settings.buildsMaxDepth)", value: $store.settings.buildsMaxDepth, in: 2...6)
            Toggle("node_modules ve diğer bağımlılıkları listele", isOn: $store.settings.includeDependencies)
            Text("Yeniden kurulum ağ gerektirir")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func addRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Ekle"
        guard panel.runModal() == .OK else { return }
        // The first custom root keeps the default ones visible, so adding never silently drops a probed default folder.
        var roots = store.settings.scanRoots.isEmpty ? store.effectiveScanRoots : store.settings.scanRoots
        for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
        store.settings.scanRoots = roots
    }

    private func removeSelected() {
        guard let selectedRoot else { return }
        store.settings.scanRoots.removeAll { $0 == selectedRoot }
        self.selectedRoot = nil
    }
}

private struct IdleSettings: View {
    @Bindable var store: DevTidyStore
    var body: some View {
        Form {
            Stepper("Sunucu: \(store.settings.serverIdleMinutes) dk sessizse boşta say",
                    value: $store.settings.serverIdleMinutes, in: 5...480, step: 5)
            Stepper("Konteyner: \(store.settings.containerIdleMinutes) dk sessizse boşta say",
                    value: $store.settings.containerIdleMinutes, in: 1...480, step: 1)
            Stepper("CPU eşiği: \(Formatting.plainPercent(store.settings.idleCPUPercent))",
                    value: $store.settings.idleCPUPercent, in: 0.5...20, step: 0.5)
            Text("Bir sunucu, CPU eşiğinin altındaysa ve açık bağlantısı yoksa; bir konteyner yalnızca CPU eşiğinin altındaysa sessiz sayılır. DevTidy'nin sayfa başlığı için gönderdiği istek (ve sonrasındaki birkaç saniye) etkinlik sayılmaz.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct DockerSettings: View {
    @Bindable var store: DevTidyStore

    private var socketPath: Binding<String> {
        Binding(
            get: { store.settings.dockerSocketOverride ?? "" },
            set: { store.settings.dockerSocketOverride = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Form {
            TextField("Docker soket yolu", text: socketPath, prompt: Text("otomatik"))
                .font(.system(.body, design: .monospaced))
            Text("Boş bırakılırsa soket otomatik bulunur (~/.docker/run/docker.sock, /var/run/docker.sock, Colima, OrbStack). Bir yol girilirse yalnızca o soket kullanılır; bulunamazsa hata gösterilir, başka bir Docker'a geçilmez.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
