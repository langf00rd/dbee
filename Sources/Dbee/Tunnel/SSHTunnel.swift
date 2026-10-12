import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// Asks the user whether to trust an SSH host key. Implemented by the UI layer.
protocol HostKeyVerifier: Sendable {
    /// - Parameters:
    ///   - fingerprint: "SHA256:<base64>" in OpenSSH format.
    ///   - knownHostsStatus: result of the read-only ~/.ssh/known_hosts lookup.
    /// - Returns: true to continue connecting.
    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool

    /// Asked instead when known_hosts lists the host only with other key types (`knownKeyTypes`, e.g. ["ECDSA"]).
    /// OpenSSH treats this as suspicious, so the default implementation shows the changed-key prompt.
    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownKeyTypes: [String]) async -> Bool
}

extension HostKeyVerifier {
    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownKeyTypes: [String]) async -> Bool {
        await confirmHostKey(host: host, port: port, keyType: keyType, fingerprint: fingerprint, knownHostsStatus: .mismatch)
    }
}

enum KnownHostsStatus: Sendable, Equatable {
    /// Key matches an entry in ~/.ssh/known_hosts. The verifier is NOT consulted in this case.
    case trusted
    /// Host not present in known_hosts.
    case unknown
    /// Host is present with a DIFFERENT key. Possible man-in-the-middle. `SSHTunnel.open` refuses this
    /// itself and never asks the verifier; the case stays for verifiers that wrap others.
    case mismatch
}

/// A local TCP listener on 127.0.0.1:<random port> whose connections are forwarded through an SSH
/// "direct-tcpip" channel to `targetHost:targetPort` as seen from the SSH server.
///
/// Credentials are used only during `open` and are not retained afterwards. Host keys are checked
/// against the user's known_hosts files read-only; nothing is ever written to disk.
final class SSHTunnel: @unchecked Sendable {
    /// The port the database driver should dial on 127.0.0.1.
    let localPort: Int

    /// Seconds allowed for the TCP connection, and again for the SSH handshake and login.
    static let connectTimeoutSeconds = 15

    /// How often the SSH server is asked to prove it is still responsive. After three unanswered probes the
    /// connection is closed, which reports the disconnect.
    static let keepaliveInterval = TimeAmount.seconds(20)

    private let sshChannel: Channel
    private let sshHandler: NIOLoopBound<NIOSSHHandler>
    private let target: (host: String, port: Int)
    private let listener: Channel
    private let connections: TunnelConnectionRegistry
    private let state = NIOLockedValueBox(State())

    private struct State {
        var isClosing = false
        var didDisconnect = false
        var disconnectHandlers: [@Sendable () -> Void] = []
    }

    private init(localPort: Int, sshChannel: Channel, sshHandler: NIOLoopBound<NIOSSHHandler>, target: (host: String, port: Int),
                 listener: Channel, connections: TunnelConnectionRegistry) {
        self.localPort = localPort
        self.sshChannel = sshChannel
        self.sshHandler = sshHandler
        self.target = target
        self.listener = listener
        self.connections = connections
    }

    deinit {
        let needsClose = state.withLockedValue { !$0.isClosing }
        if needsClose {
            listener.close(promise: nil)
            connections.closeAll().forEach { $0.close(promise: nil) }
            sshChannel.close(promise: nil)
        }
    }

    static func open(ssh: SSHConfig, targetHost: String, targetPort: Int, verifier: any HostKeyVerifier) async throws -> SSHTunnel {
        try await open(ssh: ssh, targetHost: targetHost, targetPort: targetPort, verifier: verifier, knownHosts: nil)
    }

    /// - Parameter knownHosts: entries to verify against; nil reads the standard OpenSSH files.
    static func open(
        ssh: SSHConfig,
        targetHost: String,
        targetPort: Int,
        verifier: any HostKeyVerifier,
        knownHosts: KnownHosts?,
        connectTimeout: Int = connectTimeoutSeconds,
        keepaliveInterval: TimeAmount = keepaliveInterval
    ) async throws -> SSHTunnel {
        var host = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { throw DatabaseError("Enter the SSH server’s host name.") }
        guard (1...65535).contains(ssh.port) else { throw DatabaseError("The SSH port must be between 1 and 65535.") }
        let username = ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw DatabaseError("Enter the SSH user name.") }
        let target = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, (1...65535).contains(targetPort) else {
            throw DatabaseError("Enter the database host and port to reach through the SSH tunnel.")
        }

