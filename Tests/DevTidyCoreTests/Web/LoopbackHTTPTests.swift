import Foundation
import Testing
@testable import DevTidyCore

@Suite("LoopbackRedirect (which redirects may be followed)")
struct LoopbackRedirectTests {
    private let port: UInt16 = 5182

    private func resolve(_ location: String, from host: LoopbackHost = .any, path: String = "/") -> LoopbackRedirect.Target? {
        LoopbackRedirect.resolve(location: location, currentHost: host, currentPath: path, port: port)
    }

    @Test func loopbackOnTheSamePortIsFollowed() {
        #expect(resolve("http://127.0.0.1:5182/en") == .init(host: .ipv4(127, 0, 0, 1), path: "/en"))
        #expect(resolve("http://127.0.0.5:5182/") == .init(host: .ipv4(127, 0, 0, 5), path: "/"))
        #expect(resolve("http://localhost:5182/app/") == .init(host: .localhost, path: "/app/"))
        #expect(resolve("HTTP://LOCALHOST:5182/x") == .init(host: .localhost, path: "/x"))
        #expect(resolve("http://[::1]:5182/v6") == .init(host: .ipv6, path: "/v6"))
        #expect(resolve("//localhost:5182/net-path") == .init(host: .localhost, path: "/net-path"))
        #expect(resolve("http://localhost:5182") == .init(host: .localhost, path: "/"))
        #expect(resolve("http://localhost:5182?x=1") == .init(host: .localhost, path: "/?x=1"))
    }

    @Test func relativeLocationsStayOnTheCurrentHost() {
        #expect(resolve("/login", from: .ipv6) == .init(host: .ipv6, path: "/login"))
        #expect(resolve("next", from: .any, path: "/a/b?q=1") == .init(host: .any, path: "/a/next"))
        #expect(resolve("../up", from: .any, path: "/a/b/c") == .init(host: .any, path: "/a/up"))
        #expect(resolve("?page=2", from: .any, path: "/list?page=1") == .init(host: .any, path: "/list?page=2"))
        #expect(resolve("/a/./b/../c#frag") == .init(host: .any, path: "/a/c"))
    }

    @Test(arguments: [
        "http://example.com:5182/", "http://192.0.2.1:5182/", "http://10.0.0.5:5182/", "http://0.0.0.0:5182/",
        "http://127.0.0.1.evil.test:5182/", "http://localhost.evil.test:5182/", "http://evil-localhost:5182/",
        "http://127.0.0.1:5183/", "http://localhost:80/", "http://localhost/", "http://localhost:5182x/",
        "http://[::2]:5182/", "http://[2001:db8::1]:5182/", "http://user@localhost:5182/", "http://localhost:5182@evil.test/",
        "https://localhost:5182/", "https://127.0.0.1:5182/", "ftp://localhost:5182/", "javascript:alert(1)",
        "http://256.0.0.1:5182/", "http://127.0.0.1.:5182/", "http://0x7f.0.0.1:5182/", "http://2130706433:5182/",
        "http://localhost:5182/\r\nHost: evil", "/path\nwith-newline", "", "   ",
    ])
    func everythingElseIsRefusedBeforeAnyConnection(location: String) {
        #expect(resolve(location) == nil, "\(location.debugDescription)")
    }

    @Test func spacesAndNonASCIIAreEncodedAndControlsRefused() {
        #expect(resolve("/a b")?.path == "/a%20b")
        #expect(resolve("/ş")?.path == "/%C5%9F")
        #expect(resolve("/a\u{7}b") == nil)
    }

    @Test func aHostHeaderNamesTheAddressItWasSentTo() {
        #expect(LoopbackHost.any.hostHeader(for: .ipv4(127, 0, 0, 1), port: 80) == "127.0.0.1:80")
        #expect(LoopbackHost.any.hostHeader(for: .ipv6, port: 80) == "[::1]:80")
        #expect(LoopbackHost.localhost.hostHeader(for: .ipv6, port: 80) == "localhost:80")
        #expect(LoopbackHost.ipv6.addresses == [.ipv6])
        #expect(LoopbackHost.ipv4(127, 1, 2, 3).addresses == [.ipv4(127, 1, 2, 3)])
    }

    @Test func onlyLoopbackAddressesAreEverCandidates() {
        for host in [LoopbackHost.any, .localhost, .ipv6, .ipv4(127, 0, 0, 1), .ipv4(127, 9, 9, 9)] {
            for address in host.addresses {
                switch address {
                case .ipv6: break
                case .ipv4(let a, _, _, _): #expect(a == 127)
                }
            }
        }
    }
}

@Suite("LoopbackResponseReader / chunk decoder")
struct LoopbackResponseReaderTests {
    private func feed(_ text: String, cap: Int = 1_000, bytewise: Bool = false) -> LoopbackResponseReader {
        var reader = LoopbackResponseReader(maxBodyBytes: cap)
        let bytes = Array(text.utf8)
        if bytewise {
            for index in bytes.indices { reader.feed(bytes[index...index]) }
        } else {
            reader.feed(bytes[...])
        }
        return reader
    }

    @Test func aContentLengthBodyIsExactAndFinished() {
        let reader = feed("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhelloEXTRA")
        #expect(reader.status == 200)
        #expect(reader.headers["content-type"] == "text/html")
        #expect(String(decoding: reader.body, as: UTF8.self) == "hello")
        #expect(reader.isFinished)
    }

