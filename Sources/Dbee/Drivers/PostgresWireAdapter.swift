import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

// PostgresNIO always asks the server for binary results and always runs a statement to completion.
// A database client wants the opposite: values exactly as Postgres prints them (psql's text output, for
// every type including user-defined ones) and a server-side row limit. `PostgresWireAdapter` sits in the
// channel pipeline between TLS and PostgresNIO and adjusts the few protocol messages involved.

/// Per-statement state shared between `PostgresDriver` and its `PostgresWireAdapter` (which runs on the event loop).
final class PostgresWireProbe: Sendable {
    struct Outcome: Sendable {
        /// Tag of the CommandComplete message ("INSERT 0 5", "UPDATE 3", "CREATE TABLE"…).
        var commandTag: String?
        /// The server stopped at the row limit (PortalSuspended).
        var portalSuspended = false
        /// Lines of `COPY … TO STDOUT` output, which PostgresNIO can't handle itself.
        var copyLines: [String]?
        var copyTruncated = false
        /// `COPY … (FORMAT binary)`: the data isn't text, so it was discarded instead of decoded.
        var copyBinary = false
        /// A frontend message didn't have the layout the adapter expects (e.g. after a PostgresNIO update).
        var framingProblem = false
    }

    private struct State: Sendable {
        var rowLimit: Int32 = 0
        var copyLineLimit = Int.max
        var outcome = Outcome()
    }

    private let state = NIOLockedValueBox(State())
    /// Transaction status from the last ReadyForQuery: "I" idle, "T" in a transaction block, "E" failed one.
    private let transactionStatus = NIOLockedValueBox(UInt8(ascii: "I"))

    /// Starts a statement. `rowLimit` is sent in the Execute message (0 means no limit);
    /// `copyLineLimit` caps the `COPY … TO STDOUT` lines kept.
    func begin(rowLimit: Int32, copyLineLimit: Int = .max) {
        state.withLockedValue { $0 = State(rowLimit: rowLimit, copyLineLimit: copyLineLimit) }
    }

    /// Ends the statement and returns what the adapter observed.
    func finish() -> Outcome {
        state.withLockedValue { state in
            let outcome = state.outcome
            state = State()
            return outcome
        }
    }

    var rowLimit: Int32 { state.withLockedValue { $0.rowLimit } }

    func noteCommandComplete(_ tag: String) { state.withLockedValue { $0.outcome.commandTag = tag } }
    func notePortalSuspended() { state.withLockedValue { $0.outcome.portalSuspended = true } }
    func noteFramingProblem() { state.withLockedValue { $0.outcome.framingProblem = true } }
    func noteReadyForQuery(status: UInt8) { transactionStatus.withLockedValue { $0 = status } }

    /// True inside an explicit transaction block (BEGIN … COMMIT), as of the last completed statement.
    var isInTransactionBlock: Bool { transactionStatus.withLockedValue { $0 != UInt8(ascii: "I") } }

    func beginCopyOut(binary: Bool) {
        state.withLockedValue { state in
            state.outcome.copyLines = []
            state.outcome.copyBinary = binary
        }
    }

    func appendCopyData(_ buffer: ByteBuffer) {
        state.withLockedValue { state in
            // Binary COPY data isn't text; decoding it would only produce garbage.
            guard !state.outcome.copyBinary else { return }
            if state.outcome.copyLines?.count ?? 0 >= state.copyLineLimit {
                state.outcome.copyTruncated = true
                return
            }
            var line = String(buffer: buffer)
            if line.hasSuffix("\n") { line.removeLast() }
            state.outcome.copyLines?.append(line)
        }
    }
}

/// Rewrites frontend (client → server) messages written by PostgresNIO.
/// - Bind: requests text-format result columns instead of binary.
/// - Execute: applies the statement's row limit so the server stops early.
/// PostgresNIO writes whole messages per buffer; the walker still tracks message boundaries across writes.
struct PostgresFrontendRewriter {
    private var header: [UInt8] = []
    private var remaining = 0

