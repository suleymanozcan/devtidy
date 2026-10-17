import Foundation
import Testing
@testable import DevTidyCore

@Suite("PathPolicy (R1/R2/R4, D2)")
struct PathPolicyTests {
    @Test func depthRulesFollowR1() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let policy = PathPolicy(homeDirectory: t.home)
        #expect(policy.depthBelowHome(t.home) == 0)
        #expect(policy.depthBelowHome(t.home + "/dev") == 1)
        #expect(policy.depthBelowHome(t.project) == 2)
        #expect(policy.depthBelowHome("/elsewhere/x") == nil)
        #expect(!policy.passesRootDepthAndDenyGate(t.home))
        #expect(!policy.passesRootDepthAndDenyGate(t.home + "/dev"))
        #expect(policy.passesRootDepthAndDenyGate(t.project))
        #expect(!policy.passesRootDepthAndDenyGate("/elsewhere/x/y"))
    }

    @Test func denyRootsAreRejectedEvenAtDepthTwoOrMore() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let policy = PathPolicy(homeDirectory: t.home)
        for rel in [".ssh/x", ".ssh/x/y", "Library/x", "Library/Developer/Xcode/DerivedData/A-b", ".Trash/a/b", "Applications/a/b",
                    "Public/a/b", ".config/a/b", ".docker/a/b", ".npm/a/b", ".claude/a/b"] {
            #expect(policy.isDenied(t.home + "/" + rel), "\(rel)")
            #expect(!policy.passesRootDepthAndDenyGate(t.home + "/" + rel), "\(rel)")
        }
        // a dot dir BELOW depth 1 is not a deny root by itself
        #expect(!policy.isDenied(t.home + "/dev/.hidden/x"))
        #expect(!policy.isDenied(t.project))
        // a project named like a deny root but nested is fine
        #expect(!policy.isDenied(t.home + "/dev/Library/x"))
    }

    @Test func symlinkedPathsAreCanonicalized() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.mkdir(t.root + "/real/proj")
        try t.symlink(t.home + "/dev/escape", to: t.root + "/real/proj")
        try t.symlink(t.home + "/dev/alias", to: t.project)
        let policy = PathPolicy(homeDirectory: t.home)
        #expect(PathPolicy.canonical(t.home + "/dev/alias") == t.project)
        #expect(PathPolicy.canonical(t.home + "/dev/escape") == t.root + "/real/proj")
        // a symlink inside home that leaves home canonicalizes OUTSIDE home and is therefore rejected
        #expect(!policy.isUnderHome(PathPolicy.canonical(t.home + "/dev/escape")))
        #expect(!policy.passesRootDepthAndDenyGate(PathPolicy.canonical(t.home + "/dev/escape")))
        // a symlinked home itself is canonicalized
        try t.symlink(t.root + "/homelink", to: t.home)
        let viaLink = PathPolicy(homeDirectory: t.root + "/homelink")
        #expect(viaLink.home == t.home)
    }

    @Test func nonexistentPathsFallBackToLexicalStandardization() {
        #expect(PathPolicy.canonical("/definitely/not/there/../here") == "/definitely/not/here")
    }

    @Test func siblingPrefixNeverMatches() {
        #expect(!PathPolicy.isStrictlyInside("/a/proj-evil", root: "/a/proj"))
        #expect(!PathPolicy.isStrictlyInside("/a/proj-evil/x", root: "/a/proj"))
        #expect(PathPolicy.isStrictlyInside("/a/proj/x", root: "/a/proj"))
        #expect(PathPolicy.isStrictlyInside("/a/proj/x/y", root: "/a/proj"))
        #expect(!PathPolicy.isStrictlyInside("/a/proj", root: "/a/proj"))
        #expect(!PathPolicy.isStrictlyInside("/a/proj/", root: "/a/proj"))
        #expect(PathPolicy.isInsideOrEqual("/a/proj", root: "/a/proj"))
        #expect(!PathPolicy.isInsideOrEqual("/a/proj-evil", root: "/a/proj"))
        #expect(PathPolicy.components(of: "/a/proj/x/y", below: "/a/proj") == ["x", "y"])
        #expect(PathPolicy.components(of: "/a/proj-evil/x", below: "/a/proj") == nil)
    }

    @Test func packageDirsRunFromStartToCeiling() {
        let dirs = PathPolicy.packageDirs(start: "/r/mono/apps/web", ceiling: "/r/mono")
        #expect(dirs == ["/r/mono/apps/web", "/r/mono/apps", "/r/mono"])
        #expect(PathPolicy.packageDirs(start: "/r/mono", ceiling: "/r/mono") == ["/r/mono"])
        // a start outside the ceiling never ascends
        #expect(PathPolicy.packageDirs(start: "/x/y", ceiling: "/r/mono") == ["/x/y"])
        // longer than 8 levels: the ceiling always survives, the list is capped
        let deep = "/r/a/b/c/d/e/f/g/h/i/j"
        let capped = PathPolicy.packageDirs(start: deep, ceiling: "/r")
        #expect(capped.count == 8)
        #expect(capped.first == deep)
        #expect(capped.last == "/r")
    }

    @Test func realDirectoryAndDeviceChecks() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let policy = PathPolicy(homeDirectory: t.home)
        #expect(policy.isRealDirectoryOnHomeDevice(t.project))
        try t.write(t.home + "/dev/file.txt")
        #expect(!policy.isRealDirectoryOnHomeDevice(t.home + "/dev/file.txt"))
        try t.symlink(t.home + "/dev/linkdir", to: t.project)
        #expect(!policy.isRealDirectoryOnHomeDevice(t.home + "/dev/linkdir"))
        #expect(!policy.isRealDirectoryOnHomeDevice(t.home + "/dev/missing"))
    }
}
