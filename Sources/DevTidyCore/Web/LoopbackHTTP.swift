import Foundation
import Darwin

// A minimal HTTP/1.1 `GET` client that can only ever talk to this machine. It exists because the title fetch must (a) never
// leave loopback, (b) never use cookies, caches or proxies, and (c) be bounded in time and bytes: with raw sockets those are
// properties of the code rather than of a URLSession configuration. It also needs no App Transport Security exception: ATS
// governs URLSession/CFNetwork loads, not BSD sockets.
//
// Only the loopback addresses the caller names (`127.0.0.0/8` literals and `::1`, the server's own sockets) are ever connected
// to. A `localhost` in a redirect is read as the address already in use; names are never resolved.

struct LoopbackLimits: Sendable, Equatable {
    /// Per connection attempt (each candidate address in turn).
    var connectTimeout: TimeInterval = 1.5
    /// Connect + send + receive, redirects included.
    var totalTimeout: TimeInterval = 3
    var maxBodyBytes = 256 * 1024
    var maxRedirects = 2

    static let standard = LoopbackLimits()
}

enum LoopbackOutcome: Sendable, Equatable {
    /// A 2xx `text/html` answer: the first bytes of its body (at most `maxBodyBytes`; reading stops once the head is behind us).
    case html([UInt8])
    /// The server answered, but there is nothing to read: another content type, a 4xx, a redirect that was refused (not
    /// loopback, another port, too many) or had no `Location`.
    case nothingToRead
    /// No usable answer: nothing listening, a timeout, a malformed response, a 5xx.
    case unreachable
}

// MARK: - Hosts ----------------------------------------------------------------------------------------

/// A loopback address a request can be sent to: an IPv4 `127.x.y.z`, or `::1`.
enum LoopbackAddress: Sendable, Hashable {
    case ipv4(UInt8, UInt8, UInt8, UInt8)
    case ipv6

    /// IPv4 before IPv6, numerically: the order candidates are tried in.
    var order: UInt64 {
        switch self {
        case .ipv4(let a, let b, let c, let d): UInt64(a) << 24 | UInt64(b) << 16 | UInt64(c) << 8 | UInt64(d)
        case .ipv6: 1 << 32
        }
    }
}

/// The host a request names (`Host:` header, redirect `Location`). The connection itself always goes to a `LoopbackAddress` the
/// caller chose; the host never decides where to connect.
enum LoopbackHost: Sendable, Equatable {
    case localhost
    case ipv4(UInt8, UInt8, UInt8, UInt8)
    case ipv6

    /// The host of a request sent straight to `address`.
    init(_ address: LoopbackAddress) {
        switch address {
        case .ipv4(let a, let b, let c, let d): self = .ipv4(a, b, c, d)
        case .ipv6: self = .ipv6
        }
    }

    /// Whether a request for this host is the one the connection to `address` already serves: `localhost` names whatever address
    /// is in use, an explicit address only itself (another one is another socket, maybe another process's).
    func isServed(by address: LoopbackAddress) -> Bool {
        switch self {
        case .localhost: true
        case .ipv4(let a, let b, let c, let d): address == .ipv4(a, b, c, d)
        case .ipv6: address == .ipv6
        }
    }

    func hostHeader(port: UInt16) -> String {
        switch self {
        case .localhost: "localhost:\(port)"
        case .ipv4(let a, let b, let c, let d): "\(a).\(b).\(c).\(d):\(port)"
        case .ipv6: "[::1]:\(port)"
        }
    }
}

// MARK: - Redirect policy ------------------------------------------------------------------------------

/// A redirect is followed only to `http://` + loopback + the SAME port + the address that answered. Everything else (another
/// host, another port, https, userinfo, other schemes, control characters, another loopback address: that is another socket,
/// maybe another process's) is refused before any connection is made. `localhost` keeps the address in use.
enum LoopbackRedirect {
    struct Target: Equatable {
        let host: LoopbackHost
        let path: String
    }

