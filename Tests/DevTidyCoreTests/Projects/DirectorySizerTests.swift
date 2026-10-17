import Foundation
import Darwin
import Testing
@testable import DevTidyCore

@Suite("DirectorySizer (R21)")
struct DirectorySizerTests {
    @Test func countsAllocatedBlocksAndFiles() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let tree = t.root + "/tree"
        try t.write(tree + "/a.bin", String(repeating: "a", count: 10_000))
        try t.write(tree + "/sub/b.bin", "bb")
        let r = DirectorySizer.size(of: tree)
        #expect(!r.isPartial)
        #expect(r.bytes > 0)
        #expect(r.bytes % 512 == 0, "allocated bytes are st_blocks * 512")
        #expect(r.itemCount == 2)
    }

    @Test func hardLinkIsCountedOnce() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let plain = t.root + "/plain"
        let linked = t.root + "/linked"
        let payload = String(repeating: "h", count: 64 * 1024)
        try t.write(plain + "/x/a.bin", payload)
        try t.write(linked + "/x/a.bin", payload)
        #expect(link(linked + "/x/a.bin", linked + "/x/b.bin") == 0)
        #expect(link(linked + "/x/a.bin", linked + "/c.bin") == 0)
        let without = DirectorySizer.size(of: plain)
        let with = DirectorySizer.size(of: linked)
        #expect(without.bytes > 0)
        #expect(with.bytes == without.bytes, "three names, one inode, one allocation")
    }

    @Test func symlinksAreMeasuredAsThemselvesAndNeverFollowed() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let big = t.root + "/big"
        try t.write(big + "/huge.bin", String(repeating: "z", count: 2 * 1024 * 1024))
        let tree = t.root + "/tree"
        try t.write(tree + "/small.txt", "s")
        try t.symlink(tree + "/dirlink", to: big)
        try t.symlink(tree + "/filelink", to: big + "/huge.bin")
        let bigSize = DirectorySizer.size(of: big).bytes
        let treeSize = DirectorySizer.size(of: tree)
        #expect(bigSize >= 2 * 1024 * 1024)
        #expect(treeSize.bytes < 256 * 1024, "the large directory behind the symlinks must not be counted")
        #expect(!treeSize.isPartial)
        // a symlink as the ROOT is not followed either
        let viaLink = DirectorySizer.size(of: tree + "/dirlink")
        #expect(viaLink.bytes < 256 * 1024)
    }

    @Test func unreadableSubdirectoryMakesTheFigurePartial() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let tree = t.root + "/tree"
        try t.write(tree + "/ok.txt", "ok")
        try t.write(tree + "/locked/inner.txt", "hidden")
        #expect(chmod(tree + "/locked", 0o000) == 0)
        defer { chmod(tree + "/locked", 0o755) }
        let r = DirectorySizer.size(of: tree)
        #expect(r.isPartial)
        #expect(r.bytes > 0)
    }

    @Test func missingPathIsPartialAndEmpty() {
        let r = DirectorySizer.size(of: "/definitely/not/here/devtidy-s2")
        #expect(r.isPartial)
        #expect(r.bytes == 0)
    }

    @Test func entryBoundMakesTheFigurePartial() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let tree = t.root + "/tree"
        for i in 0..<50 { try t.write(tree + "/f\(i).txt", "x") }
        let bounded = DirectorySizer.size(of: tree, bounds: .init(maxEntries: 10, maxSeconds: 10))
        #expect(bounded.isPartial)
        let full = DirectorySizer.size(of: tree)
        #expect(!full.isPartial)
        #expect(full.bytes > bounded.bytes)
    }

    @Test func aCancelledWalkReportsAPartialFigure() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let tree = t.root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        for d in 0..<4 {
            try FileManager.default.createDirectory(atPath: tree + "/d\(d)", withIntermediateDirectories: true)
            for i in 0..<2_500 { FileManager.default.createFile(atPath: tree + "/d\(d)/f\(i)", contents: nil) }
        }
        let task = Task { await DirectorySizer.sizeOffActor(of: tree) }
        task.cancel()
        let r = await task.value
        #expect(r.isPartial, "a cancelled walk reports a partial figure")
    }
}
