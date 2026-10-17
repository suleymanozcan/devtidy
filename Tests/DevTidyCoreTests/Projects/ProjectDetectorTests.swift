import Foundation
import Testing
@testable import DevTidyCore

@Suite("ProjectDetector (ENV §3.4/§4.1, CAT §2)")
struct ProjectDetectorTests {
    private func detector(_ t: S2TempDir, git: S2FakeGit = S2FakeGit()) -> ProjectDetector {
        ProjectDetector(homeDirectory: t.home, git: git)
    }

    @Test func nearestMarkerWalkUpStopsBeforeHome() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        // A marker directly in HOME must never become a project root.
        try t.write(t.home + "/package.json", "{}")
        try t.mkdir(t.home + "/.git")
        try t.packageJSON(at: t.project, deps: ["next"])
        try t.mkdir(t.p("src/components/deep"))
        let d = detector(t)
        #expect(d.project(containing: t.p("src/components/deep"))?.root == t.project)
        #expect(d.project(containing: t.project)?.root == t.project)
        // no marker below home ⇒ nil, even though HOME itself carries markers
        try t.mkdir(t.home + "/dev/empty/sub")
        #expect(d.project(containing: t.home + "/dev/empty/sub") == nil)
        // cwd == home ⇒ nil
        #expect(d.project(containing: t.home) == nil)
    }

    @Test func aFilePathStartsAtItsParent() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.packageJSON(at: t.project)
        try t.write(t.p("node_modules/.bin/vite"), "#!/bin/sh")
        #expect(detector(t).project(containing: t.p("node_modules/.bin/vite"))?.root == t.project)
    }

    @Test func monorepoSubAppWithOwnGitGetsGroupName() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        // ENV §4.1: ~/developer/rentacarsaas/backoffice has its own .git + package.json; the parent has no markers.
        let app = t.home + "/dev/rentacarsaas/backoffice"
        try t.packageJSON(at: app, deps: ["next", "wrangler"])
        try t.mkdir(app + "/.git")
        try t.write(app + "/package-lock.json", "{}")
        try t.write(app + "/wrangler.jsonc", "{}")
        let d = detector(t)
        let p = try #require(d.project(containing: app + "/src"))
        #expect(p.root == app)
        #expect(p.name == "backoffice")
        #expect(p.groupName == "rentacarsaas")
        #expect(p.repoRoot == app)
        #expect(p.kinds.first == .next)
        #expect(p.kinds.contains(.cloudflareWorkers))
        // the folder that merely groups apps is not a project
        #expect(d.project(containing: t.home + "/dev/rentacarsaas") == nil)
        // a project directly below a depth-1 container has no group name
        try t.packageJSON(at: t.project)
        #expect(d.project(containing: t.project)?.groupName == nil)
    }

    @Test func onlyGitMarkerYieldsUnknownKind() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        // ENV §4.1: tunahan-monorepo-eski -> .git compose.yaml
        let dir = t.home + "/dev/tunahan-monorepo-eski"
        try t.mkdir(dir + "/.git")
        try t.write(dir + "/compose.yaml", "services: {}")
        let p = try #require(detector(t).project(containing: dir))
        #expect(p.kinds == [.unknown])
        #expect(p.repoRoot == dir)
    }

    @Test(arguments: [
        (["next"], ProjectKind.next), (["vite"], .vite), (["nuxt"], .nuxt), (["astro"], .astro), (["@sveltejs/kit"], .svelteKit),
        (["@remix-run/node"], .remix), (["@react-router/dev"], .reactRouter), (["gatsby"], .gatsby),
        (["@angular/core"], .angular), (["expo"], .expo), (["react-native"], .reactNative), (["parcel"], .parcel),
        (["wrangler"], .cloudflareWorkers), (["@cloudflare/vitest-pool-workers"], .cloudflareWorkers),
    ])
    func kindsFromPackageJSONDeps(deps: [String], expected: ProjectKind) throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.packageJSON(at: t.project, deps: deps)
        let p = try #require(detector(t).project(containing: t.project))
        #expect(p.kinds.contains(expected))
        #expect(!p.kinds.contains(.node), "a framework kind replaces the plain node kind")
    }

    @Test func plainPackageJSONIsNodeAndEmptyIsUnknown() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.packageJSON(at: t.project)
        #expect(detector(t).project(containing: t.project)?.kinds == [.node])
        try t.write(t.project + "/package.json", "{ not json")
        #expect(detector(t).project(containing: t.project)?.kinds == [.node])
    }

    @Test func nonJavaScriptMarkers() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let cases: [(String, [String], ProjectKind)] = [
            ("laravel", ["artisan", "composer.json"], .laravel), ("php", ["composer.json"], .php),
            ("py", ["pyproject.toml"], .python), ("rb", ["Gemfile"], .ruby), ("java", ["pom.xml"], .java),
            ("rs", ["Cargo.toml"], .rust), ("go", ["go.mod"], .go), ("swift", ["Package.swift"], .swiftPackage),
            ("flutter", ["pubspec.yaml"], .flutter), ("godot", ["project.godot"], .godot), ("gradle", ["settings.gradle.kts"], .gradle),
        ]
        for (name, files, kind) in cases {
            let dir = t.home + "/dev/\(name)"
            for f in files {
                let content = (name == "laravel" && f == "composer.json") ? "{\"require\":{\"laravel/framework\":\"^11\"}}" : "x"
                try t.write(dir + "/" + f, content)
            }
            let p = try #require(detector(t).project(containing: dir), "\(name)")
            #expect(p.kinds.contains(kind), "\(name): \(p.kinds)")
        }
        try t.mkdir(t.home + "/dev/xc/App.xcodeproj")
        #expect(detector(t).project(containing: t.home + "/dev/xc")?.kinds.contains(.xcode) == true)
        // a plain composer project without laravel/framework is php, not laravel
        try t.write(t.home + "/dev/plainphp/composer.json", "{\"require\":{\"monolog/monolog\":\"^3\"}}")
        let plain = try #require(detector(t).project(containing: t.home + "/dev/plainphp"))
        #expect(plain.kinds.contains(.php) && !plain.kinds.contains(.laravel))
    }

    @Test func symlinkedStartIsCanonicalized() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.packageJSON(at: t.project)
        try t.symlink(t.home + "/dev/alias", to: t.project)
        #expect(detector(t).project(containing: t.home + "/dev/alias")?.root == t.project)
    }

    // MARK: projectContext (R1/R2, ceiling)

    @Test func contextUsesRepoRootAsCeiling() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let app = t.project + "/apps/web"
        try t.mkdir(app)
        let git = S2FakeGit()
        git.toplevelResult = .repository(t.project)
        let ctx = try #require(await detector(t, git: git).projectContext(for: app))
        #expect(ctx.ceiling == t.project)
        #expect(ctx.project.root == t.project)
        #expect(ctx.project.repoRoot == t.project)
        #expect(ctx.packageDirs == [app, t.project + "/apps", t.project])
    }

    @Test func nonRepoDoesNotAscend() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let git = S2FakeGit()
        git.toplevelResult = .notARepository
        let ctx = try #require(await detector(t, git: git).projectContext(for: t.project))
        #expect(ctx.ceiling == t.project)
        #expect(ctx.project.repoRoot == nil)
        #expect(ctx.packageDirs == [t.project])
    }

    @Test func gitFailureStillReturnsAContextWithoutRepoRoot() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let git = S2FakeGit()
        git.toplevelResult = .failed("dubious ownership")
        let ctx = try #require(await detector(t, git: git).projectContext(for: t.project))
        #expect(ctx.project.repoRoot == nil)
        #expect(ctx.ceiling == t.project)
    }

    @Test func shallowRepoRootDoesNotBecomeTheCeiling() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let git = S2FakeGit()
        git.toplevelResult = .repository(t.home + "/dev")      // depth 1: R1 forbids it as a root
        let ctx = try #require(await detector(t, git: git).projectContext(for: t.project))
        #expect(ctx.ceiling == t.project)
    }

    @Test func gatesRejectShallowDeniedAndForeignRoots() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let git = S2FakeGit()
        let d = detector(t, git: git)
        try t.mkdir(t.home + "/.ssh/keys/x")
        try t.mkdir(t.home + "/Library/Application Support/x")
        try t.mkdir(t.root + "/outside/a/b")
        for path in [t.home, t.home + "/dev", t.home + "/.ssh/keys/x", t.home + "/Library/Application Support/x",
                     t.root + "/outside/a/b", t.home + "/dev/missing"] {
            git.toplevelResult = .notARepository
            #expect(await d.projectContext(for: path) == nil, "\(path)")
        }
        // a regular file is not a root
        try t.write(t.home + "/dev/file.txt")
        #expect(await d.projectContext(for: t.home + "/dev/file.txt") == nil)
        // a repo whose toplevel is a denied dir never promotes the start
        git.toplevelResult = .repository(t.home + "/.ssh")
        #expect(await d.projectContext(for: t.home + "/.ssh/keys/x") == nil)
    }

    @Test func contextCanonicalizesSymlinkedStart() async throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.symlink(t.home + "/dev/alias", to: t.project)
        let git = S2FakeGit()
        let ctx = try #require(await detector(t, git: git).projectContext(for: t.home + "/dev/alias"))
        #expect(ctx.ceiling == t.project)
        // an alias that leaves home is rejected after canonicalization
        try t.mkdir(t.root + "/real/a/b")
        try t.symlink(t.home + "/dev/leave", to: t.root + "/real/a/b")
        #expect(await detector(t, git: git).projectContext(for: t.home + "/dev/leave") == nil)
    }

    /// P2-1: the per-tick server association is cached (including "no project") for a bounded time, then walks again.
    @Test func serverAssociationIsCachedUntilTheTTLExpires() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        let clock = S2Clock()
        let d = ProjectDetector(homeDirectory: t.home, git: S2FakeGit(), now: { clock.now })
        try t.packageJSON(at: t.project, deps: ["next"])
        #expect(d.project(containing: t.project)?.root == t.project)
        try FileManager.default.removeItem(atPath: t.project + "/package.json")
        #expect(d.project(containing: t.project)?.root == t.project, "served from the cache: no directory was listed again")
        clock.advance(ProjectDetector.cacheTTL - 1)
        #expect(d.project(containing: t.project)?.root == t.project)
        clock.advance(2)
        #expect(d.project(containing: t.project) == nil, "expired: the walk ran again and found no marker")
        // "no project" is cached as well
        try t.packageJSON(at: t.project, deps: ["next"])
        #expect(d.project(containing: t.project) == nil)
        clock.advance(ProjectDetector.cacheTTL + 1)
        #expect(d.project(containing: t.project)?.root == t.project)
    }

    @Test func theAnswerCacheStaysBounded() {
        let cache = ExpiringCache<Project?>(ttl: ProjectDetector.cacheTTL, capacity: ProjectDetector.cacheCapacity)
        let t0 = Date()
        for i in 0..<ProjectDetector.cacheCapacity { cache.store(nil, for: "/p\(i)", now: t0) }
        #expect(cache.cached("/p0", now: t0) != nil, "a full cache still answers")
        cache.store(nil, for: "/new", now: t0)
        #expect(cache.cached("/new", now: t0) != nil)
        #expect(cache.cached("/p0", now: t0) == nil, "nothing is older than the TTL, so a full cache starts over instead of growing")
        // entries past the TTL are never served
        #expect(cache.cached("/new", now: t0.addingTimeInterval(ProjectDetector.cacheTTL + 1)) == nil)
    }
}