    static func resolve(location raw: String, currentHost: LoopbackHost, currentPath: String, port: UInt16,
                        answeredBy address: LoopbackAddress) -> Target? {
        let location = raw.trimmingCharacters(in: .whitespaces)
        guard !location.isEmpty, location.utf8.count <= 2048 else { return nil }
        let lower = location.lowercased()

        var host = currentHost
        var rest: Substring
        var hasAuthority = true
        if lower.hasPrefix("http://") {
            guard let parsed = parseAuthority(location.dropFirst("http://".count), port: port) else { return nil }
            host = parsed.host
            rest = parsed.rest
        } else if lower.hasPrefix("//") {
            guard let parsed = parseAuthority(location.dropFirst(2), port: port) else { return nil }
            host = parsed.host
            rest = parsed.rest
        } else if hasScheme(lower) {
            return nil                                           // https:, ftp:, javascript:, …
        } else {
            hasAuthority = false
            rest = Substring(location)
        }

        let current = String(currentPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var pathAndQuery: String
        if rest.isEmpty {
            pathAndQuery = "/"
        } else if rest.hasPrefix("/") {
            pathAndQuery = String(rest)
        } else if rest.hasPrefix("?") {
            pathAndQuery = (hasAuthority ? "/" : current) + String(rest)
        } else if rest.hasPrefix("#") {
            pathAndQuery = hasAuthority ? "/" : current
        } else if hasAuthority {
            return nil                                           // `http://localhost:5173foo`: not a path
        } else {
            let directory = current.lastIndex(of: "/").map { String(current[...$0]) } ?? "/"
            pathAndQuery = directory + String(rest)
        }
        if let fragment = pathAndQuery.firstIndex(of: "#") { pathAndQuery = String(pathAndQuery[..<fragment]) }
        guard host.isServed(by: address), let target = requestTarget(pathAndQuery) else { return nil }
        return Target(host: host, path: target)
    }

    /// `host[:port]` up to the first `/`, `?` or `#`; the port must be `port` (an absent port means 80).
    private static func parseAuthority(_ text: Substring, port: UInt16) -> (host: LoopbackHost, rest: Substring)? {
        let end = text.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? text.endIndex
        let authority = text[..<end]
        guard !authority.contains("@") else { return nil }
        var hostText: Substring
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            hostText = authority[authority.index(after: authority.startIndex)..<close]
            let tail = authority[authority.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { return nil }
                portText = tail.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: ":") {
            hostText = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        } else {
            hostText = authority
        }
        let declaredPort: UInt16
        if let portText {
            guard !portText.isEmpty, portText.utf8.count <= 5, portText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = UInt16(portText) else { return nil }
            declaredPort = value
        } else {
            declaredPort = 80
        }
        guard declaredPort == port, let host = loopbackHost(String(hostText), bracketed: authority.hasPrefix("[")) else { return nil }
        return (host, text[end...])
    }

    private static func loopbackHost(_ text: String, bracketed: Bool) -> LoopbackHost? {
        if bracketed { return text == "::1" ? .ipv6 : nil }
        let lower = text.lowercased()
        if lower == "localhost" || lower == "localhost." { return .localhost }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.count <= 3, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets[0] == 127 ? .ipv4(octets[0], octets[1], octets[2], octets[3]) : nil
    }

    private static func hasScheme(_ lower: String) -> Bool {
        guard let colon = lower.firstIndex(of: ":") else { return false }
        let name = lower[..<colon]
        guard let first = name.unicodeScalars.first, first.properties.isAlphabetic, first.isASCII else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || (scalar.value >= 0x30 && scalar.value <= 0x39)
                               || scalar == "+" || scalar == "-" || scalar == ".")
        }
    }

    /// The origin-form request target: dot segments resolved, controls refused, spaces and non-ASCII percent-encoded.
    static func requestTarget(_ pathAndQuery: String) -> String? {
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var segments: [Substring] = []
        for segment in parts[0].split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            if segment == "." { continue }
            if segment == ".." { if !segments.isEmpty { segments.removeLast() }; continue }
            segments.append(segment)
        }
        var target = "/" + segments.joined(separator: "/")
        if parts.count > 1 { target += "?" + parts[1] }
        var encoded = ""
        for byte in target.utf8 {
            if byte < 0x20 || byte == 0x7F { return nil }
            if byte == 0x20 || byte >= 0x80 || byte == UInt8(ascii: "\\") {
                encoded += String(format: "%%%02X", byte)
            } else {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return encoded
    }
}

// MARK: - Response reader ------------------------------------------------------------------------------

/// Incremental HTTP/1.x response reader: head, then the body framed by `Content-Length`, `chunked` or end of stream. The body
/// is cut at `maxBodyBytes`; the reader never holds more than that.
struct LoopbackResponseReader {
    enum Failure: Equatable { case malformed, headTooLarge }

