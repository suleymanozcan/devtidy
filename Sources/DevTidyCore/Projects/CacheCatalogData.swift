import Foundation

/// The closed cache catalog (CAT §3–§6, transcribed from design §5.4). A path that is not in this table can never be deleted.
/// NEVER in the table: `.wrangler` (only `.wrangler/tmp`), `.wrangler/state`, `public` (except `gatsby.public`,
/// `public/build`, `public/hot`), `tmp .tmp temp .release release releases bin obj lib .data .vercel .venv venv env .tox
/// .ipynb_checkpoints .hypothesis .swiftpm .yarn pnpm-store storage/app storage/logs storage/framework/sessions
/// storage/framework/cache/data public/storage .env*`, single-file globs, global Go caches.
enum CatalogData {
    typealias Detect = CacheRule.Detect

    static let derivedDataRuleID = "xcode.deriveddata"

    static func rule(id: String) -> CacheRule? { byID[id] }

    private static let byID: [String: CacheRule] = {
        var d: [String: CacheRule] = [:]
        for r in rules { d[r.id] = r }
        return d
    }()

    // MARK: Shared detection fragments

    private static let nuxt = Detect.anyOf(.D("nuxt", "nuxt3"), .F("nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs"))
    private static let astro = Detect.anyOf(.D("astro"), .F("astro.config.mjs", "astro.config.ts", "astro.config.js"))
    private static let vite = Detect.anyOf(.D("vite"), .F("vite.config.ts", "vite.config.js", "vite.config.mjs", "vite.config.mts"))
    private static let remixClassic = Detect.anyOf(.D("@remix-run/dev", "@remix-run/node"), .F("remix.config.js", "remix.config.mjs"))
    private static let gatsby = Detect.anyOf(.D("gatsby"), .F("gatsby-config.js", "gatsby-config.ts", "gatsby-config.mjs"))
    private static let reactNative = Detect.D("react-native", "expo")
    private static let laravel = Detect(files: [["artisan"]], composerRequires: ["laravel/framework"])
    private static let python = Detect.F("pyproject.toml", "setup.py", "setup.cfg", "requirements*.txt", "Pipfile", "manage.py", "tox.ini")
    private static let xcode = Detect.F("*.xcodeproj", "*.xcworkspace")
    private static let gradle = Detect.F("settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts")

    // MARK: Table

