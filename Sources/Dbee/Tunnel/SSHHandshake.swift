import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// Credentials for one connection attempt. In memory only; dropped as soon as authentication finishes.
enum SSHCredential {
    case password(String)
    case privateKey(SSHLoadedKey)
}

/// Offers exactly the user's configured credential and remembers why the server refused it.
final class TunnelUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    struct Rejection: Equatable {
        enum Reason: Equatable {
            /// The server doesn't allow our method, but does allow another one Dbee supports.
            case methodNotOffered
            /// The server tried our credential and refused it.
            case credentialRejected
            /// The server only offers methods Dbee doesn't support, such as keyboard-interactive.
            case unsupportedMethodsOnly
            /// The server accepted our credential but requires another step (AuthenticationMethods a,b).
            case needsAdditionalMethod
        }

        /// What the server says it accepts among the methods NIOSSH recognises, e.g. ["publickey", "password"].
        var serverMethods: [String]
        var reason: Reason
    }

    private let lock = NIOLock()
    private var username: String
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]
    private let usesPassword: Bool
    private var _rejection: Rejection?
    /// Whether the server has already been sent one of our credentials.
    private var sentOffer = false

    init(username: String, credential: SSHCredential) {
        self.username = username
        switch credential {
        case .password(let password):
            offers = [.password(.init(password: password))]
            usesPassword = true
        case .privateKey(let key):
            offers = key.signingKeys.map { .privateKey(.init(privateKey: $0)) }
            usesPassword = false
        }
    }

    var rejection: Rejection? { lock.withLock { _rejection } }

    /// Drops every reference to the secret material.
    func wipe() {
        lock.withLock {
            offers.removeAll()
            username = ""
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let next: Result<NIOSSHUserAuthenticationOffer, SSHAuthenticationRejected> = lock.withLock {
            let methods = Self.names(of: availableMethods)
            let required: NIOSSHAvailableUserAuthenticationMethods = usesPassword ? .password : .publicKey
            guard availableMethods.contains(required) else {
                offers.removeAll()
                // NIOSSH drops method names it doesn't know (keyboard-interactive, gssapi-with-mic, …), so an
                // empty set means only unsupported methods are left. If our method disappeared after we used
                // it, the server accepted it as one step of several (partial success).
                let reason: Rejection.Reason = if methods.isEmpty {
                    .unsupportedMethodsOnly
                } else if sentOffer {
                    .needsAdditionalMethod
                } else {
                    .methodNotOffered
                }
                _rejection = Rejection(serverMethods: methods, reason: reason)
                return .failure(SSHAuthenticationRejected())
            }
            guard !offers.isEmpty else {
                _rejection = Rejection(serverMethods: methods, reason: .credentialRejected)
                return .failure(SSHAuthenticationRejected())
            }
            sentOffer = true
            let offer = offers.removeFirst()
            return .success(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
        }
        switch next {
        case .success(let offer): nextChallengePromise.succeed(offer)
        case .failure(let error): nextChallengePromise.fail(error)
        }
    }

    private static func names(of methods: NIOSSHAvailableUserAuthenticationMethods) -> [String] {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        return names
    }
}

struct SSHAuthenticationRejected: Error {}

/// Thrown by the first connection attempt when the host key needs the user's decision.
struct SSHHostKeyNeedsConfirmation: Error {
    var key: SSHHostKey
    /// `.unknown`, `.mismatch` or `.otherKeyTypesKnown`.
    var status: KnownHosts.Verdict
}

struct SSHHostKeyRevoked: Error {}

struct SSHHostKeyChangedDuringConnect: Error {}

/// Validates the server's host key against known_hosts, or against one key the user already accepted.
final class TunnelHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    enum Policy {
        case knownHosts(KnownHosts, host: String, port: Int)
        case exactly(SSHHostKey)
    }

    private let policy: Policy
    private let lock = NIOLock()
    private var _pendingConfirmation: SSHHostKeyNeedsConfirmation?
    private var _changedDuringConnect = false
    private var _revokedKey: SSHHostKey?

    init(policy: Policy) {
        self.policy = policy
    }

    var pendingConfirmation: SSHHostKeyNeedsConfirmation? { lock.withLock { _pendingConfirmation } }
    var changedDuringConnect: Bool { lock.withLock { _changedDuringConnect } }
    /// The server's key when known_hosts marks it `@revoked`. The user is not asked in that case.
    var revokedKey: SSHHostKey? { lock.withLock { _revokedKey } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = SSHHostKey(hostKey)
        switch policy {
        case .knownHosts(let knownHosts, let host, let port):
            switch knownHosts.status(host: host, port: port, key: key) {
            case .trusted:
                validationCompletePromise.succeed(())
            case .revoked:
                lock.withLock { _revokedKey = key }
                validationCompletePromise.fail(SSHHostKeyRevoked())
            case let status:
                let pending = SSHHostKeyNeedsConfirmation(key: key, status: status)
                lock.withLock { _pendingConfirmation = pending }
                validationCompletePromise.fail(pending)
            }
        case .exactly(let accepted):
            if accepted == key {
                validationCompletePromise.succeed(())
            } else {
                lock.withLock { _changedDuringConnect = true }
                validationCompletePromise.fail(SSHHostKeyChangedDuringConnect())
            }
        }
    }
}