    private enum BodyMode { case none, length(Int), chunked, untilClose }

    let maxHeadBytes: Int
    let maxBodyBytes: Int
    private(set) var status = 0
    /// Lowercased names; repeated headers joined with ", ".
    private(set) var headers: [String: String] = [:]
    private(set) var body: [UInt8] = []
    private(set) var isHeadComplete = false
    /// The framing says the body is complete (or `endOfStream()` was called).
    private(set) var isFinished = false
    private(set) var failure: Failure?
    private var head: [UInt8] = []
    private var headScanFrom = 0
    private var mode = BodyMode.none
    private var decoder = LoopbackChunkDecoder()
    private var interimHeads = 0

    /// Interim `1xx` responses (`100 Continue`, `103 Early Hints`) that may precede the real one; more than this is malformed.
    static let maxInterimHeads = 8

    init(maxHeadBytes: Int = 32 * 1024, maxBodyBytes: Int) {
        self.maxHeadBytes = maxHeadBytes
        self.maxBodyBytes = maxBodyBytes
    }

    var isBodyCapped: Bool { body.count >= maxBodyBytes }

    mutating func feed(_ bytes: ArraySlice<UInt8>) {
        guard failure == nil, !bytes.isEmpty else { return }
        var remainder = bytes
        if !isHeadComplete {
            head.append(contentsOf: bytes)
            while true {
                guard let end = headEnd() else {
                    if head.count > maxHeadBytes { failure = .headTooLarge }
                    return
                }
                guard parseHead(head[..<end]) else { failure = .malformed; return }
                let after = Array(head[(end + 4)...])
                if (100..<200).contains(status), status != 101 {
                    // An interim answer comes before the real one: it carries no body, skip it and read the next head.
                    interimHeads += 1
                    guard interimHeads <= Self.maxInterimHeads else { failure = .malformed; return }
                    status = 0
                    headers = [:]
                    mode = .none
                    isFinished = false
                    head = after
                    headScanFrom = 0
                    continue
                }
                remainder = after[...]
                head = []
                isHeadComplete = true
                break
            }
        }
        consumeBody(remainder)
    }

    /// The peer closed the connection.
    mutating func endOfStream() {
        if isHeadComplete, case .untilClose = mode { isFinished = true }
    }

    private mutating func headEnd() -> Int? {
        var index = max(0, headScanFrom - 3)
        while index + 3 < head.count {
            if head[index] == 13, head[index + 1] == 10, head[index + 2] == 13, head[index + 3] == 10 { return index }
            index += 1
        }
        headScanFrom = head.count
        return nil
    }

    private mutating func parseHead(_ bytes: ArraySlice<UInt8>) -> Bool {
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return false }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]), (100...599).contains(code) else { return false }
        status = code
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        if status == 204 || status == 304 || status < 200 {
            mode = .none
            isFinished = true
        } else if let encoding = headers["transfer-encoding"] {
            let last = encoding.lowercased().split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
            mode = last == "chunked" ? .chunked : .untilClose
        } else if let length = headers["content-length"], let count = Int(length.trimmingCharacters(in: .whitespaces)), count >= 0 {
            mode = count == 0 ? .none : .length(count)
            isFinished = count == 0
        } else {
            mode = .untilClose
        }
        return true
    }

    private mutating func consumeBody(_ input: ArraySlice<UInt8>) {
        guard !input.isEmpty else { return }
        switch mode {
        case .none:
            return
        case .length(let remaining):
            let take = min(remaining, input.count)
            append(input.prefix(take))
            mode = .length(remaining - take)
            if remaining - take == 0 { isFinished = true }
        case .untilClose:
            append(input)
        case .chunked:
            guard decoder.feed(input, into: &body, limit: maxBodyBytes) else { failure = .malformed; return }
            if decoder.isDone { isFinished = true }
        }
    }

    private mutating func append(_ bytes: ArraySlice<UInt8>) {
        let room = maxBodyBytes - body.count
        if room > 0 { body.append(contentsOf: bytes.prefix(room)) }
    }
}

/// `Transfer-Encoding: chunked` decoder, one byte at a time (the input is bounded by the body cap).
struct LoopbackChunkDecoder {
    private enum State {
        case size
        case data(remaining: Int)
        case dataEnd
        case trailers(lineLength: Int)
        case done
    }

