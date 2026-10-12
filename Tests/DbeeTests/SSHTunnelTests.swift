import Crypto
import _CryptoExtras
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import Testing
@testable import Dbee

// MARK: - Private key loading (no network)

@Suite("SSHTunnel key loading")
final class SSHTunnelKeyLoadingTests {
    let dir: URL

    init() throws {
        dir = try SSHTestTools.makeTempDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func expectLoads(_ path: URL, passphrase: String = "", algorithm: String) throws {
        let loaded = try SSHKeyLoader.load(path: path.path, passphrase: passphrase)
        let pub = try SSHTestTools.publicKeyLine(path)
        #expect(loaded.algorithm == algorithm)
        #expect(Data(loaded.publicKeyBlob).base64EncodedString() == pub.base64)
        #expect(!loaded.signingKeys.isEmpty)
    }

    @Test func unencryptedOpenSSHKeys() throws {
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "ed", type: "ed25519"), algorithm: "ssh-ed25519")
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "rsa", type: "rsa", bits: 2048), algorithm: "ssh-rsa")
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "ec256", type: "ecdsa", bits: 256), algorithm: "ecdsa-sha2-nistp256")
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "ec384", type: "ecdsa", bits: 384), algorithm: "ecdsa-sha2-nistp384")
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "ec521", type: "ecdsa", bits: 521), algorithm: "ecdsa-sha2-nistp521")
    }

    @Test(arguments: ["aes256-ctr", "aes128-ctr", "aes192-ctr", "aes256-cbc", "aes128-cbc",
                      "aes256-gcm@openssh.com", "aes128-gcm@openssh.com"])
    func encryptedOpenSSHKeys(cipher: String) throws {
        let ed = try SSHTestTools.generateKey(in: dir, name: "ed-\(cipher)", type: "ed25519",
                                              passphrase: "correct horse", extra: ["-Z", cipher])
        try expectLoads(ed, passphrase: "correct horse", algorithm: "ssh-ed25519")
        let ec = try SSHTestTools.generateKey(in: dir, name: "ec-\(cipher)", type: "ecdsa", bits: 384,
                                              passphrase: "correct horse", extra: ["-Z", cipher])
        try expectLoads(ec, passphrase: "correct horse", algorithm: "ecdsa-sha2-nistp384")
        do {
            _ = try SSHKeyLoader.load(path: ed.path, passphrase: "wrong horse")
            Issue.record("Expected a wrong passphrase error")
        } catch let error as DatabaseError {
            #expect(error.message.contains("Incorrect passphrase"))
        }
    }

    @Test func encryptedRSAKeyAndPassphraseErrors() throws {
        let rsa = try SSHTestTools.generateKey(in: dir, name: "rsa-enc", type: "rsa", bits: 2048, passphrase: "pp")
        try expectLoads(rsa, passphrase: "pp", algorithm: "ssh-rsa")
        #expect(throws: DatabaseError.self) { try SSHKeyLoader.load(path: rsa.path, passphrase: "nope") }
        do {
            _ = try SSHKeyLoader.load(path: rsa.path, passphrase: "")
            Issue.record("Expected a passphrase-required error")
        } catch let error as DatabaseError {
            #expect(error.message.contains("protected by a passphrase"))
        }
    }

    @Test func legacyPEMAndPKCS8Keys() throws {
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "rsa-pem", type: "rsa", bits: 2048, extra: ["-m", "PEM"]),
                        algorithm: "ssh-rsa")
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "ec-pem", type: "ecdsa", bits: 256, extra: ["-m", "PEM"]),
                        algorithm: "ecdsa-sha2-nistp256")
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "rsa-p8", type: "rsa", bits: 2048, extra: ["-m", "PKCS8"]),
                        algorithm: "ssh-rsa")
        try expectLoads(try SSHTestTools.generateKey(in: dir, name: "ec-p8", type: "ecdsa", bits: 521, extra: ["-m", "PKCS8"]),
                        algorithm: "ecdsa-sha2-nistp521")
        // P-521 scalars start with a zero byte about half the time; some encoders drop it.
        for i in 0..<12 {
            let format = i.isMultiple(of: 2) ? "PEM" : "PKCS8"
            try expectLoads(try SSHTestTools.generateKey(in: dir, name: "ec521-\(i)", type: "ecdsa", bits: 521, extra: ["-m", format]),
                            algorithm: "ecdsa-sha2-nistp521")
        }
        let encryptedPEM = try SSHTestTools.generateKey(in: dir, name: "rsa-pem-enc", type: "rsa", bits: 2048,
                                                        passphrase: "legacy-pass", extra: ["-m", "PEM"])
        do {
            _ = try SSHKeyLoader.load(path: encryptedPEM.path, passphrase: "legacy-pass")
            Issue.record("Expected an unsupported-format error")
        } catch let error as DatabaseError {
            #expect(error.detail?.contains("ssh-keygen -p -f") == true)
        }
    }

    @Test func unsupportedFormatsGiveActionableErrors() throws {
        func message(for contents: String, name: String = "key") -> DatabaseError? {
            let url = dir.appendingPathComponent(name)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            do {
                _ = try SSHKeyLoader.load(path: url.path, passphrase: "")
                return nil
            } catch {
                return error as? DatabaseError
            }
        }
        let putty = message(for: "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n", name: "k.ppk")
        #expect(putty?.message.contains("PuTTY") == true)
        #expect(putty?.detail?.contains("puttygen") == true)

        let ed = try SSHTestTools.generateKey(in: dir, name: "pubonly", type: "ed25519")
        let pubText = try String(contentsOf: ed.appendingPathExtension("pub"), encoding: .utf8)
        #expect(message(for: pubText, name: "id.pub")?.message.contains("public key") == true)

        #expect(message(for: "hello world")?.message.contains("isn’t a recognized private key") == true)

        let chacha = try SSHTestTools.generateKey(in: dir, name: "chacha", type: "ed25519", passphrase: "pp",
                                                  extra: ["-Z", "chacha20-poly1305@openssh.com"])
        do {
            _ = try SSHKeyLoader.load(path: chacha.path, passphrase: "pp")
            Issue.record("Expected an unsupported-cipher error")
        } catch let error as DatabaseError {
            #expect(error.detail?.contains("ssh-keygen -p -Z aes256-ctr") == true)
        }

        #expect(throws: DatabaseError.self) { try SSHKeyLoader.load(path: dir.appendingPathComponent("missing").path, passphrase: "") }
        #expect(throws: DatabaseError.self) { try SSHKeyLoader.load(path: dir.path, passphrase: "") }
        #expect(throws: DatabaseError.self) { try SSHKeyLoader.load(path: "  ", passphrase: "") }
    }

    @Test func tildeExpansionUsesHomeDirectory() {
        let home = KnownHosts.userHomeDirectory.path
        #expect(SSHKeyLoader.expandTilde("~/.ssh/id_ed25519") == home + "/.ssh/id_ed25519")
        #expect(SSHKeyLoader.expandTilde("~") == home)
        #expect(SSHKeyLoader.expandTilde("/abs/path") == "/abs/path")
    }

    @Test func rsaSignaturesVerify() throws {
        let path = try SSHTestTools.generateKey(in: dir, name: "rsa-sig", type: "rsa", bits: 2048, extra: ["-m", "PEM"])
        let loaded = try SSHKeyLoader.load(path: path.path, passphrase: "")
        #expect(loaded.signingKeys.count == 2)
        let key = try _RSA.Signing.PrivateKey(unsafePEMRepresentation: String(contentsOf: path, encoding: .utf8))
        let primitives = try key.publicKey.getKeyPrimitives()
        let n = Array(primitives.modulus), e = Array(primitives.publicExponent)
        let sha256Key = SSHRSAPrivateKey<SSHRSASHA256>(key: key, modulus: n, publicExponent: e)
        let sha1Key = SSHRSAPrivateKey<SSHRSASHA1>(key: key, modulus: n, publicExponent: e)
        #expect(SSHRSAPrivateKey<SSHRSASHA256>.keyPrefix == "rsa-sha2-256")
        #expect(SSHRSAPrivateKey<SSHRSASHA1>.keyPrefix == "ssh-rsa")

        let message = Array("session-id-and-request".utf8)
        let sig256 = try sha256Key.signature(for: message)
        let sig1 = try sha1Key.signature(for: message)
        #expect(sha256Key.publicKey.isValidSignature(sig256, for: message))
        #expect(sha1Key.publicKey.isValidSignature(sig1, for: message))
        #expect(!sha256Key.publicKey.isValidSignature(sig1, for: message))
        #expect(!sha256Key.publicKey.isValidSignature(sig256, for: Array("tampered".utf8)))
    }

    @Test func cancellationStopsAPendingConnect() async throws {
        var config = SSHConfig()
        config.host = "192.0.2.1"   // TEST-NET-1: never answers
        config.username = "nobody"
        config.authMethod = .password
        let started = Date()
        let task = Task {
            try await SSHTunnel.open(ssh: config, targetHost: "127.0.0.1", targetPort: 5432,
                                     verifier: SSHRecordingVerifier(answer: false), knownHosts: KnownHosts())
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 3)
        if case .success(let tunnel) = result {
            await tunnel.close()
            Issue.record("Expected the connect to be cancelled")
        }
    }

    @Test func connectErrorsAreHumanReadable() async throws {
        var config = SSHConfig()
        config.enabled = true
        config.username = "nobody"
        config.authMethod = .password
        config.password = "x"

        config.host = "dbee-does-not-exist.invalid"
        await expectOpenError(config, contains: "Couldn’t find the SSH server")

        config.host = "127.0.0.1"
        config.port = 1
        await expectOpenError(config, contains: "refused the connection")

        config.host = ""
        await expectOpenError(config, contains: "host name")
    }
}

