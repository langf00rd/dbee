import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Enforces TLS for MySQL before MySQLNIO sends anything.
///
/// MySQLNIO only starts TLS when the server's greeting advertises CLIENT_SSL; otherwise it quietly signs in
/// over plain TCP. An attacker on the path could clear that flag and collect the login (and with
/// caching_sha2_password, get the password itself by answering with their own RSA key). MySQLNIO can't be told
/// to refuse, so for TLS Required and Verify Certificate the connection runs through this in-process relay:
/// it reads the greeting itself and hangs up unless it offers TLS. Bytes are otherwise passed through
/// untouched, so the TLS session is still between MySQLNIO and the server.
///
/// MySQLNIO reaches the relay over a Unix socket in a private (0700) directory, removed once connected.
final class MySQLTLSRelay: Sendable {
    /// Where MySQLNIO should connect.
    let address: SocketAddress

    private let upstream: any Channel
    private let listener: any Channel
    private let directory: String

    private init(address: SocketAddress, upstream: any Channel, listener: any Channel, directory: String) {
        self.address = address
        self.upstream = upstream
        self.listener = listener
        self.directory = directory
    }

    /// Connects to the server and checks its greeting. Throws before anything is sent if TLS isn't offered.
    static func open(to server: SocketAddress, deadline: NIODeadline) async throws -> MySQLTLSRelay {
        let greeting = MySQLGreetingReader()
        let upstream = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(max(deadline - .now(), .milliseconds(1)))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(greeting) }
            }
            .connect(to: server).get()
        let timer = upstream.eventLoop.scheduleTask(deadline: deadline) {
            greeting.fail(HandshakeDeadline())
            upstream.close(promise: nil)
        }
        let bytes: ByteBuffer
        do {
            bytes = try await greeting.result.get()
            timer.cancel()
        } catch {
            timer.cancel()
            upstream.close(promise: nil)
            throw error is HandshakeDeadline ? ChannelError.connectTimeout(deadline - .now()) : error
        }
        guard Self.allowsGreeting(bytes) else {
            upstream.close(promise: nil)
            throw DatabaseError("The server doesn't support TLS.",
                                detail: "Set TLS to Off to connect without encryption, preferably through an SSH tunnel.")
        }

        // A private directory keeps other local users from connecting to the socket first.
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("dbee-XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else {
            upstream.close(promise: nil)
            throw DatabaseError("Couldn't prepare the connection.", detail: String(cString: strerror(errno)))
        }
        let directory = String(cString: created)
        let path = (directory as NSString).appendingPathComponent("s")
        let accepted = NIOLockedValueBox(false)
        do {
            let listener = try await ServerBootstrap(group: upstream.eventLoop, childGroup: upstream.eventLoop)
                .childChannelInitializer { child in
                    // Only the first connection is MySQLNIO's.
                    let isFirst = accepted.withLockedValue { wasAccepted in
                        defer { wasAccepted = true }
                        return !wasAccepted
                    }
                    guard isFirst else { return child.close() }
                    return child.eventLoop.makeCompletedFuture {
                        try Self.glue(child, to: upstream, greeting: bytes)
                    }
                }
                .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true).get()
            let address = try SocketAddress(unixDomainSocketPath: path)
            return MySQLTLSRelay(address: address, upstream: upstream, listener: listener, directory: directory)
        } catch {
            upstream.close(promise: nil)
            Self.removeSocket(in: directory)
            throw error
        }
    }

    /// Stops accepting connections and removes the socket. Call once MySQLNIO has connected (or given up).
    func finishListening() {
        listener.close(promise: nil)
        Self.removeSocket(in: directory)
    }

    /// Closes everything; for when the MySQLNIO side failed.
    func close() {
        finishListening()
        upstream.close(promise: nil)
    }

    /// True for a HandshakeV10 that advertises CLIENT_SSL, and for an error packet (e.g. "Too many
    /// connections"), which is safe to pass on and gives MySQLNIO's readable error.
    static func allowsGreeting(_ packet: ByteBuffer) -> Bool {
        var buffer = packet
        buffer.moveReaderIndex(forwardBy: 4) // length and sequence id
        guard let first = buffer.readInteger(as: UInt8.self) else { return false }
        if first == 0xFF { return true }
        guard first == 10, // protocol version
              let terminator = buffer.readableBytesView.firstIndex(of: 0) // server version
        else { return false }
        buffer.moveReaderIndex(to: terminator + 1)
        // connection id (4), auth data part 1 (8), filler (1), then the lower capability flags.
        guard buffer.readableBytes >= 15 else { return false }
        buffer.moveReaderIndex(forwardBy: 13)
        let capabilities = buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0
        return capabilities & 0x0800 != 0 // CLIENT_SSL
    }

    private static func glue(_ child: any Channel, to upstream: any Channel, greeting: ByteBuffer) throws {
        let (local, remote) = MySQLRelayGlue.pair(greeting: greeting)
        try child.pipeline.syncOperations.addHandler(local)
        let pipeline = upstream.pipeline.syncOperations
        try pipeline.addHandler(remote)
        if let reader = try? pipeline.handler(type: MySQLGreetingReader.self) {
            pipeline.removeHandler(reader, promise: nil)
        }
    }

    private static func removeSocket(in directory: String) {
        unlink((directory as NSString).appendingPathComponent("s"))
        rmdir(directory)
    }

    private struct HandshakeDeadline: Error {}
}

/// Collects the server's first packet, then holds any later bytes back (the server sends none until it's answered).
private final class MySQLGreetingReader: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise = NIOLockedValueBox<EventLoopPromise<ByteBuffer>?>(nil)
    private var buffer = ByteBuffer()
    private var done = false

    var result: EventLoopFuture<ByteBuffer> {
        promise.withLockedValue { $0! }.futureResult
    }

    func handlerAdded(context: ChannelHandlerContext) {
        promise.withLockedValue { $0 = context.eventLoop.makePromise() }
    }

    func fail(_ error: Error) {
        promise.withLockedValue { $0 }?.fail(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        buffer.writeBuffer(&input)
        guard !done, buffer.readableBytes >= 4 else { return }
        let length = Int(buffer.getInteger(at: buffer.readerIndex, endianness: .little, as: UInt32.self)! & 0xFF_FFFF)
        guard buffer.readableBytes >= 4 + length else { return }
        done = true
        promise.withLockedValue { $0 }?.succeed(buffer)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(ChannelError.eof)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(ChannelError.ioOnClosedChannel)
    }
}

/// One half of a byte pipe between two channels on the same event loop, with backpressure.
private final class MySQLRelayGlue: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: MySQLRelayGlue?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// Sent once this side's channel is active (the greeting, already read from the server).
    private var initialBytes: ByteBuffer?

    /// The first handler goes on MySQLNIO's side and starts by passing on `greeting`.
    static func pair(greeting: ByteBuffer) -> (MySQLRelayGlue, MySQLRelayGlue) {
        let first = MySQLRelayGlue()
        first.initialBytes = greeting
        let second = MySQLRelayGlue()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private var partnerWritable: Bool { partner?.context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelActive(context: ChannelHandlerContext) {
        if let bytes = initialBytes {
            initialBytes = nil
            context.writeAndFlush(wrapOutboundOut(bytes), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.becameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    private func becameWritable() {
        if pendingRead, let context {
            pendingRead = false
            context.read()
        }
    }
}
