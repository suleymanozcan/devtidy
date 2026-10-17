import Foundation
import Testing
@testable import DevTidyCore

/// Pure functions of the process layer: KERN_PROCARGS2 layout, bind scope decoding, unit conversion, name predicates.
@Suite struct S1LibprocParsingTests {

    // MARK: KERN_PROCARGS2

    private func procArgs(argc: Int32, execPath: String, padding: Int = 3, args: [String], env: [String] = ["PATH=/usr/bin"]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(execPath.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for arg in args { bytes += Array(arg.utf8) + [0] }
        for variable in env { bytes += Array(variable.utf8) + [0] }
        return bytes
    }

    @Test func argumentsAreReadAfterTheExecPathAndPaddingAndEnvironmentIsIgnored() {
        let bytes = procArgs(argc: 3, execPath: "/usr/bin/node", args: ["node", "/x/y.js", "-p"], env: ["SECRET=hunter2", "A=1"])
        #expect(Libproc.parseArguments(bytes) == ["node", "/x/y.js", "-p"])
    }

    @Test func aRewrittenTitleLeavesEmptyTrailingArguments() {
        let bytes = procArgs(argc: 2, execPath: "/Users/x/node", args: ["next-server (v16.3.4)", ""])
        #expect(Libproc.parseArguments(bytes) == ["next-server (v16.3.4)", ""])
    }

    @Test func malformedBuffersYieldNoArguments() {
        #expect(Libproc.parseArguments([]) == [])
        #expect(Libproc.parseArguments([1, 0, 0]) == [])
        #expect(Libproc.parseArguments(procArgs(argc: 0, execPath: "/bin/sh", args: ["sh"])) == [])
        #expect(Libproc.parseArguments(procArgs(argc: -4, execPath: "/bin/sh", args: ["sh"])) == [])
    }

    @Test func aTruncatedBufferStopsAtItsEnd() {
        var bytes = procArgs(argc: 5, execPath: "/bin/sh", args: ["sh", "-c", "echo"], env: [])
        bytes.removeLast()      // last NUL gone
        #expect(Libproc.parseArguments(bytes) == ["sh", "-c", "echo"])
    }

    @Test func argcIsClampedSoAHostileBufferCannotAllocateUnbounded() {
        let bytes = procArgs(argc: Int32.max, execPath: "/bin/sh", args: ["a", "b"], env: [])
        #expect(Libproc.parseArguments(bytes) == ["a", "b"])
    }

    @Test func liveArgvOfThisProcessMatchesProcessInfo() {
        let argv = Libproc.argv(getpid())
        #expect(!argv.isEmpty)
        #expect(argv.first.map { ProcessNames.basename($0) } == ProcessInfo.processInfo.arguments.first.map { ProcessNames.basename($0) })
    }

    @Test func argvOfAMissingPidIsEmptyNotNil() {
        #expect(Libproc.argv(Int32.max - 7).isEmpty)
    }

    // MARK: Bind address

    private func bind(vflag: UInt8, _ address: [UInt8]) -> BindAddress? {
        address.withUnsafeBytes { Libproc.bindAddress(vflag: vflag, address: $0) }
    }

    private func scope(vflag: UInt8, _ address: [UInt8]) -> BindScope {
        bind(vflag: vflag, address)?.scope ?? .other
    }

    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] { [UInt8](repeating: 0, count: 12) + [a, b, c, d] }

    @Test func ipv4ScopesAreDecodedFromTheInAddrPartOfTheUnion() {
        #expect(scope(vflag: 0x1, v4(127, 0, 0, 1)) == .loopback)
        #expect(scope(vflag: 0x1, v4(127, 9, 9, 9)) == .loopback)
        #expect(scope(vflag: 0x1, v4(0, 0, 0, 0)) == .allInterfaces)
        #expect(scope(vflag: 0x1, v4(192, 168, 1, 20)) == .other)
    }

    @Test func ipv4BindsKeepTheExactAddress() {
        #expect(bind(vflag: 0x1, v4(127, 0, 0, 1)) == .ipv4(127, 0, 0, 1))
        #expect(bind(vflag: 0x1, v4(127, 9, 8, 7)) == .ipv4(127, 9, 8, 7))
        #expect(bind(vflag: 0x1, v4(0, 0, 0, 0)) == .ipv4Wildcard)
        #expect(bind(vflag: 0x1, v4(192, 168, 1, 20)) == .ipv4(192, 168, 1, 20))
    }

