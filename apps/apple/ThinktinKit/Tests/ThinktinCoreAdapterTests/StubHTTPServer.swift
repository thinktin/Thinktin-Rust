import Foundation
import ThinktinKit

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// 本机上的极简 HTTP 服务端（只给测试用）：按“方法 路径”（不含查询串）返回预设的响应，记下收到的请求。
///
/// 让真实的 client-core 发真实的请求、解析真实的 JSON，再经适配层转成 ThinktinKit 的模型，测的是整条链路。
/// 每个连接只答一个请求（`Connection: close`）。只监听 127.0.0.1，端口由系统分配。
final class StubHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var contentType: String

        init(_ status: Int, json: String) {
            self.status = status
            self.body = Data(json.utf8)
            self.contentType = "application/json"
        }

        init(_ status: Int, bytes: Data, contentType: String) {
            self.status = status
            self.body = bytes
            self.contentType = contentType
        }
    }

    struct Request: Sendable, Hashable {
        var method: String
        /// 带查询串。
        var target: String
        /// 名字是小写。
        var headers: [String: String]
        var body: String

        /// 不带查询串的路径。
        var path: String { String(target.prefix { $0 != "?" }) }

        /// 查询参数（解码后）。
        var query: [String: String] {
            let items = URLComponents(string: "http://stub\(target)")?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }
    }

    struct SocketError: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call) failed: errno \(code)" }
    }

    let port: UInt16
    var baseURL: String { "http://127.0.0.1:\(port)" }

    private let listener: Int32
    private let routes: [String: Response]
    private let log = Locked<[Request]>([])
    private let isStopped = Locked(false)

    /// `routes` 的键是“方法 路径”，比如 `GET /v1/me`。没配的路径答 404 not_found。
    init(routes: [String: Response]) throws {
        self.routes = routes
        #if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if !os(Linux)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw SocketError(call: "bind/listen", code: code)
        }
        var actual = sockaddr_in()
        var actualSize = size
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualSize) }
        }
        guard named == 0 else {
            let code = errno
            close(fd)
            throw SocketError(call: "getsockname", code: code)
        }
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
        // 监听线程持有 self，用完要调 `stop()`（测试里 `defer { server.stop() }`）。
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// 收到的请求（按顺序）。
    var requests: [Request] { log.value }

    /// 停止监听。可以重复调用。
    func stop() {
        let first = isStopped.withLock { stopped -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        // shutdown 让阻塞在 accept 上的线程返回（Linux）；再连一下自己，兜住不返回的平台。
        _ = shutdown(listener, Int32(SHUT_RDWR))
        wakeAcceptor()
        close(listener)
    }

    private func wakeAcceptor() {
        #if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if !os(Linux)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        close(fd)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR && !isStopped.value { continue }
                return
            }
            if isStopped.value {
                close(client)
                return
            }
            #if !os(Linux)
                var yes: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            serve(client)
            close(client)
        }
    }

    private func serve(_ fd: Int32) {
        guard let request = readRequest(fd) else { return }
        log.withLock { $0.append(request) }
        let key = "\(request.method) \(request.path)"
        let response =
            routes[key] ?? Response(404, json: #"{"code":"not_found","message":"no stub for \#(key)"}"#)
        var head = "HTTP/1.1 \(response.status) Stub\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        writeAll(fd, Data(head.utf8) + response.body)
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Int?
        var contentLength = 0
        let separator = Data("\r\n\r\n".utf8)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if headerEnd == nil, let range = data.range(of: separator) {
                headerEnd = range.upperBound
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                for line in head.split(separator: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }
            if let end = headerEnd, data.count >= end + contentLength { break }
        }
        guard let end = headerEnd else { return nil }
        let head = String(decoding: data[..<(end - separator.count)], as: UTF8.self)
        var lines = head.split(separator: "\r\n").map(String.init)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let body = String(decoding: data[end...].prefix(contentLength), as: UTF8.self)
        return Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body)
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        #if os(Linux)
            let flags = Int32(MSG_NOSIGNAL)
        #else
            let flags: Int32 = 0
        #endif
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress! + offset, raw.count - offset, flags)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