private func expectOpenError(_ config: SSHConfig, contains text: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        let tunnel = try await SSHTunnel.open(ssh: config, targetHost: "127.0.0.1", targetPort: 5432,
                                              verifier: SSHRecordingVerifier(answer: false), knownHosts: KnownHosts())
        await tunnel.close()
        Issue.record("Expected an error containing “\(text)”", sourceLocation: sourceLocation)
    } catch let error as DatabaseError {
        #expect(error.message.contains(text), "got: \(error.message)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: - Forwarding glue, connection registry and login errors (no network)

@Suite("SSHTunnel forwarding units")
struct SSHTunnelForwardingUnitTests {
    private struct BrokenPipe: Error {}

    /// Fails every write with `error`, like NIOSSH does for channel data sent during a key exchange.
    private final class FailingWrites: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        let error: Error
        init(_ error: Error) { self.error = error }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            promise?.fail(error)
        }
    }

    private func gluedPair(failingWith error: Error, reported: NIOLockedValueBox<[String]>) throws -> (EmbeddedChannel, EmbeddedChannel) {
        let loop = EmbeddedEventLoop()
        let (localGlue, remoteGlue) = TunnelGlueHandler.matchedPair { error in
            reported.withLockedValue { $0.append(String(describing: error)) }
        }
        let local = EmbeddedChannel(loop: loop)
        let remote = EmbeddedChannel(loop: loop)
        try local.pipeline.syncOperations.addHandler(localGlue)
        try remote.pipeline.syncOperations.addHandlers([FailingWrites(error), remoteGlue])
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try local.connect(to: address).wait()
        try remote.connect(to: address).wait()
        return (local, remote)
    }

    @Test func failedWriteClosesBothSidesAndIsReported() throws {
        let reported = NIOLockedValueBox<[String]>([])
        let (local, remote) = try gluedPair(failingWith: BrokenPipe(), reported: reported)
        try local.writeInbound(ByteBuffer(string: "SELECT 1"))
        local.embeddedEventLoop.run()
        #expect(!local.isActive)
        #expect(!remote.isActive)
        #expect(reported.withLockedValue { $0 }.count == 1)
    }

    @Test func writesFailingBecauseOfAClosedChannelAreNotReported() throws {
        let reported = NIOLockedValueBox<[String]>([])
        let (local, remote) = try gluedPair(failingWith: ChannelError.ioOnClosedChannel, reported: reported)
        try local.writeInbound(ByteBuffer(string: "SELECT 1"))
        local.embeddedEventLoop.run()
        #expect(local.isActive)
        #expect(reported.withLockedValue { $0 }.isEmpty)
        _ = try? local.finish()
        _ = try? remote.finish()
    }

    @Test func restrictedRegistryAdmitsOnlyAnnouncedConnections() {
        let registry = TunnelConnectionRegistry()
        #expect(registry.admitLocalConnection())
        #expect(registry.admitLocalConnection())
        registry.restrictLocalConnections()
        #expect(!registry.admitLocalConnection())
        registry.allowNextLocalConnection()
        registry.allowNextLocalConnection()
        #expect(registry.admitLocalConnection())
        #expect(registry.admitLocalConnection())
        #expect(!registry.admitLocalConnection())
    }
}

