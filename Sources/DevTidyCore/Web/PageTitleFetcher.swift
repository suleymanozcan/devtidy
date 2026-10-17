import Foundation
import os

/// One server, as far as the title fetch is concerned: the tree root's identity (pid + start time, so a restarted server on
/// the same port is a new target), the port to ask and the loopback addresses to ask it on.
public struct PageTitleTarget: Hashable, Sendable {
    public let server: ProcessIdentity
    public let port: UInt16
    /// Tried in this order. Each one reaches a socket of `server` itself on `port` and no other process's: a port is often
    /// shared by sockets of several processes (a Vite server on `[::1]:5173`, a Docker container published on
    /// `127.0.0.1:5173`), and a connection to the wrong address is answered by the wrong one. Part of the identity, so a title
    /// read through one set of addresses is never reused for another.
    let addresses: [LoopbackAddress]

    init(server: ProcessIdentity, port: UInt16, addresses: [LoopbackAddress]) {
        self.server = server
        self.port = port
        self.addresses = addresses
    }

    /// What the title fetch may do about one server.
    enum Selection: Equatable, Sendable {
        /// Ask this target.
        case ask(PageTitleTarget)
        /// Not asked: no main port, an inspector port (declared by the argv or one of 9229–9231), or sockets that no loopback
        /// address reaches (every bind is to one specific non-loopback address).
        case notApplicable
        /// Not asked: every loopback address that reaches the server's sockets is taken by another process's more specific
        /// socket on the same port, so the answer would not be the server's.
        case shared
    }

    /// The target DevTidy asks, or nil when this server must not be asked (see `Selection`). Only dev servers get here at all;
    /// "other" listeners (tools, apps, system) never do.
    public static func make(for server: DevServer, in scan: ServerScan) -> PageTitleTarget? {
        if case .ask(let target) = select(for: server, in: scan) { return target }
        return nil
    }

    /// The server's main-port sockets decide the addresses: a specific loopback bind is asked at that address, an IPv4 wildcard at
    /// `127.0.0.1`, an IPv6 wildcard at `::1` (and at `127.0.0.1` when the socket is dual-stack). An address is dropped when a
    /// socket of another process in `scan` takes a connection to it at least as firmly as the server's own (a more specific bind;
    /// an equally specific one is a `SO_REUSEPORT` pair, where the kernel picks either).
    static func select(for server: DevServer, in scan: ServerScan) -> Selection {
        guard let port = server.mainPort, !server.declaredInspectorPorts.contains(port),
              !ListeningPort.inspectorPorts.contains(port) else { return .notApplicable }
        let own = server.ports.filter { $0.port == port }
        let binds = own.reduce(into: Set<BindAddress>()) { $0.formUnion($1.binds) }
        let candidates = Set(binds.flatMap(\.loopbackAddresses)).sorted { $0.order < $1.order }
        guard !candidates.isEmpty else { return .notApplicable }

        let ownPIDs = Set(server.members.map(\.pid)).union(own.map(\.ownerPID))
        var rivals: [BindAddress] = []
        for (pid, listeners) in scan.listeners where !ownPIDs.contains(pid) {
            for listener in listeners where listener.port == port { rivals.append(contentsOf: listener.binds) }
        }
        let reachable = candidates.filter { address in
            let ours = binds.compactMap { $0.claim(on: address) }.max() ?? 0
            return !rivals.contains { ($0.claim(on: address) ?? -1) >= ours }
        }
        return reachable.isEmpty ? .shared : .ask(PageTitleTarget(server: server.id, port: port, addresses: reachable))
    }
}

extension BindAddress {
    /// The loopback addresses that reach this very socket: a specific loopback bind → that address; the IPv4 wildcard →
    /// `127.0.0.1`; the IPv6 wildcard → `::1`, and `127.0.0.1` too only when the socket is dual-stack. None for a bind to one
    /// non-loopback address.
    var loopbackAddresses: [LoopbackAddress] {
        switch self {
        case .ipv4(let a, let b, let c, let d):
            if a == 127 { return [.ipv4(a, b, c, d)] }
            return (a, b, c, d) == (0, 0, 0, 0) ? [.ipv4(127, 0, 0, 1)] : []
        case .ipv6(let high, let low, let dualStack):
            if high == 0 && low == 1 { return [.ipv6] }
            if high == 0 && low == 0 { return dualStack ? [.ipv4(127, 0, 0, 1), .ipv6] : [.ipv6] }
            return []
        }
    }

