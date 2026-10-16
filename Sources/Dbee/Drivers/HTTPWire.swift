import Foundation
import NIOCore

/// A small HTTP/1.1 client on a `WireConnection`, for engines whose interface is HTTP (ClickHouse, Meilisearch).
///
/// Dbee doesn't use URLSession for them: URLSession shares cookies and may cache responses on disk, and it
/// can't run over the SSH tunnel's own channel. One request at a time per connection, kept alive between
/// requests unless the server closes it.
enum HTTPWire {
    struct Request: Sendable {
        var method: String
        /// Path and query, already percent-encoded.
        var target: String
        var headers: [(name: String, value: String)] = []
        var body: [UInt8] = []
    }

    struct Head: Sendable {
        var status: Int
        var reason: String
        var headers: [(name: String, value: String)]
        /// Whether the server keeps the connection open after this response.
        var keepsAlive: Bool

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var isSuccess: Bool { (200..<300).contains(status) }

        /// How long the connection may sit idle before the server closes it: `Keep-Alive: timeout=N` less a
        /// second, or a few seconds when the server doesn't say (actix-web, behind Meilisearch, uses 5).
        var idleLimit: TimeAmount {
            let timeout = header("Keep-Alive")?
                .split(separator: ",")
                .compactMap { part -> Int? in
                    let pair = part.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                    return pair.count == 2 && pair[0].lowercased() == "timeout" ? Int(pair[1]) : nil
                }
                .first
            return .seconds(Int64(max(1, (timeout ?? 5) - 1)))
        }
    }

    struct Response: Sendable {
        var head: Head
        var body: [UInt8]

        var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// Longest header block Dbee reads, so a server that never ends its headers can't fill memory.
    static let maxHeadSize = 64 * 1024

    // MARK: Encoding

    static func encode(_ request: Request, host: String) -> ByteBuffer {
        var head = "\(request.method) \(request.target) HTTP/1.1\r\nHost: \(host)\r\n"
        let names = Set(request.headers.map { $0.name.lowercased() })
        if !names.contains("user-agent") { head += "User-Agent: Dbee\r\n" }
        for (name, value) in request.headers {
            // Header values come from Dbee and the connect form; a line break would start a new header.
            // (Filtered by scalar: "\r\n" is a single Character.)
            var clean = String.UnicodeScalarView()
            clean.append(contentsOf: value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })
            head += "\(name): \(String(clean))\r\n"
        }
        if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method) {
            head += "Content-Length: \(request.body.count)\r\n"
        }
        head += "\r\n"
        var buffer = ByteBuffer()
        buffer.writeString(head)
        buffer.writeBytes(request.body)
        return buffer
    }

    /// "a=1&b=x%20y", with every character outside the unreserved set percent-encoded.
    static func query(_ items: [(String, String)]) -> String {
        items.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Parsing

    /// The status line and headers, or nil until the blank line that ends them has arrived.
    static func parseHead(_ buffer: inout ByteBuffer) throws -> Head? {
        let view = buffer.readableBytesView
        guard let end = headEnd(view) else {
            if view.count > maxHeadSize { throw WireConnection.Failure.malformed("HTTP headers too long") }
            return nil
        }
        let text = String(decoding: view.prefix(end - view.startIndex), as: UTF8.self)
        buffer.moveReaderIndex(forwardBy: end - view.startIndex + 4)
        var lines = text.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
            throw WireConnection.Failure.malformed("not an HTTP response")
        }
        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        let connection = headers.first { $0.name.lowercased() == "connection" }?.value.lowercased() ?? ""
        let keepsAlive = status[0] == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
        return Head(status: code, reason: status.count > 2 ? String(status[2]) : "", headers: headers, keepsAlive: keepsAlive)
    }

    private static func headEnd(_ view: ByteBufferView) -> Int? {
        var i = view.startIndex
        while i + 3 < view.endIndex {
            if view[i] == 0x0D, view[i + 1] == 0x0A, view[i + 2] == 0x0D, view[i + 3] == 0x0A { return i }
            i += 1
        }
        return nil
    }

    /// Decodes a response body as it arrives: Content-Length, chunked, or up to the end of the connection.
    struct BodyDecoder {
        enum Piece {
            case data(ByteBuffer)
            case end
        }

        private enum Framing {
            case length(Int)
            case chunked(ChunkState)
            case untilClose
            case done
        }

        private enum ChunkState {
            case size
            case data(Int)
            case dataEnd
            case trailers
        }

        private var framing: Framing

        init(head: Head, method: String) {
            if method == "HEAD" || (100..<200).contains(head.status) || head.status == 204 || head.status == 304 {
                framing = .done
            } else if head.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
                framing = .chunked(.size)
            } else if let length = head.header("Content-Length").flatMap({ Int($0) }) {
                framing = length > 0 ? .length(length) : .done
            } else {
                framing = .untilClose
            }
        }

        var isFinished: Bool { if case .done = framing { true } else { false } }
        /// Whether the body only ends when the server closes the connection.
        var endsWithConnection: Bool { if case .untilClose = framing { true } else { false } }

        /// The next piece of the body from `buffer`, or nil when more bytes are needed. `WireConnection.read`
        /// throws away what a parse consumed when it returns nil, so the decoder's state goes back too.
        mutating func next(_ buffer: inout ByteBuffer) throws -> Piece? {
            let saved = framing
            if let piece = try step(&buffer) { return piece }
            framing = saved
            return nil
        }

        private mutating func step(_ buffer: inout ByteBuffer) throws -> Piece? {
            while true {
                switch framing {
                case .done:
                    return .end
                case .untilClose:
                    guard buffer.readableBytes > 0 else { return nil }
                    return .data(buffer.readSlice(length: buffer.readableBytes)!)
                case .length(let remaining):
                    guard buffer.readableBytes > 0 else { return nil }
                    let count = min(remaining, buffer.readableBytes)
                    let slice = buffer.readSlice(length: count)!
                    framing = remaining == count ? .done : .length(remaining - count)
                    return .data(slice)
                case .chunked(let state):
                    switch state {
                    case .size:
                        guard let line = try readLine(&buffer) else { return nil }
                        let digits = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                        guard let size = Int(digits.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                            throw WireConnection.Failure.malformed("bad chunk size")
                        }
                        framing = .chunked(size == 0 ? .trailers : .data(size))
                    case .data(let remaining):
                        guard buffer.readableBytes > 0 else { return nil }
                        let count = min(remaining, buffer.readableBytes)
                        let slice = buffer.readSlice(length: count)!
                        framing = .chunked(remaining == count ? .dataEnd : .data(remaining - count))
                        return .data(slice)
                    case .dataEnd:
                        guard let line = try readLine(&buffer) else { return nil }
                        guard line.isEmpty else { throw WireConnection.Failure.malformed("bad chunk end") }
                        framing = .chunked(.size)
                    case .trailers:
                        guard let line = try readLine(&buffer) else { return nil }
                        if line.isEmpty { framing = .done }
                    }
                }
            }
        }

        /// One CRLF-terminated line without the CRLF, or nil until it has arrived.
        private func readLine(_ buffer: inout ByteBuffer) throws -> String? {
            let view = buffer.readableBytesView
            var i = view.startIndex
            while i + 1 < view.endIndex {
                if view[i] == 0x0D, view[i + 1] == 0x0A {
                    let line = String(decoding: view[view.startIndex..<i], as: UTF8.self)
                    buffer.moveReaderIndex(forwardBy: i - view.startIndex + 2)
                    return line
                }
                i += 1
            }
            if view.count > 4096 { throw WireConnection.Failure.malformed("chunk header too long") }
            return nil
        }
    }
}