@Suite("SSHTunnel login errors")
struct SSHTunnelLoginErrorTests {
    /// Asks the delegate for its next offer; returns true when it sent one.
    private func ask(_ delegate: TunnelUserAuthDelegate, _ methods: NIOSSHAvailableUserAuthenticationMethods) -> Bool {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        var offered = false
        promise.futureResult.whenComplete { offered = ((try? $0.get()) ?? nil) != nil }
        delegate.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise)
        return offered
    }

    private func passwordDelegate() -> TunnelUserAuthDelegate {
        TunnelUserAuthDelegate(username: "dbee", credential: .password("secret"))
    }

    @Test func onlyUnsupportedMethodsLeft() throws {
        // NIOSSH drops keyboard-interactive from the list, so the server appears to offer nothing.
        let delegate = passwordDelegate()
        #expect(!ask(delegate, []))
        let rejection = try #require(delegate.rejection)
        #expect(rejection.reason == .unsupportedMethodsOnly)
        let error = SSHTunnelErrors.authenticationFailed(rejection, usesPassword: true)
        #expect(error.message.contains("keyboard-interactive"))
    }

    @Test func partialSuccessIsNotReportedAsMethodNotAllowed() throws {
        // AuthenticationMethods password,publickey: the password is accepted, then only publickey remains.
        let delegate = passwordDelegate()
        #expect(ask(delegate, .all))
        #expect(!ask(delegate, .publicKey))
        let rejection = try #require(delegate.rejection)
        #expect(rejection.reason == .needsAdditionalMethod)
        let error = SSHTunnelErrors.authenticationFailed(rejection, usesPassword: true)
        #expect(error.message.contains("more than one sign-in step"))
        #expect(!(error.detail ?? "").contains("instead"))
    }

    @Test func methodNotOfferedAndRejectedSecret() throws {
        let notOffered = passwordDelegate()
        #expect(!ask(notOffered, .publicKey))
        #expect(notOffered.rejection?.reason == .methodNotOffered)
        #expect(SSHTunnelErrors.authenticationFailed(try #require(notOffered.rejection), usesPassword: true)
            .message == "The SSH server doesn’t allow password authentication (publickey).")

        let rejected = passwordDelegate()
        #expect(ask(rejected, .all))
        #expect(!ask(rejected, [.password, .publicKey]))
        #expect(rejected.rejection?.reason == .credentialRejected)
    }
}

