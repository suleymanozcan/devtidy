import Foundation
import DevTidyCore

/// Display-only formatting. Nothing here is ever parsed back.
@MainActor
enum Formatting {
    private static let cpuFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    /// Process / container memory: memory style (1024-based), like Activity Monitor.
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    /// Disk sizes (caches, reclaimed space): file style (decimal), like Finder.
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    /// Disk size with the `≥` prefix when the walk was cut short; `—` while not sized yet.
    static func size(_ value: Int64?, partial: Bool = false) -> String {
        guard let value else { return "—" }
        let text = bytes(value)
        return partial ? "≥ \(text)" : text
    }

    /// `%1,2`
    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return "%" + (cpuFormatter.string(from: NSNumber(value: percent)) ?? String(format: "%.1f", percent))
    }

    static func plainPercent(_ percent: Double) -> String {
        "%" + (percentFormatter.string(from: NSNumber(value: percent)) ?? String(format: "%.1f", percent))
    }

    /// `17 Eki 2026 14:03 (2 sa 5 dk)`: the absolute local start time and how long ago that was.
    static func startText(_ start: Date, now: Date = Date()) -> String {
        "\(startFormatter.string(from: start)) (\(uptime(now.timeIntervalSince(start))))"
    }

    private static let startFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func portRoleText(_ role: ServerDetails.PortLine.Role) -> String? {
        switch role {
        case .main: "ana"
        case .inspector: "denetleyici"
        case .ephemeral: "dahili"
        case .regular: nil
        }
    }

    static func scopeText(_ scope: BindScope) -> String {
        switch scope {
        case .loopback: "yerel"
        case .allInterfaces: "tüm arayüzler"
        case .other: "belirli adres"
        }
    }

    /// `main`, or `a1b2c3d` for a detached HEAD.
    static func branchText(_ head: GitHead) -> String {
        head.isDetached ? "\(head.label) (ayrık HEAD)" : head.label
    }

    /// `12 sa 9 dk` / `3 gün 4 sa` / `7 dk` / `20 sn`
    static func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) gün \(hours) sa" }
        if hours > 0 { return "\(hours) sa \(minutes) dk" }
        if minutes > 0 { return "\(minutes) dk" }
        return "\(total % 60) sn"
    }

    /// A path for the SCREEN: `~`-abbreviated, invisible characters replaced, bounded. Finder and the pasteboard get the real
    /// path, never this.
    static func displayPath(_ path: String) -> String {
        DisplayText.literal(tildePath(path), scalarLimit: 1_024)
    }

    /// `/Users/me/developer/x` → `~/developer/x`
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func frameworkName(_ kind: ProjectKind) -> String? {
        switch kind {
        case .next: "Next.js"
        case .vite: "Vite"
        case .nuxt: "Nuxt"
        case .svelteKit: "SvelteKit"
        case .astro: "Astro"
        case .remix: "Remix"
        case .reactRouter: "React Router"
        case .gatsby: "Gatsby"
        case .angular: "Angular"
        case .parcel: "Parcel"
        case .expo: "Expo"
        case .reactNative: "React Native"
        case .cloudflareWorkers: "Workers"
        case .node: "Node.js"
        case .laravel: "Laravel"
        case .php: "PHP"
        case .python: "Python"
        case .ruby: "Ruby"
        case .java: "Java"
        case .rust: "Rust"
        case .go: "Go"
        case .swiftPackage: "Swift"
        case .xcode: "Xcode"
        case .gradle: "Gradle"
        case .flutter: "Flutter"
        case .godot: "Godot"
        case .unknown: nil
        }
    }

    static func modeLabel(_ mode: DeleteMode) -> String {
        switch mode {
        case .permanent: "Kalıcı sil"
        case .trash: "Çöp Kutusu'na taşı"
        }
    }

    static func skipReasonText(_ reason: SkipReason) -> String {
        switch reason {
        case .rootRejected: "klasör reddedildi"
        case .notFound: "bulunamadı"
        case .symlink: "sembolik bağlantı"
        case .nameMismatch: "ad uyuşmuyor"
        case .outsideRoot: "proje dışında"
        case .crossesDevice: "başka disk"
        case .immutable: "değiştirilemez bayrağı var"
        case .trackedByGit: "git tarafından izleniyor"
        case .notIgnoredByGit: "git yok saymıyor"
        case .hasUntrackedFiles: "izlenmeyen dosyalar var"
        case .gitUnavailable: "git kullanılamıyor"
        case .blockedByActivity: "çalışan süreç var"
        case .identityChanged: "klasör değişti"
        case .notInCatalog: "katalogda yok"
        case .notSelected: "seçilmedi"
        case .emptyAlready: "zaten boş"
        case .containsRepository: "içinde başka bir git deposu var"
        case .scanIncomplete: "içinde depo olmadığı doğrulanamadı"
        case .packageOutput: "paketin yayın çıktısı olabilir"
        }
    }

    static func statusText(_ status: CleanupStatus) -> String {
        switch status {
        case .deleted(let bytes): "Silindi \(Self.bytes(bytes))"
        case .movedToTrash(let bytes): "Çöp Kutusu'na taşındı \(Self.bytes(bytes))"
        case .skipped(let reason): "Atlandı: \(skipReasonText(reason))"
        case .failed(let message): "Hata: \(message)"
        }
    }
}