extension WireConnection.Endpoint {
    /// The Host header: the server's real name (reverse proxies route on it), with the port unless it is the
    /// scheme's default.
    func hostHeader(tls: Bool) -> String {
        var host = displayHost
        if host.contains(":") { host = "[\(host)]" }
        let defaultPort = tls ? 443 : 80
        return displayPort == defaultPort ? host : "\(host):\(displayPort)"
    }
}

extension WireConnection {
    /// Sends `request` and reads the response head. The body follows with `readBody` or `streamBody`.
    func send(_ request: HTTPWire.Request, deadline: NIODeadline? = nil) async throws -> HTTPWire.Head {
        try await write(HTTPWire.encode(request, host: endpoint.hostHeader(tls: usesTLS)))
        while true {
            let head = try await read(deadline: deadline) { try HTTPWire.parseHead(&$0) }
            // 100 Continue and other interim responses come before the real one.
            if (100..<200).contains(head.status), head.status != 101 { continue }
            return head
        }
    }

    /// Hands each piece of the body to `consume` until it returns false or the body ends. Returns whether the
    /// whole body was read; when it wasn't, the connection is in the middle of a response and must be closed.
    func streamBody(_ head: HTTPWire.Head, method: String, deadline: NIODeadline? = nil,
                    _ consume: (ByteBuffer) throws -> Bool) async throws -> Bool {
        var decoder = HTTPWire.BodyDecoder(head: head, method: method)
        while !decoder.isFinished {
            let piece: HTTPWire.BodyDecoder.Piece
            do {
                piece = try await read(deadline: deadline) { try decoder.next(&$0) }
            } catch Failure.closed where decoder.endsWithConnection {
                break
            }
            switch piece {
            case .end: return true
            case .data(let bytes): if try !consume(bytes) { return false }
            }
        }
        return true
    }

    /// Reads the whole body, failing when it grows past `limit` bytes.
    func readBody(_ head: HTTPWire.Head, method: String, deadline: NIODeadline? = nil,
                  limit: Int = 256 * 1024 * 1024) async throws -> [UInt8] {
        var body: [UInt8] = []
        _ = try await streamBody(head, method: method, deadline: deadline) { piece in
            guard body.count + piece.readableBytes <= limit else {
                throw DatabaseError("The server's reply is too large to show.",
                                    detail: "Dbee reads at most \(limit / 1024 / 1024) MB per reply.")
            }
            body.append(contentsOf: piece.readableBytesView)
            return true
        }
        return body
    }

    /// One complete exchange.
    func exchange(_ request: HTTPWire.Request, deadline: NIODeadline? = nil) async throws -> HTTPWire.Response {
        let head = try await send(request, deadline: deadline)
        let body = try await readBody(head, method: request.method, deadline: deadline)
        return HTTPWire.Response(head: head, body: body)
    }
}
