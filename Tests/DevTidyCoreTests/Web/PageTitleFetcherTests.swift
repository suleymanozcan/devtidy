import Foundation
import Testing
import Darwin
@testable import DevTidyCore

/// Every request in this file goes to a server the test starts itself on a kernel-chosen loopback port.
@Suite("PageTitleFetcher")
struct PageTitleFetcherTests {
    private func target(_ port: UInt16, pid: Int32 = 100, started: Int64 = 1_800_000_000) -> PageTitleTarget {
        PageTitleTarget(server: ProcessIdentity(pid: pid, startSeconds: started, startMicroseconds: 0), port: port)
    }

    private func fetcher(_ clock: S4Clock = S4Clock(), total: TimeInterval = 3, cap: Int = 256 * 1024,
                         redirects: Int = 2) -> PageTitleFetcher {
        PageTitleFetcher(limits: LoopbackLimits(connectTimeout: 1.5, totalTimeout: total, maxBodyBytes: cap, maxRedirects: redirects),
                         now: { clock.now })
    }

    private func page(_ title: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(title)</title></head><body><div id=root></div></body></html>"
    }

    /// Polls a condition; used to wait for a server thread to notice a client has gone. No time bound is asserted.
    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: The request itself

    @Test func readsTheTitleWithOneGetToTheLoopbackAddress() async throws {
        let server = try LoopbackTestServer { _, _ in .html(page("Red Alert · Admin")) }
        defer { server.stop() }
        let state = await fetcher().title(for: target(server.port))
        #expect(state == .title("Red Alert · Admin"))

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.target == "/")
        #expect(request.headers["host"] == "127.0.0.1:\(server.port)")
        #expect(request.headers["accept"] == "text/html")
        #expect(request.headers["connection"] == "close")
        #expect(request.headers["accept-encoding"] == "identity")
        #expect(request.headers["cookie"] == nil)
        #expect(request.headers["authorization"] == nil)
    }

    @Test func aChunkedMultilineEntityEncodedTitleIsDecoded() async throws {
        let html = "<html><head><title>\n  Tom &amp; Jerry\n  &mdash; Admin </title></head>"
        let server = try LoopbackTestServer { _, _ in .html(html, chunked: true) }
        defer { server.stop() }
        #expect(await fetcher().title(for: target(server.port)) == .title("Tom & Jerry — Admin"))
    }

    @Test func aServerBoundToIPv6LoopbackOnlyIsReachedAfterIPv4IsRefused() async throws {
        let server = try LoopbackTestServer(ipv6: true) { _, _ in .html(page("Only v6")) }
        defer { server.stop() }
        #expect(await fetcher().title(for: target(server.port)) == .title("Only v6"))
        #expect(server.requests.first?.headers["host"] == "[::1]:\(server.port)")
    }

    // MARK: Once per server identity

    @Test func oneFetchPerIdentityEvenWhenAskedManyTimesAtOnce() async throws {
        let server = try LoopbackTestServer { _, _ in .html(page("Once")) }
        defer { server.stop() }
        let fetcher = self.fetcher()
        let key = target(server.port)
        let states = await withTaskGroup(of: PageTitleState.self) { group in
            for _ in 0..<12 { group.addTask { await fetcher.title(for: key) } }
            var all: [PageTitleState] = []
            for await state in group { all.append(state) }
            return all
        }
        #expect(states.count == 12)
        #expect(states.allSatisfy { $0 == .title("Once") })
        for _ in 0..<3 { _ = await fetcher.title(for: key) }
        #expect(server.requests.count == 1)
    }

    @Test func aRestartedServerOnTheSamePortIsANewIdentity() async throws {
        let server = try LoopbackTestServer { _, index in .html(page("Run \(index)")) }
        defer { server.stop() }
        let fetcher = self.fetcher()
        #expect(await fetcher.title(for: target(server.port, pid: 100, started: 1_800_000_000)) == .title("Run 0"))
        #expect(await fetcher.title(for: target(server.port, pid: 100, started: 1_800_000_000)) == .title("Run 0"))
        #expect(await fetcher.title(for: target(server.port, pid: 100, started: 1_800_000_500)) == .title("Run 1"))
        #expect(await fetcher.title(for: target(server.port, pid: 101, started: 1_800_000_000)) == .title("Run 2"))
        #expect(server.requests.count == 3)
    }

    @Test func aPageWithoutUsableTitleIsFinalAndNotAskedAgain() async throws {
        let server = try LoopbackTestServer { _, _ in .html(page("Vite App")) }
        defer { server.stop() }
        let fetcher = self.fetcher()
        #expect(await fetcher.title(for: target(server.port)) == .noTitle)
        #expect(await fetcher.title(for: target(server.port)) == .noTitle)
        #expect(server.requests.count == 1)
    }

    // MARK: What is parsed

    @Test func onlyTextHTMLIsParsed() async throws {
        let cases: [(String, LoopbackTestServer.Reply)] = [
            ("json", .html("{\"title\":\"x\"} <title>Sneaky</title>", type: "application/json")),
            ("plain", .html(page("Plain"), type: "text/plain")),
            ("xml", .html(page("Xml"), type: "application/xhtml+xml")),
            ("gzip", .html(page("Packed"), extraHeaders: ["Content-Encoding: gzip"])),
            ("no type", .bytes(Array("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc".utf8))),
            ("404", .html(page("Not Found"), status: "404 Not Found")),
        ]
        for (name, reply) in cases {
            let server = try LoopbackTestServer { _, _ in reply }
            defer { server.stop() }
            #expect(await fetcher().title(for: target(server.port)) == .noTitle, "\(name)")
            #expect(server.requests.count == 1, "\(name)")
        }
    }

    @Test func anHTMLAnswerWithTheCharsetParameterAndMixedCaseIsParsed() async throws {
        let server = try LoopbackTestServer { _, _ in .html(page("Typed"), type: "Text/HTML; Charset=UTF-8") }
        defer { server.stop() }
        #expect(await fetcher().title(for: target(server.port)) == .title("Typed"))
    }

    // MARK: Body cap

    @Test func aTitleBeyondTheBodyCapIsNotFoundAndOneInsideItIs() async throws {
        let padding = String(repeating: "x", count: 5_000)
        let late = "<html><head><meta name=pad content=\"\(padding)\"><title>Late</title></head>"
        let early = "<html><head><title>Early</title><meta name=pad content=\"\(padding)\"></head>"
        let lateServer = try LoopbackTestServer { _, _ in .html(late) }
        let earlyServer = try LoopbackTestServer { _, _ in .html(early) }
        defer { lateServer.stop(); earlyServer.stop() }
        let small = fetcher(cap: 2_000)
        #expect(await small.title(for: target(lateServer.port)) == .noTitle)
        #expect(await small.title(for: target(earlyServer.port)) == .title("Early"))
    }

    @Test func anEndlessBodyIsAbandonedAtTheCapAndTheConnectionClosed() async throws {
        let head = Array("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><head><meta charset=utf-8>".utf8)
        let chunk = [UInt8](repeating: UInt8(ascii: " "), count: 4_096)
        let server = try LoopbackTestServer { _, _ in .stream(head: head, chunk: chunk) }
        defer { server.stop() }
        // A generous total timeout: the cap, not the clock, must end this.
        let state = await fetcher(total: 30, cap: 16 * 1024).title(for: target(server.port))
        #expect(state == .noTitle)
        #expect(await eventually { server.activeStreams == 0 }, "the client closed its end, so the server's endless write failed")
    }

    @Test func theReaderStopsAsSoonAsTheTitleIsBehindIt() async throws {
        // After </head> the server would stream forever; the client must not wait for the end of such a page.
        let head = Array(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
                          + "<html><head><title>Streaming</title></head><body>").utf8)
        let chunk = [UInt8](repeating: UInt8(ascii: " "), count: 4_096)
        let server = try LoopbackTestServer { _, _ in .stream(head: head, chunk: chunk) }
        defer { server.stop() }
        #expect(await fetcher(total: 30).title(for: target(server.port)) == .title("Streaming"))
        #expect(await eventually { server.activeStreams == 0 })
    }

    // MARK: Redirects

    @Test func redirectsToLoopbackOnTheSamePortAreFollowedWithoutCookies() async throws {
        let base = S4Locked<UInt16>(0)
        let server = try LoopbackTestServer { request, _ in
            switch request.target {
            case "/": return .bytes(Array("HTTP/1.1 302 Found\r\nLocation: /en\r\nSet-Cookie: a=b\r\nContent-Length: 0\r\n\r\n".utf8))
            case "/en": return .redirect(to: "http://localhost:\(base.snapshot)/en/home", status: "307 Temporary Redirect")
            case "/en/home": return .html("<title>Home</title>")
            default: return .html("", status: "404 Not Found")
            }
        }
        defer { server.stop() }
        base.with { $0 = server.port }
        #expect(await fetcher().title(for: target(server.port)) == .title("Home"))
        let requests = server.requests
        #expect(requests.map(\.target) == ["/", "/en", "/en/home"])
        #expect(requests.allSatisfy { $0.headers["cookie"] == nil })                     // Set-Cookie was not kept
        #expect(requests[2].headers["host"] == "localhost:\(server.port)")
    }

    @Test func aRedirectToAnotherLoopbackPortIsRefusedAndNeverContacted() async throws {
        let other = try LoopbackTestServer { _, _ in .html(page("Other")) }
        let server = try LoopbackTestServer { _, _ in .redirect(to: "http://127.0.0.1:\(other.port)/") }
        defer { server.stop(); other.stop() }
        #expect(await fetcher().title(for: target(server.port)) == .noTitle)
        #expect(server.requests.count == 1)
        #expect(other.requests.isEmpty)
    }

    @Test(arguments: [
        "http://example.invalid:PORT/", "http://192.0.2.1:PORT/", "http://127.0.0.1.evil.test:PORT/", "https://localhost:PORT/",
        "http://user@localhost:PORT/", "http://localhost.evil.test:PORT/", "javascript:alert(1)", "http://10.1.2.3:PORT/x",
    ])
    func aRedirectLeavingLoopbackIsRefusedWithoutAnySecondRequest(template: String) async throws {
        let port = S4Locked<UInt16>(0)
        // Were the host ignored, the follow-up would hit this very server again and show up in `requests`.
        let server = try LoopbackTestServer { _, _ in
            .redirect(to: template.replacingOccurrences(of: "PORT", with: String(port.snapshot)))
        }
        defer { server.stop() }
        port.with { $0 = server.port }
        #expect(await fetcher().title(for: target(server.port)) == .noTitle)
        #expect(server.requests.count == 1)
    }

    @Test func atMostTwoRedirectsAreFollowed() async throws {
        let server = try LoopbackTestServer { request, _ in
            switch request.target {
            case "/": return .redirect(to: "/1")
            case "/1": return .redirect(to: "/2")
            case "/2": return .redirect(to: "/3")
            default: return .html("<title>Too far</title>")
            }
        }
        defer { server.stop() }
        #expect(await fetcher().title(for: target(server.port)) == .noTitle)
        #expect(server.requests.map(\.target) == ["/", "/1", "/2"])
    }

    @Test func aRedirectWithoutALocationIsNotFollowed() async throws {
        let server = try LoopbackTestServer { _, _ in
            .bytes(Array("HTTP/1.1 302 Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        }
        defer { server.stop() }
        #expect(await fetcher().title(for: target(server.port)) == .noTitle)
        #expect(server.requests.count == 1)
    }

    // MARK: Failure: timeout, closed, refused, 5xx — and the single retry

    @Test func aServerThatNeverAnswersFailsAtTheTotalTimeout() async throws {
        let clock = S4Clock()
        let server = try LoopbackTestServer { _, _ in .hang }
        defer { server.stop() }
        // The limit is injected (0.3 s); nothing asserts how long the call actually took.
        let state = await fetcher(clock, total: 0.3).title(for: target(server.port))
        #expect(state == .failed(retryAt: clock.now.addingTimeInterval(PageTitleFetcher.retryDelay)))
    }

    @Test func aServerThatClosesWithoutAnAnswerFails() async throws {
        let clock = S4Clock()
        let server = try LoopbackTestServer { _, _ in .close }
        defer { server.stop() }
        #expect(await fetcher(clock).title(for: target(server.port)) == .failed(retryAt: clock.now.addingTimeInterval(60)))
    }

    @Test func aTruncatedHeadFails() async throws {
        let clock = S4Clock()
        let server = try LoopbackTestServer { _, _ in .bytes(Array("HTTP/1.1 200 OK\r\nContent-Ty".utf8)) }
        defer { server.stop() }
        #expect(await fetcher(clock).title(for: target(server.port)) == .failed(retryAt: clock.now.addingTimeInterval(60)))
    }

    @Test func aServerErrorIsAFailureNotAFinalAnswer() async throws {
        let clock = S4Clock()
        let server = try LoopbackTestServer { _, _ in .html(page("Oops"), status: "503 Service Unavailable") }
        defer { server.stop() }
        #expect(await fetcher(clock).title(for: target(server.port)) == .failed(retryAt: clock.now.addingTimeInterval(60)))
    }

    @Test func nothingListeningIsAFailure() async throws {
        // Bound but never listening: connect() is refused, on IPv4 and on IPv6 alike.
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: address.sin_port)
        let clock = S4Clock()
        #expect(await fetcher(clock).title(for: target(port)) == .failed(retryAt: clock.now.addingTimeInterval(60)))
    }

    @Test func aFailureIsRetriedExactlyOnceAfterSixtySeconds() async throws {
        let clock = S4Clock()
        let server = try LoopbackTestServer { _, index in index == 0 ? .close : .html(page("Recovered")) }
        defer { server.stop() }
        let fetcher = self.fetcher(clock)
        let key = target(server.port)
        let due = clock.now.addingTimeInterval(60)

        #expect(await fetcher.title(for: key) == .failed(retryAt: due))
        #expect(await fetcher.title(for: key) == .failed(retryAt: due))                 // not due: answered from the cache
        clock.advance(59)
        #expect(await fetcher.title(for: key) == .failed(retryAt: due))
        #expect(server.requests.count == 1)

        clock.advance(1)                                                                 // t0 + 60
        #expect(await fetcher.title(for: key) == .title("Recovered"))
        #expect(server.requests.count == 2)
        clock.advance(3_600)
        #expect(await fetcher.title(for: key) == .title("Recovered"))
        #expect(server.requests.count == 2)
    }

    @Test func aSecondFailureIsFinal() async throws {
        let clock = S4Clock()
        let server = try LoopbackTestServer { _, _ in .close }
        defer { server.stop() }
        let fetcher = self.fetcher(clock)
        let key = target(server.port)
        #expect(await fetcher.title(for: key) == .failed(retryAt: clock.now.addingTimeInterval(60)))
        clock.advance(60)
        #expect(await fetcher.title(for: key) == .failed(retryAt: nil))                 // the retry failed too
        clock.advance(86_400)
        #expect(await fetcher.title(for: key) == .failed(retryAt: nil))
        #expect(server.requests.count == 2)
    }
}
