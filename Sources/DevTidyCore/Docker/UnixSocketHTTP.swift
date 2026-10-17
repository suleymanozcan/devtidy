import Foundation

// MARK: - Seam -------------------------------------------------------------------------------------------------------

struct HTTPResponse: Sendable {
    let status: Int
    /// Header names are lowercased; duplicate headers are joined with ", ".
    let headers: [String: String]
    let body: Data
}

protocol DockerHTTPTransport: Sendable {
    func request(method: String, path: String, query: [URLQueryItem], timeout: TimeInterval) async throws -> HTTPResponse
}

// MARK: - Incremental HTTP/1.1 response parser -----------------------------------------------------------------------

/// Byte-at-a-time safe response parser: optional interim (1xx) heads, then status line + headers of the final response, then a
/// `Content-Length`, `chunked`, or read-to-EOF body. Pure value type so the framing rules are testable without a socket.
/// Malformed input throws `DockerError.decoding`.
struct HTTPParser {
    static let defaultMaxHeaderBytes = 64 * 1024
    static let defaultMaxBodyBytes = 32 * 1024 * 1024
    private static let maxLineBytes = 1024
    /// Interim (1xx) heads tolerated before the final one; a peer that keeps sending them is not speaking to us.
    private static let maxInterimResponses = 8

    private enum Phase: Equatable {
        case head
        case fixedBody(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailers
        case untilEOF
        case done
    }

    private let maxHeaderBytes: Int
    private let maxBodyBytes: Int
    private var phase: Phase = .head
    private var input: [UInt8] = []
    /// `input[..<cursor]` is already consumed.
    private var cursor = 0
    /// Resume point for the header-terminator search, so byte-wise feeding stays linear.
    private var scanFrom = 0
    private var trailerBytes = 0
    private var interimResponses = 0
    private var status = 0
    private var headers: [String: String] = [:]
    private var body: [UInt8] = []

    init(maxHeaderBytes: Int = HTTPParser.defaultMaxHeaderBytes, maxBodyBytes: Int = HTTPParser.defaultMaxBodyBytes) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    var isComplete: Bool { phase == .done }

    /// Non-nil once the response is complete.
    var response: HTTPResponse? {
        phase == .done ? HTTPResponse(status: status, headers: headers, body: Data(body)) : nil
    }

    /// Feeds received bytes. Bytes after the end of a complete response are ignored (`Connection: close`, no pipelining).
    mutating func feed<S: Sequence>(_ bytes: S) throws where S.Element == UInt8 {
        guard phase != .done else { return }
        input.append(contentsOf: bytes)
        try advance()
    }

    /// Call when the peer closed the connection. Only a read-to-EOF body is complete at EOF.
    mutating func finish() throws {
        switch phase {
        case .done:
            return
        case .untilEOF:
            phase = .done
        case .head:
            throw DockerError.decoding("connection closed before response headers")
        default:
            throw DockerError.decoding("connection closed before the response body was complete")
        }
    }

    // MARK: State machine

