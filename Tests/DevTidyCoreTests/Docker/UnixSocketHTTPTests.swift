import Foundation
import Testing
@testable import DevTidyCore

/// Real `AF_UNIX` round trips, but only against a test-owned server on a temp socket — never the Docker socket.
@Suite("UnixSocketHTTP")
struct UnixSocketHTTPTests {
    private let jsonBody = #"[{"Id":"abc","Names":["/web"]},{"Id":"def","Names":["/db"]}]"#

    private func chunked(_ body: String, splitAt: Int) -> [Data] {
        let utf8 = Array(body.utf8)
        let first = utf8[0..<splitAt]
        let second = utf8[splitAt...]
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        let chunk1 = String(first.count, radix: 16) + "\r\n"
        let chunk2 = String(second.count, radix: 16) + "\r\n"
        return [
            Data(head.utf8) + Data(chunk1.utf8) + Data(first) + Data("\r\n".utf8),
            Data(chunk2.utf8) + Data(second) + Data("\r\n0\r\n\r\n".utf8),
        ]
    }

    // MARK: Happy paths

    @Test func chunkedJSONSplitAcrossWrites() async throws {
        let body = jsonBody
        let parts = chunked(body, splitAt: 20)
        let server = try S3UnixSocketServer(.respond(gapMilliseconds: 25) { _ in parts })
        defer { server.stop() }

        let transport = UnixSocketHTTP(socketPath: server.path)
        let response = try await transport.request(method: "GET", path: "/containers/json",
                                                   query: [URLQueryItem(name: "all", value: "1")], timeout: 3)
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == body)