    @Test func ipv6ScopesIncludeDualStackWildcardsAndMappedV4() {
        let wildcard = [UInt8](repeating: 0, count: 16)
        var loopback = wildcard; loopback[15] = 1
        var mappedLoopback = wildcard; mappedLoopback[10] = 0xFF; mappedLoopback[11] = 0xFF; mappedLoopback[12] = 127; mappedLoopback[15] = 1
        var linkLocal = wildcard; linkLocal[0] = 0xFE; linkLocal[1] = 0x80; linkLocal[15] = 2
        #expect(scope(vflag: 0x2, wildcard) == .allInterfaces)        // `*:3000` bound to ::
        #expect(scope(vflag: 0x3, wildcard) == .allInterfaces)        // dual-stack wildcard carries both flags
        #expect(scope(vflag: 0x2, loopback) == .loopback)            // [::1]:5174
        #expect(scope(vflag: 0x2, mappedLoopback) == .loopback)
        #expect(scope(vflag: 0x2, linkLocal) == .other)
        #expect(scope(vflag: 0x0, wildcard) == .other)
        #expect(scope(vflag: 0x1, [1, 2, 3]) == .other)              // short buffer
    }

    @Test func ipv6BindsKeepTheExactAddressAndTellDualStackFromV6Only() {
        let wildcard = [UInt8](repeating: 0, count: 16)
        var loopback = wildcard; loopback[15] = 1
        var mappedLoopback = wildcard; mappedLoopback[10] = 0xFF; mappedLoopback[11] = 0xFF; mappedLoopback[12] = 127; mappedLoopback[15] = 1
        var mappedWildcard = wildcard; mappedWildcard[10] = 0xFF; mappedWildcard[11] = 0xFF
        var linkLocal = wildcard; linkLocal[0] = 0xFE; linkLocal[1] = 0x80; linkLocal[15] = 2
        #expect(bind(vflag: 0x2, loopback) == .ipv6Loopback)                          // [::1]:5173, one family only
        #expect(bind(vflag: 0x2, wildcard) == .ipv6Wildcard(dualStack: false))        // IPV6_V6ONLY
        #expect(bind(vflag: 0x3, wildcard) == .ipv6Wildcard(dualStack: true))         // node's default `::`
        #expect(bind(vflag: 0x2, linkLocal) == .ipv6(high: 0xFE80_0000_0000_0000, low: 2, dualStack: false))
        // a v4-mapped bind is an IPv4 bind: only IPv4 connections reach it
        #expect(bind(vflag: 0x2, mappedLoopback) == .ipv4(127, 0, 0, 1))
        #expect(bind(vflag: 0x2, mappedWildcard) == .ipv4Wildcard)
        #expect(bind(vflag: 0x0, wildcard) == nil)
        #expect(bind(vflag: 0x1, [1, 2, 3]) == nil)
    }

    // MARK: Units

    @Test func machTicksConvertWithoutOverflowAndMonotonically() {
        #expect(Libproc.nanoseconds(fromMachTicks: 0) == 0)
        let a = Libproc.nanoseconds(fromMachTicks: 24_000_000)
        let b = Libproc.nanoseconds(fromMachTicks: 48_000_000)
        #expect(a > 0 && b >= a)
        // Two years of CPU time at 24 MHz must not trap or wrap.
        let huge = Libproc.nanoseconds(fromMachTicks: 24_000_000 * 3600 * 24 * 365 * 2)
        #expect(huge > Libproc.nanoseconds(fromMachTicks: 24_000_000 * 3600 * 24 * 365))
    }

    // MARK: Name predicates

    private func node(name: String, exe: String? = nil, args: [String]? = nil) -> ProcessNode {
        S1SnapshotBuilder.node(100, ppid: 1, name: name, exe: exe, args: args)
    }

    @Test func runtimesAreRecognisedByNameBasenameAndPythonApp() {
        #expect(ProcessNames.isRuntime(node(name: "node")))
        #expect(ProcessNames.isRuntime(node(name: "Python")))
        #expect(ProcessNames.isRuntime(node(name: "x", exe: "/a/b/node")))
        #expect(ProcessNames.isRuntime(node(name: "Python", exe: "/Applications/Xcode.app/x/Python.app/Contents/MacOS/Python")))
        #expect(ProcessNames.isRuntime(node(name: "workerd")))
        #expect(!ProcessNames.isRuntime(node(name: "omp", exe: "/Users/x/.local/bin/omp")))
        #expect(!ProcessNames.isRuntime(node(name: "Safe", exe: "/Applications/Safe.app/Contents/MacOS/Safe")))
    }