    mutating func process(_ buffer: inout ByteBuffer, probe: PostgresWireProbe) {
        var index = buffer.readerIndex
        let end = buffer.writerIndex
        while index < end {
            if remaining > 0 {
                let n = min(remaining, end - index)
                remaining -= n
                index += n
                continue
            }
            header.append(buffer.getInteger(at: index, as: UInt8.self)!)
            index += 1
            guard header.count == 5 else { continue }
            let type = header[0]
            let bodyLength = max(PostgresWireFormat.length(header) - 4, 0)
            header.removeAll(keepingCapacity: true)
            let bodyEnd = index + bodyLength
            switch type {
            case UInt8(ascii: "B"):
                // PostgresNIO ends every Bind with "1 result format code: binary" (0x0001 0x0001).
                if bodyEnd <= end, bodyLength >= 4,
                   buffer.getInteger(at: bodyEnd - 4, as: UInt16.self) == 1,
                   buffer.getInteger(at: bodyEnd - 2, as: UInt16.self) == 1 {
                    buffer.setInteger(UInt16(0), at: bodyEnd - 2)
                } else {
                    probe.noteFramingProblem()
                }
            case UInt8(ascii: "E"):
                // Execute: portal name, then Int32 max rows (PostgresNIO sends 0 = all).
                let limit = probe.rowLimit
                if limit > 0, bodyEnd <= end, bodyLength >= 5 {
                    buffer.setInteger(limit, at: bodyEnd - 4)
                }
            default:
                break
            }
            remaining = bodyLength
        }
    }
}

/// Walks backend (server → client) messages across arbitrary chunk boundaries. Most bytes pass through
/// untouched; a few message types are intercepted:
/// - CommandComplete: the tag is recorded (PostgresNIO's async API doesn't expose it), then forwarded.
/// - ReadyForQuery: the transaction status is recorded, then forwarded.
/// - PortalSuspended (row limit reached): replaced by a CommandComplete, which PostgresNIO understands.
/// - COPY TO STDOUT (CopyOutResponse / CopyData / CopyDone): captured as text lines and hidden from PostgresNIO,
///   which would otherwise drop the connection.
/// - COPY FROM STDIN (CopyInResponse): answered with CopyFail + Sync so the server reports an error instead.
struct PostgresBackendRewriter {
    enum Output {
        /// Bytes to pass on to PostgresNIO.
        case forward(ByteBuffer)
        /// Bytes to send to the server.
        case reply(ByteBuffer)
    }

    private var header: [UInt8] = []
    private var passRemaining = 0
    private var interceptedType: UInt8?
    private var interceptRemaining = 0
    private var body = ByteBuffer()
    private var copyOutActive = false

    private static func intercepts(_ type: UInt8) -> Bool {
        switch type {
        case UInt8(ascii: "C"), UInt8(ascii: "Z"), UInt8(ascii: "s"), UInt8(ascii: "H"), UInt8(ascii: "d"), UInt8(ascii: "c"), UInt8(ascii: "G"):
            true
        default:
            false
        }
    }

