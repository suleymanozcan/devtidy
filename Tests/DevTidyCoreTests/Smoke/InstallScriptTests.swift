import Foundation
import Testing
import Darwin
@testable import DevTidyCore

/// `scripts/install.sh` and `scripts/smoke.sh` must refuse an empty / relative / missing HOME before they build, copy or create
/// anything: with `HOME=""` the install target `$HOME/Applications/DevTidy.app` would silently become `/Applications/DevTidy.app`
/// (security F-12) and the smoke project `$HOME/devtidy-smoke-*` a path in the root.
///
/// The guard tests run the real scripts with `PATH` pointing nowhere, so even a regression in the guard could neither build
/// (`swift`) nor copy (`ditto`) nor touch any directory: it would die on the first external command. The guard itself uses only
/// builtins.
///
/// The install tests run a COPY of install.sh inside a temp tree, next to a fake `bundle.sh`, with `HOME` set to a temp directory:
/// the real `~/Applications` and the real app are never involved.
struct InstallScriptTests {
    private struct Outcome {
        let status: Int32
        let stderr: String
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)                       // Tests/DevTidyCoreTests/Smoke/InstallScriptTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func run(script: String, home: String?) throws -> Outcome {
        try run(executable: Self.repoRoot.appendingPathComponent(script).path, home: home, path: "/nonexistent")
    }

    private static func run(executable: String, home: String?, path: String) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [executable]
        var environment = ["PATH": path]
        if let home { environment["HOME"] = home }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
    }

    // MARK: HOME guard

    private static let unsafeHomes = [
        "",                              // /Applications/DevTidy.app
        "/",                             // //Applications/DevTidy.app
        "relative/home",                 // resolved against whatever the cwd is
        "/nonexistent-devtidy-install-test",
    ]

    @Test(arguments: unsafeHomes)
    func installRefusesAnUnsafeHome(home: String) throws {
        let outcome = try Self.run(script: "scripts/install.sh", home: home)
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("HOME must be an absolute path to an existing directory"))
    }

    @Test(arguments: unsafeHomes)
    func smokeRefusesAnUnsafeHome(home: String) throws {
        let outcome = try Self.run(script: "scripts/smoke.sh", home: home)
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("HOME must be an absolute path to an existing directory"))
    }

    @Test func bothRefuseAnUnsetHome() throws {
        for script in ["scripts/install.sh", "scripts/smoke.sh"] {
            let outcome = try Self.run(script: script, home: nil)
            #expect(outcome.status == 1, "\(script)")
            #expect(outcome.stderr.contains("HOME must be an absolute path to an existing directory"), "\(script)")
        }
    }

    // MARK: A throwaway install tree

    private struct Layout {
        let root: String
        var home: String { root + "/home" }
        var applications: String { home + "/Applications" }
        var installed: String { applications + "/DevTidy.app" }
        var script: String { root + "/repo/scripts/install.sh" }
        var shims: String { root + "/shims" }

        init() throws {
            let physical = PathPolicy.canonical(NSTemporaryDirectory())
            var template = Array((physical + "/devtidy-install-test-XXXXXX").utf8CString)
            guard mkdtemp(&template) != nil else { throw CocoaError(.fileWriteUnknown) }
            root = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let fm = FileManager.default
            try fm.createDirectory(atPath: root + "/repo/scripts", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: shims, withIntermediateDirectories: true)
            let real = InstallScriptTests.repoRoot.appendingPathComponent("scripts/install.sh")
            try fm.copyItem(at: real, to: URL(fileURLWithPath: script))
            try write(root + "/repo/scripts/bundle.sh", executable: true, """
            #!/bin/bash
            set -e
            mkdir -p build/DevTidy.app/Contents
            cat > build/DevTidy.app/Contents/Info.plist <<'PLIST'
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.minata.DevTidy</string></dict></plist>
            PLIST
            echo new > build/DevTidy.app/Contents/marker
            """)
        }

        func write(_ path: String, executable: Bool = false, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            if executable { chmod(path, 0o755) }
        }

        /// A previously installed DevTidy (same bundle id) with a marker file saying "old".
        func installOldApp() throws {
            try write(installed + "/Contents/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.minata.DevTidy</string></dict></plist>
            """)
            try write(installed + "/Contents/marker", "old\n")
        }

        func marker() -> String? {
            (try? String(contentsOfFile: installed + "/Contents/marker", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func names(in directory: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        }

        /// Removes ONLY this temp tree.
        func cleanup() {
            let base = PathPolicy.canonical(NSTemporaryDirectory())
            guard root.hasPrefix(base + "/devtidy-install-test-"), !root.contains("..") else { return }
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    private func runInstall(_ layout: Layout, path: String = "/usr/bin:/bin") throws -> Outcome {
        try Self.run(executable: layout.script, home: layout.home, path: path)
    }

    // MARK: install.sh

    @Test func aFreshInstallLandsInHomeApplicationsAndLeavesNoStaging() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let outcome = try runInstall(layout)
        #expect(outcome.status == 0, "\(outcome.stderr)")
        #expect(layout.marker() == "new")
        #expect(layout.names(in: layout.applications) == ["DevTidy.app"])
    }

    @Test func anUpgradeReplacesTheOldAppAndLeavesNoStaging() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        try layout.installOldApp()
        let outcome = try runInstall(layout)
        #expect(outcome.status == 0, "\(outcome.stderr)")
        #expect(layout.marker() == "new")
        #expect(layout.names(in: layout.applications) == ["DevTidy.app"])
    }

    @Test func aSymlinkedApplicationsDirectoryIsNeverInstalledThrough() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let elsewhere = layout.root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.applications, withDestinationPath: elsewhere)
        let outcome = try runInstall(layout)
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("symlink"))
        #expect(layout.names(in: elsewhere).isEmpty)
    }

    /// SIGTERM lands exactly between the two renames of the swap (the old app is already aside, the new one not yet in
    /// place). A `mv` shim performs the first rename for real and, instead of the second, sends SIGTERM to its parent: the
    /// install.sh this test started. The exit handler must put the old app back and clean up.
    @Test func anInterruptBetweenTheTwoRenamesPutsTheOldAppBack() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        try layout.installOldApp()
        try layout.write(layout.shims + "/mv", executable: true, """
        #!/bin/bash
        case "$1" in
            */.DevTidy-install.*/DevTidy.app) kill -TERM "$PPID"; exit 0 ;;
        esac
        exec /bin/mv "$@"
        """)
        let outcome = try runInstall(layout, path: layout.shims + ":/usr/bin:/bin")
        #expect(outcome.status == 143, "\(outcome.stderr)")
        #expect(layout.marker() == "old", "the previous app must be back in place")
        #expect(layout.names(in: layout.applications) == ["DevTidy.app"], "no staging directory is left behind")
        #expect(outcome.stderr.contains("the previous app was put back"))
    }
}