struct SSHLoginTimedOut: Error {}
struct SSHConnectionClosedDuringLogin: Error {}

/// Sits behind `NIOSSHHandler` on the connection to the SSH server.
///
/// Completes `authenticated` once user authentication succeeds, or fails it on the first error, on timeout
/// or when the connection closes. Any error, before or after login, closes the connection.
final class SSHSessionGuard: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>
    private let loginTimeout: TimeAmount
    private var timer: Scheduled<Void>?
    private var isFinished = false

    init(authenticated: EventLoopPromise<Void>, loginTimeout: TimeAmount) {
        self.authenticated = authenticated
        self.loginTimeout = loginTimeout
    }

    func channelActive(context: ChannelHandlerContext) {
        let bound = NIOLoopBound((handler: self, context: context), eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: loginTimeout) {
            bound.value.handler.finish(.failure(SSHLoginTimedOut()))
            bound.value.context.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            finish(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(SSHConnectionClosedDuringLogin()))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(.failure(SSHConnectionClosedDuringLogin()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timer?.cancel()
        timer = nil
        authenticated.completeWith(result)
    }
}

/// Turns low-level NIO / NIOSSH errors into messages a person can act on.
enum SSHTunnelErrors {
    enum Phase {
        case tcpConnect
        case handshake
    }

    static func describe(_ error: Error, phase: Phase, host: String, port: Int, timeoutSeconds: Int) -> Error {
        if error is DatabaseError || error is CancellationError || error is SSHHostKeyNeedsConfirmation { return error }
        let endpoint = port == 22 ? host : "\(host):\(port)"
        if error is SSHConnectionClosedDuringLogin { return closedDuringHandshake(endpoint) }

        if let error = error as? NIOConnectionError {
            if error.dnsAError != nil || error.dnsAAAAError != nil || error.connectionErrors.isEmpty {
                return DatabaseError("Couldn’t find the SSH server “\(host)”.",
                                     detail: "The host name could not be resolved. Check the spelling and your network connection.")
            }
            if let first = error.connectionErrors.first?.error {
                return describe(first, phase: phase, host: host, port: port, timeoutSeconds: timeoutSeconds)
            }
        }
        if error is SocketAddressError.UnknownHost {
            return DatabaseError("Couldn’t find the SSH server “\(host)”.",
                                 detail: "The host name could not be resolved. Check the spelling and your network connection.")
        }
        if let error = error as? IOError {
            switch error.errnoCode {
            case ECONNREFUSED:
                return DatabaseError("The SSH server \(endpoint) refused the connection.",
                                     detail: "Nothing is accepting SSH connections on port \(port). Check the port and that the SSH server is running.")
            case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN:
                return DatabaseError("The SSH server \(endpoint) is unreachable.",
                                     detail: "Check your network connection, VPN and firewall settings.")
            case ETIMEDOUT:
                return timeout(endpoint: endpoint, seconds: timeoutSeconds, phase: phase)
            case ECONNRESET, EPIPE:
                return DatabaseError("The SSH server \(endpoint) closed the connection.",
                                     detail: "The server or a firewall dropped the connection during the SSH handshake.")
            default:
                return DatabaseError("Couldn’t connect to the SSH server \(endpoint).", detail: error.description)
            }
        }
        if let error = error as? ChannelError {
            switch error {
            case .connectTimeout:
                return timeout(endpoint: endpoint, seconds: timeoutSeconds, phase: phase)
            case .eof, .ioOnClosedChannel, .alreadyClosed, .outputClosed:
                return closedDuringHandshake(endpoint)
            default:
                break
            }
        }
        if let error = error as? NIOSSHError {
            switch error.type {
            case .keyExchangeNegotiationFailure:
                return DatabaseError("Dbee and the SSH server \(endpoint) have no encryption algorithms in common.",
                                     detail: "Dbee supports curve25519/ECDH key exchange, AES-GCM ciphers and Ed25519/ECDSA host keys. Older servers may need an OpenSSH update.")
            case .unsupportedVersion:
                return DatabaseError("\(endpoint) doesn’t speak a supported SSH protocol version.")
            case .tcpShutdown:
                return closedDuringHandshake(endpoint)
            default:
                return DatabaseError("The SSH handshake with \(endpoint) failed.", detail: String(describing: error))
            }
        }
        if error is SSHLoginTimedOut {
            return timeout(endpoint: endpoint, seconds: timeoutSeconds, phase: .handshake)
        }
        return DatabaseError("Couldn’t connect to the SSH server \(endpoint).", detail: String(describing: error))
    }

    static func authenticationFailed(_ rejection: TunnelUserAuthDelegate.Rejection, usesPassword: Bool) -> DatabaseError {
        let list = rejection.serverMethods.isEmpty ? "" : " (\(rejection.serverMethods.joined(separator: ",")))"
        switch rejection.reason {
        case .unsupportedMethodsOnly:
            return DatabaseError("The SSH server only offers sign-in methods Dbee doesn’t support, such as keyboard-interactive or two-factor prompts.",
                                 detail: "Dbee can sign in with a password or a private key. Ask the server’s administrator to enable one of them for this account.")
        case .needsAdditionalMethod:
            return DatabaseError("The SSH server needs more than one sign-in step\(list).",
                                 detail: "The server accepted the \(usesPassword ? "password" : "key") but also requires another method (for example a key and then a password). Dbee can’t do multi-step SSH login yet.")
        case .methodNotOffered:
            let method = usesPassword ? "password" : "public key"
            let alternative = usesPassword ? "Use a private key instead." : "Use a password instead."
            return DatabaseError("The SSH server doesn’t allow \(method) authentication\(list).", detail: alternative)
        case .credentialRejected:
            break
        }
        if usesPassword {
            return DatabaseError("Permission denied\(list).",
                                 detail: "The SSH server rejected the user name or password.")
        }
        return DatabaseError("Permission denied\(list).",
                             detail: "The SSH server didn’t accept this private key for the user. Make sure its public key is in ~/.ssh/authorized_keys on the server.")
    }

    private static func timeout(endpoint: String, seconds: Int, phase: Phase) -> DatabaseError {
        switch phase {
        case .tcpConnect:
            return DatabaseError("Timed out connecting to the SSH server \(endpoint).",
                                 detail: "There was no response within \(seconds) seconds. Check the host, port and any firewall in between.")
        case .handshake:
            return DatabaseError("The SSH server \(endpoint) didn’t complete the login in time.",
                                 detail: "The connection opened but the SSH handshake stalled. The server may be overloaded or blocking this client.")
        }
    }

    private static func closedDuringHandshake(_ endpoint: String) -> DatabaseError {
        DatabaseError("The SSH server \(endpoint) closed the connection during login.",
                      detail: "The server may limit connections from your address, or it isn’t an SSH server.")
    }

    /// Describes why the server refused to open a forwarded channel.
    static func describeForwardingFailure(_ error: Error, targetHost: String, targetPort: Int) -> String {
        let target = "\(targetHost):\(targetPort)"
        if let error = error as? NIOSSHError, error.type == .channelSetupRejected {
            let text = String(describing: error).lowercased()
            if text.contains("prohibited") {
                return "The SSH server doesn’t allow port forwarding to \(target) (AllowTcpForwarding may be disabled)."
            }
            return "The SSH server couldn’t connect to \(target). Check the database host and port as seen from the SSH server."
        }
        return "Forwarding to \(target) through SSH failed."
    }

    /// Describes why a forwarded connection was cut off after a write through SSH failed.
    static func describeForwardingWriteFailure(_ error: NIOSSHError) -> String {
        if error.type == .protocolViolation {
            return "The SSH server started a new key exchange while data was being forwarded, which Dbee can’t handle yet. The SSH connection was closed so no data was lost silently."
        }
        return "Sending data through the SSH tunnel failed, so the connection was closed (\(error))."
    }
}

/// Lets a non-Sendable value cross into a `@Sendable` closure when it is only used on one event loop.
struct SSHTunnelUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}