    mutating func process(_ input: ByteBuffer, probe: PostgresWireProbe) -> [Output] {
        var outputs: [Output] = []
        var index = input.readerIndex
        let end = input.writerIndex
        var forwardFrom = index
        // Where the header being parsed started in this chunk (the chunk start if it began in an earlier one).
        var headerStart = index
        // Header bytes carried over from an earlier chunk; they haven't been forwarded yet.
        var carried = header.count

        func forward(_ from: Int, _ to: Int) {
            if to > from, let slice = input.getSlice(at: from, length: to - from) {
                outputs.append(.forward(slice))
            }
        }

        while index < end {
            if passRemaining > 0 {
                let n = min(passRemaining, end - index)
                passRemaining -= n
                index += n
                continue
            }
            if interceptedType != nil, interceptRemaining > 0 {
                let n = min(interceptRemaining, end - index)
                var slice = input.getSlice(at: index, length: n)!
                body.writeBuffer(&slice)
                interceptRemaining -= n
                index += n
                forwardFrom = index
                if interceptRemaining == 0 { finishIntercepted(into: &outputs, probe: probe) }
                continue
            }
            let type: UInt8
            let bodyLength: Int
            if header.isEmpty, end - index >= 5 {
                // Fast path: the whole header is in this chunk.
                headerStart = index
                type = input.getInteger(at: index, as: UInt8.self)!
                bodyLength = max(Int(input.getInteger(at: index + 1, as: Int32.self)!) - 4, 0)
                index += 5
            } else {
                if header.isEmpty { headerStart = index }
                header.append(input.getInteger(at: index, as: UInt8.self)!)
                index += 1
                guard header.count == 5 else { continue }
                type = header[0]
                bodyLength = max(PostgresWireFormat.length(header) - 4, 0)
            }
            if Self.intercepts(type) {
                forward(forwardFrom, headerStart)
                forwardFrom = index
                interceptedType = type
                interceptRemaining = bodyLength
                body.clear()
                header.removeAll(keepingCapacity: true)
                if bodyLength == 0 { finishIntercepted(into: &outputs, probe: probe) }
            } else {
                if carried > 0 {
                    outputs.append(.forward(ByteBuffer(bytes: header.prefix(carried))))
                }
                header.removeAll(keepingCapacity: true)
                passRemaining = bodyLength
            }
            carried = 0
        }
        forward(forwardFrom, header.isEmpty ? end : headerStart)
        return outputs
    }

    private mutating func finishIntercepted(into outputs: inout [Output], probe: PostgresWireProbe) {
        guard let type = interceptedType else { return }
        interceptedType = nil
        switch type {
        case UInt8(ascii: "C"):
            probe.noteCommandComplete(body.getNullTerminatedString(at: body.readerIndex) ?? "")
            outputs.append(.forward(PostgresWireFormat.message(type, body: body)))
        case UInt8(ascii: "Z"):
            if let status = body.getInteger(at: body.readerIndex, as: UInt8.self) { probe.noteReadyForQuery(status: status) }
            outputs.append(.forward(PostgresWireFormat.message(type, body: body)))
        case UInt8(ascii: "s"):
            probe.notePortalSuspended()
            outputs.append(.forward(PostgresWireFormat.commandComplete("SELECT")))
        case UInt8(ascii: "H"):
            copyOutActive = true
            // Overall format: 0 = text, 1 = binary.
            probe.beginCopyOut(binary: body.getInteger(at: body.readerIndex, as: UInt8.self) == 1)
        case UInt8(ascii: "d"):
            if copyOutActive { probe.appendCopyData(body) }
        case UInt8(ascii: "c"):
            copyOutActive = false
        case UInt8(ascii: "G"):
            var reply = PostgresWireFormat.message(UInt8(ascii: "f"), cString: "COPY FROM STDIN isn't supported in Dbee.")
            var sync = PostgresWireFormat.message(UInt8(ascii: "S"), body: ByteBuffer())
            reply.writeBuffer(&sync)
            outputs.append(.reply(reply))
        default:
            outputs.append(.forward(PostgresWireFormat.message(type, body: body)))
        }
        body.clear()
    }
}

enum PostgresWireFormat {
    /// Big-endian Int32 length from a 5-byte message header (type byte + length).
    static func length(_ header: [UInt8]) -> Int {
        Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
    }

    static func message(_ type: UInt8, body: ByteBuffer) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(5 + body.readableBytes)
        buffer.writeInteger(type)
        buffer.writeInteger(Int32(4 + body.readableBytes))
        var body = body
        buffer.writeBuffer(&body)
        return buffer
    }

    static func message(_ type: UInt8, cString: String) -> ByteBuffer {
        var body = ByteBuffer()
        body.writeString(cString)
        body.writeInteger(UInt8(0))
        return message(type, body: body)
    }

    static func commandComplete(_ tag: String) -> ByteBuffer {
        message(UInt8(ascii: "C"), cString: tag)
    }
}

