import Foundation
import Darwin
import Testing
@testable import DevTidyCore

/// One class-A rule fixture: markers (package.json deps and/or files) + the target directory it must find.
struct S2ARuleCase: Sendable, CustomTestStringConvertible {
    let ruleID: String
    let deps: [String]
    let files: [String]       // created as empty files, unless the name ends with "/" (directory)
    let target: String
    var testDescription: String { ruleID }
}

@Suite("CacheEvaluator (detection, gating, D3/D7/D9)")
struct CacheEvaluatorTests {
    static let classACases: [S2ARuleCase] = [
        .init(ruleID: "next.cache", deps: ["next"], files: [], target: ".next"),
        .init(ruleID: "nuxt.cache", deps: ["nuxt"], files: [], target: ".nuxt"),
        .init(ruleID: "svelte.kit", deps: ["@sveltejs/kit"], files: [], target: ".svelte-kit"),
        .init(ruleID: "astro.cache", deps: ["astro"], files: [], target: ".astro"),
        .init(ruleID: "astro.nm", deps: ["astro"], files: [], target: "node_modules/.astro"),
        .init(ruleID: "vite.nm", deps: ["vite"], files: [], target: "node_modules/.vite"),
        .init(ruleID: "vite.tmp", deps: ["vite"], files: [], target: "node_modules/.vite-temp"),
        .init(ruleID: "vitest.cache", deps: ["vitest"], files: [], target: "node_modules/.vitest-cache"),
        .init(ruleID: "turbo.cache", deps: [], files: ["turbo.json"], target: ".turbo"),
        .init(ruleID: "nx.cache", deps: [], files: ["nx.json"], target: ".nx/cache"),
        .init(ruleID: "parcel.cache", deps: [], files: [".parcelrc"], target: ".parcel-cache"),
        .init(ruleID: "ng.cache", deps: [], files: ["angular.json"], target: ".angular/cache"),
        .init(ruleID: "remix.cache", deps: ["@remix-run/node"], files: [], target: ".cache"),
        .init(ruleID: "rr.types", deps: ["@react-router/dev"], files: [], target: ".react-router"),
        .init(ruleID: "gatsby.cache", deps: ["gatsby"], files: [], target: ".cache"),
        .init(ruleID: "node.cache", deps: [], files: [], target: "node_modules/.cache"),
        .init(ruleID: "wrangler.tmp", deps: [], files: ["wrangler.jsonc"], target: ".wrangler/tmp"),
        .init(ruleID: "expo.state", deps: ["expo"], files: [], target: ".expo"),
        .init(ruleID: "php.phpunit", deps: [], files: ["phpunit.xml"], target: ".phpunit.cache"),
        .init(ruleID: "py.pytest", deps: [], files: ["pyproject.toml"], target: ".pytest_cache"),
        .init(ruleID: "py.mypy", deps: [], files: ["pyproject.toml"], target: ".mypy_cache"),
        .init(ruleID: "py.ruff", deps: [], files: ["pyproject.toml"], target: ".ruff_cache"),
        .init(ruleID: "gradle.root", deps: [], files: ["build.gradle"], target: ".gradle"),
        .init(ruleID: "gradle.kotlin", deps: [], files: ["settings.gradle.kts"], target: ".kotlin"),
        .init(ruleID: "flutter.dart_tool", deps: [], files: ["pubspec.yaml"], target: ".dart_tool"),
        .init(ruleID: "godot.cache", deps: [], files: ["project.godot"], target: ".godot"),
    ]

    private func ids(_ report: ProjectCacheReport?) -> Set<String> { Set(report?.entries.map(\.ruleID) ?? []) }

    private func report(_ env: S2Env, includeDependencies: Bool = false) async -> ProjectCacheReport? {
        var o = CatalogOptions()
        o.includeDependencies = includeDependencies
        o.includeDerivedData = false
        return await env.catalog.report(forProjectAt: env.tmp.project, options: o)
    }