// MARK: - Integration (needs the dbee-it-sshd container)

/// Records host key prompts and answers them with a fixed decision.
final class SSHRecordingVerifier: HostKeyVerifier, @unchecked Sendable {
    struct Prompt: Equatable {
        var host: String
        var port: Int
        var keyType: String
        var fingerprint: String
        var status: KnownHosts.Verdict
    }

    private let lock = NSLock()
    private var _prompts: [Prompt] = []
    let answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    var prompts: [Prompt] { lock.withLock { _prompts } }

    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool {
        let status: KnownHosts.Verdict = switch knownHostsStatus {
        case .trusted: .trusted
        case .unknown: .unknown
        case .mismatch: .mismatch
        }
        lock.withLock { _prompts.append(Prompt(host: host, port: port, keyType: keyType, fingerprint: fingerprint, status: status)) }
        return answer
    }

    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownKeyTypes: [String]) async -> Bool {
        lock.withLock {
            _prompts.append(Prompt(host: host, port: port, keyType: keyType, fingerprint: fingerprint,
                                   status: .otherKeyTypesKnown(knownKeyTypes)))
        }
        return answer
    }
}

private enum SSHIntegrationEnv {
    static let env = ProcessInfo.processInfo.environment
    static let port = env["DBEE_SSH_PORT"].flatMap(Int.init)
    static let host = env["DBEE_SSH_HOST"] ?? "127.0.0.1"
    static let user = env["DBEE_SSH_USER"] ?? "dbee"
    static let password = env["DBEE_SSH_PASSWORD"] ?? "dbee-ssh-password"
    static let passphrase = env["DBEE_SSH_PASSPHRASE"] ?? "dbee-passphrase"
    static let container = env["DBEE_SSH_CONTAINER"] ?? "dbee-it-sshd"
    static let keysDir = URL(fileURLWithPath: env["DBEE_SSH_KEYS_DIR"]
        ?? FileManager.default.currentDirectoryPath + "/../dbee-it-sshd/keys")
    /// Echo service inside the container (socat EXEC:cat).
    static let echoPort = 7777
    static let docker = "/usr/local/bin/docker"

    static var isEnabled: Bool { port != nil }

    static func config(password: String? = nil, key: String? = nil, passphrase: String = "") -> SSHConfig {
        var config = SSHConfig()
        config.enabled = true
        config.host = host
        config.port = port ?? 22
        config.username = user
        if let key {
            config.authMethod = .privateKey
            config.privateKeyPath = keysDir.appendingPathComponent(key).path
            config.passphrase = passphrase
        } else {
            config.authMethod = .password
            config.password = password ?? self.password
        }
        return config
    }

    /// known_hosts contents for the container, from ssh-keyscan (written to a temp file only).
    static func trustedKnownHosts() throws -> KnownHosts {
        KnownHosts(contents: try #require(keyscanOutput, "ssh-keyscan failed"))
    }

    /// Scanned once per run: every scan is an unauthenticated connection, which newer sshd versions penalize.
    private static let keyscanOutput: String? = try? SSHTestTools.run("/usr/bin/ssh-keyscan", ["-p", String(port ?? 22), host])

    /// Waits until sshd answers with its banner (it is restarted by the container after being killed).
    static func waitForSSHD(timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let socket = try? SSHTestSocket(host: host, port: port ?? 22),
               let banner = try? socket.read(upTo: 8), banner.starts(with: Array("SSH-".utf8)) {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw DatabaseError("sshd did not come back")
    }
}

@Suite("SSHTunnel integration", .serialized, .enabled(if: SSHIntegrationEnv.isEnabled, "Set DBEE_SSH_PORT to run"))
struct SSHTunnelIntegrationTests {
    init() throws {
        try SSHIntegrationEnv.waitForSSHD()
    }

    private func openEchoTunnel(_ config: SSHConfig, targetPort: Int = SSHIntegrationEnv.echoPort,
                                verifier: SSHRecordingVerifier = SSHRecordingVerifier(answer: false),
                                knownHosts: KnownHosts? = nil) async throws -> SSHTunnel {
        try await SSHTunnel.open(ssh: config, targetHost: "127.0.0.1", targetPort: targetPort, verifier: verifier,
                                 knownHosts: knownHosts ?? SSHIntegrationEnv.trustedKnownHosts())
    }

    /// Sends `payload`, half-closes, and reads the echo until EOF, on dedicated threads.
    private func roundTrip(_ tunnel: SSHTunnel, _ payload: [UInt8]) async throws -> [UInt8] {
        let port = tunnel.localPort
        return try await sshTestOnThread {
            let socket = try SSHTestSocket(host: "127.0.0.1", port: port)
            let writer = Thread {
                try? socket.write(payload)
                socket.shutdownWrite()
            }
            writer.start()
            return try socket.readToEOF()
        }
    }

    @Test func passwordAuthRoundTripAndHalfClose() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config())
        defer { Task { await tunnel.close() } }
        #expect(tunnel.localPort > 0)
        let echoed = try await roundTrip(tunnel, Array("hello through the tunnel".utf8))
        #expect(String(decoding: echoed, as: UTF8.self) == "hello through the tunnel")
        await tunnel.close()
    }