/// Installs the rewriters on a connection's channel, between TLS (if any) and PostgresNIO.
final class PostgresWireAdapter: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let probe: PostgresWireProbe
    private var frontend = PostgresFrontendRewriter()
    private var backend = PostgresBackendRewriter()

    init(probe: PostgresWireProbe) {
        self.probe = probe
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        for output in backend.process(unwrapInboundIn(data), probe: probe) {
            switch output {
            case .forward(let buffer):
                context.fireChannelRead(wrapInboundOut(buffer))
            case .reply(let buffer):
                context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
            }
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        frontend.process(&buffer, probe: probe)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }
}

/// The BackendKeyData (process id and secret) the server sends during startup. A CancelRequest carrying it is
/// routed by poolers such as PgBouncer to whichever server backend is running the client's statement.
struct PostgresBackendKey: Sendable, Equatable {
    var processID: Int32
    var secret: Int32
}

/// Watches the startup messages for BackendKeyData, which PostgresNIO doesn't expose, and removes itself at
/// the first ReadyForQuery. Installed first in the pipeline before PostgresNIO starts; when TLS is
/// negotiated it moves itself behind the TLS handler so it keeps reading plaintext.
final class PostgresBackendKeyCapture: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let key: NIOLockedValueBox<PostgresBackendKey?>
    /// The next byte is the server's one-byte answer to SSLRequest ("S" or "N").
    private var awaitingSSLAnswer: Bool
    private var pending = ByteBuffer()
    private var finished = false

    init(key: NIOLockedValueBox<PostgresBackendKey?>, awaitingSSLAnswer: Bool) {
        self.key = key
        self.awaitingSSLAnswer = awaitingSSLAnswer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        guard !finished else {
            context.fireChannelRead(data)
            return
        }
        if awaitingSSLAnswer, let answer = input.getInteger(at: input.readerIndex, as: UInt8.self) {
            awaitingSSLAnswer = false
            if answer == UInt8(ascii: "S") {
                context.fireChannelRead(data)
                // PostgresNIO adds the TLS handler while handling "S"; everything after it is encrypted.
                finished = true
                let pipeline = context.pipeline.syncOperations
                if let tls = try? pipeline.handler(type: NIOSSLClientHandler.self) {
                    try? pipeline.addHandler(PostgresBackendKeyCapture(key: key, awaitingSSLAnswer: false), position: .after(tls))
                }
                pipeline.removeHandler(context: context, promise: nil)
                return
            }
            if answer == UInt8(ascii: "N") {
                input.moveReaderIndex(forwardBy: 1)
            }
        }
        pending.writeBuffer(&input)
        context.fireChannelRead(data)
        parse(context: context)
    }

    private func parse(context: ChannelHandlerContext) {
        while pending.readableBytes >= 5,
              let type = pending.getInteger(at: pending.readerIndex, as: UInt8.self),
              let length = pending.getInteger(at: pending.readerIndex + 1, as: Int32.self) {
            let bodyLength = max(Int(length) - 4, 0)
            guard pending.readableBytes >= 5 + bodyLength else { return }
            if type == UInt8(ascii: "K"), bodyLength >= 8,
               let processID = pending.getInteger(at: pending.readerIndex + 5, as: Int32.self),
               let secret = pending.getInteger(at: pending.readerIndex + 9, as: Int32.self) {
                key.withLockedValue { $0 = PostgresBackendKey(processID: processID, secret: secret) }
            }
            pending.moveReaderIndex(forwardBy: 5 + bodyLength)
            if type == UInt8(ascii: "Z") || type == UInt8(ascii: "E") {
                finished = true
                pending = ByteBuffer()
                context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
                return
            }
        }
        pending.discardReadBytes()
    }
}