        // Read the key now (never cached); it lives only until this function returns.
        let credential: SSHCredential = switch ssh.authMethod {
        case .password: .password(ssh.password)
        case .privateKey: .privateKey(try SSHKeyLoader.load(path: ssh.privateKeyPath, passphrase: ssh.passphrase))
        }
        try Task.checkCancellation()

        let knownHosts = knownHosts ?? KnownHosts.loadDefault()
        let endpoint = Endpoint(host: host, port: ssh.port, username: username, targetHost: target,
                                targetPort: targetPort, timeout: connectTimeout, keepaliveInterval: keepaliveInterval)
        do {
            return try await establish(endpoint, credential: credential,
                                       hostKeyPolicy: .knownHosts(knownHosts, host: host, port: ssh.port))
        } catch let pending as SSHHostKeyNeedsConfirmation {
            // Ask outside the SSH handshake so the user can take their time, then reconnect pinned to that key.
            try Task.checkCancellation()
            let (keyType, fingerprint) = (pending.key.displayType, pending.key.fingerprint)
            let accepted = switch pending.status {
            case .unknown:
                await verifier.confirmHostKey(host: host, port: ssh.port, keyType: keyType, fingerprint: fingerprint,
                                              knownHostsStatus: .unknown)
            case .mismatch:
                // Like OpenSSH, a changed key is never something to click through.
                throw Self.changedHostKeyError(host: host, port: ssh.port, keyType: keyType, fingerprint: fingerprint)
            case .otherKeyTypesKnown(let knownTypes):
                await verifier.confirmHostKey(host: host, port: ssh.port, keyType: keyType, fingerprint: fingerprint,
                                              knownKeyTypes: knownTypes)
            case .trusted, .revoked:
                // Never asked: trusted keys connect and revoked keys fail during the handshake.
                false
            }
            guard accepted else {
                throw DatabaseError("Host key rejected",
                                    detail: "The \(pending.key.displayType) host key of \(host) wasn’t trusted, so the connection was not opened.")
            }
            try Task.checkCancellation()
            return try await establish(endpoint, credential: credential, hostKeyPolicy: .exactly(pending.key))
        }
    }

    static func changedHostKeyError(host: String, port: Int, keyType: String, fingerprint: String) -> DatabaseError {
        let entry = port == 22 ? host : "'[\(host)]:\(port)'"
        return DatabaseError(
            "The host key of \(host) has changed.",
            detail: "~/.ssh/known_hosts lists a different \(keyType) key for this server, so someone could be intercepting the connection. Dbee won’t connect. If the server’s key really changed, remove the old entry with “ssh-keygen -R \(entry)” and connect again.\n\n\(keyType) key fingerprint offered:\n\(fingerprint)"
        )
    }

    /// Called when the SSH connection drops unexpectedly.
    ///
    /// Not called after `close()`. If the connection has already dropped, the handler runs immediately.
    /// Handlers run on an arbitrary thread.
    func onDisconnect(_ handler: @escaping @Sendable () -> Void) {
        let alreadyDisconnected = state.withLockedValue { state -> Bool in
            if state.didDisconnect { return true }
            if !state.isClosing { state.disconnectHandlers.append(handler) }
            return false
        }
        if alreadyDisconnected { handler() }
    }

    /// Stops listening, closes forwarded channels and the SSH connection. Safe to call more than once.
    func close() async {
        let isFirstClose = state.withLockedValue { state -> Bool in
            defer {
                state.isClosing = true
                state.disconnectHandlers.removeAll()
            }
            return !state.isClosing
        }
        if isFirstClose {
            listener.close(promise: nil)
            connections.closeAll().forEach { $0.close(promise: nil) }
            try? await sshChannel.close()
        }
        try? await sshChannel.closeFuture.get()
        try? await listener.closeFuture.get()
    }

    /// Whether the SSH connection is still up.
    var isConnected: Bool { sshChannel.isActive }

    /// Number of local connections currently being forwarded.
    var forwardedConnectionCount: Int { connections.openCount }

    /// Human-readable reason the most recent forwarded connection could not be opened (for example the
    /// server refused to reach the database host) or was cut off. Useful to explain a driver's "connection
    /// closed" error.
    var lastForwardingFailure: String? { connections.lastFailure }

    /// Opens a direct-tcpip channel to the target that carries plain bytes, without going through the local
    /// listener. Drivers that can run over an established channel (PostgresNIO) should prefer this, since
    /// no other process on the Mac can reach it. The channel is closed with the tunnel.
    func openForwardedChannel() async throws -> Channel {
        let loop = sshChannel.eventLoop
        let (sshHandler, registry, target, sshChannel) = (sshHandler, connections, target, sshChannel)
        let opened = loop.makePromise(of: Channel.self)
        let created = loop.makePromise(of: Channel.self)
        loop.execute {
            let originator = try? SocketAddress(ipAddress: "127.0.0.1", port: 0)
            guard let originator else { return created.fail(ChannelError.ioOnClosedChannel) }
            let request = SSHChannelType.DirectTCPIP(targetHost: target.host, targetPort: target.port, originatorAddress: originator)
            sshHandler.value.createChannel(created, channelType: .directTCPIP(request)) { child, _ in
                guard registry.register(child) else { return child.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
                return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                    try child.pipeline.syncOperations.addHandler(SSHChannelByteCodec())
                }
            }
        }
        // Never wait forever: the SSH connection may die, or the server may never answer the open.
        let isSettled = NIOLockedValueBox(false)
        let settle = { @Sendable (result: Result<Channel, Error>) in
            let first = isSettled.withLockedValue { settled in
                defer { settled = true }
                return !settled
            }
            guard first else {
                // Opened after we gave up: nobody will use it.
                if case .success(let late) = result { late.close(promise: nil) }
                return
            }
            opened.completeWith(result)
        }
        let timeout = loop.scheduleTask(in: .seconds(Int64(Self.connectTimeoutSeconds))) {
            settle(.failure(ChannelError.connectTimeout(.seconds(Int64(Self.connectTimeoutSeconds)))))
        }
        sshChannel.closeFuture.whenComplete { _ in settle(.failure(ChannelError.ioOnClosedChannel)) }
        created.futureResult.whenComplete { result in
            timeout.cancel()
            settle(result)
        }
        do {
            return try await opened.futureResult.get()
        } catch {
            let reason = SSHTunnelErrors.describeForwardingFailure(error, targetHost: target.host, targetPort: target.port)
            registry.recordFailure(reason)
            throw DatabaseError(reason)
        }
    }

    /// Stops the local listener from accepting connections that weren't announced with
    /// `allowNextLocalConnection()`. Without this, any local process can use the tunnel while it is open.
    func restrictLocalConnections() {
        connections.restrictLocalConnections()
    }

    /// Lets exactly one more connection through the local listener, if it arrives within a few seconds.
    /// Call it right before the driver dials `localPort`. Implies `restrictLocalConnections()`.
    func allowNextLocalConnection() {
        connections.allowNextLocalConnection()
    }

    // MARK: Connecting

    private struct Endpoint {
        var host: String
        var port: Int
        var username: String
        var targetHost: String
        var targetPort: Int
        var timeout: Int
        var keepaliveInterval: TimeAmount
    }

    private static func establish(
        _ endpoint: Endpoint,
        credential: SSHCredential,
        hostKeyPolicy: TunnelHostKeyDelegate.Policy
    ) async throws -> SSHTunnel {
        let usesPassword = if case .password = credential { true } else { false }
        func describe(_ error: Error, _ phase: SSHTunnelErrors.Phase) -> Error {
            SSHTunnelErrors.describe(error, phase: phase, host: endpoint.host, port: endpoint.port,
                                     timeoutSeconds: endpoint.timeout)
        }

        let hostKeyDelegate = TunnelHostKeyDelegate(policy: hostKeyPolicy)
        let authDelegate = TunnelUserAuthDelegate(username: endpoint.username, credential: credential)
        defer { authDelegate.wipe() }
        let delegates = SSHTunnelUncheckedBox(value: (auth: authDelegate, hostKey: hostKeyDelegate))
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let loginTimeout = TimeAmount.seconds(Int64(endpoint.timeout))

        // 1. TCP connection to the SSH server, with the SSH handler installed before any bytes arrive.
        let tcpLevel = SocketOptionLevel(IPPROTO_TCP)
        let connecting = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(Int64(endpoint.timeout)))
            .channelOption(ChannelOptions.socket(tcpLevel, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.socket(tcpLevel, TCP_KEEPALIVE), value: 60)
            .channelOption(ChannelOptions.socket(tcpLevel, TCP_KEEPINTVL), value: 15)
            .channelOption(ChannelOptions.socket(tcpLevel, TCP_KEEPCNT), value: 4)
            // Bounds retransmission when sent data goes unacknowledged (sleep, Wi-Fi change), where keepalive
            // probes don't run. Without it macOS waits minutes before giving up on the connection.
            .channelOption(ChannelOptions.socket(tcpLevel, TCP_RXT_CONNDROPTIME), value: 30)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHClientConfiguration(userAuthDelegate: delegates.value.auth,
                                                               serverAuthDelegate: delegates.value.hostKey)
                    let ssh = NIOSSHHandler(role: .client(configuration), allocator: channel.allocator,
                                            inboundChildChannelInitializer: nil)
                    let guardHandler = SSHSessionGuard(authenticated: authenticated, loginTimeout: loginTimeout)
                    try channel.pipeline.syncOperations.addHandlers([ssh, guardHandler])
                }
            }
            .connect(host: endpoint.host, port: endpoint.port)
        // A pending connect can't be aborted, so cancellation completes this promise early instead and the
        // late channel, if any, is closed as soon as it appears.
        let connected = loop.makePromise(of: Channel.self)
        connecting.cascade(to: connected)
        let channel: Channel
        do {
            channel = try await withTaskCancellationHandler {
                try await connected.futureResult.get()
            } onCancel: {
                connected.fail(CancellationError())
                connecting.whenSuccess { $0.close(promise: nil) }
            }
        } catch {
            authenticated.fail(error)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw describe(error, .tcpConnect)
        }

        // 2. SSH handshake, host key verification and user authentication.
        do {
            try await withTaskCancellationHandler {
                try await authenticated.futureResult.get()
            } onCancel: {
                channel.close(promise: nil)
            }
        } catch {
            channel.close(promise: nil)
            if let revoked = hostKeyDelegate.revokedKey {
                throw DatabaseError("The host key of \(endpoint.host) has been revoked.",
                                    detail: "~/.ssh/known_hosts marks the server’s \(revoked.displayType) key (\(revoked.fingerprint)) as @revoked, so Dbee won’t connect. Ask the server’s administrator for its current key.")
            }
            if let pending = hostKeyDelegate.pendingConfirmation { throw pending }
            if hostKeyDelegate.changedDuringConnect {
                throw DatabaseError("The host key of \(endpoint.host) changed while connecting.",
                                    detail: "The server presented a different key than the one you just accepted. Someone could be intercepting this connection.")
            }
            if let rejection = authDelegate.rejection {
                throw SSHTunnelErrors.authenticationFailed(rejection, usesPassword: usesPassword)
            }
            if Task.isCancelled { throw CancellationError() }
            throw describe(error, .handshake)
        }
        authDelegate.wipe()

        // 3. Local listener whose connections become direct-tcpip channels.
        do {
            let loop = channel.eventLoop
            let sshHandler = try await loop.submit {
                NIOLoopBound(try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self), eventLoop: loop)
            }.get()
            let registry = TunnelConnectionRegistry()
            let targetHost = endpoint.targetHost
            let targetPort = endpoint.targetPort
            let sshChannel = channel
            let listener = try await ServerBootstrap(group: loop)
                .serverChannelOption(ChannelOptions.backlog, value: 128)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socket(tcpLevel, TCP_NODELAY), value: 1)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { local in
                    forward(local, through: sshHandler, to: targetHost, port: targetPort, registry: registry,
                            connection: sshChannel)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let localPort = listener.localAddress?.port else {
                listener.close(promise: nil)
                throw DatabaseError("Couldn’t start the local end of the SSH tunnel.")
            }
            let tunnel = SSHTunnel(localPort: localPort, sshChannel: channel, sshHandler: sshHandler,
                                   target: (targetHost, targetPort), listener: listener, connections: registry)
            channel.closeFuture.whenComplete { [weak tunnel] _ in tunnel?.sshConnectionClosed() }
            let interval = endpoint.keepaliveInterval
            try await loop.submit {
                SSHKeepalive(connection: channel, handler: sshHandler.value, interval: interval).start()
            }.get()
            if Task.isCancelled {
                await tunnel.close()
                throw CancellationError()
            }
            return tunnel
        } catch {
            try? await channel.close()
            if error is DatabaseError || error is CancellationError { throw error }
            throw DatabaseError("Couldn’t start the local end of the SSH tunnel.", detail: String(describing: error))
        }
    }

    /// Accepted-connection initializer: opens a direct-tcpip channel and glues it to the local socket.
    /// The local socket is only registered (and starts reading) once the SSH channel is open.
    private static func forward(
        _ local: Channel,
        through sshHandler: NIOLoopBound<NIOSSHHandler>,
        to targetHost: String,
        port targetPort: Int,
        registry: TunnelConnectionRegistry,
        connection: Channel
    ) -> EventLoopFuture<Void> {
        guard registry.admitLocalConnection(), registry.register(local) else {
            return local.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
        }
        let (localGlue, remoteGlue) = TunnelGlueHandler.matchedPair { error in
            guard let error = error as? NIOSSHError else { return }
            registry.recordFailure(SSHTunnelErrors.describeForwardingWriteFailure(error))
            // The SSH library rejects channel data while the server re-keys the connection, and loses window
            // updates the same way, which stalls every forwarded connection. Fail the whole tunnel loudly.
            if error.type == .protocolViolation { connection.close(promise: nil) }
        }
        do {
            try local.pipeline.syncOperations.addHandler(localGlue)
        } catch {
            return local.eventLoop.makeFailedFuture(error)
        }

        let originator = local.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
        guard let originator else { return local.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
        let request = SSHChannelType.DirectTCPIP(targetHost: targetHost, targetPort: targetPort, originatorAddress: originator)
        let opened = local.eventLoop.makePromise(of: Channel.self)
        sshHandler.value.createChannel(opened, channelType: .directTCPIP(request)) { child, type in
            guard case .directTCPIP = type else {
                return child.eventLoop.makeFailedFuture(SSHUnexpectedChannelType())
            }
            return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                try child.pipeline.syncOperations.addHandlers([SSHChannelByteCodec(), remoteGlue])
            }
        }
        return opened.futureResult.map { _ in }.flatMapErrorThrowing { error in
            registry.recordFailure(SSHTunnelErrors.describeForwardingFailure(error, targetHost: targetHost, targetPort: targetPort))
            throw error
        }
    }

    private func sshConnectionClosed() {
        let handlers = state.withLockedValue { state -> [@Sendable () -> Void] in
            guard !state.isClosing, !state.didDisconnect else { return [] }
            state.didDisconnect = true
            defer { state.disconnectHandlers.removeAll() }
            return state.disconnectHandlers
        }
        // Drop the listener and forwarded sockets so the driver notices right away.
        listener.close(promise: nil)
        connections.closeAll().forEach { $0.close(promise: nil) }
        handlers.forEach { $0() }
    }
}

