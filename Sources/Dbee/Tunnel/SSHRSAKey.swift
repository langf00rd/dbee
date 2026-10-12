import Foundation
import Crypto
import _CryptoExtras
import NIOCore
import NIOSSH

/// Hash used for an RSA user-auth signature. OpenSSH 8.8+ rejects SHA-1 ("ssh-rsa") signatures by default,
/// so Dbee offers "rsa-sha2-256" first and only falls back to "ssh-rsa" for very old servers.
protocol SSHRSAHashScheme {
    /// Algorithm name used in the auth request and signature blob.
    static var algorithmName: String { get }
    static func digest<D: DataProtocol>(_ data: D) -> any Digest
}

enum SSHRSASHA256: SSHRSAHashScheme {
    static let algorithmName = "rsa-sha2-256"
    static func digest<D: DataProtocol>(_ data: D) -> any Digest { SHA256.hash(data: data) }
}

enum SSHRSASHA1: SSHRSAHashScheme {
    static let algorithmName = "ssh-rsa"
    static func digest<D: DataProtocol>(_ data: D) -> any Digest { Insecure.SHA1.hash(data: data) }
}

/// RSA public key whose wire blob is `e, n` and whose algorithm name follows the hash scheme.
///
/// OpenSSH parses an "rsa-sha2-256" key blob as a plain RSA key, so the same blob layout works for both
/// algorithm names.
struct SSHRSAPublicKey<Scheme: SSHRSAHashScheme>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Scheme.algorithmName }

    let modulus: [UInt8]
    let publicExponent: [UInt8]

    var rawRepresentation: Data {
        var writer = SSHWireWriter()
        writer.writeMPInt(publicExponent)
        writer.writeMPInt(modulus)
        return Data(writer.bytes)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? SSHRSASignature<Scheme>,
              let key = try? _RSA.Signing.PublicKey(n: modulus, e: publicExponent)
        else { return false }
        return Self.verify(key, signature: _RSA.Signing.RSASignature(rawRepresentation: signature.rawRepresentation),
                           digest: Scheme.digest(data))
    }

    private static func verify(_ key: _RSA.Signing.PublicKey, signature: _RSA.Signing.RSASignature, digest: some Digest) -> Bool {
        key.isValidSignature(signature, for: digest, padding: .insecurePKCS1v1_5)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        let raw = rawRepresentation
        return buffer.writeBytes(raw)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        let bytes = Array(buffer.readableBytesView)
        var reader = SSHWireReader(bytes)
        guard let e = reader.readMPInt(), let n = reader.readMPInt() else {
            throw DatabaseError("Invalid RSA public key")
        }
        buffer.moveReaderIndex(forwardBy: reader.offset)
        return Self(modulus: n, publicExponent: e)
    }
}

struct SSHRSASignature<Scheme: SSHRSAHashScheme>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Scheme.algorithmName }

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        var writer = SSHWireWriter()
        writer.writeString(Array(rawRepresentation))
        return buffer.writeBytes(writer.bytes)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        let bytes = Array(buffer.readableBytesView)
        var reader = SSHWireReader(bytes)
        guard let raw = reader.readString() else { throw DatabaseError("Invalid RSA signature") }
        buffer.moveReaderIndex(forwardBy: reader.offset)
        return Self(rawRepresentation: Data(raw))
    }
}

/// RSA private key that signs with PKCS#1 v1.5 over the scheme's hash.
struct SSHRSAPrivateKey<Scheme: SSHRSAHashScheme>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Scheme.algorithmName }

    private let key: _RSA.Signing.PrivateKey
    private let typedPublicKey: SSHRSAPublicKey<Scheme>

    init(key: _RSA.Signing.PrivateKey, modulus: [UInt8], publicExponent: [UInt8]) {
        self.key = key
        self.typedPublicKey = SSHRSAPublicKey(modulus: modulus, publicExponent: publicExponent)
    }

    var publicKey: NIOSSHPublicKeyProtocol { typedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signature = try Self.sign(key, digest: Scheme.digest(data))
        return SSHRSASignature<Scheme>(rawRepresentation: signature.rawRepresentation)
    }

    private static func sign(_ key: _RSA.Signing.PrivateKey, digest: some Digest) throws -> _RSA.Signing.RSASignature {
        try key.signature(for: digest, padding: .insecurePKCS1v1_5)
    }
}

enum SSHRSAKeys {
    /// Auth keys to offer for one RSA key, preferred algorithm first.
    static func signingKeys(_ key: _RSA.Signing.PrivateKey, modulus: [UInt8], publicExponent: [UInt8]) -> [NIOSSHPrivateKey] {
        [
            NIOSSHPrivateKey(custom: SSHRSAPrivateKey<SSHRSASHA256>(key: key, modulus: modulus, publicExponent: publicExponent)),
            NIOSSHPrivateKey(custom: SSHRSAPrivateKey<SSHRSASHA1>(key: key, modulus: modulus, publicExponent: publicExponent)),
        ]
    }

    /// OpenSSH wire blob ("ssh-rsa", e, n) used for comparisons and fingerprints.
    static func publicBlob(modulus: [UInt8], publicExponent: [UInt8]) -> [UInt8] {
        var writer = SSHWireWriter()
        writer.writeString("ssh-rsa")
        writer.writeMPInt(publicExponent)
        writer.writeMPInt(modulus)
        return writer.bytes
    }
}
