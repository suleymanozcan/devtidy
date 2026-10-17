import Foundation
import Testing
@testable import DevTidyCore

@Suite("HTTPParser")
struct HTTPParserTests {
    // MARK: Helpers

    private func parseWhole(_ text: String, maxHeader: Int = HTTPParser.defaultMaxHeaderBytes,
                            maxBody: Int = HTTPParser.defaultMaxBodyBytes, eof: Bool = false) throws -> HTTPResponse? {
        var parser = HTTPParser(maxHeaderBytes: maxHeader, maxBodyBytes: maxBody)
        try parser.feed(Array(text.utf8))
        if eof { try parser.finish() }
        return parser.response
    }

    private func parseByteWise(_ text: String, eof: Bool = false) throws -> HTTPResponse? {
        var parser = HTTPParser()
        for byte in text.utf8 { try parser.feed([byte]) }
        if eof { try parser.finish() }
        return parser.response
    }

    private func bodyText(_ response: HTTPResponse?) -> String? {
        response.map { String(decoding: $0.body, as: UTF8.self) }
    }

    // MARK: Framing

    @Test func statusLineAndHeaders() throws {
        let response = try parseWhole("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nApi-Version: 1.56\r\nContent-Length: 2\r\n\r\n{}")
        #expect(response?.status == 200)
        #expect(response?.headers["content-type"] == "application/json")
        #expect(response?.headers["api-version"] == "1.56")
        #expect(bodyText(response) == "{}")
    }

    @Test func statusLineWithoutReasonPhrase() throws {
        let response = try parseWhole("HTTP/1.1 204\r\n\r\n")
        #expect(response?.status == 204)
    }

    @Test func duplicateHeadersAreJoined() throws {
        let response = try parseWhole("HTTP/1.1 200 OK\r\nX-Multi: a\r\nx-multi: b\r\nContent-Length: 0\r\n\r\n")
        #expect(response?.headers["x-multi"] == "a, b")
    }

    @Test func contentLengthBodyAcrossFeeds() throws {
        var parser = HTTPParser()
        try parser.feed(Array("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n01234".utf8))
        #expect(!parser.isComplete)
        try parser.feed(Array("567".utf8))
        #expect(!parser.isComplete)
        try parser.feed(Array("89EXTRA-IGNORED".utf8))
        #expect(parser.isComplete)
        #expect(bodyText(parser.response) == "0123456789")
    }