        let request = try #require(server.requests.first)
        #expect(request.hasPrefix("GET /containers/json?all=1 HTTP/1.1\r\n"))
        #expect(request.contains("\r\nHost: docker\r\n"))
        #expect(request.contains("\r\nConnection: close\r\n"))
        #expect(request.contains("\r\nContent-Length: 0\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test func noContentAndNotModified() async throws {
        for (status, reason) in [(204, "No Content"), (304, "Not Modified")] {
            let response = "HTTP/1.1 \(status) \(reason)\r\nApi-Version: 1.56\r\n\r\n"
            let server = try S3UnixSocketServer(.respond(gapMilliseconds: 0) { _ in [Data(response.utf8)] })
            defer { server.stop() }
            let result = try await UnixSocketHTTP(socketPath: server.path)
                .request(method: "POST", path: "/containers/abc123abc123/start", query: [], timeout: 3)
            #expect(result.status == status)
            #expect(result.body.isEmpty)
            #expect(server.requests.first?.hasPrefix("POST /containers/abc123abc123/start HTTP/1.1\r\n") == true)
        }
    }

    @Test func interimResponseOverTheWireIsNotTheAnswer() async throws {
        let body = jsonBody
        let parts = [Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                     Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)]
        let server = try S3UnixSocketServer(.respond(gapMilliseconds: 25) { _ in parts })
        defer { server.stop() }
        let result = try await UnixSocketHTTP(socketPath: server.path)
            .request(method: "GET", path: "/containers/json", query: [], timeout: 3)
        #expect(result.status == 200)
        #expect(String(decoding: result.body, as: UTF8.self) == body)
    }

    @Test func daemonSocketIsCloseOnExecAndNeverRaisesSIGPIPE() throws {
        let fd = try UnixSocketHTTP.makeStreamSocket()
        defer { Darwin.close(fd) }
        #expect(Darwin.fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)       // a spawned git/docker child never inherits the connection
        var noSigPipe: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(Darwin.getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &length) == 0)
        #expect(noSigPipe != 0)
    }

    @Test func nonSuccessStatusIsReturnedNotThrown() async throws {
        let body = #"{"message":"conflict: container is running"}"#
        let response = "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let server = try S3UnixSocketServer(.respond(gapMilliseconds: 0) { _ in [Data(response.utf8)] })
        defer { server.stop() }
        let result = try await UnixSocketHTTP(socketPath: server.path)
            .request(method: "DELETE", path: "/containers/abc123abc123", query: [URLQueryItem(name: "force", value: "false")], timeout: 3)
        #expect(result.status == 409)
        #expect(String(decoding: result.body, as: UTF8.self) == body)
    }

    @Test func largeContentLengthBody() async throws {
        let payload = String(repeating: "0123456789abcdef", count: 16_384)      // 256 KiB, many recv() calls
        let response = "HTTP/1.1 200 OK\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)"
        let server = try S3UnixSocketServer(.respond(gapMilliseconds: 0) { _ in [Data(response.utf8)] })
        defer { server.stop() }
        let result = try await UnixSocketHTTP(socketPath: server.path).request(method: "GET", path: "/big", query: [], timeout: 5)
        #expect(result.body.count == payload.utf8.count)
    }

    @Test func eofDelimitedBodyOverTheWire() async throws {
        let response = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nOK"
        let server = try S3UnixSocketServer(.respond(gapMilliseconds: 0) { _ in [Data(response.utf8)] })
        defer { server.stop() }
        let result = try await UnixSocketHTTP(socketPath: server.path).request(method: "GET", path: "/_ping", query: [], timeout: 3)
        #expect(result.status == 200)
        #expect(String(decoding: result.body, as: UTF8.self) == "OK")
    }

    // MARK: Failure paths

    @Test func hangingServerTimesOutWithTheTypedTimeoutError() async throws {
        let server = try S3UnixSocketServer(.hang)
        defer { server.stop() }
        let error = await s3Error {
            _ = try await UnixSocketHTTP(socketPath: server.path).request(method: "GET", path: "/containers/json", query: [], timeout: 0.4)
        }
        #expect(error as? DockerError == .timeout)
    }

    @Test func closeBeforeHeadersIsAnError() async throws {
        let server = try S3UnixSocketServer(.closeAfterRequest)
        defer { server.stop() }
        let error = await s3Error {
            _ = try await UnixSocketHTTP(socketPath: server.path).request(method: "GET", path: "/containers/json", query: [], timeout: 3)
        }
        #expect(error is DockerError)
    }

    @Test func truncatedBodyIsAnError() async throws {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort"
        let server = try S3UnixSocketServer(.respond(gapMilliseconds: 0) { _ in [Data(response.utf8)] })
        defer { server.stop() }
        let error = await s3Error {
            _ = try await UnixSocketHTTP(socketPath: server.path).request(method: "GET", path: "/x", query: [], timeout: 3)
        }
        #expect(error is DockerError)
    }

    @Test func missingSocketIsDaemonUnavailable() async throws {
        let directory = try S3Temp.makeDirectory()
        defer { S3Temp.remove(directory) }
        let error = await s3Error {
            _ = try await UnixSocketHTTP(socketPath: directory + "/missing.sock")
                .request(method: "GET", path: "/containers/json", query: [], timeout: 3)
        }
        // Decided by connect(2)'s errno: a typed daemon-unavailable error, never the `.timeout` of an exhausted budget.
        #expect(s3IsDaemonUnavailable(error))
    }

    @Test func staleSocketFileIsDaemonUnavailable() async throws {
        let directory = try S3Temp.makeDirectory()
        defer { S3Temp.remove(directory) }
        let path = directory + "/stale.sock"
        try S3Sockets.makeSocketFile(at: path)        // file exists, nobody listens ⇒ ECONNREFUSED
        let error = await s3Error {
            _ = try await UnixSocketHTTP(socketPath: path).request(method: "GET", path: "/containers/json", query: [], timeout: 3)
        }
        #expect(s3IsDaemonUnavailable(error))
    }

    @Test func regularFileIsDaemonUnavailable() async throws {
        let directory = try S3Temp.makeDirectory()
        defer { S3Temp.remove(directory) }
        let path = directory + "/not-a-socket"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let error = await s3Error {
            _ = try await UnixSocketHTTP(socketPath: path).request(method: "GET", path: "/containers/json", query: [], timeout: 3)
        }
        #expect(s3IsDaemonUnavailable(error))
    }

    @Test func overlongSocketPathIsInvalidArgument() async {
        let path = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        let error = await s3Error {
            _ = try await UnixSocketHTTP(socketPath: path).request(method: "GET", path: "/containers/json", query: [], timeout: 3)
        }
        #expect(s3IsInvalidArgument(error))
    }

    // MARK: Request encoding

    @Test func requestEncodingPercentEncodesQueryValues() throws {
        let bytes = try UnixSocketHTTP.encodeRequest(
            method: "POST", path: "/build/prune",
            query: [URLQueryItem(name: "all", value: "1"), URLQueryItem(name: "filters", value: #"{"until":["168h"]}"#)])
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("POST /build/prune?all=1&filters=%7B%22until%22%3A%5B%22168h%22%5D%7D HTTP/1.1\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func requestEncodingWithoutQuery() throws {
        let bytes = try UnixSocketHTTP.encodeRequest(method: "GET", path: "/version", query: [])
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text == "GET /version HTTP/1.1\r\nHost: docker\r\nUser-Agent: DevTidy\r\nAccept: application/json\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
    }

    @Test(arguments: ["/containers/json HTTP/1.1\r\nEvil: 1", "containers/json", "/a b", "/a?b=1", "/containers/../x#", ""])
    func unsafePathsAreRejectedBeforeAnythingIsSent(path: String) {
        #expect(throws: DockerError.self) {
            try UnixSocketHTTP.encodeRequest(method: "GET", path: path, query: [])
        }
    }

    @Test(arguments: ["", "get", "GET /x\r\n", "G ET"])
    func unsafeMethodsAreRejected(method: String) {
        #expect(throws: DockerError.self) {
            try UnixSocketHTTP.encodeRequest(method: method, path: "/version", query: [])
        }
    }
}
