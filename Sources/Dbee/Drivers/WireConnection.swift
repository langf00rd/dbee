import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// A byte stream to a server, for drivers that speak their wire protocol themselves (Redis, MongoDB).
///
/// Dials host:port, or opens the SSH tunnel's own channel when tunnelled, optionally wraps the stream in TLS
/// right away (both protocols use TLS from the first byte, without STARTTLS), and hands received bytes to
/// async code that parses its own frames. Not thread-safe: the owning driver runs one exchange at a time.
final class WireConnection: @unchecked Sendable {
    struct Endpoint: Sendable {
        var dialHost: String
        var dialPort: Int
        /// The server's real name (differs from `dialHost` when tunnelled); used for SNI and certificate checks.
        var logicalHost: String
        var displayPort: Int
        var tls: TLSMode
        var transport: DriverTransport
        /// "Redis", "MongoDB": used in error messages.
        var engine: String

        init(config: ConnectionConfig, dialHost: String, dialPort: Int, transport: DriverTransport) {
            self.dialHost = dialHost
            self.dialPort = dialPort
            logicalHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
            displayPort = config.port
            tls = config.tls
            self.transport = transport
            engine = config.kind.displayName
        }

        var displayHost: String { logicalHost.isEmpty ? dialHost : logicalHost }
        var displayName: String { "\(displayHost):\(displayPort)" }
    }