    @Test func zeroContentLengthCompletesAtHeaders() throws {
        let response = try parseWhole("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        #expect(response?.status == 200)
        #expect(response?.body.isEmpty == true)
    }

    @Test func chunkedWithHexSizesExtensionAndTrailer() throws {
        let second = String(repeating: "x", count: 31)       // 0x1f
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n"
            + "A\r\n0123456789\r\n"
            + "1f\r\n\(second)\r\n"
            + "5;ext=1\r\nhello\r\n"
            + "0\r\nX-Trailer: yes\r\nX-Other: 1\r\n\r\n"
        let response = try parseWhole(text)
        #expect(response?.status == 200)
        #expect(bodyText(response) == "0123456789" + second + "hello")
        // Trailers are ignored, not merged into the headers.
        #expect(response?.headers["x-trailer"] == nil)
    }

    @Test func chunkedWithUppercaseHexSize() throws {
        let response = try parseWhole("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nB\r\nhello world\r\n0\r\n\r\n")
        #expect(bodyText(response) == "hello world")
    }

    @Test func chunkedOverridesContentLength() throws {
        let response = try parseWhole("HTTP/1.1 200 OK\r\nContent-Length: 99\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n")
        #expect(bodyText(response) == "ok")
    }

    @Test func chunkedWithoutTrailersEndsAtEmptyLine() throws {
        var parser = HTTPParser()
        try parser.feed(Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n".utf8))
        #expect(!parser.isComplete)
        try parser.feed(Array("\r\n".utf8))
        #expect(parser.isComplete)
        #expect(bodyText(parser.response) == "abc")
    }

    @Test func eofDelimitedBody() throws {
        var parser = HTTPParser()
        try parser.feed(Array("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabc".utf8))
        #expect(!parser.isComplete)
        try parser.feed(Array("def".utf8))
        #expect(!parser.isComplete)
        try parser.finish()
        #expect(parser.isComplete)
        #expect(bodyText(parser.response) == "abcdef")
    }

    @Test func noBodyStatusesCompleteAtHeaders() throws {
        let noContent = try parseWhole("HTTP/1.1 204 No Content\r\nApi-Version: 1.56\r\n\r\n")
        #expect(noContent?.status == 204)
        #expect(noContent?.body.isEmpty == true)
        // 304 never has a body even if a Content-Length is advertised.
        let notModified = try parseWhole("HTTP/1.1 304 Not Modified\r\nContent-Length: 42\r\n\r\n")
        #expect(notModified?.status == 304)
        #expect(notModified?.body.isEmpty == true)
    }

    @Test func nonSuccessStatusKeepsItsBody() throws {
        let body = #"{"message":"No such container: abc"}"#
        let response = try parseWhole("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(response?.status == 404)
        #expect(bodyText(response) == body)
    }

    // MARK: Interim (1xx) responses

    @Test(arguments: [100, 102, 103])
    func interimResponsesAreSkippedAndTheFinalOneIsReturned(code: Int) throws {
        let body = #"{"ok":true}"#
        let text = "HTTP/1.1 \(code) Interim\r\nX-Hint: a\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let whole = try parseWhole(text)
        #expect(whole?.status == 200)
        #expect(bodyText(whole) == body)
        #expect(whole?.headers["x-hint"] == nil)          // the interim head's headers are not the final response's
        let byteWise = try parseByteWise(text)
        #expect(byteWise?.status == 200)
        #expect(bodyText(byteWise) == body)
    }

    @Test func interimResponseAloneIsNeverAFinalResponse() throws {
        var parser = HTTPParser()
        try parser.feed(Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        #expect(!parser.isComplete)
        #expect(parser.response == nil)
        // The peer closing right after an interim head is an error, not an empty success.
        #expect(throws: DockerError.self) { try parseWhole("HTTP/1.1 100 Continue\r\n\r\n", eof: true) }
    }

    @Test func switchingProtocolsAndInterimFloodsAreRejected() throws {
        #expect(throws: DockerError.decoding("unexpected 101 Switching Protocols")) {
            try parseWhole("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n")
        }
        let finalHead = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        let interim = "HTTP/1.1 100 Continue\r\n\r\n"
        #expect(throws: DockerError.decoding("too many interim responses")) {
            try parseWhole(String(repeating: interim, count: 9) + finalHead)
        }
        let tolerated = try parseWhole(String(repeating: interim, count: 8) + finalHead)
        #expect(tolerated?.status == 200)
    }

    // MARK: One byte at a time

    @Test func byteWiseContentLength() throws {
        let response = try parseByteWise("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
        #expect(response?.status == 200)
        #expect(bodyText(response) == "hello")
    }

    @Test func byteWiseChunked() throws {
        let response = try parseByteWise("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;x=y\r\n world\r\n0\r\nT: 1\r\n\r\n")
        #expect(bodyText(response) == "hello world")
    }

    @Test func byteWiseEOFBody() throws {
        let response = try parseByteWise("HTTP/1.1 200 OK\r\n\r\ndata", eof: true)
        #expect(bodyText(response) == "data")
    }

    // MARK: Limits

    @Test func headersOverSixtyFourKiBRejectedWithoutTerminator() {
        let text = "HTTP/1.1 200 OK\r\nX-Big: " + String(repeating: "a", count: 70_000)
        #expect(throws: DockerError.self) { try parseWhole(text) }
    }

    @Test func headersOverSixtyFourKiBRejectedWithTerminator() {
        let text = "HTTP/1.1 200 OK\r\nX-Big: " + String(repeating: "a", count: 70_000) + "\r\n\r\n"
        #expect(throws: DockerError.self) { try parseWhole(text) }
    }

    @Test func headerBlockJustUnderTheCapIsAccepted() throws {
        let text = "HTTP/1.1 200 OK\r\nX-Big: " + String(repeating: "a", count: 60_000) + "\r\nContent-Length: 0\r\n\r\n"
        let response = try parseWhole(text)
        #expect(response?.status == 200)
    }

    @Test func customHeaderCapIsHonoured() {
        #expect(throws: DockerError.self) {
            try parseWhole("HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 200) + "\r\n\r\n", maxHeader: 128)
        }
    }

    @Test func bodyCapOnContentLength() {
        #expect(throws: DockerError.decoding("response too large")) {
            try parseWhole("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n", maxBody: 10)
        }
    }

    @Test func bodyCapOnChunks() {
        #expect(throws: DockerError.decoding("response too large")) {
            try parseWhole("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nabcdef\r\n6\r\nghijkl\r\n0\r\n\r\n", maxBody: 10)
        }
    }

    @Test func bodyCapOnEOFDelimitedBody() {
        #expect(throws: DockerError.decoding("response too large")) {
            try parseWhole("HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "z", count: 11), maxBody: 10)
        }
    }

    // MARK: Malformed input

    @Test(arguments: ["zz", "", "-5", "+5", "0x5", "5 5", "fffffffffffffffff"])
    func garbageChunkSizeRejected(size: String) {
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(size)\r\nhello\r\n0\r\n\r\n"
        #expect(throws: DockerError.self) { try parseWhole(text) }
    }

    @Test func missingCRLFAfterChunkDataRejected() {
        #expect(throws: DockerError.self) {
            try parseWhole("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n")
        }
    }

