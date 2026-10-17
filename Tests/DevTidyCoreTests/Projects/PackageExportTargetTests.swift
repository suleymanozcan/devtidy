import Foundation
import Testing
@testable import DevTidyCore

/// One `package.json` whose own entry fields (do not) point into `dist`.
struct S2ExportCase: Sendable, CustomTestStringConvertible {
    let name: String
    let manifest: String
    var testDescription: String { name }

    /// A buildable package (build script, so `dist.generic` detects) carrying one extra top-level JSON member.
    static func with(_ name: String, _ member: String) -> S2ExportCase {
        S2ExportCase(name: name, manifest: "{\"name\":\"app\",\"scripts\":{\"build\":\"x\"},\"devDependencies\":{\"left-pad\":\"1\"},\(member)}")
    }
}

@Suite("Package export targets are never offered (QA F1)")
struct PackageExportTargetTests {
    static let referencing: [S2ExportCase] = [
        .with("main", "\"main\":\"dist/index.js\""),
        .with("main with ./", "\"main\":\"./dist/index.js\""),
        .with("module", "\"module\":\"dist/index.es.js\""),
        .with("types", "\"types\":\"dist/types/index.d.ts\""),
        .with("typings", "\"typings\":\"./dist/index.d.ts\""),
        .with("exports string", "\"exports\":\"./dist/index.js\""),
        .with("exports with nested conditions",
              "\"exports\":{\".\":{\"import\":{\"types\":\"./dist/index.d.mts\",\"default\":\"./dist/index.mjs\"},\"require\":\"./dist/index.cjs\"},\"./styles.css\":\"./dist/styles.css\"}"),
        .with("exports array fallback", "\"exports\":{\".\":[\"./dist/a.js\",\"./fallback.js\"]}"),
        .with("bin string", "\"bin\":\"dist/cli.js\""),
        .with("bin map", "\"bin\":{\"tool\":\"./dist/cli.js\"}"),
        .with("files dist", "\"files\":[\"dist\"]"),
        .with("files dist glob", "\"files\":[\"dist/**/*\"]"),
        .with("files ./dist/", "\"files\":[\"./dist/\"]"),
        .with("files match-everything glob", "\"files\":[\"**/*.js\"]"),
        .with("directories", "\"directories\":{\"lib\":\"dist\"}"),
        .with("browser string", "\"browser\":\"dist/browser.js\""),
        .with("browser map", "\"browser\":{\"./a.js\":\"./dist/a.js\"}"),
        .with("typesVersions", "\"typesVersions\":{\"*\":{\"*\":[\"dist/*\"]}}"),
        .with("different letter case", "\"main\":\"./Dist/index.js\""),
        // the real marketing package of the QA report
        S2ExportCase(name: "QA F1 marketing package", manifest: """
            {"name":"minata-rental-suite","scripts":{"dev":"next dev","build":"next build","build:ds":"node scripts/build-ds.mjs"},
             "module":"dist/index.es.js","types":"dist/types/index.d.ts",
             "exports":{".":{"types":"./dist/types/index.d.ts","import":"./dist/index.es.js"},"./styles.css":"./dist/styles.css"},
             "dependencies":{"next":"15.0.0"}}
            """),
    ]

    static let notReferencing: [S2ExportCase] = [
        .with("main elsewhere", "\"main\":\"index.js\""),
        .with("files list without dist and a negation", "\"files\":[\"src\",\"!dist/ignored\"]"),
        .with("a sibling that merely starts with the name", "\"main\":\"dist-extra/x.js\""),
        .with("a key (not a value) named like dist", "\"exports\":{\"./dist\":\"./src/x.js\"}"),
        .with("a reference that climbs out of the package", "\"types\":\"../dist/x.d.ts\""),
        .with("no entry fields at all", "\"private\":true"),
    ]

    private func opts() -> CatalogOptions {
        var o = CatalogOptions()
        o.includeDerivedData = false
        return o
    }

    private func ids(_ env: S2Env) async throws -> Set<String> {
        let report = try #require(await env.catalog.report(forProjectAt: env.tmp.project, options: opts()))
        return Set(report.entries.map(\.ruleID))
    }