    private var state = State.size
    private var line: [UInt8] = []

    var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    /// Appends decoded bytes to `output` up to `limit` in total. false = malformed framing.
    mutating func feed(_ input: ArraySlice<UInt8>, into output: inout [UInt8], limit: Int) -> Bool {
        for byte in input {
            switch state {
            case .size:
                if byte == 10 {
                    guard let size = Self.parseSize(line) else { return false }
                    line.removeAll(keepingCapacity: true)
                    state = size == 0 ? .trailers(lineLength: 0) : .data(remaining: size)
                } else {
                    line.append(byte)
                    if line.count > 64 { return false }
                }
            case .data(let remaining):
                if output.count < limit { output.append(byte) }
                state = remaining == 1 ? .dataEnd : .data(remaining: remaining - 1)
            case .dataEnd:
                if byte == 10 { state = .size } else if byte != 13 { return false }
            case .trailers(let lineLength):
                if byte == 10 {
                    state = lineLength == 0 ? .done : .trailers(lineLength: 0)
                } else if byte != 13 {
                    state = .trailers(lineLength: lineLength + 1)
                }
            case .done:
                return true
            }
        }
        return true
    }

    private static func parseSize(_ line: [UInt8]) -> Int? {
        var digits = line
        if digits.last == 13 { digits.removeLast() }
        if let semicolon = digits.firstIndex(of: UInt8(ascii: ";")) { digits = Array(digits[..<semicolon]) }
        let text = String(decoding: digits, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        // Only hex digits: `Int(_, radix:)` also takes a sign, and a negative size would turn the rest of the stream into one
        // endless chunk.
        guard !text.isEmpty, text.utf8.count <= 8, text.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
        }) else { return nil }
        return Int(text, radix: 16)
    }
}

// MARK: - Client -----------------------------------------------------------------------------------------

enum LoopbackHTTP {
    private static let queue = DispatchQueue(label: "dev.minata.devtidy.loopback-http", qos: .utility, attributes: .concurrent)

