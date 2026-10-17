// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevTidy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DevTidy", targets: ["DevTidy"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "CDevTidyShim", path: "Sources/CDevTidyShim"),
        .target(name: "DevTidyCore", dependencies: ["CDevTidyShim"], path: "Sources/DevTidyCore"),
        .executableTarget(
            name: "DevTidy",
            dependencies: [
                "DevTidyCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DevTidy",
            // scripts/bundle.sh embeds Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "DevTidyCoreTests", dependencies: ["DevTidyCore"], path: "Tests/DevTidyCoreTests"),
    ]
)