    @Test func serverFirstProtocol() async throws {
        // The SSH daemon itself speaks first, like MySQL's greeting.
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), targetPort: 22)
        let socket = try SSHTestSocket(host: "127.0.0.1", port: tunnel.localPort)
        let banner = try socket.read(upTo: 64)
        #expect(String(decoding: banner, as: UTF8.self).hasPrefix("SSH-2.0-"))
        await tunnel.close()
    }

    @Test(arguments: [
        ("id_ed25519", ""), ("id_rsa", ""), ("id_rsa_pem", ""), ("id_ecdsa", ""), ("id_ecdsa521", ""),
        ("id_ed25519_enc", "dbee-passphrase"), ("id_rsa_enc", "dbee-passphrase"), ("id_ecdsa384_enc", "dbee-passphrase"),
    ])
    func keyAuthentication(key: String, passphrase: String) async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(key: key, passphrase: passphrase))
        let echoed = try await roundTrip(tunnel, Array(key.utf8))
        #expect(echoed == Array(key.utf8))
        await tunnel.close()
    }

    @Test func largeTransferIsNotCorrupted() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(key: "id_ed25519"))
        var payload = [UInt8](repeating: 0, count: 6 * 1024 * 1024)
        for i in payload.indices { payload[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
        let echoed = try await roundTrip(tunnel, payload)
        #expect(echoed.count == payload.count)
        #expect(Data(SHA256.hash(data: echoed)) == Data(SHA256.hash(data: payload)))
        await tunnel.close()
    }

    @Test func manyConcurrentConnections() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config())
        let count = 24
        let results = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<count {
                group.addTask {
                    let payload = (0..<(64 * 1024 + i)).map { UInt8(truncatingIfNeeded: $0 &+ i) }
                    return (try? await self.roundTrip(tunnel, payload)) == payload
                }
            }
            var ok = 0
            for await success in group where success { ok += 1 }
            return ok
        }
        #expect(results == count)
        // Every forwarded connection is released once both ends have closed.
        let deadline = Date().addingTimeInterval(5)
        while tunnel.forwardedConnectionCount > 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tunnel.forwardedConnectionCount == 0)
        await tunnel.close()
    }

    @Test func wrongPasswordIsPermissionDenied() async throws {
        do {
            let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(password: "definitely-wrong"))
            await tunnel.close()
            Issue.record("Expected authentication to fail")
        } catch let error as DatabaseError {
            #expect(error.message.hasPrefix("Permission denied"))
            #expect(error.message.contains("password"))
        }
    }

    @Test func unauthorizedKeyIsPermissionDenied() async throws {
        do {
            let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(key: "id_unauthorized"))
            await tunnel.close()
            Issue.record("Expected authentication to fail")
        } catch let error as DatabaseError {
            #expect(error.message.hasPrefix("Permission denied"))
            #expect(error.detail?.contains("authorized_keys") == true)
        }
    }

    @Test func wrongPassphrase() async throws {
        do {
            let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(key: "id_ed25519_enc", passphrase: "nope"))
            await tunnel.close()
            Issue.record("Expected a passphrase error")
        } catch let error as DatabaseError {
            #expect(error.message.contains("Incorrect passphrase"))
        }
    }

    @Test func unknownHostIsPromptedAndDeclineFails() async throws {
        let verifier = SSHRecordingVerifier(answer: false)
        do {
            let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), verifier: verifier, knownHosts: KnownHosts())
            await tunnel.close()
            Issue.record("Expected the host key to be rejected")
        } catch let error as DatabaseError {
            #expect(error.message == "Host key rejected")
        }
        let prompt = try #require(verifier.prompts.first)
        #expect(verifier.prompts.count == 1)
        #expect(prompt.status == .unknown)
        #expect(prompt.host == SSHIntegrationEnv.host)
        #expect(prompt.port == SSHIntegrationEnv.port)
        #expect(prompt.keyType == "ED25519")
        let trusted = try SSHIntegrationEnv.trustedKnownHosts()
        let expected = trusted.entries.first { $0.key.algorithm == "ssh-ed25519" }?.key.fingerprint
        #expect(prompt.fingerprint == expected)
    }

    @Test func unknownHostAcceptedConnects() async throws {
        let verifier = SSHRecordingVerifier(answer: true)
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), verifier: verifier, knownHosts: KnownHosts())
        #expect(verifier.prompts.count == 1)
        #expect(try await roundTrip(tunnel, [1, 2, 3]) == [1, 2, 3])
        await tunnel.close()
    }

    @Test func trustedHostIsNotPrompted() async throws {
        let verifier = SSHRecordingVerifier(answer: false)
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), verifier: verifier)
        #expect(verifier.prompts.isEmpty)
        await tunnel.close()
    }

    @Test func changedHostKeyIsReportedAsMismatch() async throws {
        let dir = try SSHTestTools.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = try SSHTestTools.generateKey(in: dir, name: "impostor", type: "ed25519")
        let pub = try SSHTestTools.publicKeyLine(other)
        let name = KnownHosts.lookupName(host: SSHIntegrationEnv.host, port: SSHIntegrationEnv.port ?? 22)
        let knownHosts = KnownHosts(contents: "\(name) \(pub.type) \(pub.base64)\n")
        // Even a verifier that would say yes is never asked: a changed key always fails.
        let verifier = SSHRecordingVerifier(answer: true)
        do {
            let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), verifier: verifier, knownHosts: knownHosts)
            await tunnel.close()
            Issue.record("Expected the changed key to be refused")
        } catch let error as DatabaseError {
            #expect(error.message.contains("changed"))
            #expect(error.detail?.contains("ssh-keygen -R") == true)
        }
        #expect(verifier.prompts.isEmpty)
    }

    @Test func revokedHostKeyFailsWithoutPrompt() async throws {
        let trusted = try SSHIntegrationEnv.trustedKnownHosts()
        let serverKey = try #require(trusted.entries.first { $0.key.algorithm == "ssh-ed25519" }).key
        let revoked = KnownHosts.Entry(marker: .revoked, hosts: .patterns(["*"]), key: serverKey)
        let verifier = SSHRecordingVerifier(answer: true)
        do {
            let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), verifier: verifier,
                                                  knownHosts: KnownHosts(entries: trusted.entries + [revoked]))
            await tunnel.close()
            Issue.record("Expected the revoked key to be refused")
        } catch let error as DatabaseError {
            #expect(error.message.contains("revoked"))
            #expect(error.detail?.contains(serverKey.fingerprint) == true)
        }
        #expect(verifier.prompts.isEmpty)
    }

    @Test func hostKnownOnlyWithAnotherKeyTypeIsFlagged() async throws {
        // Like an old known_hosts that only has the server's ECDSA key, while Dbee negotiates Ed25519.
        let trusted = try SSHIntegrationEnv.trustedKnownHosts()
        let ecdsaOnly = KnownHosts(entries: trusted.entries.filter { $0.key.algorithm.hasPrefix("ecdsa-") })
        try #require(!ecdsaOnly.entries.isEmpty)
        let verifier = SSHRecordingVerifier(answer: false)
        await #expect(throws: DatabaseError.self) {
            let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), verifier: verifier, knownHosts: ecdsaOnly)
            await tunnel.close()
        }
        #expect(verifier.prompts.map(\.status) == [.otherKeyTypesKnown(["ECDSA"])])
        #expect(verifier.prompts.first?.keyType == "ED25519")
    }

    @Test func restrictedListenerOnlyForwardsAnnouncedConnections() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config())
        tunnel.restrictLocalConnections()
        let port = tunnel.localPort
        // An unannounced connection is closed without being forwarded.
        #expect(try await sshTestOnThread { try SSHTestSocket(host: "127.0.0.1", port: port).readToEOF() }.isEmpty)
        tunnel.allowNextLocalConnection()
        #expect(try await roundTrip(tunnel, [7, 8, 9]) == [7, 8, 9])
        // The allowance is used up.
        #expect(try await sshTestOnThread { try SSHTestSocket(host: "127.0.0.1", port: port).readToEOF() }.isEmpty)
        await tunnel.close()
    }

    @Test func forwardedChannelWorksWithoutTheListener() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config())
        let channel = try await tunnel.openForwardedChannel()
        let payload = Array("straight through SSH".utf8)
        let echoed = channel.eventLoop.makePromise(of: [UInt8].self)
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(SSHTestCollector(expected: payload.count, done: echoed))
        }.get()
        try await channel.writeAndFlush(ByteBuffer(bytes: payload)).get()
        #expect(try await echoed.futureResult.get() == payload)
        #expect(tunnel.forwardedConnectionCount == 1)
        await tunnel.close()
        // Closed with the SSH connection (NIOSSH fails the child's close future with tcpShutdown).
        try? await channel.closeFuture.get()
        #expect(!channel.isActive)
    }

    @Test func keepaliveLeavesAHealthyTunnelOpen() async throws {
        let tunnel = try await SSHTunnel.open(ssh: SSHIntegrationEnv.config(), targetHost: "127.0.0.1",
                                              targetPort: SSHIntegrationEnv.echoPort, verifier: SSHRecordingVerifier(answer: false),
                                              knownHosts: SSHIntegrationEnv.trustedKnownHosts(), keepaliveInterval: .milliseconds(100))
        let fired = SSHTestFlag()
        tunnel.onDisconnect { fired.set() }
        try await Task.sleep(for: .seconds(1.5))
        #expect(!fired.isSet)
        #expect(tunnel.isConnected)
        #expect(try await roundTrip(tunnel, [4, 5, 6]) == [4, 5, 6])
        await tunnel.close()
    }

    @Test func keepaliveDetectsAnUnresponsiveServer() async throws {
        // A relay in front of sshd that silently stops forwarding while keeping both TCP connections up,
        // like a hung server or a dead network path that TCP hasn't noticed yet.
        let frozen = SSHTestFlag()
        let relay = try await SSHTestRelay.start(to: SSHIntegrationEnv.host, port: SSHIntegrationEnv.port ?? 22, frozen: frozen)
        defer { relay.close(promise: nil) }
        var config = SSHIntegrationEnv.config()
        config.port = try #require(relay.localAddress?.port)
        let tunnel = try await SSHTunnel.open(ssh: config, targetHost: "127.0.0.1", targetPort: SSHIntegrationEnv.echoPort,
                                              verifier: SSHRecordingVerifier(answer: true), knownHosts: KnownHosts(),
                                              keepaliveInterval: .milliseconds(300))
        let fired = SSHTestFlag()
        tunnel.onDisconnect { fired.set() }
        #expect(try await roundTrip(tunnel, [1]) == [1])
        frozen.set()
        let deadline = Date().addingTimeInterval(5)
        while !fired.isSet && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fired.isSet)
        #expect(!tunnel.isConnected)
        await tunnel.close()
    }

    @Test func serverInitiatedRekeyNeverTruncatesSilently() async throws {
        // A second sshd in the container that re-keys after every 1 MB or 3 s, reached through a tunnel
        // to the stock sshd. NIOSSH can't send channel data during a key exchange, so a busy connection may
        // fail, but it must fail loudly: every round either echoes all bytes or the tunnel reports why.
        _ = try? SSHTestTools.run(SSHIntegrationEnv.docker, ["exec", SSHIntegrationEnv.container,
                                                             "/usr/sbin/sshd", "-p", "2222", "-o", "RekeyLimit=1M 3"])
        let outer = try await openEchoTunnel(SSHIntegrationEnv.config(), targetPort: 2222)
        var config = SSHIntegrationEnv.config(key: "id_ed25519")
        config.host = "127.0.0.1"
        config.port = outer.localPort
        let tunnel = try await SSHTunnel.open(ssh: config, targetHost: "127.0.0.1", targetPort: SSHIntegrationEnv.echoPort,
                                              verifier: SSHRecordingVerifier(answer: true), knownHosts: KnownHosts(),
                                              keepaliveInterval: .seconds(1))
        let disconnected = SSHTestFlag()
        tunnel.onDisconnect { disconnected.set() }
        var delivered = 0
        for round in 0..<4 {
            let payload = (0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ round) }
            let echoed = try? await roundTrip(tunnel, payload)
            if echoed == payload {
                delivered += 1
                continue
            }
            // Short or failed: the tunnel must say so rather than end with a clean, truncated stream.
            let deadline = Date().addingTimeInterval(5)
            while !disconnected.isSet && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(disconnected.isSet, "round \(round) lost data (\(echoed?.count ?? -1) of \(payload.count) bytes) without a disconnect")
            #expect(tunnel.lastForwardingFailure != nil || !tunnel.isConnected)
            break
        }
        print("rekey: \(delivered) of 4 rounds delivered intact; disconnected: \(disconnected.isSet)")
        await tunnel.close()
        await outer.close()
    }

    @Test func forwardingFailureClosesLocalConnection() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config(), targetPort: 1)
        let port = tunnel.localPort
        let received = try await sshTestOnThread { try SSHTestSocket(host: "127.0.0.1", port: port).readToEOF() }
        #expect(received.isEmpty)
        #expect(tunnel.lastForwardingFailure?.contains("127.0.0.1:1") == true)
        #expect(tunnel.isConnected)
        await tunnel.close()
    }

    @Test func closeIsIdempotentAndDoesNotReportDisconnect() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config())
        let fired = SSHTestFlag()
        tunnel.onDisconnect { fired.set() }
        let port = tunnel.localPort
        let openSocket = try SSHTestSocket(host: "127.0.0.1", port: port)
        #expect(try await roundTrip(tunnel, [42]) == [42])
        await tunnel.close()
        await tunnel.close()
        // Connections that were open are closed with the tunnel.
        #expect(try await sshTestOnThread { try openSocket.readToEOF() }.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fired.isSet)
        #expect(!tunnel.isConnected)
        #expect(throws: (any Error).self) { _ = try SSHTestSocket(host: "127.0.0.1", port: port) }
    }

    @Test func reachesOtherContainersOnTheDockerNetwork() async throws {
        // Optional: DBEE_SSH_ECHO_TARGET=<container>:<port> of an echo service on the same docker network.
        guard let target = SSHIntegrationEnv.env["DBEE_SSH_ECHO_TARGET"],
              let separator = target.lastIndex(of: ":"), let port = Int(target[target.index(after: separator)...])
        else { return }
        let tunnel = try await SSHTunnel.open(ssh: SSHIntegrationEnv.config(), targetHost: String(target[..<separator]),
                                              targetPort: port, verifier: SSHRecordingVerifier(answer: false),
                                              knownHosts: SSHIntegrationEnv.trustedKnownHosts())
        #expect(try await roundTrip(tunnel, Array("across the docker network".utf8)) == Array("across the docker network".utf8))
        await tunnel.close()
    }

    @Test(.sshdInUse) func onDisconnectFiresWhenSSHDIsKilled() async throws {
        let tunnel = try await openEchoTunnel(SSHIntegrationEnv.config())
        let socket = try SSHTestSocket(host: "127.0.0.1", port: tunnel.localPort)
        let fired = SSHTestFlag()
        tunnel.onDisconnect { fired.set() }
        try SSHTestTools.run(SSHIntegrationEnv.docker, ["exec", SSHIntegrationEnv.container, "pkill", "sshd"])
        let deadline = Date().addingTimeInterval(10)
        while !fired.isSet && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fired.isSet)
        #expect(!tunnel.isConnected)
        // Forwarded sockets are closed too, so drivers notice.
        #expect(try await sshTestOnThread { try socket.readToEOF() }.isEmpty)
        // Handlers registered after the drop run immediately.
        let late = SSHTestFlag()
        tunnel.onDisconnect { late.set() }
        #expect(late.isSet)
        await tunnel.close()
        try SSHIntegrationEnv.waitForSSHD()
    }
}