    @Test(arguments: ["garbage\r\n\r\n", "HTTP/1.1\r\n\r\n", "HTTP/1.1 abc OK\r\n\r\n", "FTP/1.1 200 OK\r\n\r\n", "HTTP/1.1 99 X\r\n\r\n"])
    func malformedStatusLineRejected(head: String) {
        #expect(throws: DockerError.self) { try parseWhole(head) }
    }

    @Test func headerLineWithoutColonRejected() {
        #expect(throws: DockerError.self) { try parseWhole("HTTP/1.1 200 OK\r\nNoColonHere\r\n\r\n") }
    }

    @Test func invalidContentLengthRejected() {
        #expect(throws: DockerError.self) { try parseWhole("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n") }
        #expect(throws: DockerError.self) { try parseWhole("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n") }
    }

    @Test func closeBeforeHeadersRejected() {
        #expect(throws: DockerError.self) { try parseWhole("", eof: true) }
        #expect(throws: DockerError.self) { try parseWhole("HTTP/1.1 200 OK\r\nContent-Le", eof: true) }
    }

    @Test func truncatedBodiesRejectedAtEOF() {
        #expect(throws: DockerError.self) { try parseWhole("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc", eof: true) }
        #expect(throws: DockerError.self) {
            try parseWhole("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel", eof: true)
        }
        #expect(throws: DockerError.self) {
            try parseWhole("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n", eof: true)
        }
    }

    @Test func bytesAfterCompletionAreIgnored() throws {
        var parser = HTTPParser()
        try parser.feed(Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1 500 Nope\r\n\r\n".utf8))
        #expect(parser.response?.status == 200)
        try parser.feed(Array("more".utf8))
        #expect(bodyText(parser.response) == "ok")
    }

    @Test func largeBodyArrivesInManyReads() throws {
        let payload = String(repeating: "0123456789abcdef", count: 16_384)       // 256 KiB
        var parser = HTTPParser()
        try parser.feed(Array("HTTP/1.1 200 OK\r\nContent-Length: \(payload.utf8.count)\r\n\r\n".utf8))
        let bytes = Array(payload.utf8)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 65_536, bytes.count)
            try parser.feed(bytes[offset..<end])
            offset = end
        }
        #expect(parser.isComplete)
        #expect(parser.response?.body.count == bytes.count)
    }
}