    private mutating func advance() throws {
        defer { compact() }
        while true {
            switch phase {
            case .head:
                guard let end = findHeaderEnd() else {
                    if input.count - cursor > maxHeaderBytes { throw DockerError.decoding("response headers too large") }
                    return
                }
                if end - cursor > maxHeaderBytes { throw DockerError.decoding("response headers too large") }
                try parseHead(input[cursor..<(end - 4)])
                cursor = end
                scanFrom = 0

            case .fixedBody(let remaining):
                let take = min(remaining, input.count - cursor)
                if take > 0 {
                    body.append(contentsOf: input[cursor..<(cursor + take)])
                    cursor += take
                }
                if remaining - take == 0 {
                    phase = .done
                    return
                }
                phase = .fixedBody(remaining: remaining - take)
                return

            case .chunkSize:
                guard let lineEnd = findCRLF(from: cursor) else {
                    if input.count - cursor > Self.maxLineBytes { throw DockerError.decoding("chunk size line too long") }
                    return
                }
                let size = try Self.parseChunkSize(input[cursor..<lineEnd])
                cursor = lineEnd + 2
                if size == 0 {
                    phase = .trailers
                } else {
                    if body.count + size > maxBodyBytes { throw DockerError.decoding("response too large") }
                    phase = .chunkData(remaining: size)
                }

            case .chunkData(let remaining):
                let take = min(remaining, input.count - cursor)
                if take > 0 {
                    body.append(contentsOf: input[cursor..<(cursor + take)])
                    cursor += take
                }
                if remaining - take == 0 {
                    phase = .chunkDataEnd
                } else {
                    phase = .chunkData(remaining: remaining - take)
                    return
                }

            case .chunkDataEnd:
                guard input.count - cursor >= 2 else { return }
                guard input[cursor] == 13, input[cursor + 1] == 10 else {
                    throw DockerError.decoding("missing CRLF after chunk data")
                }
                cursor += 2
                phase = .chunkSize

            case .trailers:
                guard let lineEnd = findCRLF(from: cursor) else {
                    if input.count - cursor > maxHeaderBytes { throw DockerError.decoding("response trailers too large") }
                    return
                }
                let length = lineEnd - cursor
                cursor = lineEnd + 2
                if length == 0 {
                    phase = .done
                    return
                }
                trailerBytes += length + 2
                if trailerBytes > maxHeaderBytes { throw DockerError.decoding("response trailers too large") }

            case .untilEOF:
                let available = input.count - cursor
                if body.count + available > maxBodyBytes { throw DockerError.decoding("response too large") }
                if available > 0 {
                    body.append(contentsOf: input[cursor...])
                    cursor = input.count
                }
                return

            case .done:
                return
            }
        }
    }

    private mutating func compact() {
        guard cursor > 0 else { return }
        input.removeFirst(cursor)
        scanFrom = max(0, scanFrom - cursor)
        cursor = 0
    }

    /// Index just past the first `\r\n\r\n` at or after `cursor`, or nil. Remembers how far it looked.
    private mutating func findHeaderEnd() -> Int? {
        var index = max(scanFrom, cursor)
        let count = input.count
        while index + 3 < count {
            if input[index] == 13, input[index + 1] == 10, input[index + 2] == 13, input[index + 3] == 10 {
                return index + 4
            }
            index += 1
        }
        scanFrom = max(cursor, count - 3)
        return nil
    }

    /// Index of the `\r` of the first `\r\n` at or after `start`, or nil.
    private func findCRLF(from start: Int) -> Int? {
        var index = start
        let count = input.count
        while index + 1 < count {
            if input[index] == 13, input[index + 1] == 10 { return index }
            index += 1
        }
        return nil
    }

    private mutating func parseHead(_ bytes: ArraySlice<UInt8>) throws {
        let text = String(decoding: bytes, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw DockerError.decoding("empty response head") }

        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]), (100...599).contains(code) else {
            throw DockerError.decoding("malformed HTTP status line")
        }
        status = code

        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw DockerError.decoding("malformed HTTP header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { throw DockerError.decoding("malformed HTTP header name") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = parsed[name] {
                parsed[name] = existing + ", " + value
            } else {
                parsed[name] = value
            }
        }
        headers = parsed

        // Interim responses (`100 Continue`, `102 Processing`, `103 Early Hints`; RFC 9110 §15.2) carry no body and are not the
        // answer: skip the head and wait for the final one. `101` would switch protocols, which DevTidy never asks for.
        if (100..<200).contains(code) {
            if code == 101 { throw DockerError.decoding("unexpected 101 Switching Protocols") }
            interimResponses += 1
            guard interimResponses <= Self.maxInterimResponses else { throw DockerError.decoding("too many interim responses") }
            status = 0
            headers = [:]
            phase = .head
            return
        }
        // Responses that never carry a body (RFC 9112 §6.3).
        if code == 204 || code == 304 {
            phase = .done
            return
        }
        if let transferEncoding = parsed["transfer-encoding"] {
            let codings = transferEncoding.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            phase = codings.last == "chunked" ? .chunkSize : .untilEOF
            return
        }
        if let rawLength = parsed["content-length"] {
            guard let length = Int(rawLength), length >= 0 else { throw DockerError.decoding("invalid Content-Length") }
            if length > maxBodyBytes { throw DockerError.decoding("response too large") }
            phase = length == 0 ? .done : .fixedBody(remaining: length)
            return
        }
        phase = .untilEOF
    }

    private static func parseChunkSize(_ line: ArraySlice<UInt8>) throws -> Int {
        let text = String(decoding: line, as: UTF8.self)
        let sizePart = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let hex = sizePart.trimmingCharacters(in: .whitespaces)
        let isHex = hex.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }
        guard !hex.isEmpty, hex.utf8.count <= 15, isHex, let size = Int(hex, radix: 16) else {
            throw DockerError.decoding("invalid chunk size")
        }
        return size
    }
}

