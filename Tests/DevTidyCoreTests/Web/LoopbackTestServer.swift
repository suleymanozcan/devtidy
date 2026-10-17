import Foundation
import Darwin

/// A small blocking HTTP/1.1 server that a test starts itself on 127.0.0.1 (or ::1) with a kernel-chosen port. It is the only
/// thing the page-title tests ever talk to: never a real dev server. Thread-based; `stop()` (also on deinit) ends every thread
/// within ~50 ms.
final class LoopbackTestServer: @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let method: String
        let target: String
        let headers: [String: String]           // lowercased names
    }

    enum Reply: Sendable {
        /// Written as is, then the connection is closed.
        case bytes([UInt8])
        /// Reads the request, then never answers until the client goes away or the server stops.
        case hang
        /// Closes without a single byte.
        case close
        /// `head`, then `chunk` over and over until the client closes (or the server stops).
        case stream(head: [UInt8], chunk: [UInt8])
    }

    enum StartError: Error { case socket(Int32), bind(Int32), listen(Int32) }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private var received: [Request] = []
    private var streaming = 0
    private let handler: @Sendable (Request, Int) -> Reply
    let port: UInt16

    /// `handler(request, index)`: `index` is the 0-based number of the request.
    init(ipv6: Bool = false, handler: @escaping @Sendable (Request, Int) -> Reply) throws {
        self.handler = handler
        let fd = Darwin.socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        var yes: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var boundPort: UInt16 = 0
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            withUnsafeMutableBytes(of: &address.sin6_addr) { $0[15] = 1 }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            guard result == 0 else { let e = errno; Darwin.close(fd); throw StartError.bind(e) }
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.getsockname(fd, $0, &length) }
            }
            boundPort = UInt16(bigEndian: address.sin6_port)
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { let e = errno; Darwin.close(fd); throw StartError.bind(e) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.getsockname(fd, $0, &length) }
            }
            boundPort = UInt16(bigEndian: address.sin_port)
        }
        guard Darwin.listen(fd, 16) == 0 else { let e = errno; Darwin.close(fd); throw StartError.listen(e) }
        listenFD = fd
        port = boundPort
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// Every request received so far, in order.
    var requests: [Request] { lock.withLock { received } }

    /// Streams (`.stream`) that are still being written.
    var activeStreams: Int { lock.withLock { streaming } }

    private var isStopped: Bool { lock.withLock { stopped } }

    // MARK: Threads

    private func acceptLoop(_ fd: Int32) {
        defer { Darwin.close(fd) }
        while !isStopped {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var noSigPipe: Int32 = 1
            Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        guard let request = readRequest(fd) else { return }
        let index = lock.withLock { () -> Int in received.append(request); return received.count - 1 }
        switch handler(request, index) {
        case .bytes(let bytes):
            send(fd, bytes)
        case .close:
            return
        case .hang:
            while !isStopped {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if Darwin.poll(&descriptor, 1, 50) > 0 {
                    var byte: UInt8 = 0
                    if Darwin.recv(fd, &byte, 1, 0) <= 0 { return }
                }
            }
        case .stream(let head, let chunk):
            lock.withLock { streaming += 1 }
            defer { lock.withLock { streaming -= 1 } }
            guard send(fd, head) else { return }
            while !isStopped, send(fd, chunk) {}
        }
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            if let end = headEnd(data) {
                let text = String(decoding: data[..<end], as: UTF8.self)
                let lines = text.components(separatedBy: "\r\n")
                let parts = lines[0].split(separator: " ")
                guard parts.count >= 2 else { return nil }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                return Request(method: String(parts[0]), target: String(parts[1]), headers: headers)
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count <= 0 { return nil }
            data.append(contentsOf: buffer[0..<count])
        }
        return nil
    }

    private func headEnd(_ data: [UInt8]) -> Int? {
        guard data.count >= 4 else { return nil }
        for index in 0...(data.count - 4)
        where data[index] == 13 && data[index + 1] == 10 && data[index + 2] == 13 && data[index + 3] == 10 {
            return index
        }
        return nil
    }

    @discardableResult
    private func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, $0.count - sent, 0) }
            if written > 0 {
                sent += written
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                if isStopped { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 50)
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Canned replies ----------------------------------------------------------------------------

extension LoopbackTestServer.Reply {
    static func html(_ body: String, status: String = "200 OK", type: String = "text/html; charset=utf-8",
                     chunked: Bool = false, extraHeaders: [String] = []) -> LoopbackTestServer.Reply {
        let payload = Array(body.utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nConnection: close\r\n"
        for header in extraHeaders { head += header + "\r\n" }
        var bytes: [UInt8]
        if chunked {
            head += "Transfer-Encoding: chunked\r\n\r\n"
            bytes = Array(head.utf8)
            var offset = 0
            while offset < payload.count {
                let size = min(7, payload.count - offset)                  // deliberately tiny chunks
                bytes.append(contentsOf: Array(String(size, radix: 16).utf8))
                bytes.append(contentsOf: [13, 10] as [UInt8])
                bytes.append(contentsOf: payload[offset..<(offset + size)])
                bytes.append(contentsOf: [13, 10] as [UInt8])
                offset += size
            }
            bytes += Array("0\r\n\r\n".utf8)
        } else {
            head += "Content-Length: \(payload.count)\r\n\r\n"
            bytes = Array(head.utf8) + payload
        }
        return .bytes(bytes)
    }

    static func redirect(to location: String, status: String = "302 Found") -> LoopbackTestServer.Reply {
        .bytes(Array("HTTP/1.1 \(status)\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
    }
}