/// Detects a dead or wedged SSH server that TCP alone doesn't notice (a hung sshd or a stuck key exchange).
///
/// Every `interval` it sends a global request that any server answers, success or failure, and closes the
/// connection once `maxUnanswered` probes in a row have gone unanswered. Lives as long as the connection.
final class SSHKeepalive {
    private let connection: Channel
    private let handler: NIOSSHHandler
    private let interval: TimeAmount
    private let maxUnanswered: Int
    private var unanswered = 0

    init(connection: Channel, handler: NIOSSHHandler, interval: TimeAmount, maxUnanswered: Int = 3) {
        self.connection = connection
        self.handler = handler
        self.interval = interval
        self.maxUnanswered = maxUnanswered
    }

    /// Must be called on the connection's event loop.
    func start() {
        let loop = connection.eventLoop
        let bound = NIOLoopBound(self, eventLoop: loop)
        let task = loop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { task in
            bound.value.tick(task)
        }
        connection.closeFuture.whenComplete { _ in task.cancel() }
    }

    private func tick(_ task: RepeatedTask) {
        guard connection.isActive else { return task.cancel() }
        if unanswered >= maxUnanswered {
            task.cancel()
            connection.close(promise: nil)
            return
        }
        unanswered += 1
        let loop = connection.eventLoop
        let bound = NIOLoopBound(self, eventLoop: loop)
        let reply = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        reply.futureResult.whenComplete { result in
            switch result {
            case .success:
                bound.value.unanswered = 0
            case .failure(let error as NIOSSHError) where error.type == .globalRequestRefused:
                bound.value.unanswered = 0
            case .failure:
                break
            }
        }
        // Cancelling a forward that was never requested is a harmless no-op that servers always answer
        // (OpenSSH replies with a failure). The SSH library doesn't expose keepalive@openssh.com.
        handler.sendTCPForwardingRequest(.cancel(host: "127.0.0.1", port: 1), promise: reply)
    }
}