// MARK: - Transport --------------------------------------------------------------------------------------------------

/// Raw POSIX HTTP/1.1 over an `AF_UNIX` stream socket (`Connection: close`, one request per connection). Blocking syscalls run
/// on a private concurrent queue bridged with a continuation; the fd never outlives the exchange.
struct UnixSocketHTTP: DockerHTTPTransport {
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    private static let queue = DispatchQueue(label: "dev.minata.devtidy.docker-http", qos: .utility, attributes: .concurrent)

    func request(method: String, path: String, query: [URLQueryItem], timeout: TimeInterval) async throws -> HTTPResponse {
        let bytes = try Self.encodeRequest(method: method, path: path, query: query)
        try Task.checkCancellation()
        let socketPath = self.socketPath
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
            Self.queue.async {
                do {
                    let response = try Self.exchange(socketPath: socketPath, request: bytes, timeout: timeout)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Request encoding

    /// `METHOD /path?query HTTP/1.1` + fixed headers. No request body is ever sent. Method and path are validated so a
    /// malformed value can never smuggle extra header lines or a second request.
    static func encodeRequest(method: String, path: String, query: [URLQueryItem]) throws -> Data {
        guard !method.isEmpty, method.utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }) else {
            throw DockerError.invalidArgument("invalid HTTP method")
        }
        let pathIsSafe = path.hasPrefix("/") && path.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2F || byte == 0x5F || byte == 0x2E || byte == 0x2D
        }
        guard pathIsSafe else { throw DockerError.invalidArgument("invalid request path") }

        var target = path
        if !query.isEmpty {
            target += "?" + query.map { "\(percentEncode($0.name))=\(percentEncode($0.value ?? ""))" }.joined(separator: "&")
        }
        let text = "\(method) \(target) HTTP/1.1\r\nHost: docker\r\nUser-Agent: DevTidy\r\nAccept: application/json\r\n"
            + "Connection: close\r\nContent-Length: 0\r\n\r\n"
        return Data(text.utf8)
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters (so `{"until":["168h"]}` survives Go's query parser).
    static func percentEncode(_ text: String) -> String {
        let hexDigits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for byte in text.utf8 {
            let unreserved = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            if unreserved {
                out.append(byte)
            } else {
                out.append(0x25)
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Blocking exchange

    private static func exchange(socketPath: String, request: Data, timeout: TimeInterval) throws -> HTTPResponse {
        let budget = UInt64(max(timeout, 0.001) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ budget
        func remainingMilliseconds() -> Int {
            let now = DispatchTime.now().uptimeNanoseconds
            return now >= deadline ? 0 : Int((deadline - now + 999_999) / 1_000_000)
        }

        let address = try makeAddress(path: socketPath)

        let fd = try makeStreamSocket()
        defer { Darwin.close(fd) }

        // Connect without blocking so a wedged listener cannot hold the thread past the budget.
        let originalFlags = Darwin.fcntl(fd, F_GETFL)
        guard originalFlags >= 0, Darwin.fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            throw DockerError.daemonUnavailable("fcntl: \(errnoText(errno))")
        }
        let connectErrno = connectOnce(fd, address)
        switch connectErrno {
        case 0:
            break
        case EINPROGRESS, EINTR, EALREADY:
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let waitMilliseconds = min(1000, remainingMilliseconds())
            let pollResult = Darwin.poll(&pollDescriptor, 1, Int32(waitMilliseconds))
            if pollResult == 0 { throw DockerError.timeout }
            if pollResult < 0 { throw DockerError.daemonUnavailable("poll: \(errnoText(errno))") }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            if socketError != 0 { throw DockerError.daemonUnavailable("connect: \(errnoText(socketError))") }
        default:
            // ENOENT (no socket file), ECONNREFUSED (stale socket), ENOTSOCK, EACCES, …: the daemon is not reachable.
            throw DockerError.daemonUnavailable("connect: \(errnoText(connectErrno))")
        }

        guard Darwin.fcntl(fd, F_SETFL, originalFlags) >= 0 else {
            throw DockerError.daemonUnavailable("fcntl: \(errnoText(errno))")
        }
        let remaining = max(remainingMilliseconds(), 1)
        var timeoutValue = timeval(tv_sec: remaining / 1000, tv_usec: Int32((remaining % 1000) * 1000))
        Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        try sendAll(fd, request)

        var parser = HTTPParser()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !parser.isComplete {
            let waitMilliseconds = remainingMilliseconds()
            if waitMilliseconds <= 0 { throw DockerError.timeout }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, Int32(min(waitMilliseconds, Int(Int32.max))))
            if pollResult == 0 { throw DockerError.timeout }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw DockerError.daemonUnavailable("poll: \(errnoText(errno))")
            }
            let (received, receiveErrno) = buffer.withUnsafeMutableBytes { raw -> (Int, Int32) in
                let count = Darwin.recv(fd, raw.baseAddress, raw.count, 0)
                return (count, errno)
            }
            if received > 0 {
                try parser.feed(buffer[0..<received])
            } else if received == 0 {
                try parser.finish()
                break
            } else if receiveErrno == EINTR {
                continue
            } else if receiveErrno == EAGAIN || receiveErrno == EWOULDBLOCK {
                throw DockerError.timeout
            } else {
                throw DockerError.decoding("recv: \(errnoText(receiveErrno))")
            }
        }
        guard let response = parser.response else { throw DockerError.decoding("incomplete HTTP response") }
        return response
    }

    private static func sendAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let (written, sendErrno) = sendOnce(fd, data, offset: sent)
            if written > 0 {
                sent += written
            } else if written < 0 && sendErrno == EINTR {
                continue
            } else if written < 0 && (sendErrno == EAGAIN || sendErrno == EWOULDBLOCK) {
                throw DockerError.timeout
            } else {
                throw DockerError.daemonUnavailable("send: \(errnoText(sendErrno))")
            }
        }
    }

    private static func sendOnce(_ fd: Int32, _ data: Data, offset: Int) -> (Int, Int32) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Int, Int32) in
            guard let base = raw.baseAddress else { return (0, 0) }
            let count = Darwin.send(fd, base + offset, raw.count - offset, 0)
            return (count, errno)
        }
    }

    private static func connectOnce(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    /// `sun_path` holds 104 bytes including the NUL terminator.
    static func makeAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, !bytes.contains(0) else { throw DockerError.invalidArgument("invalid socket path") }
        guard bytes.count <= 103 else { throw DockerError.invalidArgument("socket path too long (\(bytes.count) bytes, max 103)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    /// `AF_UNIX` stream socket that is close-on-exec (a `git`/`docker` child spawned on another thread while a request is in
    /// flight must never inherit the daemon connection; Darwin has no `SOCK_CLOEXEC`, so the flag is set right after
    /// creation) and never raises `SIGPIPE`.
    static func makeStreamSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerError.daemonUnavailable("socket: \(errnoText(errno))") }
        guard Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else {
            let failure = errno
            Darwin.close(fd)
            throw DockerError.daemonUnavailable("fcntl: \(errnoText(failure))")
        }
        var noSigPipe: Int32 = 1
        guard Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw DockerError.daemonUnavailable("setsockopt: \(errnoText(failure))")
        }
        return fd
    }

    static func errnoText(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        let capacity = buffer.count
        guard strerror_r(code, &buffer, capacity) == 0 else { return "errno \(code)" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