    /// Transport-level failures. Anything the server itself reports is a `DatabaseError` instead, which is
    /// how `open` tells a TLS attempt that failed from a server that answered and refused.
    enum Failure: LocalizedError, Equatable {
        case closed
        case timedOut
        case cancelled
        case tls(String)
        case io(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .closed: "The server closed the connection."
            case .timedOut: "The server didn't answer in time."
            case .cancelled: "Query stopped"
            case .tls(let reason): "The TLS connection failed: \(reason)"
            case .io(let reason): "The connection failed: \(reason)"
            case .malformed(let reason): "The server sent a reply Dbee couldn't read: \(reason)"
            }
        }
    }

    static let connectTimeout = TimeAmount.seconds(15)
    /// How long TLS Preferred waits for a TLS handshake before trying plain TCP. A server without TLS may
    /// not answer the ClientHello at all (MongoDB reads it as the start of a very large message).
    static let preferredHandshakeTimeout = TimeAmount.seconds(3)

    let endpoint: Endpoint
    let usesTLS: Bool
    private let channel: any Channel
    private let inbound: InboundBytes
    /// Received bytes not yet consumed by a parser.
    private var buffer: ByteBuffer

    private init(endpoint: Endpoint, channel: any Channel, inbound: InboundBytes, usesTLS: Bool) {
        self.endpoint = endpoint
        self.channel = channel
        self.inbound = inbound
        self.usesTLS = usesTLS
        buffer = channel.allocator.buffer(capacity: 0)
    }

    deinit {
        channel.close(promise: nil)
    }

    var isOpen: Bool { channel.isActive }

    // MARK: Opening

    /// Dials the endpoint and runs `handshake` (hello, authentication) on the new connection. With TLS set
    /// to Preferred, a TLS attempt that fails at the transport level is retried once without TLS.
    static func open<T>(_ endpoint: Endpoint,
                        handshake: (WireConnection) async throws -> T) async throws -> (WireConnection, T) {
        let context: NIOSSLContext?
        let serverName: String?
        do {
            (context, serverName) = try tlsContext(for: endpoint)
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError("Couldn't set up TLS.", detail: String(describing: error))
        }

        func attempt(_ context: NIOSSLContext?) async throws -> (WireConnection, T) {
            let connection = try await dial(endpoint, tls: context, serverName: serverName)
            do {
                if context != nil {
                    let wait = endpoint.tls == .preferred ? preferredHandshakeTimeout : connectTimeout
                    try await connection.awaitTLSHandshake(deadline: .now() + wait)
                }
                return (connection, try await handshake(connection))
            } catch {
                connection.close()
                throw error
            }
        }

        do {
            return try await attempt(context)
        } catch let failure as Failure where endpoint.tls == .preferred && context != nil && failure != .cancelled {
            return try await attempt(nil)
        } catch let failure as Failure {
            throw describeOpenFailure(failure, endpoint: endpoint)
        }
    }

    private static func describeOpenFailure(_ failure: Failure, endpoint: Endpoint) -> any Error {
        switch failure {
        case .tls(let reason) where endpoint.tls != .disabled:
            return DatabaseError("Couldn't open a TLS connection to \(endpoint.displayName).",
                                 detail: "\(reason). If the server doesn't use TLS, set TLS to Off, preferably through an SSH tunnel.")
        case .closed, .malformed:
            return DatabaseError("\(endpoint.displayName) didn't answer like a \(endpoint.engine) server.",
                                 detail: failure.errorDescription.map { $0 + " Check the port number and the TLS setting." })
        default:
            return failure
        }
    }

    private static func dial(_ endpoint: Endpoint, tls: NIOSSLContext?, serverName: String?) async throws -> WireConnection {
        let channel: any Channel
        do {
            if let openChannel = endpoint.transport.openChannel {
                channel = try await openChannel()
            } else {
                endpoint.transport.willDial()
                let host = endpoint.dialHost.isEmpty ? "127.0.0.1" : endpoint.dialHost
                channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(connectTimeout)
                    .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                    .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
                    .connect(host: host, port: endpoint.dialPort).get()
            }
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError("Couldn't connect to \(endpoint.displayName).", detail: reason(for: error))
        }

        let inbound = InboundBytes(expectsTLS: tls != nil)
        do {
            try await channel.eventLoop.submit {
                let pipeline = channel.pipeline.syncOperations
                if let tls {
                    try pipeline.addHandlerFacingBytes(try NIOSSLClientHandler(context: tls, serverHostname: serverName))
                }
                try pipeline.addHandler(inbound)
            }.get()
        } catch {
            channel.close(promise: nil)
            throw DatabaseError("Couldn't prepare the connection.", detail: String(describing: error))
        }
        return WireConnection(endpoint: endpoint, channel: channel, inbound: inbound, usesTLS: tls != nil)
    }

    /// The TLS context for the endpoint's mode (nil when TLS is off), plus the SNI / verification name.
    private static func tlsContext(for endpoint: Endpoint) throws -> (NIOSSLContext?, String?) {
        let host = endpoint.logicalHost
        // SNI can't carry IP literals; NIOSSL then verifies the certificate against the dialled address.
        let serverName = host.isEmpty || (try? SocketAddress(ipAddress: host, port: 0)) != nil ? nil : host

        func context(_ verification: CertificateVerification) throws -> NIOSSLContext {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = verification
            return try NIOSSLContext(configuration: configuration)
        }

        switch endpoint.tls {
        case .disabled:
            return (nil, nil)
        case .preferred, .required:
            return (try context(.none), serverName)
        case .verifyFull:
            if serverName == nil, !host.isEmpty, host != endpoint.dialHost {
                throw PostgresDriver.verifyNeedsHostName
            }
            return (try context(.fullVerification), serverName)
        }
    }

    /// Waits until the TLS handshake is done, failing with `.timedOut` (and closing) at `deadline`.
    private func awaitTLSHandshake(deadline: NIODeadline) async throws {
        let inbound = inbound
        try await channel.eventLoop.flatSubmit { inbound.handshake(deadline: deadline) }.get()
    }

    // MARK: Reading and writing

    /// Queues `bytes` without waiting for them to be sent: under TLS a write only completes once the handshake
    /// does, which a server that doesn't speak TLS may never finish. A failed write closes the connection, so
    /// the read that follows fails (or times out) instead.
    func write(_ bytes: ByteBuffer) async throws {
        guard channel.isActive else { throw Failure.closed }
        let channel = channel
        channel.writeAndFlush(bytes).whenFailure { _ in channel.close(promise: nil) }
    }

    func write(_ bytes: [UInt8]) async throws {
        try await write(channel.allocator.buffer(bytes: bytes))
    }

    /// Reads until `parse` returns a value. `parse` gets the unconsumed bytes and moves the reader index past
    /// what it used; it returns nil when it needs more bytes. Without a deadline it waits as long as the
    /// server takes (a slow query), until `abort()` or the connection closes.
    func read<T>(deadline: NIODeadline? = nil, _ parse: (inout ByteBuffer) throws -> T?) async throws -> T {
        while true {
            if buffer.readableBytes > 0 {
                var candidate = buffer
                if let value = try parse(&candidate) {
                    buffer = candidate
                    if buffer.readerIndex > 64 * 1024 { buffer.discardReadBytes() }
                    return value
                }
            }
            let inbound = inbound
            var more = try await channel.eventLoop.flatSubmit { inbound.take(deadline: deadline) }.get()
            buffer.writeBuffer(&more)
        }
    }

    /// Fails a pending read with `.cancelled` and closes the connection. The statement it was waiting for
    /// may still finish on the server; the driver opens a new connection for the next one.
    func abort() {
        let inbound = inbound
        channel.eventLoop.execute { inbound.fail(.cancelled) }
        channel.close(promise: nil)
    }

    func close() {
        channel.close(promise: nil)
    }

    func closeAndWait() async {
        try? await channel.close()
    }

    static func reason(for error: any Error) -> String {
        if let failure = error as? Failure { return failure.errorDescription ?? "\(failure)" }
        if let error = error as? IOError { return String(cString: strerror(error.errnoCode)) }
        if let error = error as? ChannelError, case .connectTimeout = error { return "The connection timed out." }
        if let error = error as? NIOConnectionError {
            if let dns = error.dnsAAAAError ?? error.dnsAError { return "Couldn't find the server (\(dns))." }
            if let first = error.connectionErrors.first { return reason(for: first.error) }
        }
        return String(describing: error)
    }
}

