import Foundation
import Darwin
import Testing
@testable import DevTidyCore

private final class S2Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite("SafeFS (D3–D6, R5–R9, R18)")
struct SafeFSTests {
    private func dev(_ path: String) -> dev_t { PathPolicy.device(of: path) ?? 0 }

    private func withParent<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
        let fd = SafeFS.openDirAbsolute(path)
        #expect(fd >= 0, "cannot open \(path)")
        defer { if fd >= 0 { close(fd) } }
        return try body(fd)
    }

    @Test func removeTreeRemovesNestedTreesWithoutFollowingInternalSymlinks() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        let outside = t.root + "/outside"
        try t.write(work + "/victim/a/b/c.txt", "c")
        try t.write(work + "/victim/a/d.txt", "d")
        try t.write(work + "/victim/top.txt", "t")
        try t.write(outside + "/precious.txt", "keep me")
        try t.write(outside + "/sub/deep.txt", "keep me too")
        try t.symlink(work + "/victim/a/dirlink", to: outside)
        try t.symlink(work + "/victim/filelink", to: outside + "/precious.txt")
        try t.symlink(work + "/victim/dangling", to: t.root + "/does-not-exist")
        try withParent(work) { fd in
            try SafeFS.removeTree(parentFD: fd, name: "victim", rootDev: dev(work))
        }
        #expect(!t.exists(work + "/victim"))
        #expect(t.read(outside + "/precious.txt") == "keep me")
        #expect(t.read(outside + "/sub/deep.txt") == "keep me too")
        #expect(t.exists(work))
    }

    /// F-7b: the depth-0 directory must be the one that was validated (`(dev, ino)`); a swap in between removes nothing.
    @Test func removeTreeRefusesADirectoryThatIsNotTheValidatedOne() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/victim/old.txt", "old")
        let validated = try #require(SafeFS.lstatAbsolute(work + "/victim")).identity

        // control: the right identity removes the tree
        try t.write(work + "/control/c.txt", "c")
        let controlIdentity = try #require(SafeFS.lstatAbsolute(work + "/control")).identity
        try withParent(work) { fd in
            try SafeFS.removeTree(parentFD: fd, name: "control", rootDev: dev(work), expected: controlIdentity)
        }
        #expect(!t.exists(work + "/control"))

        // swap: the validated directory moves aside and a new one (new inode) takes its name
        try FileManager.default.moveItem(atPath: work + "/victim", toPath: work + "/victim-aside")
        try t.write(work + "/victim/new.txt", "new")
        var failure: SafeFSFailure?
        try withParent(work) { fd in
            do { try SafeFS.removeTree(parentFD: fd, name: "victim", rootDev: dev(work), expected: validated) } catch let f as SafeFSFailure { failure = f }
        }
        #expect(failure == .identityChanged)
        #expect(failure?.text.isEmpty == false)
        #expect(t.read(work + "/victim/new.txt") == "new", "the directory that was swapped in is untouched")
        #expect(t.read(work + "/victim-aside/old.txt") == "old")
    }

    @Test func readOnlyDirectoryFailsWithAReportedErrno() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/victim/locked/file.txt", "x")
        try t.write(work + "/victim/free/file.txt", "x")
        #expect(chmod(work + "/victim/locked", 0o555) == 0)
        defer { chmod(work + "/victim/locked", 0o755) }
        var failure: SafeFSFailure?
        try withParent(work) { fd in
            do { try SafeFS.removeTree(parentFD: fd, name: "victim", rootDev: dev(work)) } catch let f as SafeFSFailure { failure = f }
        }
        guard case .errno(let code)? = failure else { Issue.record("expected an errno failure, got \(String(describing: failure))"); return }
        #expect(code == EACCES || code == EPERM)
        #expect(failure?.text.isEmpty == false)
        #expect(t.exists(work + "/victim/locked/file.txt"), "no chmod escalation")
        #expect(!t.exists(work + "/victim/free/file.txt"), "siblings are still attempted")
    }

    @Test func refusesToCrossADevice() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/victim/a/f.txt", "x")
        let wrongDev = dev(work) &+ 1
        var failure: SafeFSFailure?
        try withParent(work) { fd in
            do { try SafeFS.removeTree(parentFD: fd, name: "victim", rootDev: wrongDev) } catch let f as SafeFSFailure { failure = f }
        }
        #expect(failure == .crossesDevice)
        #expect(t.exists(work + "/victim/a/f.txt"), "nothing is deleted when the device differs")
    }

    @Test func enotemptyIsRetriedOnceThenReported() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        // A writer sneaks a file into the top directory right before the first rmdir: the retry removes it.
        try t.write(work + "/v1/a.txt", "x")
        try withParent(work) { fd in
            try SafeFS.removeTree(parentFD: fd, name: "v1", rootDev: dev(work)) { attempt in
                if attempt == 0 { FileManager.default.createFile(atPath: work + "/v1/late.txt", contents: Data("late".utf8)) }
            }
        }
        #expect(!t.exists(work + "/v1"))
        // A writer that never stops: exactly one retry, then ENOTEMPTY is reported.
        try t.write(work + "/v2/a.txt", "x")
        var hookCalls = 0
        var failure: SafeFSFailure?
        try withParent(work) { fd in
            do {
                try SafeFS.removeTree(parentFD: fd, name: "v2", rootDev: dev(work)) { attempt in
                    hookCalls += 1
                    FileManager.default.createFile(atPath: work + "/v2/late-\(attempt).txt", contents: Data("late".utf8))
                }
            } catch let f as SafeFSFailure { failure = f }
        }
        #expect(failure == .errno(ENOTEMPTY))
        #expect(hookCalls == 2)
        #expect(t.exists(work + "/v2"))
    }

    @Test func concurrentWriterNeverCausesAnythingButENOTEMPTY() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        for i in 0..<300 { try t.write(work + "/busy/d\(i % 10)/f\(i).txt", "x") }
        let stop = S2Flag()
        let done = DispatchSemaphore(value: 0)
        let writerDir = work + "/busy"
        DispatchQueue.global().async {
            var n = 0
            while !stop.isSet && n < 400 {
                _ = FileManager.default.createFile(atPath: writerDir + "/w\(n).txt", contents: Data("w".utf8))
                n += 1
                usleep(200)
            }
            done.signal()
        }
        var failure: SafeFSFailure?
        try withParent(work) { fd in
            do { try SafeFS.removeTree(parentFD: fd, name: "busy", rootDev: dev(work)) } catch let f as SafeFSFailure { failure = f }
        }
        stop.set()
        done.wait()
        if let f = failure { #expect(f == .errno(ENOTEMPTY), "unexpected failure \(f)") }
        #expect(t.exists(work))
    }

    @Test func caseMismatchIsRefused() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/build/out.txt", "x")
        let rd = dev(work)
        let result = SafeFS.openTarget(parent: work, name: "Build", expect: .directory, rootDev: rd)
        switch result {
        case .skip(let reason): #expect(reason == .nameMismatch || reason == .notFound, "\(reason)")
        case .ok(let fd, _): close(fd); Issue.record("a case-mismatched name must never be accepted")
        }
        if case .ok(let fd, _) = SafeFS.openTarget(parent: work, name: "build", expect: .directory, rootDev: rd) { close(fd) } else {
            Issue.record("the exact name must be accepted")
        }
    }

    @Test func symlinkedParentAndSymlinkedTargetAreRefused() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/real/victim/f.txt", "x")
        try t.symlink(work + "/link", to: work + "/real")
        try t.write(t.root + "/elsewhere/target/f.txt", "x")
        try t.symlink(work + "/linkdir", to: t.root + "/elsewhere/target")
        let rd = dev(work)

        // a symlink at an intermediate component of the parent path
        let linkFD = SafeFS.openDirAbsolute(work + "/link")
        let linkErrno = errno
        if linkFD >= 0 { close(linkFD) }
        #expect(linkFD < 0)
        #expect(linkErrno == ELOOP)
        if case .skip(let r) = SafeFS.openTarget(parent: work + "/link", name: "victim", expect: .directory, rootDev: rd) {
            #expect(r == .symlink)
        } else { Issue.record("symlinked parent must be refused") }
        #expect(t.exists(work + "/real/victim/f.txt"))

        // a symlink as the target itself is skipped, never unlinked
        if case .skip(let r) = SafeFS.openTarget(parent: work, name: "linkdir", expect: .directory, rootDev: rd) {
            #expect(r == .symlink)
        } else { Issue.record("symlink target must be refused") }
        #expect(t.isSymlink(work + "/linkdir"))
        var failure: SafeFSFailure?
        try withParent(work) { fd in
            do { try SafeFS.removeTree(parentFD: fd, name: "linkdir", rootDev: rd) } catch let f as SafeFSFailure { failure = f }
        }
        guard case .notDirectory? = failure else { Issue.record("removeTree must refuse a symlink leaf, got \(String(describing: failure))"); return }
        #expect(t.isSymlink(work + "/linkdir"), "the link itself survives")
        #expect(t.exists(t.root + "/elsewhere/target/f.txt"), "the destination survives")
    }

    @Test func typeMismatchAndImmutableFlagsAreSkipped() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/file.txt", "x")
        try t.mkdir(work + "/dir")
        let rd = dev(work)
        if case .skip(let r) = SafeFS.openTarget(parent: work, name: "file.txt", expect: .directory, rootDev: rd) {
            #expect(r == .notFound)
        } else { Issue.record("a file is not a directory target") }
        if case .skip(let r) = SafeFS.openTarget(parent: work, name: "dir", expect: .regularFile, rootDev: rd) {
            #expect(r == .notFound)
        } else { Issue.record("a directory is not a file target") }
        if case .skip(let r) = SafeFS.openTarget(parent: work, name: "missing", expect: .directory, rootDev: rd) {
            #expect(r == .notFound)
        } else { Issue.record("missing target") }
        // D6: UF_IMMUTABLE ⇒ skip, never chflags
        let uchg: UInt32 = 0x2
        if chflags(work + "/dir", uchg) == 0 {
            defer { chflags(work + "/dir", 0) }
            if case .skip(let r) = SafeFS.openTarget(parent: work, name: "dir", expect: .directory, rootDev: rd) {
                #expect(r == .immutable)
            } else { Issue.record("immutable directory must be skipped") }
            #expect(SafeFS.lstatAbsolute(work + "/dir")?.hasProtectedFlags == true, "DevTidy never clears flags")
        }
    }

    @Test func enumerateSkipsDotEntriesAndReportsTypes() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/a.txt")
        try t.mkdir(work + "/sub")
        try t.symlink(work + "/ln", to: work + "/sub")
        let fd = SafeFS.openDirAbsolute(work)
        #expect(fd >= 0)
        defer { close(fd) }
        let entries = try #require(SafeFS.enumerate(dirFD: fd))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.stat) })
        #expect(Set(byName.keys) == ["a.txt", "sub", "ln"])
        #expect(byName["a.txt"]?.isRegularFile == true)
        #expect(byName["sub"]?.isDirectory == true)
        #expect(byName["ln"]?.isSymlink == true, "enumerate never follows")
        #expect(SafeFS.directoryContains(dirFD: fd, name: "sub"))
        #expect(!SafeFS.directoryContains(dirFD: fd, name: "SUB"))
    }

    @Test func smallManifestReadsRefuseSymlinksAndOversizeFiles() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/ok.json", "{\"a\":1}")
        try t.write(work + "/big.json", String(repeating: "x", count: 4096))
        try t.symlink(work + "/link.json", to: work + "/ok.json")
        #expect(SafeFS.readSmallFile(work + "/ok.json").map { String(decoding: $0, as: UTF8.self) } == "{\"a\":1}")
        #expect(SafeFS.readSmallFile(work + "/big.json", maxBytes: 1024) == nil)
        #expect(SafeFS.readSmallFile(work + "/link.json") == nil)
        #expect(SafeFS.readSmallFile(work + "/missing.json") == nil)
        #expect(SafeFS.readSmallFile(work) == nil)
    }

    /// Security F3-5: `O_NOFOLLOW` covers only the last component, so a file reached through a symlinked PARENT used to be
    /// read. The `gitdir:` target of a worktree pointer is free text, which made that reachable from repository data.
    @Test func smallFileReadsRefuseASymlinkAtAnyComponentOfTheParent() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/real/dir/HEAD", "ref: refs/heads/main")
        try t.symlink(work + "/alias", to: work + "/real")                 // a symlink in the middle of the path
        try t.symlink(work + "/dirlink", to: work + "/real/dir")           // a symlink as the immediate parent

        let direct = try #require(SafeFS.readSmallFile(work + "/real/dir/HEAD"))
        #expect(String(decoding: direct, as: UTF8.self) == "ref: refs/heads/main", "the file itself is readable")
        #expect(SafeFS.readSmallFile(work + "/alias/dir/HEAD") == nil)
        #expect(SafeFS.readSmallFile(work + "/dirlink/HEAD") == nil)
        #expect(SafeFS.readSmallFile(work + "/real/../real/dir/HEAD") != nil, "dot-dot is lexical, not a symlink")
    }

    @Test func smallFileReadsNeedAnAbsolutePathToARegularFile() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let work = t.root + "/work"
        try t.write(work + "/ok.json", "{}")
        #expect(SafeFS.readSmallFile("work/ok.json") == nil, "a relative path is never resolved against the working directory")
        #expect(SafeFS.readSmallFile(work + "/ok.json/") == nil)
        #expect(SafeFS.readSmallFile(work + "/.") == nil)
        #expect(SafeFS.readSmallFile("") == nil)
        #expect(SafeFS.readSmallFile("/") == nil)
    }
}