    /// How firmly this socket claims a connection to `address`: nil = not at all; of several claimants the higher number takes
    /// it. An exact bind beats a wildcard, and an IPv4 wildcard beats a dual-stack IPv6 one (the kernel's lookup order).
    func claim(on address: LoopbackAddress) -> Int? {
        switch (self, address) {
        case (.ipv4(let a, let b, let c, let d), .ipv4(let x, let y, let z, let w)):
            if (a, b, c, d) == (x, y, z, w) { return 3 }
            return (a, b, c, d) == (0, 0, 0, 0) ? 2 : nil
        case (.ipv6(let high, let low, let dualStack), .ipv4):
            return high == 0 && low == 0 && dualStack ? 1 : nil
        case (.ipv6(let high, let low, _), .ipv6):
            if high == 0 && low == 1 { return 3 }
            return high == 0 && low == 0 ? 2 : nil
        case (.ipv4, .ipv6):
            return nil
        }
    }
}

public enum PageTitleState: Sendable, Equatable {
    /// The cleaned page title.
    case title(String)
    /// The server answered but there is no usable title: not HTML, no `<title>`, an empty or generic one, a refused redirect.
    case noTitle
    /// No usable answer. `retryAt` is when the single retry is due; nil once it was used.
    case failed(retryAt: Date?)
}

/// Reads the `<title>` of a dev server's home page with one `GET /` to the loopback address of the server's own socket (the
/// target's `addresses`, see `LoopbackHTTP`).
///
/// - Once per server identity: the first call fetches, every later call returns the cached state without any I/O; calls that
///   arrive while the fetch runs share it.
/// - A failure (nothing listening yet, timeout, 5xx) is retried at most once, `retryDelay` after the first attempt.
/// - The cache is bounded; the oldest targets are dropped first.
public actor PageTitleFetcher: PageTitleFetching {
    public static let retryDelay: TimeInterval = 60
    static let capacity = 256

    private struct Entry {
        var state: PageTitleState
        var attempts: Int
    }

    private let limits: LoopbackLimits
    private let logger = Logger(subsystem: "dev.minata.DevTidy", category: "pagetitle")
    private let now: @Sendable () -> Date
    private var entries: [PageTitleTarget: Entry] = [:]
    private var order: [PageTitleTarget] = []
    private var inFlight: [PageTitleTarget: Task<PageTitleState, Never>] = [:]

    public init() {
        self.init(limits: .standard, now: { Date() })
    }

    /// Test seam: short timeouts / small caps, a virtual clock.
    init(limits: LoopbackLimits, now: @escaping @Sendable () -> Date) {
        self.limits = limits
        self.now = now
    }

    public func title(for target: PageTitleTarget) async -> PageTitleState {
        if let entry = entries[target] {
            guard case .failed(let retryAt) = entry.state, let retryAt, now() >= retryAt else { return entry.state }
        }
        if let running = inFlight[target] { return await running.value }

        let attempts = (entries[target]?.attempts ?? 0) + 1
        let port = target.port
        let addresses = target.addresses
        let limits = self.limits
        let task = Task<PageTitleState, Never> {
            let outcome = await LoopbackHTTP.fetchHTML(addresses: addresses, port: port, limits: limits)
            return self.finish(target, outcome: outcome, attempts: attempts)
        }
        inFlight[target] = task
        return await task.value
    }

    /// Records the result and releases the in-flight slot, in one actor turn.
    private func finish(_ target: PageTitleTarget, outcome: LoopbackOutcome, attempts: Int) -> PageTitleState {
        let state: PageTitleState
        switch outcome {
        case .html(let bytes):
            state = HTMLTitle.title(inHTML: bytes).map(PageTitleState.title) ?? .noTitle
        case .nothingToRead:
            state = .noTitle
        case .unreachable:
            state = .failed(retryAt: attempts < 2 ? now().addingTimeInterval(Self.retryDelay) : nil)
        }
        if entries[target] == nil {
            order.append(target)
            if order.count > Self.capacity { entries[order.removeFirst()] = nil }
        }
        entries[target] = Entry(state: state, attempts: attempts)
        inFlight[target] = nil
        // The outcome class only (never the title): enough to tell "answered without a title" from "never answered" in a field
        // report, e.g. a dev server on HTTPS, which answers a plaintext request with a reset.
        let kind: String
        switch outcome {
        case .html: kind = state == .noTitle ? "html-without-title" : "html"
        case .nothingToRead: kind = "nothing-to-read"
        case .unreachable: kind = "unreachable"
        }
        logger.debug("port \(target.port, privacy: .public): \(kind, privacy: .public), attempt \(attempts, privacy: .public)")
        return state
    }
}