/// Collects bytes from a forwarded channel until `expected` have arrived.
final class SSHTestCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let expected: Int
    private let done: EventLoopPromise<[UInt8]>
    private var received: [UInt8] = []

    init(expected: Int, done: EventLoopPromise<[UInt8]>) {
        self.expected = expected
        self.done = done
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received += unwrapInboundIn(data).readableBytesView
        if received.count >= expected { done.succeed(received) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        done.fail(ChannelError.eof)
    }
}

/// A TCP relay on 127.0.0.1 that drops everything (without closing) once `frozen` is set.
enum SSHTestRelay {
    private final class Relay: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let frozen: SSHTestFlag
        var peer: Channel?
        var buffered: [ByteBuffer] = []

        init(frozen: SSHTestFlag) { self.frozen = frozen }

        func connect(_ peer: Channel) {
            self.peer = peer
            buffered.forEach { peer.write($0, promise: nil) }
            peer.flush()
            buffered.removeAll()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !frozen.isSet else { return }
            let bytes = unwrapInboundIn(data)
            if let peer { peer.writeAndFlush(bytes, promise: nil) } else { buffered.append(bytes) }
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer?.close(promise: nil)
        }
    }

    static func start(to host: String, port: Int, frozen: SSHTestFlag) async throws -> Channel {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        return try await ServerBootstrap(group: loop)
            .childChannelInitializer { inbound in
                let toServer = Relay(frozen: frozen)
                do {
                    try inbound.pipeline.syncOperations.addHandler(toServer)
                } catch {
                    return inbound.eventLoop.makeFailedFuture(error)
                }
                let box = SSHTunnelUncheckedBox(value: toServer)
                return ClientBootstrap(group: inbound.eventLoop)
                    .channelInitializer { outbound in
                        let toClient = Relay(frozen: frozen)
                        toClient.connect(inbound)
                        return outbound.pipeline.addHandler(toClient)
                    }
                    .connect(host: host, port: port)
                    .map { outbound in box.value.connect(outbound) }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }
}

