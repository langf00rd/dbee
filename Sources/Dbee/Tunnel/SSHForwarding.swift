import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Converts between SSH channel data and plain bytes on a direct-tcpip child channel.
/// Extended data (stderr) is not used by direct-tcpip and is dropped.
final class SSHChannelByteCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let bytes) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }
}

/// Joins two channels on the same event loop so bytes read on one are written to the other.
///
/// Backpressure: a side only reads while its partner is active and writable. Half-closure is forwarded
/// (EOF on one side shuts down output on the other); full closure, an error or a failed write on either side
/// closes both, so a forwarded byte stream is either delivered whole or torn down, never left with a gap.
/// Modelled on the GlueHandler from the swift-nio-ssh port forwarding example.
final class TunnelGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: TunnelGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// Completes once the most recent forwarded write has left this channel. NIO fails writes that are still
    /// queued when a socket is shut down, so half-close and close wait for it to avoid truncating data.
    private var lastWrite: EventLoopFuture<Void>?
    /// Told about writes that failed for a reason other than the channel already closing.
    private let onWriteFailure: (Error) -> Void

    private init(onWriteFailure: @escaping (Error) -> Void) {
        self.onWriteFailure = onWriteFailure
    }

    static func matchedPair(onWriteFailure: @escaping (Error) -> Void = { _ in }) -> (TunnelGlueHandler, TunnelGlueHandler) {
        let first = TunnelGlueHandler(onWriteFailure: onWriteFailure)
        let second = TunnelGlueHandler(onWriteFailure: onWriteFailure)
        first.partner = second
        second.partner = first
        return (first, second)
    }

    // MARK: Calls made by the partner

    private func partnerWrite(_ buffer: ByteBuffer) {
        guard let context else { return }
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.write(wrapOutboundOut(buffer), promise: promise)
        lastWrite = promise.futureResult
        // NIOSSH can fail a child-channel write without closing the channel (for example during a
        // server-initiated re-key). Dropping those bytes would leave a hole in the stream, so close both sides.
        promise.futureResult.whenFailure { [weak self] error in
            guard let self, let context = self.context, !Self.isClosing(error) else { return }
            self.onWriteFailure(error)
            self.partner?.partnerCloseNow()
            context.close(promise: nil)
        }
    }

    /// Errors a write gets when the channel is already being closed, which the close path handles.
    private static func isClosing(_ error: Error) -> Bool {
        guard let error = error as? ChannelError else { return false }
        switch error {
        case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .eof: return true
        default: return false
        }
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        afterPendingWrites { $0.close(mode: .output, promise: nil) }
    }

    private func partnerCloseFull() {
        afterPendingWrites { $0.close(promise: nil) }
    }

    private func partnerCloseNow() {
        context?.close(promise: nil)
    }

    private func afterPendingWrites(_ body: @escaping @Sendable (Channel) -> Void) {
        guard let context else { return }
        let channel = context.channel
        context.flush()
        if let lastWrite {
            lastWrite.whenComplete { _ in body(channel) }
        } else {
            body(channel)
        }
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var isWritableForPartner: Bool {
        guard let channel = context?.channel else { return false }
        return channel.isActive && channel.isWritable
    }

    // MARK: ChannelDuplexHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive && context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseNow()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.isWritableForPartner {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// Tracks the local connections accepted by a tunnel's listener so they can be closed together.
final class TunnelConnectionRegistry: Sendable {
    private struct State {
        var isClosed = false
        var channels: [ObjectIdentifier: Channel] = [:]
        var lastFailure: String?
        /// When true, local connections need an allowance (an expiry time) from `allowNextLocalConnection`.
        var restrictsLocalConnections = false
        var allowances: [NIODeadline] = []
    }

    /// How long an allowance from `allowNextLocalConnection` stays usable.
    static let allowanceLifetime = TimeAmount.seconds(10)

    private let state = NIOLockedValueBox(State())

    /// Returns false (and the caller must close the channel) once the registry is closed.
    func register(_ channel: Channel) -> Bool {
        let added = state.withLockedValue { state -> Bool in
            guard !state.isClosed else { return false }
            state.channels[ObjectIdentifier(channel)] = channel
            return true
        }
        if added {
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.state.withLockedValue { _ = $0.channels.removeValue(forKey: ObjectIdentifier(channel)) }
            }
        }
        return added
    }

    /// Marks the registry closed and returns the channels that were still open.
    func closeAll() -> [Channel] {
        state.withLockedValue { state in
            state.isClosed = true
            defer { state.channels.removeAll() }
            return Array(state.channels.values)
        }
    }

    func restrictLocalConnections() {
        state.withLockedValue { $0.restrictsLocalConnections = true }
    }

    func allowNextLocalConnection() {
        state.withLockedValue { state in
            state.restrictsLocalConnections = true
            state.allowances.append(.now() + Self.allowanceLifetime)
        }
    }

    /// Whether a connection accepted by the local listener may be forwarded. Uses up one allowance when
    /// local connections are restricted.
    func admitLocalConnection() -> Bool {
        state.withLockedValue { state in
            guard state.restrictsLocalConnections else { return true }
            let now = NIODeadline.now()
            state.allowances.removeAll { $0 < now }
            guard !state.allowances.isEmpty else { return false }
            state.allowances.removeFirst()
            return true
        }
    }

    var openCount: Int {
        state.withLockedValue { $0.channels.count }
    }

    var lastFailure: String? {
        state.withLockedValue { $0.lastFailure }
    }

    func recordFailure(_ message: String) {
        state.withLockedValue { $0.lastFailure = message }
    }
}

struct SSHUnexpectedChannelType: Error {}