    @Test func dockerBackendMatchesTheTruncatedKernelName() {
        #expect(ProcessNames.isDockerBackend(node(name: "com.docker.backe")))
        #expect(ProcessNames.isDockerBackend(node(name: "com.docker.vpnki")))
        #expect(ProcessNames.isDockerBackend(node(name: "OrbStack")))
        #expect(ProcessNames.isDockerBackend(node(name: "x", exe: "/Applications/Docker.app/Contents/MacOS/anything")))
        #expect(!ProcessNames.isDockerBackend(node(name: "node")))
    }

    @Test func launchersAreFoundThroughTitlesScriptsAndDashCShells() {
        #expect(ProcessNames.isLauncher(node(name: "node", args: ["npm exec next dev -p 3000"])))
        #expect(ProcessNames.isLauncher(node(name: "node", exe: "/x/node", args: ["/x/node", "/usr/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"])))
        #expect(ProcessNames.isLauncher(node(name: "node", exe: "/x/node", args: ["/x/node", "/p/node_modules/.bin/turbo", "run", "dev"])))
        #expect(ProcessNames.isLauncher(node(name: "pnpm")))
        #expect(ProcessNames.isLauncher(node(name: "sh", args: ["sh", "-c", "vite"])))
        #expect(ProcessNames.isLauncher(node(name: "zsh", args: ["zsh", "-lc", "npm run dev"])))
        #expect(!ProcessNames.isLauncher(node(name: "zsh", args: ["-zsh"])))
        #expect(!ProcessNames.isLauncher(node(name: "sh", args: ["sh", "script.sh", "-c", "x"])))
        #expect(!ProcessNames.isLauncher(node(name: "node", exe: "/x/node", args: ["/x/node", "server.js"])))
        #expect(!ProcessNames.isLauncher(node(name: "fish", args: ["fish", "-c", "npm run dev"])))   // fish is not a launcher shell
    }

    @Test func shellsTerminalsIdesAndAgentsAreNeverKillRoots() {
        #expect(ProcessNames.isShellTerminalIDEOrAgent(node(name: "zsh", args: ["-zsh"])))
        #expect(ProcessNames.isShellTerminalIDEOrAgent(node(name: "fish", args: ["fish", "-c", "x"])) == false)
        #expect(ProcessNames.isShellTerminalIDEOrAgent(node(name: "sh", args: ["sh", "-c", "x"])) == false)
        for name in ["login", "launchd", "iTerm2", "iTermServer", "Terminal", "Ghostty", "Warp", "WezTerm", "Alacritty", "kitty", "tmux",
                     "screen", "Code", "Cursor", "Xcode", "Zed", "omp", "claude"] {
            #expect(ProcessNames.isShellTerminalIDEOrAgent(node(name: name)), "\(name)")
        }
        #expect(ProcessNames.isShellTerminalIDEOrAgent(node(name: "node", args: ["omp", "__omp_worker_daemon_broker"])))
        #expect(!ProcessNames.isShellTerminalIDEOrAgent(node(name: "node", exe: "/x/node", args: ["/x/node", "code.js"])))
        #expect(!ProcessNames.isShellTerminalIDEOrAgent(node(name: "workerd")))
    }

    @Test func commandFlagDetectionStopsAtTheFirstNonFlagArgument() {
        #expect(ProcessNames.hasCommandFlag(node(name: "bash", args: ["bash", "-c", "x"])))
        #expect(ProcessNames.hasCommandFlag(node(name: "bash", args: ["bash", "-ic", "x"])))
        #expect(ProcessNames.hasCommandFlag(node(name: "bash", args: ["bash", "-o", "pipefail", "-c", "x"])))
        #expect(!ProcessNames.hasCommandFlag(node(name: "bash", args: ["bash", "script", "-c"])))
        #expect(!ProcessNames.hasCommandFlag(node(name: "bash", args: ["bash", "--rcfile", "x"])))
        #expect(!ProcessNames.hasCommandFlag(node(name: "bash", args: ["-bash"])))
        #expect(!ProcessNames.hasCommandFlag(node(name: "bash", args: nil)))
    }

    @Test func tokensSplitOnlyARewrittenTitle() {
        #expect(ProcessNames.tokens(of: node(name: "node", args: ["npm exec next dev -p 3000", ""])) == ["npm", "exec", "next", "dev", "-p", "3000"])
        #expect(ProcessNames.tokens(of: node(name: "node", args: ["/x/node", "a b"])) == ["/x/node", "a b"])
        #expect(ProcessNames.tokens(of: node(name: "node", args: ["/Users/me/My Tool/bin"])) == ["/Users/me/My Tool/bin"])
        #expect(ProcessNames.tokens(of: node(name: "node", args: nil)).isEmpty)
    }
}
