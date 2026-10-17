import Foundation
import Darwin

/// JSON-lines audit trail at `~/Library/Logs/DevTidy/cleanup.log` (design §5.7). Also receives `terminate` and `docker*` events.
/// `record` never throws; `recordDurably` reports whether the line reached the file. A cleanup must not start when
/// `isWritable()` is false and stops as soon as a line cannot be written (D12).
public actor AuditLog: AuditLogging {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Logs/DevTidy/cleanup.log")
    }

    static let defaultMaxBytes = 1 << 20

    private let fileURL: URL
    private let maxBytes: Int
    private let encoder: JSONEncoder

    public init(fileURL: URL = AuditLog.defaultURL) {
        self.init(fileURL: fileURL, maxBytes: AuditLog.defaultMaxBytes)
    }

    /// Test seam: a small rotation threshold.
    init(fileURL: URL, maxBytes: Int) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = e
    }

    /// Creates the directory (0700) and file (0600) if needed and opens for append.
    public func isWritable() async -> Bool {
        let fd = openForAppend()
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public func record(_ event: AuditEvent) async {
        _ = await recordDurably(event)
    }

    /// One append of one JSON line. `false` = the line is NOT (fully) in the file: encode, open or write failed.
    public func recordDurably(_ event: AuditEvent) async -> Bool {
        guard let json = try? encoder.encode(event) else { return false }
        var line = json
        line.append(0x0A)
        rotateIfNeeded()
        let fd = openForAppend()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // One `write` on an O_APPEND descriptor; a short write (rare) is continued so a line is never truncated.
        return line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    // MARK: Plumbing

    private func openForAppend() -> Int32 {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    }

    /// How many rotated generations are kept (`.1` newest … `.5` oldest). Every acted target writes two lines (intent +
    /// result), so a single large cleanup must not push the previous history out of the single `.1` file.
    static let retainedRotations = 5

    /// Over `maxBytes` ⇒ the generations shift up by one (`.n` → `.n+1`, the oldest is dropped) and the live file becomes `.1`.
    private func rotateIfNeeded() {
        var st = stat()
        guard lstat(fileURL.path, &st) == 0, Int(st.st_size) > maxBytes else { return }
        let base = fileURL.path
        unlink(base + ".\(Self.retainedRotations)")
        for generation in stride(from: Self.retainedRotations - 1, through: 1, by: -1) {
            rename(base + ".\(generation)", base + ".\(generation + 1)")
        }
        rename(base, base + ".1")
    }
}
