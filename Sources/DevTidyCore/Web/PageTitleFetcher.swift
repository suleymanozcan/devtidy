import Foundation
import os

/// One server, as far as the title fetch is concerned: the tree root's identity (pid + start time, so a restarted server on
/// the same port is a new target) and the port to ask.
public struct PageTitleTarget: Hashable, Sendable {
    public let server: ProcessIdentity
    public let port: UInt16

    public init(server: ProcessIdentity, port: UInt16) {
        self.server = server
        self.port = port
    }

    /// The listener DevTidy asks, or nil when this server must not be asked: no main port, an inspector port (declared by the
    /// argv or one of 9229–9231), or a port bound to one specific non-loopback address (nothing answers on loopback there).
    /// Only dev servers get here at all; "other" listeners (tools, apps, system) never do.
    public static func make(for server: DevServer) -> PageTitleTarget? {
        guard let port = server.mainPort, !server.declaredInspectorPorts.contains(port) else { return nil }
        guard let listener = server.ports.first(where: { $0.port == port }), !listener.isInspector else { return nil }
        switch listener.scope {
        case .loopback, .allInterfaces: return PageTitleTarget(server: server.id, port: port)
        case .other: return nil
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

/// Reads the `<title>` of a dev server's home page with one `GET /` to its own loopback address (see `LoopbackHTTP`).
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
        let limits = self.limits
        let task = Task<PageTitleState, Never> {
            let outcome = await LoopbackHTTP.fetchHTML(port: port, limits: limits)
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