/// Collects received bytes until the driver asks for them. Only touched on the channel's event loop.
private final class InboundBytes: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var context: ChannelHandlerContext?
    private var received: ByteBuffer?
    private var handshakeDone: Bool
    private var handshakeWaiter: EventLoopPromise<Void>?
    private var waiter: EventLoopPromise<ByteBuffer>?
    private var timeout: Scheduled<Void>?
    private var failure: WireConnection.Failure?

    init(expectsTLS: Bool) {
        handshakeDone = !expectsTLS
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            handshakeDone = true
            timeout?.cancel()
            timeout = nil
            handshakeWaiter?.succeed(())
            handshakeWaiter = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func handshake(deadline: NIODeadline) -> EventLoopFuture<Void> {
        guard let eventLoop = context?.eventLoop else {
            return MultiThreadedEventLoopGroup.singleton.next().makeFailedFuture(failure ?? .closed)
        }
        if handshakeDone { return eventLoop.makeSucceededVoidFuture() }
        if let failure { return eventLoop.makeFailedFuture(failure) }
        let promise = eventLoop.makePromise(of: Void.self)
        handshakeWaiter = promise
        timeout = eventLoop.scheduleTask(deadline: deadline) { [weak self] in
            self?.fail(.timedOut)
            self?.context?.close(promise: nil)
        }
        return promise.futureResult
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(.closed)
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        if let waiter {
            self.waiter = nil
            timeout?.cancel()
            timeout = nil
            waiter.succeed(bytes)
        } else if received == nil {
            received = bytes
        } else {
            received!.writeBuffer(&bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is NIOSSLError || error is NIOSSLExtraError || error is BoringSSLError {
            fail(.tls(String(describing: error)))
        } else {
            fail(.io(WireConnection.reason(for: error)))
        }
        context.close(promise: nil)
    }

    /// Bytes received so far, or the next ones to arrive. Buffered bytes are still handed out after the
    /// connection failed, so a final reply that arrived just before the server closed can be read.
    func take(deadline: NIODeadline?) -> EventLoopFuture<ByteBuffer> {
        guard let eventLoop = context?.eventLoop else {
            return MultiThreadedEventLoopGroup.singleton.next().makeFailedFuture(failure ?? .closed)
        }
        if let received {
            self.received = nil
            return eventLoop.makeSucceededFuture(received)
        }
        if let failure { return eventLoop.makeFailedFuture(failure) }
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        waiter = promise
        if let deadline {
            timeout = eventLoop.scheduleTask(deadline: deadline) { [weak self] in
                self?.fail(.timedOut)
                self?.context?.close(promise: nil)
            }
        }
        return promise.futureResult
    }

    func fail(_ failure: WireConnection.Failure) {
        if self.failure == nil { self.failure = failure }
        timeout?.cancel()
        timeout = nil
        if let waiter {
            self.waiter = nil
            waiter.fail(self.failure ?? failure)
        }
        if let handshakeWaiter {
            self.handshakeWaiter = nil
            handshakeWaiter.fail(self.failure ?? failure)
        }
    }
}