/// Runs blocking socket work on its own thread so the Swift concurrency pool never blocks.
func sshTestOnThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try work() }) }.start()
    }
}

final class SSHTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Small blocking TCP client used to exercise the tunnel like a database driver would.
final class SSHTestSocket: @unchecked Sendable {
    private let fd: Int32

    init(host: String, port: Int, timeout: TimeInterval = 10) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError("socket() failed") }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw DatabaseError("connect() failed: \(errno)")
        }
    }

    deinit { Darwin.close(fd) }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw DatabaseError("send() failed: \(errno)") }
            offset += n
        }
    }

    func shutdownWrite() {
        Darwin.shutdown(fd, SHUT_WR)
    }

    /// Reads at most `count` bytes (blocking until at least one arrives or EOF).
    func read(upTo count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let n = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, count, 0) }
        guard n >= 0 else { throw DatabaseError("recv() failed: \(errno)") }
        return Array(buffer.prefix(n))
    }

    func readToEOF() throws -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if n == 0 { return result }
            if n < 0 {
                if errno == ECONNRESET { return result }
                throw DatabaseError("recv() failed: \(errno)")
            }
            result += buffer.prefix(n)
        }
    }
}

/// Tests that kill the test sshd must not run while other suites hold tunnels through it (the end-to-end
/// suite runs in parallel with this one). Both take this lock: the end-to-end suite for its whole run.
struct SSHDInUseTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await SSHDLock.shared.acquire()
        do {
            try await function()
        } catch {
            await SSHDLock.shared.release()
            throw error
        }
        await SSHDLock.shared.release()
    }
}

extension Trait where Self == SSHDInUseTrait {
    static var sshdInUse: Self { SSHDInUseTrait() }
}

actor SSHDLock {
    static let shared = SSHDLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { isHeld = false } else { waiters.removeFirst().resume() }
    }
}
