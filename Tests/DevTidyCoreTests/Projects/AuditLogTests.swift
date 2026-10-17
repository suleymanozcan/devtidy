import Foundation
import Darwin
import Testing
@testable import DevTidyCore

@Suite("AuditLog (§5.7, D12)")
struct AuditLogTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ subject: String, result: String = "deleted", detail: [String: String] = [:]) -> AuditEvent {
        AuditEvent(time: fixedDate, kind: .cleanup, subject: subject, result: result, detail: detail)
    }

    private func lines(_ path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func mode(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode & 0o777 : nil
    }

    @Test func isWritableCreatesDirectoryAndFileWithPrivateModes() async throws {
        let t = try S2TempDir(createProject: false)
        defer { t.cleanup() }
        let url = URL(fileURLWithPath: t.root + "/logs/DevTidy/cleanup.log")
        let log = AuditLog(fileURL: url)
        #expect(await log.isWritable())
        #expect(t.exists(url.path))
        #expect(mode(url.path) == 0o600)
        #expect(mode(t.root + "/logs/DevTidy") == 0o700)
        #expect(await log.isWritable(), "idempotent")
    }

    @Test func appendedLinesParseBackAndAreCompact() async throws {
        let t = try S2TempDir(createProject: false)
        defer { t.cleanup() }
        let url = URL(fileURLWithPath: t.root + "/logs/cleanup.log")
        let log = AuditLog(fileURL: url)
        let e1 = event("/Users/x/proj/.next", detail: ["rule": "next.cache", "class": "A", "bytes": "123", "packageDir": "/Users/x/proj"])
        let e2 = AuditEvent(time: fixedDate, kind: .terminate, subject: "pid:123:1700000000", result: "ok", detail: ["signals": "TERM"])
        await log.record(e1)
        await log.record(e2)
        let ls = lines(url.path)
        #expect(ls.count == 2)
        #expect(try decoder().decode(AuditEvent.self, from: Data(ls[0].utf8)) == e1)
        #expect(try decoder().decode(AuditEvent.self, from: Data(ls[1].utf8)) == e2)
        #expect(ls[0].contains("\"subject\":\"/Users/x/proj/.next\""), "slashes are not escaped")
        #expect(!ls[0].contains("\\/"))
        #expect(!ls[0].contains("\n"))
        #expect(ls[0].contains("\"time\":\"2023-11-14T22:13:20Z\""), "ISO-8601 time")
        // sorted keys ⇒ deterministic: detail < kind < result < subject < time
        let order = ["\"detail\"", "\"kind\"", "\"result\"", "\"subject\"", "\"time\""].compactMap { ls[0].range(of: $0)?.lowerBound }
        #expect(order == order.sorted() && order.count == 5)
        let raw = try #require(FileManager.default.contents(atPath: url.path))
        #expect(raw.last == 0x0A)
        // a second AuditLog instance appends to the same file
        await AuditLog(fileURL: url).record(event("/another"))
        #expect(lines(url.path).count == 3)
    }

    @Test func rotatesAtTheThresholdKeepingFiveGenerations() async throws {
        let t = try S2TempDir(createProject: false)
        defer { t.cleanup() }
        let url = URL(fileURLWithPath: t.root + "/logs/cleanup.log")
        let log = AuditLog(fileURL: url, maxBytes: 1_500)
        let pad = String(repeating: "p", count: 200)
        let total = 60
        for i in 0..<total { await log.record(event("/subject/\(i)", detail: ["pad": pad])) }
        let generations = (1...AuditLog.retainedRotations).map { url.path + ".\($0)" }
        #expect(generations.allSatisfy { t.exists($0) }, "the file exceeded its threshold many times: every generation is in use")
        #expect(!t.exists(url.path + ".\(AuditLog.retainedRotations + 1)"), "the oldest generation is dropped, never kept as .6")
        let current = lines(url.path)
        #expect(!current.isEmpty)
        // every surviving line is intact; generations are ordered newest (.1) to oldest (.5); the newest event is in the CURRENT file
        let all = generations.reversed().flatMap { lines($0) } + current
        for l in all { #expect((try? decoder().decode(AuditEvent.self, from: Data(l.utf8))) != nil) }
        #expect(current.last?.contains("/subject/\(total - 1)\"") == true)
        let indices = all.compactMap { l -> Int? in
            guard let e = try? decoder().decode(AuditEvent.self, from: Data(l.utf8)) else { return nil }
            return Int(e.subject.dropFirst("/subject/".count))
        }
        #expect(indices == indices.sorted() && Set(indices).count == indices.count, "history reads in order without gaps inside a generation")
        // 60 events ≫ what six ~1.5 KB files hold: the first events are gone, the most recent ones are all there
        #expect(!indices.contains(0))
        #expect(indices.count >= 25)
        #expect(Set(indices.suffix(20)) == Set((total - 20)..<total))
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size <= 1_500 + 600, "the live file stays near the threshold (size \(size))")
    }

    @Test func unwritableDirectoryReportsNotWritableAndRecordNeverThrows() async throws {
        let t = try S2TempDir(createProject: false)
        defer { t.cleanup() }
        let ro = t.root + "/readonly"
        try t.mkdir(ro)
        #expect(chmod(ro, 0o555) == 0)
        defer { chmod(ro, 0o755) }
        let log = AuditLog(fileURL: URL(fileURLWithPath: ro + "/sub/cleanup.log"))
        #expect(await log.isWritable() == false)
        await log.record(event("/x"))          // must not crash or throw
        #expect(await log.recordDurably(event("/x")) == false, "an unwritable log reports that the line is NOT in the file")
        #expect(!t.exists(ro + "/sub"))

        // the "directory" is actually a regular file
        try t.write(t.root + "/notadir", "x")
        let blocked = AuditLog(fileURL: URL(fileURLWithPath: t.root + "/notadir/cleanup.log"))
        #expect(await blocked.isWritable() == false)
    }

    /// F-5: the cleaner stops when this is false, so it must be true exactly when the line reached the file.
    @Test func recordDurablyIsTrueExactlyWhenTheLineIsInTheFile() async throws {
        let t = try S2TempDir(createProject: false)
        defer { t.cleanup() }
        let url = URL(fileURLWithPath: t.root + "/logs/cleanup.log")
        let log = AuditLog(fileURL: url)
        #expect(await log.recordDurably(event("/ok")) == true)
        #expect(lines(url.path).count == 1)
        // the log directory turns into a plain file mid-run: the append fails and is reported
        try FileManager.default.removeItem(atPath: t.root + "/logs")
        try t.write(t.root + "/logs", "now a file")
        #expect(await log.recordDurably(event("/lost")) == false)
        #expect(!(FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? "").contains("/lost"))
    }

    @Test func concurrentRecordsNeverInterleaveALine() async throws {
        let t = try S2TempDir(createProject: false)
        defer { t.cleanup() }
        let url = URL(fileURLWithPath: t.root + "/logs/cleanup.log")
        let log = AuditLog(fileURL: url)
        let big = String(repeating: "z", count: 3_000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { await log.record(AuditEvent(time: Date(timeIntervalSince1970: 1_700_000_000), kind: .cleanup,
                                                           subject: "/s/\(i)", result: "deleted", detail: ["pad": big, "i": String(i)])) }
            }
        }
        let ls = lines(url.path)
        #expect(ls.count == 200)
        var subjects = Set<String>()
        for l in ls {
            let e = try decoder().decode(AuditEvent.self, from: Data(l.utf8))
            #expect(e.detail["pad"] == big, "a line was torn")
            subjects.insert(e.subject)
        }
        #expect(subjects.count == 200)
    }

    @Test func allEventKindsRoundTrip() async throws {
        let t = try S2TempDir(createProject: false)
        defer { t.cleanup() }
        let url = URL(fileURLWithPath: t.root + "/logs/cleanup.log")
        let log = AuditLog(fileURL: url)
        let kinds: [AuditEvent.Kind] = [.cleanup, .terminate, .dockerContainer, .dockerCompose, .dockerPrune]
        for k in kinds { await log.record(AuditEvent(time: fixedDate, kind: k, subject: "s", result: "ok", detail: [:])) }
        let decoded = try lines(url.path).map { try decoder().decode(AuditEvent.self, from: Data($0.utf8)).kind }
        #expect(decoded == kinds)
    }
}