    private func create(_ env: S2Env, _ c: S2ARuleCase, withMarkers: Bool) throws {
        let t = env.tmp
        if withMarkers {
            if !c.deps.isEmpty || c.ruleID == "node.cache" || c.files.isEmpty {
                try t.packageJSON(at: t.project, deps: c.deps)
            }
            for f in c.files { try t.write(t.p(f)) }
        } else {
            // a package.json that does NOT carry the marker dependency
            try t.packageJSON(at: t.project, deps: ["left-pad"])
        }
        try t.write(t.p(c.target + "/payload.bin"), "x")
        if c.ruleID == "godot.cache" && !withMarkers { try t.mkdir(t.p(".godot")) }
    }

    // MARK: Class A — detected only with the marker

    @Test(arguments: CacheEvaluatorTests.classACases)
    func classARuleNeedsItsMarker(_ c: S2ARuleCase) async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try create(env, c, withMarkers: true)
        let hit = await report(env)
        #expect(ids(hit).contains(c.ruleID), "\(c.ruleID) must be detected: \(ids(hit))")
        let entry = hit?.entries.first { $0.ruleID == c.ruleID }
        #expect(entry?.safety == .always)
        #expect(entry?.defaultMode == .permanent)
        #expect(entry?.defaultSelected == true)
        #expect(entry?.sizeBytes == nil, "entries are unsized (lazy)")
        #expect(entry?.packageDir == env.tmp.project)
        #expect(entry?.id == "\(c.ruleID)@\(env.tmp.project)")
    }

    @Test(arguments: CacheEvaluatorTests.classACases)
    func classARuleIsAbsentWithoutItsMarker(_ c: S2ARuleCase) async throws {
        // `node.cache` only needs a package.json, so its "no marker" variant is a project without one.
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        if c.ruleID == "node.cache" {
            try env.tmp.write(env.tmp.p(c.target + "/payload.bin"), "x")
        } else {
            try create(env, c, withMarkers: false)
        }
        #expect(!ids(await report(env)).contains(c.ruleID))
    }

    @Test func nextCacheNeedsTheNextDependencyNotJustTheDirectory() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["react"])
        try env.tmp.write(env.tmp.p(".next/x"), "x")
        #expect(!ids(await report(env)).contains("next.cache"))
    }

    @Test func entryCarriesTurkishFacts() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        let entry = try #require(await report(env)?.entries.first { $0.ruleID == "next.cache" })
        #expect(entry.title == "Next.js önbelleği")
        #expect(entry.displayPath == ".next")
        #expect(entry.qualifiedBecause.contains("`next` bağımlılığı bulundu"))
        #expect(entry.qualifiedBecause.contains("izlenen dosya: 0"))
        #expect(!entry.notes.isEmpty)
        #expect(entry.reinstallCommand == nil)
        #expect(!entry.isContentsOnly)
    }

    // MARK: Hoisted markers

    @Test func turboAtTheCeilingAppliesToPackageDirs() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let app = env.tmp.p("apps/web")
        try env.tmp.write(env.tmp.p("turbo.json"), "{}")
        try env.tmp.packageJSON(at: app)
        try env.tmp.write(app + "/.turbo/log.txt", "x")
        try env.tmp.write(env.tmp.p(".turbo/cache.txt"), "x")
        let r = try #require(await env.catalog.report(forProjectAt: app, options: CatalogOptions()))
        let dirs = Set(r.entries.filter { $0.ruleID == "turbo.cache" }.map(\.packageDir))
        #expect(dirs == [app, env.tmp.project])
    }

    // MARK: .wrangler and public (D9)

    @Test func wranglerOnlyTmpIsOfferedNeverState() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("wrangler.jsonc"), "{}")
        try env.tmp.packageJSON(at: env.tmp.project)
        try env.tmp.write(env.tmp.p(".wrangler/state/v3/d1/db.sqlite"), "precious")
        try env.tmp.write(env.tmp.p(".wrangler/tmp/bundle.js"), "x")
        env.git.ignored = [env.tmp.p(".wrangler")]
        let r = try #require(await report(env))
        let paths = r.entries.map(\.displayPath)
        #expect(paths.contains(".wrangler/tmp"))
        #expect(!paths.contains { $0.contains("state") }, "\(paths)")
        #expect(!paths.contains(".wrangler"))
        // only state present ⇒ nothing from .wrangler at all
        try FileManager.default.removeItem(atPath: env.tmp.p(".wrangler/tmp"))
        let again = try #require(await report(env))
        #expect(!again.entries.contains { $0.displayPath.hasPrefix(".wrangler") })
    }

    @Test(arguments: ["tracked", "untracked", "ignored", "plain"])
    func publicIsNeverOffered(_ variant: String) async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        try env.tmp.write(env.tmp.p("public/more.txt"), "x")
        let pub = env.tmp.p("public")
        switch variant {
        case "tracked": env.git.tracked = [pub + "/logo.txt"]
        case "untracked": env.git.untracked = [pub + "/more.txt"]
        case "ignored": env.git.ignored = [pub]
        default: break
        }
        let r = try #require(await report(env))
        #expect(!r.entries.contains { $0.displayPath == "public" || $0.displayPath.hasPrefix("public/") })
        #expect(!r.entries.contains { $0.displayPath == ".env" || $0.displayPath == "src" })
        #expect(env.tmp.exists(pub + "/logo.txt"))
    }

    // MARK: dist (class B)

    private func distFixture(_ env: S2Env, buildScript: Bool, viteConfig: Bool = false) throws {
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["left-pad"], buildScript: buildScript)
        if viteConfig { try env.tmp.write(env.tmp.p("vite.config.ts"), "export default {}") }
        try env.tmp.write(env.tmp.p("dist/index.js"), "x")
    }

    @Test func distNeedsABundlerMarkerAndIgnoreAndNoUntrackedFiles() async throws {
        // no marker at all, even though git ignores dist
        var env = try S2Env()
        try distFixture(env, buildScript: false)
        env.git.ignored = [env.tmp.p("dist")]
        #expect(!ids(await report(env)).contains("dist.generic"))
        env.tmp.cleanup()

        // build script + ignored + clean ⇒ offered as class B, default OFF, Trash
        env = try S2Env()
        try distFixture(env, buildScript: true)
        env.git.ignored = [env.tmp.p("dist")]
        let hit = try #require(await report(env)?.entries.first { $0.ruleID == "dist.generic" })
        #expect(hit.safety == .conditional)
        #expect(hit.defaultSelected == false)
        #expect(hit.defaultMode == .trash)
        #expect(hit.qualifiedBecause.contains("git tarafından yok sayılıyor"))
        env.tmp.cleanup()

        // a bundler config file is an alternative marker
        env = try S2Env()
        try distFixture(env, buildScript: false, viteConfig: true)
        env.git.ignored = [env.tmp.p("dist")]
        #expect(ids(await report(env)).contains("dist.generic"))
        env.tmp.cleanup()

        // not ignored ⇒ rejected
        env = try S2Env()
        try distFixture(env, buildScript: true)
        #expect(!ids(await report(env)).contains("dist.generic"))
        env.tmp.cleanup()

        // tracked file inside ⇒ rejected
        env = try S2Env()
        try distFixture(env, buildScript: true)
        env.git.ignored = [env.tmp.p("dist")]
        env.git.tracked = [env.tmp.p("dist/index.js")]
        #expect(!ids(await report(env)).contains("dist.generic"))
        env.tmp.cleanup()

        // untracked-not-ignored file inside ⇒ rejected
        env = try S2Env()
        try distFixture(env, buildScript: true)
        env.git.ignored = [env.tmp.p("dist")]
        env.git.untracked = [env.tmp.p("dist/index.js")]
        #expect(!ids(await report(env)).contains("dist.generic"))
        env.tmp.cleanup()

        // no repository ⇒ class B is never offered
        env = try S2Env(repoAtProject: false)
        try distFixture(env, buildScript: true)
        env.git.isRepository = false
        #expect(!ids(await report(env)).contains("dist.generic"))
        env.tmp.cleanup()

        // any other git failure ⇒ rejected (fail closed)
        env = try S2Env()
        try distFixture(env, buildScript: true)
        env.git.ignored = [env.tmp.p("dist")]
        env.git.failing = true
        #expect(!ids(await report(env)).contains("dist.generic"))
        env.tmp.cleanup()
    }

    @Test func distWarnsWhenASiblingPackageDependsOnIt() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let design = env.tmp.home + "/dev/ws/design"
        let site = env.tmp.home + "/dev/ws/site"
        try env.tmp.packageJSON(at: design, name: "@acme/design", deps: [], buildScript: true)
        try env.tmp.packageJSON(at: site, name: "site", deps: ["@acme/design"])
        try env.tmp.write(design + "/dist/index.js", "x")
        env.git.toplevelResult = .repository(design)
        env.git.ignored = [design + "/dist"]
        let r = try #require(await env.catalog.report(forProjectAt: design, options: CatalogOptions()))
        let entry = try #require(r.entries.first { $0.ruleID == "dist.generic" })
        #expect(entry.notes.contains { $0.contains("site") })
    }

    /// Security F3-4: the sibling's directory name goes into a note on the cleanup sheet, so a bidirectional override or a
    /// zero-width character in it never reaches the screen.
    @Test func theSiblingNameInTheDistWarningIsCleanedForDisplay() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let design = env.tmp.home + "/dev/ws/design"
        let site = env.tmp.home + "/dev/ws/si\u{202E}te\u{200B}"
        try env.tmp.packageJSON(at: design, name: "@acme/design", deps: [], buildScript: true)
        try env.tmp.packageJSON(at: site, name: "site", deps: ["@acme/design"])
        try env.tmp.write(design + "/dist/index.js", "x")
        env.git.toplevelResult = .repository(design)
        env.git.ignored = [design + "/dist"]
        let r = try #require(await env.catalog.report(forProjectAt: design, options: CatalogOptions()))
        let entry = try #require(r.entries.first { $0.ruleID == "dist.generic" })
        let note = try #require(entry.notes.first { $0.hasPrefix("kardeş paket") })
        #expect(note == "kardeş paket (site) bu paketi kullanıyor: yeniden derlenene kadar çalışmayabilir")
    }

    // MARK: Class A / B git gating

    @Test func classAIsRejectedWhenTrackedOrWhenGitFails_andAllowedWithoutARepo() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        #expect(ids(await report(env)).contains("next.cache"))
        env.git.tracked = [env.tmp.p(".next/dev/lock")]
        #expect(!ids(await report(env)).contains("next.cache"), "a tracked file inside rejects the whole directory")
        env.git.tracked = []
        env.git.failing = true
        #expect(!ids(await report(env)).contains("next.cache"), "git failure other than 'not a repository' ⇒ reject")
        env.git.failing = false
        env.git.isRepository = false
        #expect(ids(await report(env)).contains("next.cache"), "only 'not a repository' is tolerated for class A")
    }

    @Test func classBRustTargetNeedsIgnoredAndCleanTree() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("Cargo.toml"), "[package]")
        try env.tmp.write(env.tmp.p("target/debug/x"), "x")
        #expect(!ids(await report(env)).contains("rust.target"), "not ignored")
        env.git.ignored = [env.tmp.p("target")]
        #expect(ids(await report(env)).contains("rust.target"))
        env.git.untracked = [env.tmp.p("target/stray.rs")]
        #expect(!ids(await report(env)).contains("rust.target"), "untracked-not-ignored file inside")
    }

    @Test func symlinkedTargetsAreNeverOffered() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["next"])
        try env.tmp.write(env.tmp.root + "/elsewhere/payload", "x")
        try env.tmp.symlink(env.tmp.p(".next"), to: env.tmp.root + "/elsewhere")
        try env.tmp.symlink(env.tmp.p("node_modules"), to: env.tmp.root + "/elsewhere")
        let r = await report(env)
        #expect(!ids(r).contains("next.cache"))
        #expect(!ids(r).contains("node.cache"))
        #expect(!ids(r).contains("node.modules"))
    }

    @Test func caseMismatchedDirectoryIsNotOffered() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("Cargo.toml"), "[package]")
        try env.tmp.write(env.tmp.p("Target/x"), "x")      // not `target`
        env.git.ignored = [env.tmp.p("Target"), env.tmp.p("target")]
        #expect(!ids(await report(env)).contains("rust.target"))
    }

    // MARK: Class C

    @Test func dependenciesNeedOptInLockfileAndNoPnP() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project)
        try env.tmp.write(env.tmp.p("node_modules/dep/index.js"), "x")
        env.git.ignored = [env.tmp.p("node_modules")]
        // no lockfile ⇒ never
        #expect(!ids(await report(env, includeDependencies: true)).contains("node.modules"))
        try env.tmp.write(env.tmp.p("pnpm-lock.yaml"), "lockfileVersion: 9")
        // lockfile but not opted in ⇒ never
        #expect(!ids(await report(env, includeDependencies: false)).contains("node.modules"))
        // opted in + lockfile + ignored ⇒ offered, OFF, permanent, reinstall command from the lockfile
        let entry = try #require(await report(env, includeDependencies: true)?.entries.first { $0.ruleID == "node.modules" })
        #expect(entry.safety == .optIn)
        #expect(entry.defaultSelected == false)
        #expect(entry.defaultMode == .permanent)
        #expect(entry.reinstallCommand == "pnpm install --frozen-lockfile")
        // Yarn PnP ⇒ nothing to offer
        try env.tmp.write(env.tmp.p(".pnp.cjs"), "")
        #expect(!ids(await report(env, includeDependencies: true)).contains("node.modules"))
        try FileManager.default.removeItem(atPath: env.tmp.p(".pnp.cjs"))
        // not ignored ⇒ rejected
        env.git.ignored = []
        #expect(!ids(await report(env, includeDependencies: true)).contains("node.modules"))
        // tracked ⇒ rejected
        env.git.ignored = [env.tmp.p("node_modules")]
        env.git.tracked = [env.tmp.p("node_modules/dep/index.js")]
        #expect(!ids(await report(env, includeDependencies: true)).contains("node.modules"))
    }

    @Test(arguments: [
        ("package-lock.json", "npm ci"), ("npm-shrinkwrap.json", "npm ci"), ("yarn.lock", "yarn install --immutable"),
        ("bun.lock", "bun install --frozen-lockfile"), ("bun.lockb", "bun install --frozen-lockfile"),
    ])
    func reinstallCommandComesFromTheLockfile(lockfile: String, command: String) async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project)
        try env.tmp.write(env.tmp.p(lockfile), "{}")
        try env.tmp.write(env.tmp.p("node_modules/dep/index.js"), "x")
        env.git.ignored = [env.tmp.p("node_modules")]
        let entry = try #require(await report(env, includeDependencies: true)?.entries.first { $0.ruleID == "node.modules" })
        #expect(entry.reinstallCommand == command)
    }

    @Test func podsAndVendorAreClassCAndOptIn() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("composer.json"), "{}")
        try env.tmp.write(env.tmp.p("composer.lock"), "{}")
        try env.tmp.write(env.tmp.p("vendor/autoload.php"), "x")
        try env.tmp.write(env.tmp.p("ios/Podfile"), "x")
        try env.tmp.write(env.tmp.p("ios/Pods/x"), "x")
        env.git.ignored = [env.tmp.p("vendor"), env.tmp.p("ios/Pods")]
        #expect(!ids(await report(env)).contains("php.vendor"))
        #expect(!ids(await report(env)).contains("rn.pods"))
        let r = try #require(await report(env, includeDependencies: true))
        #expect(r.entries.first { $0.ruleID == "php.vendor" }?.reinstallCommand == "composer install")
        #expect(r.entries.first { $0.ruleID == "rn.pods" }?.reinstallCommand == "pod install")
    }

    // MARK: Laravel contents-only and public/hot

    private func laravel(_ env: S2Env) throws {
        try env.tmp.write(env.tmp.p("artisan"), "#!/usr/bin/env php")
        try env.tmp.write(env.tmp.p("composer.json"), "{\"require\":{\"laravel/framework\":\"^11.0\"}}")
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["laravel-vite-plugin"])
    }

    @Test func laravelViewsEvaluateChildrenAndKeepGitignore() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        let views = env.tmp.p("storage/framework/views")
        try env.tmp.write(views + "/a1.php", "<?php")
        try env.tmp.write(views + "/b2.php", "<?php")
        try env.tmp.write(views + "/.gitignore", "*\n!.gitignore\n")
        try env.tmp.write(views + "/note.txt", "not a compiled view")
        try env.tmp.symlink(views + "/sneaky.php", to: env.tmp.root + "/outside.php")
        env.git.tracked = [views + "/.gitignore"]
        env.git.ignored = [views + "/a1.php", views + "/b2.php", views + "/note.txt", views + "/sneaky.php"]
        let entry = try #require(await report(env)?.entries.first { $0.ruleID == "laravel.views" })
        #expect(entry.isContentsOnly)
        #expect(entry.itemCount == 2, "only regular, ignored, untracked *.php children")
        #expect(entry.displayPath == "storage/framework/views")
        #expect(entry.defaultSelected)
        // a tracked child is not counted
        env.git.tracked = [views + "/.gitignore", views + "/a1.php"]
        let afterTracked = try #require(await report(env)?.entries.first { $0.ruleID == "laravel.views" })
        #expect(afterTracked.itemCount == 1)
        // nothing ignored ⇒ no entry
        env.git.ignored = []
        #expect(!ids(await report(env)).contains("laravel.views"))
        // no repository ⇒ per-child ignore evidence is impossible ⇒ no entry (even for class A)
        env.git.ignored = [views + "/a1.php", views + "/b2.php"]
        env.git.isRepository = false
        #expect(!ids(await report(env)).contains("laravel.views"))
    }

    @Test func laravelBootstrapCacheMatchesExactNamesOnlyAndIsClassB() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        let cache = env.tmp.p("bootstrap/cache")
        for n in ["packages.php", "services.php", "other.php", ".gitignore"] { try env.tmp.write(cache + "/" + n, "<?php") }
        env.git.ignored = [cache + "/packages.php", cache + "/services.php", cache + "/other.php"]
        env.git.tracked = [cache + "/.gitignore"]
        let entry = try #require(await report(env)?.entries.first { $0.ruleID == "laravel.bootcache" })
        #expect(entry.itemCount == 2)
        #expect(entry.safety == .conditional)
        #expect(entry.defaultSelected == false)
        #expect(entry.defaultMode == .trash)
    }

    @Test func laravelHotFileContentIsChecked() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try laravel(env)
        let hot = env.tmp.p("public/hot")
        env.git.ignored = [hot]
        try env.tmp.write(hot, "http://[::1]:5173")
        #expect(ids(await report(env)).contains("laravel.hot"))
        try env.tmp.write(hot, "<?php echo 1;")
        #expect(!ids(await report(env)).contains("laravel.hot"), "content must look like a URL")
        try env.tmp.write(hot, "https://x/" + String(repeating: "a", count: 600))
        #expect(!ids(await report(env)).contains("laravel.hot"), "larger than 512 bytes")
        try env.tmp.write(hot, "http://[::1]:5173")
        env.git.ignored = []
        #expect(!ids(await report(env)).contains("laravel.hot"), "must be git-ignored")
        env.git.ignored = [hot]
        env.git.tracked = [hot]
        #expect(!ids(await report(env)).contains("laravel.hot"), "must not be tracked")
        env.git.tracked = []
        try FileManager.default.removeItem(atPath: hot)
        try env.tmp.symlink(hot, to: env.tmp.root + "/real-hot")
        try env.tmp.write(env.tmp.root + "/real-hot", "http://x")
        #expect(!ids(await report(env)).contains("laravel.hot"), "symlink")
    }

    // MARK: pycache discovery

    @Test func pycacheRejectsDirectoriesWithForeignFiles() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("pyproject.toml"), "[project]")
        try env.tmp.write(env.tmp.p("pkg/__pycache__/mod.cpython-311.pyc"), "x")
        try env.tmp.write(env.tmp.p("pkg/__pycache__/mod2.cpython-311.pyo"), "x")
        try env.tmp.write(env.tmp.p("notes/__pycache__/notes.txt"), "user data")          // foreign file ⇒ rejected
        try env.tmp.write(env.tmp.p("mixed/__pycache__/a.pyc"), "x")
        try env.tmp.write(env.tmp.p("mixed/__pycache__/b.pyc/inner"), "dir named like bytecode") // non-regular entry ⇒ rejected
        try env.tmp.write(env.tmp.p(".venv/lib/__pycache__/v.pyc"), "x")                  // skipped dir
        try env.tmp.write(env.tmp.p("node_modules/x/__pycache__/n.pyc"), "x")             // skipped dir
        try env.tmp.write(env.tmp.root + "/outside/__pycache__/o.pyc", "x")
        try env.tmp.symlink(env.tmp.p("linked"), to: env.tmp.root + "/outside")          // symlinked dir ⇒ never walked
        let entry = try #require(await report(env)?.entries.first { $0.ruleID == "py.pycache" })
        #expect(entry.itemCount == 1)
        #expect(entry.defaultSelected)
        let walked = DiscoveryWalker.pycache(packageDir: env.tmp.project, rootDev: PathPolicy.device(of: env.tmp.project) ?? 0)
        #expect(walked == ["pkg/__pycache__"])
        // a tracked bytecode file removes just that directory
        env.git.tracked = [env.tmp.p("pkg/__pycache__/mod.cpython-311.pyc")]
        #expect(!ids(await report(env)).contains("py.pycache"))
    }

    @Test func gradleModuleBuildDirsAreDiscoveredWithinThreeLevels() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("settings.gradle.kts"), "")
        try env.tmp.write(env.tmp.p("build.gradle.kts"), "")
        try env.tmp.write(env.tmp.p("build/o"), "x")
        try env.tmp.write(env.tmp.p("app/build.gradle"), "")
        try env.tmp.write(env.tmp.p("app/build/o"), "x")
        try env.tmp.write(env.tmp.p("core/data/build.gradle.kts"), "")
        try env.tmp.write(env.tmp.p("core/data/build/o"), "x")
        try env.tmp.write(env.tmp.p("a/b/c/d/build.gradle"), "")           // too deep
        try env.tmp.write(env.tmp.p("a/b/c/d/build/o"), "x")
        try env.tmp.write(env.tmp.p("node_modules/m/build.gradle"), "")    // skipped
        try env.tmp.write(env.tmp.p("node_modules/m/build/o"), "x")
        try env.tmp.write(env.tmp.p("nomodule/build/o"), "x")              // build dir without build.gradle
        let dirs = DiscoveryWalker.gradleBuildDirs(packageDir: env.tmp.project, rootDev: PathPolicy.device(of: env.tmp.project) ?? 0)
        #expect(dirs == ["app/build", "build", "core/data/build"])
        env.git.ignored = [env.tmp.p("build"), env.tmp.p("app/build"), env.tmp.p("core/data/build")]
        let entry = try #require(await report(env)?.entries.first { $0.ruleID == "gradle.build" })
        #expect(entry.itemCount == 3)
        #expect(entry.safety == .conditional)
        #expect(entry.defaultSelected == false)
    }

    // MARK: DerivedData

    private func plist(_ dict: [String: Any], format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
    }

    private func derivedFixture(_ env: S2Env) throws -> (matched: String, orphan: String) {
        let root = env.derivedRoot
        let matched = "App-abcdefghijklmnopqrstuvwxyzab"
        let orphan = "Gone-bcdefghijklmnopqrstuvwxyzabc"
        try env.tmp.mkdir(env.tmp.p("App.xcworkspace"))
        try env.tmp.write(root + "/" + matched + "/Build/Products/x.o", "x")
        try plist(["WorkspacePath": env.tmp.p("App.xcworkspace"), "LastAccessedDate": Date(timeIntervalSince1970: 1_700_000_000)],
                  format: .binary).write(to: URL(fileURLWithPath: root + "/" + matched + "/info.plist"))
        try env.tmp.write(root + "/" + orphan + "/Build/y.o", "y")
        try plist(["WorkspacePath": env.tmp.home + "/dev/deleted/Old.xcworkspace"], format: .xml)
            .write(to: URL(fileURLWithPath: root + "/" + orphan + "/info.plist"))
        // Unsaved_* matches the name rule but has no info.plist
        try env.tmp.write(root + "/Unsaved_Xcode_Document-cdefghijklmnopqrstuvwxyzabcd/Logs/l.txt", "x")
        // info.plist without WorkspacePath ⇒ fail closed
        try env.tmp.write(root + "/NoWP-defghijklmnopqrstuvwxyzabcde/Build/z.o", "z")
        try plist(["LastAccessedDate": Date()], format: .xml).write(to: URL(fileURLWithPath: root + "/NoWP-defghijklmnopqrstuvwxyzabcde/info.plist"))
        // shared dirs / wrong names / short hash
        try env.tmp.write(root + "/ModuleCache.noindex/a", "x")
        try env.tmp.write(root + "/Short-abc/info.plist", "x")
        try env.tmp.write(root + "/UPPER-ABCDEFGHIJKLMNOPQRSTUVWXYZAB/info.plist", "x")
        // symlinked child and a plain file
        try env.tmp.mkdir(env.tmp.root + "/elsewhere")
        try env.tmp.symlink(root + "/Link-efghijklmnopqrstuvwxyzabcdef", to: env.tmp.root + "/elsewhere")
        try env.tmp.write(root + "/File-fghijklmnopqrstuvwxyzabcdefg", "x")
        return (matched, orphan)
    }

    @Test func derivedDataMatchingUsesInfoPlist() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let (matched, orphan) = try derivedFixture(env)
        let children = env.catalog.engine.derived.children().map(\.name)
        #expect(children == [matched, orphan].sorted(), "only plist-backed, rule-conforming real directories: \(children)")

        let orphans = await env.catalog.orphanedDerivedData()
        #expect(orphans.map(\.instance) == [orphan])
        let o = try #require(orphans.first)
        #expect(o.defaultSelected == false)
        #expect(o.safety == .always)
        #expect(o.defaultMode == .permanent)
        #expect(o.packageDir == env.derivedRoot)
        #expect(o.id == "xcode.deriveddata@\(env.derivedRoot)#\(orphan)")
        #expect(o.title == "Xcode DerivedData: Gone")

        var opts = CatalogOptions()
        opts.includeDerivedData = true
        let r = try #require(await env.catalog.report(forProjectAt: env.tmp.project, options: opts))
        let derived = r.entries.filter { $0.ruleID == "xcode.deriveddata" }
        #expect(derived.map(\.instance) == [matched])
        #expect(derived.first?.defaultSelected == true)
        opts.includeDerivedData = false
        let r2 = try #require(await env.catalog.report(forProjectAt: env.tmp.project, options: opts))
        #expect(!r2.entries.contains { $0.ruleID == "xcode.deriveddata" })
    }

    @Test func derivedDataInstanceValidation() throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let (matched, _) = try derivedFixture(env)
        let dd = env.catalog.engine.derived
        #expect(dd.isValidInstance(matched))
        #expect(!dd.isValidInstance("../" + matched))
        #expect(!dd.isValidInstance(matched + "/Build"))
        #expect(!dd.isValidInstance("Unsaved_Xcode_Document-cdefghijklmnopqrstuvwxyzabcd"))
        #expect(!dd.isValidInstance("ModuleCache.noindex"))
        #expect(!dd.isValidInstance(""))
        #expect(DerivedDataLocator.matchesNameRule("A-abcdefghijklmnopqrstuvwxyzab"))
        #expect(!DerivedDataLocator.matchesNameRule("-abcdefghijklmnopqrstuvwxyzab"))
        #expect(!DerivedDataLocator.matchesNameRule("A-abcdefghijklmnopqrstuvwxyza"))
        #expect(!DerivedDataLocator.matchesNameRule("A-abcdefghijklmnopqrstuvwxyzabc"))
        #expect(DerivedDataLocator.displayName(of: "My-App-abcdefghijklmnopqrstuvwxyzab") == "My-App")
    }

    /// The confirmation sheet shows `targetPaths`: absolute, one per directory the rule will touch (never "a, b" glued onto
    /// one prefix), the exact discovered directories for discovered rules (see `CacheCleanerSafetyTests`), and
    /// `root/instance` for DerivedData.
    @Test func targetPathsAreTheAbsolutePathsTheConfirmationSheetShows() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        let t = env.tmp
        try t.packageJSON(at: t.project, deps: ["next"])
        try t.write(t.p("nx.json"))
        try t.write(t.p(".next/cache/a"), "x")
        try t.write(t.p(".nx/cache/a"), "x")
        try t.write(t.p(".nx/workspace-data/b"), "x")
        let r = try #require(await report(env))
        let next = try #require(r.entries.first { $0.ruleID == "next.cache" })
        #expect(next.targetPaths == [t.project + "/.next"])
        let nx = try #require(r.entries.first { $0.ruleID == "nx.cache" })
        #expect(nx.targetPaths == [t.project + "/.nx/cache", t.project + "/.nx/workspace-data"])

        let (_, orphan) = try derivedFixture(env)
        let o = try #require(await env.catalog.orphanedDerivedData().first)
        #expect(o.targetPaths == [env.derivedRoot + "/" + orphan])
    }
}
