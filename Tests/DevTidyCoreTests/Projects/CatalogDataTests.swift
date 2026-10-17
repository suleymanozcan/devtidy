import Foundation
import Testing
@testable import DevTidyCore

/// Invariants of the closed catalog. What each rule DOES is covered behaviorally by `CacheEvaluatorTests` and
/// `CacheCleanerTests`; nothing here restates the table.
@Suite("CatalogData (D9, §5.4 invariants)")
struct CatalogDataTests {
    private var rules: [CacheRule] { CatalogData.rules }

    @Test func everyCatalogIDIsUnique() {
        let ids = rules.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func componentsAreLiteralAndSafe() {
        for rule in rules {
            for comps in rule.allComponentLists {
                #expect(!comps.isEmpty, "\(rule.id)")
                for c in comps {
                    #expect(!c.isEmpty && c != "." && c != "..", "\(rule.id): \(c)")
                    #expect(!c.contains("/") && !c.contains("\0"), "\(rule.id): \(c)")
                    #expect(c.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]{}\\")) == nil, "\(rule.id): \(c)")
                    // `CacheEntry.targetPaths` splits `displayPath` on this separator: a component must never contain it
                    #expect(!c.contains(CacheEntry.displaySeparator), "\(rule.id): \(c)")
                }
            }
        }
    }

    @Test func forbiddenFirstComponentsNeverAppear() {
        let forbidden: Set<String> = [".git", "src", "app", "lib", "docs"]
        for rule in rules {
            for comps in rule.allComponentLists { #expect(!forbidden.contains(comps[0]), "\(rule.id)") }
        }
    }

    @Test func publicOnlyInTheNamedExceptions() {
        let allowed: Set<String> = ["gatsby.public", "remix.pubbuild", "laravel.vitebuild", "laravel.hot"]
        for rule in rules {
            for comps in rule.allComponentLists where comps[0] == "public" {
                #expect(allowed.contains(rule.id), "\(rule.id) offers public")
                if rule.id != "gatsby.public" { #expect(comps == ["public", "build"] || comps == ["public", "hot"]) }
            }
        }
    }

    @Test func wranglerOnlyTmpAndStorageOnlyViews() {
        for rule in rules {
            for comps in rule.allComponentLists {
                if comps[0] == ".wrangler" { #expect(comps == [".wrangler", "tmp"], "\(rule.id)") }
                if comps[0] == "storage" { #expect(comps == ["storage", "framework", "views"], "\(rule.id)") }
            }
        }
    }

    @Test func neverOfferedNamesAreAbsent() {
        let never: Set<String> = ["tmp", ".tmp", "temp", ".release", "release", "releases", "bin", "obj", "lib", ".data", ".vercel",
                                  ".venv", "venv", "env", ".tox", ".ipynb_checkpoints", ".hypothesis", ".swiftpm", ".yarn", "pnpm-store"]
        for rule in rules {
            for comps in rule.allComponentLists {
                // `.wrangler/tmp` is the one sanctioned use of `tmp` (pinned by wranglerOnlyTmpAndStorageOnlyViews)
                if comps != [".wrangler", "tmp"] { #expect(comps.allSatisfy { !never.contains($0) }, "\(rule.id)") }
                #expect(comps.allSatisfy { !$0.hasPrefix(".env") }, "\(rule.id)")
                #expect(comps.last != ".git", "\(rule.id)")
            }
        }
    }

    /// Only class A is ever pre-selected: a class B/C row must always be an explicit user choice.
    @Test func onlyClassAIsPreselected() {
        for rule in rules where rule.defaultOn { #expect(rule.safety == .always, "\(rule.id)") }
    }

    @Test func globMatching() {
        #expect(CacheEvaluator.globMatches("*.xcodeproj", "App.xcodeproj"))
        #expect(!CacheEvaluator.globMatches("*.xcodeproj", ".xcodeprojx"))
        #expect(CacheEvaluator.globMatches("requirements*.txt", "requirements-dev.txt"))
        #expect(CacheEvaluator.globMatches("requirements*.txt", "requirements.txt"))
        #expect(CacheEvaluator.globMatches("vite.config.*", "vite.config.ts"))
        #expect(!CacheEvaluator.globMatches("vite.config.*", "vite.config"))
    }
}
