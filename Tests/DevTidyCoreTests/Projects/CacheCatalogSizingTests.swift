import Foundation
import Testing
@testable import DevTidyCore

@Suite("CacheCatalog size cache (P2-5)")
struct CacheCatalogSizingTests {
    @Test func expiredSizesAreEvictedWhenANewOneIsInserted() async throws {
        let clock = S2Clock()
        let env = try S2Env(clock: clock)
        defer { env.tmp.cleanup() }
        try env.tmp.packageJSON(at: env.tmp.project, deps: ["next", "vite"])
        try env.tmp.write(env.tmp.p(".next/a.bin"), String(repeating: "a", count: 4096))
        try env.tmp.write(env.tmp.p("node_modules/.vite/b.bin"), String(repeating: "b", count: 4096))
        var options = CatalogOptions()
        options.includeDerivedData = false
        let report = try #require(await env.catalog.report(forProjectAt: env.tmp.project, options: options))
        #expect(report.entries.count == 2)

        for e in report.entries { _ = await env.catalog.size(of: e) }
        #expect(await env.catalog.cachedSizeCount == 2)
        // a repeated request inside the TTL is a cache hit and adds nothing
        _ = await env.catalog.size(of: report.entries[0])
        #expect(await env.catalog.cachedSizeCount == 2)

        // entries of projects that were deleted or renamed never come back: once past the TTL the next insert drops them
        clock.advance(CacheCatalog.sizeTTL + 1)
        _ = await env.catalog.size(of: report.entries[0])
        #expect(await env.catalog.cachedSizeCount == 1)
    }

    /// CodeReview P3-9: dropping the expired sizes filtered the whole dictionary on every insert (quadratic over a big
    /// builds scan). The sweep now runs at most once per half TTL; an expired size that is still held is never served (the
    /// hit test checks the TTL itself).
    @Test func expiredSizesAreSweptAtMostOncePerHalfTheTTL() async throws {
        let clock = S2Clock()
        let env = try S2Env(clock: clock)
        defer { env.tmp.cleanup() }
        var options = CatalogOptions()
        options.includeDerivedData = false
        var entries: [CacheEntry] = []
        for name in ["a", "b", "c", "d"] {
            let app = env.tmp.p("apps/\(name)")
            try env.tmp.packageJSON(at: app, deps: ["next"])
            try env.tmp.write(app + "/.next/x.bin", String(repeating: "x", count: 4096))
            let report = try #require(await env.catalog.report(forProjectAt: app, options: options))
            entries.append(try #require(report.entries.first { $0.ruleID == "next.cache" && $0.packageDir == app }))
        }
        let ttl = CacheCatalog.sizeTTL

        _ = await env.catalog.size(of: entries[0])                 // t = 0: the first insert (nothing to sweep yet)
        clock.advance(ttl * 0.6)
        _ = await env.catalog.size(of: entries[1])                 // t = 0.6 ttl: a sweep is due, `a` is still fresh
        #expect(await env.catalog.cachedSizeCount == 2)
        clock.advance(ttl * 0.45)
        _ = await env.catalog.size(of: entries[2])                 // t = 1.05 ttl: `a` expired, but the last sweep was 0.45 ttl ago
        #expect(await env.catalog.cachedSizeCount == 3, "no sweep on this insert: the expired size is still held")
        clock.advance(ttl * 0.15)
        _ = await env.catalog.size(of: entries[3])                 // t = 1.2 ttl: a sweep is due again and drops `a`
        #expect(await env.catalog.cachedSizeCount == 3, "b, c and d remain")
    }
}