    /// `GET /` on `port` of the first of `addresses` (loopback, in the order given) that accepts a connection, redirects followed
    /// under `LoopbackRedirect`'s rules and only on the address that answered. Runs the blocking socket work on a private queue.
    static func fetchHTML(addresses: [LoopbackAddress], port: UInt16, limits: LoopbackLimits = .standard) async -> LoopbackOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<LoopbackOutcome, Never>) in
            queue.async {
                continuation.resume(returning: fetchHTMLBlocking(addresses: addresses, port: port, limits: limits))
            }
        }
    }

    static func fetchHTMLBlocking(addresses: [LoopbackAddress], port: UInt16, limits: LoopbackLimits) -> LoopbackOutcome {
        let deadline = Deadline(seconds: limits.totalTimeout)
        guard var connection = connect(to: addresses, port: port, limits: limits, deadline: deadline) else { return .unreachable }
        // The first address that answers is the one socket asked; a redirect never moves to another.
        let address = connection.address
        var host = LoopbackHost(address)
        var path = "/"
        var redirects = 0
        while true {
            switch exchange(connection.fd, host: host, port: port, path: path, limits: limits, deadline: deadline) {
            case .final(let outcome):
                return outcome
            case .redirect(let location):
                guard redirects < limits.maxRedirects,
                      let next = LoopbackRedirect.resolve(location: location, currentHost: host, currentPath: path, port: port,
                                                          answeredBy: address)
                else { return .nothingToRead }
                guard let again = connect(to: [address], port: port, limits: limits, deadline: deadline) else { return .unreachable }
                redirects += 1
                host = next.host
                path = next.path
                connection = again
            }
        }
    }

    private enum Exchange {
        case final(LoopbackOutcome)
        case redirect(String)
    }

    private struct Deadline {
        private let end: UInt64
        init(seconds: TimeInterval) {
            end = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(seconds, 0.001) * 1_000_000_000)
        }
        var remainingMilliseconds: Int {
            let now = DispatchTime.now().uptimeNanoseconds
            return now >= end ? 0 : Int((end - now + 999_999) / 1_000_000)
        }
    }

    /// Sends one request on the connected `fd` and reads the answer; closes `fd`.
    private static func exchange(_ fd: Int32, host: LoopbackHost, port: UInt16, path: String, limits: LoopbackLimits,
                                 deadline: Deadline) -> Exchange {
        defer { Darwin.close(fd) }

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host.hostHeader(port: port))\r\nUser-Agent: DevTidy\r\n"
            + "Accept: text/html\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        guard sendAll(fd, Array(request.utf8), deadline: deadline) else { return .final(.unreachable) }

        var reader = LoopbackResponseReader(maxBodyBytes: limits.maxBodyBytes)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let decided = decide(reader) { return decided }
            let wait = deadline.remainingMilliseconds
            if wait <= 0 { return .final(pageIfComplete(reader) ?? .unreachable) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(wait, Int(Int32.max))))
            if ready == 0 { return .final(pageIfComplete(reader) ?? .unreachable) }
            if ready < 0 {
                if errno == EINTR { continue }
                return .final(.unreachable)
            }
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if received > 0 {
                reader.feed(buffer[0..<received])
            } else if received == 0 {
                reader.endOfStream()
                return decide(reader) ?? .final(pageIfComplete(reader) ?? .unreachable)
            } else if errno != EINTR && errno != EAGAIN {
                return .final(pageIfComplete(reader) ?? .unreachable)
            }
        }
    }

    /// nil = keep reading.
    private static func decide(_ reader: LoopbackResponseReader) -> Exchange? {
        if reader.failure != nil { return .final(.unreachable) }
        guard reader.isHeadComplete else { return nil }
        switch reader.status {
        case 301, 302, 303, 307, 308:
            guard let location = reader.headers["location"] else { return .final(.nothingToRead) }
            return .redirect(location)
        case 200..<300:
            guard isIdentityHTML(reader) else { return .final(.nothingToRead) }
            if reader.isFinished || reader.isBodyCapped || HTMLTitle.isPastTitle(reader.body) { return .final(.html(reader.body)) }
            return nil
        case 500..<600:
            return .final(.unreachable)
        default:
            return .final(.nothingToRead)
        }
    }

    /// `text/html` (parameters allowed) with no content coding: the only answer the title is read from.
    static func isIdentityHTML(_ reader: LoopbackResponseReader) -> Bool {
        let type = reader.headers["content-type"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let encoding = reader.headers["content-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? "identity"
        return (type == "text/html" || type.hasPrefix("text/html;") || type.hasPrefix("text/html ")) && encoding == "identity"
    }

    /// At a deadline or a reset: what was read so far still counts when it is the start of an HTML answer (the same test as
    /// the live decision: `text/htmlx` is not HTML here either).
    static func pageIfComplete(_ reader: LoopbackResponseReader) -> LoopbackOutcome? {
        guard reader.isHeadComplete, reader.failure == nil, (200..<300).contains(reader.status), isIdentityHTML(reader) else {
            return nil
        }
        return .html(reader.body)
    }

    // MARK: Sockets

    /// The first of `addresses`, in order, that accepts a connection within the budget.
    private static func connect(to addresses: [LoopbackAddress], port: UInt16, limits: LoopbackLimits,
                                deadline: Deadline) -> (fd: Int32, address: LoopbackAddress)? {
        for address in addresses {
            let budget = min(Int(limits.connectTimeout * 1000), deadline.remainingMilliseconds)
            guard budget > 0 else { return nil }
            if let fd = connectOnce(address, port: port, milliseconds: budget) { return (fd, address) }
        }
        return nil
    }

    private static func connectOnce(_ address: LoopbackAddress, port: UInt16, milliseconds: Int) -> Int32? {
        let family: Int32
        switch address {
        case .ipv4: family = AF_INET
        case .ipv6: family = AF_INET6
        }
        let fd = Darwin.socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0, flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0,
              Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            return nil
        }

        let result: Int32
        switch address {
        case .ipv4(let a, let b, let c, let d):
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = port.bigEndian
            socketAddress.sin_addr.s_addr = (UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)).bigEndian
            result = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6:
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { $0[15] = 1 }      // ::1
            result = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if result == 0 { return fd }
        guard errno == EINPROGRESS || errno == EINTR || errno == EALREADY else {
            Darwin.close(fd)
            return nil
        }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, Int32(min(milliseconds, Int(Int32.max))))
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard ready > 0, Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8], deadline: Deadline) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, $0.count - sent, 0) }
            if written > 0 {
                sent += written
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                let wait = deadline.remainingMilliseconds
                guard wait > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&descriptor, 1, Int32(min(wait, Int(Int32.max))))
            } else {
                return false
            }
        }
        return true
    }
}