    @Test func aChunkedBodyIsDecodedEvenFedOneByteAtATime() {
        let wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nTrailer: x\r\n\r\n"
        for bytewise in [false, true] {
            let reader = feed(wire, bytewise: bytewise)
            #expect(String(decoding: reader.body, as: UTF8.self) == "hello world", "bytewise: \(bytewise)")
            #expect(reader.isFinished, "bytewise: \(bytewise)")
            #expect(reader.failure == nil)
        }
    }

    @Test func aBodyWithoutFramingEndsWithTheConnection() {
        var reader = feed("HTTP/1.0 200 OK\r\n\r\nabc")
        #expect(!reader.isFinished)
        reader.endOfStream()
        #expect(reader.isFinished)
        #expect(String(decoding: reader.body, as: UTF8.self) == "abc")
    }

    @Test func theBodyIsCutAtTheCapAndNothingBeyondIsKept() {
        let reader = feed("HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "a", count: 5_000), cap: 1_024)
        #expect(reader.body.count == 1_024)
        #expect(reader.isBodyCapped)
        let chunked = feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1388\r\n" + String(repeating: "b", count: 5_000) + "\r\n0\r\n\r\n",
                           cap: 1_024)
        #expect(chunked.body.count == 1_024)
        #expect(chunked.isBodyCapped)
    }

    @Test(arguments: [
        "garbage\r\n\r\n", "HTTP/2 200 OK\r\n\r\n", "HTTP/1.1 abc OK\r\n\r\n", "HTTP/1.1 99 OK\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX",
        // a signed size is not a size: `-1` would otherwise make the rest of the stream one endless chunk
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\nabc",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+3\r\nabc\r\n0\r\n\r\n",
    ])
    func malformedFramingFails(wire: String) {
        #expect(feed(wire).failure == .malformed)
    }

    @Test func aHeadThatNeverEndsFails() {
        var reader = LoopbackResponseReader(maxHeadBytes: 256, maxBodyBytes: 100)
        reader.feed(Array(("HTTP/1.1 200 OK\r\nX-Pad: " + String(repeating: "p", count: 400)).utf8)[...])
        #expect(reader.failure == .headTooLarge)
    }

    @Test func noBodyStatusesAreFinishedAtTheHead() {
        #expect(feed("HTTP/1.1 204 No Content\r\n\r\n").isFinished)
        #expect(feed("HTTP/1.1 304 Not Modified\r\n\r\n").isFinished)
        #expect(feed("HTTP/1.1 302 Found\r\nLocation: /x\r\nContent-Length: 0\r\n\r\n").isFinished)
    }

    // MARK: Interim answers

    private let early = "HTTP/1.1 103 Early Hints\r\nLink: </app.css>; rel=preload\r\n\r\n"
    private let real = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello"

    @Test func anInterimAnswerBeforeTheRealOneIsSkipped() {
        for bytewise in [false, true] {
            let reader = feed(early + real, bytewise: bytewise)
            #expect(reader.status == 200, "bytewise: \(bytewise)")
            #expect(reader.headers["content-type"] == "text/html", "bytewise: \(bytewise)")
            #expect(reader.headers["link"] == nil)                                      // the interim head's headers are gone
            #expect(String(decoding: reader.body, as: UTF8.self) == "hello")
            #expect(reader.isFinished)
            #expect(reader.failure == nil)
        }
    }

    @Test func severalInterimAnswersAreSkippedAndTheRealOneMayArriveLater() {
        var reader = LoopbackResponseReader(maxBodyBytes: 100)
        reader.feed(Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)[...])
        #expect(!reader.isHeadComplete)                                                 // still waiting for the real head
        reader.feed(Array(early.utf8)[...])
        #expect(!reader.isHeadComplete)
        reader.feed(Array(real.utf8)[...])
        #expect(reader.isHeadComplete && reader.status == 200)
        #expect(String(decoding: reader.body, as: UTF8.self) == "hello")
    }

    @Test func aFloodOfInterimAnswersFails() {
        let flood = String(repeating: "HTTP/1.1 100 Continue\r\n\r\n", count: LoopbackResponseReader.maxInterimHeads + 1)
        #expect(feed(flood + real).failure == .malformed)
    }

    @Test func switchingProtocolsIsTheFinalAnswerNotAnInterimOne() {
        let reader = feed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n")
        #expect(reader.isHeadComplete && reader.status == 101)
    }

    // MARK: What counts as HTML

    @Test func aHalfReadAnswerCountsOnlyWhenItIsHTMLInTheSenseOfTheLiveDecision() {
        let page = "<head><title>x"
        let html = feed("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" + page)
        #expect(LoopbackHTTP.pageIfComplete(html) == .html(Array(page.utf8)))
        // `text/htmlx` and `text/html-sandboxed` merely START with "text/html"
        for lookalike in ["text/htmlx", "text/html-sandboxed", "application/xhtml+xml", ""] {
            let reader = feed("HTTP/1.1 200 OK\r\nContent-Type: \(lookalike)\r\n\r\n" + page)
            #expect(LoopbackHTTP.pageIfComplete(reader) == nil, "\(lookalike)")
            #expect(!LoopbackHTTP.isIdentityHTML(reader), "\(lookalike)")
        }
        let coded = feed("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\n\r\n" + page)
        #expect(LoopbackHTTP.pageIfComplete(coded) == nil)
        #expect(LoopbackHTTP.pageIfComplete(feed("HTTP/1.1 500 Oops\r\nContent-Type: text/html\r\n\r\n" + page)) == nil)
    }
}