    private func fixture(_ env: S2Env, manifest: String) throws {
        try env.tmp.write(env.tmp.p("package.json"), manifest)
        try env.tmp.write(env.tmp.p("dist/index.js"), String(repeating: "x", count: 4096))
        env.git.ignored = [env.tmp.p("dist")]
    }

    @Test(arguments: PackageExportTargetTests.referencing)
    func aBuildOutputThePackageExportsIsNeverOffered(_ c: S2ExportCase) async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try fixture(env, manifest: c.manifest)
        #expect(!(try await ids(env)).contains("dist.generic"), "\(c.name)")
    }

    @Test(arguments: PackageExportTargetTests.notReferencing)
    func aBuildOutputNobodyPointsAtIsStillOffered(_ c: S2ExportCase) async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try fixture(env, manifest: c.manifest)
        #expect((try await ids(env)).contains("dist.generic"), "\(c.name)")
    }

    @Test func theQAScenarioKeepsTheCachesAndDropsTheExportTarget() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try fixture(env, manifest: Self.referencing.last?.manifest ?? "")
        try env.tmp.write(env.tmp.p(".next/cache/x.bin"), "x")
        let found = try await ids(env)
        #expect(found.contains("next.cache"), "class A caches are unaffected")
        #expect(!found.contains("dist.generic"))
    }

    @Test func otherClassBOutputsFollowTheSameRule() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.tmp.write(env.tmp.p("Cargo.toml"), "[package]")
        try env.tmp.write(env.tmp.p("target/wasm/index.js"), "x")
        env.git.ignored = [env.tmp.p("target")]
        try env.tmp.write(env.tmp.p("package.json"), "{\"name\":\"w\"}")
        #expect(try await ids(env).contains("rust.target"))
        try env.tmp.write(env.tmp.p("package.json"), "{\"name\":\"w\",\"main\":\"target/wasm/index.js\"}")
        #expect(!(try await ids(env)).contains("rust.target"), "a wasm package whose main lives in target/")
    }

    @Test func classAIsNeverSuppressedByTheRule() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try env.makeNextProject()
        try env.tmp.write(env.tmp.p("package.json"),
                          "{\"name\":\"a\",\"main\":\".next/server.js\",\"files\":[\".next\"],\"devDependencies\":{\"next\":\"1\"}}")
        #expect(try await ids(env).contains("next.cache"))
    }

    /// The cleaner re-reads the manifest: a package that starts exporting `dist` after the plan keeps it.
    @Test func theCleanerRefusesATargetThatBecameAnExportAfterThePlan() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try fixture(env, manifest: S2ExportCase.with("none", "\"private\":true").manifest)
        var o = CatalogOptions()
        o.includeDerivedData = false
        let p = try #require(await env.cleaner.makePlan(forProjectAt: env.tmp.project, options: o))
        let e = try #require(p.entries.first { $0.ruleID == "dist.generic" })
        try env.tmp.write(env.tmp.p("package.json"), S2ExportCase.with("now exporting", "\"module\":\"dist/index.es.js\"").manifest)
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        #expect(r.outcomes.first { $0.entryID == e.id }?.status == .skipped(.packageOutput))
        #expect(env.tmp.exists(env.tmp.p("dist/index.js")))
        #expect(env.audit.events.map(\.result) == ["skipped:packageOutput"])
    }

    // MARK: I-7 — a manifest that cannot be read is no licence to delete

    static let unreadable: [S2ExportCase] = [
        S2ExportCase(name: "invalid JSON", manifest: "{ not json"),
        S2ExportCase(name: "not an object", manifest: "[\"dist\"]"),
        S2ExportCase(name: "larger than the read bound", manifest: "{\"name\":\"w\",\"x\":\"" + String(repeating: "a", count: (1 << 20) + 16) + "\"}"),
    ]

    private func wasmCrate(_ env: S2Env) throws {
        try env.tmp.write(env.tmp.p("Cargo.toml"), "[package]")
        try env.tmp.write(env.tmp.p("target/wasm/index.js"), "x")
        env.git.ignored = [env.tmp.p("target")]
    }

    @Test(arguments: PackageExportTargetTests.unreadable)
    func aBuildOutputNextToAnUnreadablePackageManifestIsNeverOffered(_ c: S2ExportCase) async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try wasmCrate(env)
        try env.tmp.write(env.tmp.p("package.json"), c.manifest)
        #expect(!(try await ids(env)).contains("rust.target"), "\(c.name): the manifest might export target/")
        // no package.json at all: nothing can be exported, the output is offered
        try FileManager.default.removeItem(atPath: env.tmp.p("package.json"))
        #expect(try await ids(env).contains("rust.target"))
    }

    @Test func theCleanerRefusesATargetWhoseManifestBecameUnreadableAfterThePlan() async throws {
        let env = try S2Env()
        defer { env.tmp.cleanup() }
        try wasmCrate(env)
        var o = CatalogOptions()
        o.includeDerivedData = false
        let p = try #require(await env.cleaner.makePlan(forProjectAt: env.tmp.project, options: o))
        let e = try #require(p.entries.first { $0.ruleID == "rust.target" })
        try env.tmp.write(env.tmp.p("package.json"), "{ not json")
        let r = try await env.cleaner.execute(p, selections: [CleanupSelection(entryID: e.id, mode: .permanent)], progress: nil)
        #expect(r.outcomes.first { $0.entryID == e.id }?.status == .skipped(.packageOutput))
        #expect(env.tmp.exists(env.tmp.p("target/wasm/index.js")))
        #expect(env.audit.events.map(\.result) == ["skipped:packageOutput"])
    }

    // MARK: Parsing and matching

    @Test func referencesAreNormalizedAndUnusablesDropped() {
        #expect(PackageEntryPaths.components(ofReference: "./dist/index.js") == ["dist", "index.js"])
        #expect(PackageEntryPaths.components(ofReference: "/dist") == ["dist"])
        #expect(PackageEntryPaths.components(ofReference: "a/../b") == ["b"])
        #expect(PackageEntryPaths.components(ofReference: "dist//x/./y") == ["dist", "x", "y"])
        #expect(PackageEntryPaths.components(ofReference: "../x") == nil)
        #expect(PackageEntryPaths.components(ofReference: "!dist/x") == nil)
        #expect(PackageEntryPaths.components(ofReference: "") == nil)
        #expect(PackageEntryPaths.components(ofReference: ".") == nil)
    }

    @Test func overlapMeansOnePathIsAPrefixOfTheOther() {
        func o(_ r: [String], _ t: [String]) -> Bool { PackageEntryPaths.overlaps(reference: r, target: t) }
        #expect(o(["dist", "index.js"], ["dist"]))
        #expect(o(["dist"], ["dist", "sub"]), "files: [dist] covers everything below it")
        #expect(!o(["dist-extra"], ["dist"]))
        #expect(!o(["src", "dist"], ["dist"]))
        #expect(o(["Dist"], ["dist"]), "case-insensitive volumes")
        #expect(o(["*"], ["dist"]) && o(["**"], ["dist"]) && o(["d?st"], ["dist"]) && o(["d*"], ["dist"]))
        #expect(!o(["*.js"], ["dist"]) && !o(["d?t"], ["dist"]))
        #expect(o(["{a,b}"], ["anything"]) && o(["[ab]"], ["anything"]), "patterns that cannot be evaluated match everything")
    }

    @Test func onlyValuesOfTheEntryFieldsAreCollected() throws {
        let t = try S2TempDir()
        defer { t.cleanup() }
        try t.write(t.p("package.json"), """
            {"name":"m","module":"dist/index.es.js","exports":{".":{"import":"./dist/a.js"},"./styles.css":"./dist/styles.css"},
             "files":["dist","!dist/skip"],"scripts":{"build":"node build/x.mjs"},"homepage":"https://example.com/dist"}
            """)
        let m = try #require(PackageManifest.load(directory: t.project))
        let paths = Set(m.entryPaths)
        #expect(paths == [["dist", "index.es.js"], ["dist", "a.js"], ["dist", "styles.css"], ["dist"]])
        #expect(!paths.contains(["styles.css"]), "an exports KEY is a subpath, not a file reference")
        #expect(m.referencesPath(["dist"]) && !m.referencesPath(["build"]), "scripts and unrelated fields are not entry fields")
    }
}
