// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevTidy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DevTidy", targets: ["DevTidy"])],
    targets: [
        .target(name: "CDevTidyShim", path: "Sources/CDevTidyShim"),
        .target(name: "DevTidyCore", dependencies: ["CDevTidyShim"], path: "Sources/DevTidyCore"),
        .executableTarget(name: "DevTidy", dependencies: ["DevTidyCore"], path: "Sources/DevTidy"),
        .testTarget(name: "DevTidyCoreTests", dependencies: ["DevTidyCore"], path: "Tests/DevTidyCoreTests"),
    ]
)