    static let rules: [CacheRule] = [
        // — Next.js
        CacheRule("next.cache", "Next.js önbelleği", .always, .dir([".next"]), detect: .D("next"), defaultOn: true,
                  notes: ["sonraki next dev/build yeniden üretir", "tsc, .next/types yeniden üretilene kadar hata verebilir"]),
        CacheRule("next.out", "Next.js statik çıktısı (out)", .conditional, .dir(["out"]), detect: .D("next"),
                  notes: ["next build ile yeniden üretilir"]),
        CacheRule("next.opennext", "OpenNext çıktısı (.open-next)", .conditional, .dir([".open-next"]),
                  detect: .anyOf(.D("@opennextjs/cloudflare", "@opennextjs/aws"), .F("open-next.config.ts", "open-next.config.js")),
                  notes: ["dağıtım çıktısıdır; yeniden derleme gerekir"]),
        // — Nuxt
        CacheRule("nuxt.cache", "Nuxt önbelleği (.nuxt)", .always, .dir([".nuxt"]), detect: nuxt, defaultOn: true,
                  notes: ["nuxt dev/build/prepare yeniden üretir"]),
        CacheRule("nuxt.output", "Nuxt çıktısı (.output)", .conditional, .dir([".output"]), detect: nuxt,
                  notes: ["nuxt build ile yeniden üretilir"]),
        // — SvelteKit / Astro
        CacheRule("svelte.kit", "SvelteKit önbelleği (.svelte-kit)", .always, .dir([".svelte-kit"]), detect: .D("@sveltejs/kit"),
                  defaultOn: true, notes: ["svelte-kit sync/dev/build yeniden üretir"]),
        CacheRule("astro.cache", "Astro önbelleği (.astro)", .always, .dir([".astro"]), detect: astro, defaultOn: true,
                  notes: ["uzak içerik yükleyicileri yeniden indirir"]),
        CacheRule("astro.nm", "Astro görsel önbelleği", .always, .dir(["node_modules", ".astro"]), detect: astro, defaultOn: true),
        // — Vite / Vitest
        CacheRule("vite.nm", "Vite önbelleği", .always, .dir(["node_modules", ".vite"]), detect: vite, defaultOn: true,
                  notes: ["çalışan bir Vite sunucusu önce durdurulmalı"]),
        CacheRule("vite.tmp", "Vite geçici dosyaları", .always, .dir(["node_modules", ".vite-temp"]), detect: vite, defaultOn: true),
        CacheRule("vitest.cache", "Vitest önbelleği", .always, .dir(["node_modules", ".vitest-cache"]), detect: .D("vitest"),
                  defaultOn: true),
        // — Monorepo tools
        CacheRule("turbo.cache", "Turborepo önbelleği (.turbo)", .always, .dir([".turbo"]),
                  detect: Detect.anyOf(.F("turbo.json"), .D("turbo")).withAncestorOK(), defaultOn: true),
        CacheRule("nx.cache", "Nx önbelleği", .always, .dirs([[".nx", "cache"], [".nx", "workspace-data"]]),
                  detect: .F("nx.json"), defaultOn: true),
        CacheRule("parcel.cache", "Parcel önbelleği", .always, .dir([".parcel-cache"]),
                  detect: .anyOf(.D("parcel"), .F(".parcelrc")), defaultOn: true),
        CacheRule("ng.cache", "Angular önbelleği", .always, .dir([".angular", "cache"]),
                  detect: .anyOf(.F("angular.json"), .D("@angular/core")), defaultOn: true),
        // — Remix / React Router
        CacheRule("remix.cache", "Remix önbelleği (.cache)", .always, .dir([".cache"]), detect: remixClassic, defaultOn: true),
        CacheRule("remix.build", "Remix / React Router çıktısı (build)", .conditional, .dir(["build"]),
                  detect: .anyOf(remixClassic, .D("@react-router/dev"), .F("react-router.config.ts")),
                  notes: ["yeniden derleme gerekir"]),
        CacheRule("remix.pubbuild", "Remix istemci paketi (public/build)", .conditional, .dir(["public", "build"]),
                  detect: remixClassic, notes: ["yeniden derleme gerekir"]),
        CacheRule("rr.types", "React Router tipleri (.react-router)", .always, .dir([".react-router"]),
                  detect: .D("@react-router/dev"), defaultOn: true),
        // — Gatsby
        CacheRule("gatsby.cache", "Gatsby önbelleği (.cache)", .always, .dir([".cache"]), detect: gatsby, defaultOn: true),
        CacheRule("gatsby.public", "Gatsby çıktısı (public)", .conditional, .dir(["public"]), detect: gatsby,
                  notes: ["gatsby build ile yeniden üretilir"]),
        // — Generic Node / Cloudflare / tests
        CacheRule("node.cache", "Node önbelleği (node_modules/.cache)", .always, .dir(["node_modules", ".cache"]),
                  detect: .F("package.json"), defaultOn: true,
                  notes: ["wrangler hesap seçimi gibi önbelleğe alınmış tercihler yeniden sorulabilir"]),
        CacheRule("wrangler.tmp", "Wrangler geçici dosyaları", .always, .dir([".wrangler", "tmp"]),
                  detect: .F("wrangler.jsonc", "wrangler.json", "wrangler.toml"), defaultOn: true),
        CacheRule("test.artifacts", "Test raporları", .conditional,
                  .dirs([["coverage"], [".nyc_output"], ["playwright-report"], ["test-results"]]),
                  detect: .D("jest", "vitest", "nyc", "c8", "@playwright/test"),
                  notes: ["testler yeniden çalıştırılınca üretilir"]),
        // — Expo / React Native
        CacheRule("expo.state", "Expo durumu (.expo)", .always, .dir([".expo"]), detect: .D("expo"), defaultOn: true),
        CacheRule("rn.ios.build", "iOS derleme çıktısı (ios/build)", .conditional, .dir(["ios", "build"]),
                  detect: reactNative.and(.F("ios/*.xcodeproj", "ios/*.xcworkspace")), notes: ["yeniden derleme gerekir"]),
        CacheRule("rn.android.build", "Android derleme çıktısı", .conditional,
                  .dirs([["android", "build"], ["android", "app", "build"]]),
                  detect: reactNative.and(.F("android/build.gradle", "android/build.gradle.kts")),
                  notes: ["yeniden derleme gerekir"]),
        CacheRule("rn.pods", "CocoaPods bağımlılıkları (ios/Pods)", .optIn, .dir(["ios", "Pods"]),
                  detect: .F("ios/Podfile"), notes: ["yeniden kurulum ağ gerektirir"], reinstall: .fixed("pod install")),
        // — Laravel / PHP
        CacheRule("laravel.views", "Laravel derlenmiş görünümler", .always, .contentsOnly(["storage", "framework", "views"], .suffix(".php")),
                  detect: laravel, defaultOn: true, notes: ["sonraki istekte yeniden derlenir"]),
        CacheRule("laravel.bootcache", "Laravel önyükleme önbelleği", .conditional,
                  .contentsOnly(["bootstrap", "cache"], .exact(["packages.php", "services.php", "config.php", "events.php", "routes-v7.php"])),
                  detect: laravel,
                  notes: ["config.php / routes-v7.php silinirse yapılandırma önbelleksiz çalışır (env() yeniden okunur)"]),
        CacheRule("laravel.vitebuild", "Laravel Vite çıktısı (public/build)", .conditional, .dir(["public", "build"]),
                  detect: laravel.and(.D("laravel-vite-plugin")), notes: ["yeniden derleme gerekir"]),
        CacheRule("laravel.hot", "Laravel Vite sıcak dosyası (public/hot)", .always, .file(["public", "hot"], .laravelHot),
                  detect: laravel.and(.D("laravel-vite-plugin")), defaultOn: true,
                  notes: ["Vite sunucusu kapatılınca eskimiş kalır"]),
        CacheRule("php.phpunit", "PHPUnit önbelleği", .always, .dir([".phpunit.cache"]),
                  detect: .F("phpunit.xml", "phpunit.xml.dist"), defaultOn: true),
        CacheRule("php.vendor", "Composer bağımlılıkları (vendor)", .optIn, .dir(["vendor"]),
                  detect: Detect.F("composer.json").and(.F("composer.lock")),
                  notes: ["yeniden kurulum ağ gerektirir"], reinstall: .fixed("composer install")),
        // — Python
        CacheRule("py.pycache", "Python __pycache__ klasörleri", .always, .discovered(.pycache), detect: python, defaultOn: true),
        CacheRule("py.pytest", "pytest önbelleği", .always, .dir([".pytest_cache"]), detect: python, defaultOn: true),
        CacheRule("py.mypy", "mypy önbelleği", .always, .dir([".mypy_cache"]), detect: python, defaultOn: true),
        CacheRule("py.ruff", "ruff önbelleği", .always, .dir([".ruff_cache"]), detect: python, defaultOn: true),
        // — Rust / Swift / Xcode
        CacheRule("rust.target", "Rust derleme çıktısı (target)", .conditional, .dir(["target"]), detect: .F("Cargo.toml"),
                  notes: ["yeniden derleme uzun sürebilir"]),
        CacheRule("swiftpm.build", "SwiftPM derleme çıktısı (.build)", .conditional, .dir([".build"]), detect: .F("Package.swift"),
                  notes: ["bağımlılıklar yeniden indirilir"]),
        CacheRule("xcode.build", "Xcode derleme çıktısı (build)", .conditional, .dir(["build"]), detect: xcode,
                  notes: ["yeniden derleme gerekir"]),
        CacheRule("xcode.derived", "Proje içi DerivedData", .conditional, .dir(["DerivedData"]),
                  detect: xcode.and(Detect(requireDerivedDataInfoPlist: true)), notes: ["Xcode yeniden derler ve dizinler"]),
        // — Gradle / Android
        CacheRule("gradle.root", "Gradle önbelleği (.gradle)", .always, .dir([".gradle"]), detect: gradle, defaultOn: true),
        CacheRule("gradle.kotlin", "Kotlin oturum verisi (.kotlin)", .always, .dir([".kotlin"]), detect: gradle, defaultOn: true),
        CacheRule("gradle.native", "Android NDK önbelleği", .always, .dirs([[".cxx"], [".externalNativeBuild"]]),
                  detect: gradle, defaultOn: true),
        CacheRule("gradle.build", "Gradle modül çıktıları (build)", .conditional, .discovered(.gradleModules), detect: gradle,
                  notes: ["yeniden derleme gerekir"]),
        // — Flutter / Godot / Maven
        CacheRule("flutter.build", "Flutter derleme çıktısı (build)", .conditional, .dir(["build"]),
                  detect: Detect(files: [["pubspec.yaml"]], pubspecDeclaresFlutter: true), notes: ["yeniden derleme gerekir"]),
        CacheRule("flutter.dart_tool", "Dart araç verisi (.dart_tool)", .always, .dir([".dart_tool"]), detect: .F("pubspec.yaml"),
                  defaultOn: true, notes: ["flutter pub get yeniden üretir"]),
        CacheRule("godot.cache", "Godot içe aktarma önbelleği (.godot)", .always, .dir([".godot"]),
                  detect: Detect.F("project.godot").and(.F(".godot")), defaultOn: true,
                  notes: ["yeniden içe aktarma dakikalar sürebilir"]),
        CacheRule("maven.target", "Maven çıktısı (target)", .conditional, .dir(["target"]), detect: .F("pom.xml"),
                  notes: ["yeniden derleme gerekir"]),
        // — Generic dist
        CacheRule("dist.generic", "Derleme çıktısı (dist)", .conditional, .dir(["dist"]),
                  detect: .anyOf(Detect(needsBuildScript: true),
                                 .F("vite.config.*", "astro.config.*", "angular.json", "nuxt.config.*", ".parcelrc",
                                    "rollup.config.*", "webpack.config.*", "tsup.config.*")),
                  notes: ["yeniden derleme gerekir"]),
        // — Dependencies (opt-in)
        CacheRule("node.modules", "Node bağımlılıkları (node_modules)", .optIn, .dir(["node_modules"]),
                  detect: Detect(files: [["package.json"]], forbidFiles: [".pnp.cjs", ".pnp.js"],
                                 requireOneOfLockfiles: ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
                                                         "pnpm-lock.yaml", "bun.lock", "bun.lockb"]),
                  notes: ["yeniden kurulum ağ gerektirir"], reinstall: .fromLockfile),
        // — Global DerivedData (children of the Xcode DerivedData root)
        CacheRule(derivedDataRuleID, "Xcode DerivedData", .always, .discovered(.derivedDataChildren), detect: Detect(),
                  defaultOn: true, notes: ["Xcode yeniden derler ve dizinler"]),
    ]
}
