import Foundation
import Crypto
import _CryptoExtras
import CCitadelBcrypt
import NIOSSH

/// A private key read from disk and ready for SSH public key authentication. Held in memory only.
struct SSHLoadedKey {
    /// Keys to offer, in order. RSA keys offer "rsa-sha2-256" first and legacy "ssh-rsa" second.
    var signingKeys: [NIOSSHPrivateKey]
    /// Key algorithm, e.g. "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256".
    var algorithm: String
    /// OpenSSH wire-format public key blob.
    var publicKeyBlob: [UInt8]
}

/// Reads private key files at connect time. Never caches keys, never writes anything.
///
/// Supported: OpenSSH format ("BEGIN OPENSSH PRIVATE KEY") with Ed25519, RSA and ECDSA P-256/384/521 keys,
/// unencrypted or encrypted with bcrypt + aes{128,192,256}-{ctr,cbc} / aes{128,256}-gcm; and unencrypted
/// legacy PEM / PKCS#8 RSA, EC and Ed25519 keys.
enum SSHKeyLoader {
    static let maxKeyFileSize = 64 * 1024

    /// Expands a leading "~" or "~/" to the user's real home directory.
    static func expandTilde(_ path: String) -> String {
        if path == "~" { return KnownHosts.userHomeDirectory.path }
        if path.hasPrefix("~/") {
            return KnownHosts.userHomeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return (path as NSString).expandingTildeInPath
    }

    static func load(path rawPath: String, passphrase: String) throws -> SSHLoadedKey {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError("Choose a private key file for SSH.")
        }
        let path = expandTilde(trimmed)
        let name = (path as NSString).lastPathComponent

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DatabaseError("The private key file “\(name)” wasn’t found.",
                                detail: "Check the key path in the SSH settings.")
        }
        guard !isDirectory.boolValue else {
            throw DatabaseError("“\(name)” is a folder, not a private key file.")
        }

        var bytes: [UInt8]
        do {
            var data = try Data(contentsOf: URL(fileURLWithPath: path), options: .uncached)
            bytes = [UInt8](data)
            data.secureWipe()
        } catch {
            throw DatabaseError("Dbee couldn’t read the private key file “\(name)”.",
                                detail: "Make sure the file is readable by your user account.")
        }
        defer { bytes.secureWipe() }
        guard bytes.count <= maxKeyFileSize else {
            throw DatabaseError("“\(name)” doesn’t look like a private key file.", detail: "The file is too large.")
        }
        return try parse(bytes, passphrase: passphrase, displayPath: trimmed)
    }

    /// Parses key file contents. `displayPath` is only used to build conversion hints in error messages.
    static func parse(_ bytes: [UInt8], passphrase: String, displayPath: String = "<key file>") throws -> SSHLoadedKey {
        let trimmed = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (displayPath as NSString).lastPathComponent

        if trimmed.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            var der = try pemBody(trimmed, label: "OPENSSH PRIVATE KEY", name: name)
            defer { der.secureWipe() }
            return try OpenSSHKeyParser.parse(der, passphrase: passphrase, displayPath: displayPath)
        }
        if trimmed.hasPrefix("PuTTY-User-Key-File-") {
            throw DatabaseError("PuTTY keys (.ppk) aren’t supported.",
                                detail: "Convert it to OpenSSH format with: puttygen \"\(displayPath)\" -O private-openssh-new -o <new file>")
        }
        if trimmed.hasPrefix("---- BEGIN SSH2") {
            throw DatabaseError("SSH2 (RFC 4716) private keys aren’t supported.",
                                detail: "Convert it to OpenSSH format, for example with PuTTYgen or ssh-keygen -i.")
        }
        for prefix in ["ssh-", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-"] where trimmed.hasPrefix(prefix) {
            throw DatabaseError("“\(name)” is a public key.",
                                detail: "Choose the matching private key file (usually the same name without “.pub”).")
        }
        if trimmed.contains("-----BEGIN DSA PRIVATE KEY-----") {
            throw DatabaseError("DSA keys aren’t supported.",
                                detail: "OpenSSH has removed DSA support. Generate a new key with: ssh-keygen -t ed25519")
        }
        if trimmed.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
            throw DatabaseError("This key uses a legacy encrypted PEM format that Dbee doesn’t support.",
                                detail: "Convert it to the OpenSSH format (keeping your passphrase) with: ssh-keygen -p -f \"\(displayPath)\"")
        }
        if trimmed.contains("-----BEGIN RSA PRIVATE KEY-----")
            || trimmed.contains("-----BEGIN EC PRIVATE KEY-----")
            || trimmed.contains("-----BEGIN PRIVATE KEY-----") {
            return try parsePEM(trimmed, displayPath: displayPath)
        }
        throw DatabaseError("“\(name)” isn’t a recognized private key.",
                            detail: "Use an OpenSSH private key (Ed25519, ECDSA or RSA), e.g. ~/.ssh/id_ed25519.")
    }

    // MARK: PEM helpers

    static func pemBody(_ text: String, label: String, name: String) throws -> [UInt8] {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            throw DatabaseError("The private key file “\(name)” is incomplete or damaged.")
        }
        let base64 = text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)) else {
            throw DatabaseError("The private key file “\(name)” is damaged.", detail: "Its contents aren’t valid base64.")
        }
        return Array(data)
    }

    /// Unencrypted legacy PEM (PKCS#1 RSA, SEC1 EC) and PKCS#8 keys.
    private static func parsePEM(_ text: String, displayPath: String) throws -> SSHLoadedKey {
        let name = (displayPath as NSString).lastPathComponent
        if text.contains("-----BEGIN PRIVATE KEY-----") {
            var der = try pemBody(text, label: "PRIVATE KEY", name: name)
            defer { der.secureWipe() }
            // PKCS#8 Ed25519: SEQ { INT 0, SEQ { OID 1.3.101.112 }, OCTET STRING { OCTET STRING (32) } }
            let ed25519Prefix: [UInt8] = [0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70,
                                          0x04, 0x22, 0x04, 0x20]
            if der.count == ed25519Prefix.count + 32, Array(der.prefix(ed25519Prefix.count)) == ed25519Prefix {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))
                return ed25519(key)
            }
        }
        if let key = try? _RSA.Signing.PrivateKey(unsafePEMRepresentation: text) {
            return try rsa(key)
        }
        // EC keys: parse the SEC1 structure directly, because ssh-keygen builds linked against LibreSSL
        // write explicit curve parameters that CryptoKit's PEM initializers reject.
        for label in ["EC PRIVATE KEY", "PRIVATE KEY"] where text.contains("-----BEGIN \(label)-----") {
            var der = try pemBody(text, label: label, name: name)
            defer { der.secureWipe() }
            if var info = SSHKeyDER.ecPrivateKey(fromSEC1OrPKCS8: der) {
                defer { info.scalar.secureWipe() }
                if let key = try? ecdsa(info) { return key }
            }
        }
        throw DatabaseError("Dbee couldn’t read the PEM private key “\(name)”.",
                            detail: "Convert it to the OpenSSH format with: ssh-keygen -p -f \"\(displayPath)\"")
    }

    /// Builds an ECDSA key from a SEC1 private key, checking it against the embedded public key if present.
    private static func ecdsa(_ info: SSHKeyDER.ECPrivateKeyInfo) throws -> SSHLoadedKey {
        let loaded: SSHLoadedKey
        let point: Data
        switch info.curveByteCount {
        case 32:
            let key = try P256.Signing.PrivateKey(rawRepresentation: leftPadded(info.scalar, to: 32))
            point = key.publicKey.x963Representation
            loaded = ecdsa(NIOSSHPrivateKey(p256Key: key), algorithm: "ecdsa-sha2-nistp256", curve: "nistp256", point: point)
        case 48:
            let key = try P384.Signing.PrivateKey(rawRepresentation: leftPadded(info.scalar, to: 48))
            point = key.publicKey.x963Representation
            loaded = ecdsa(NIOSSHPrivateKey(p384Key: key), algorithm: "ecdsa-sha2-nistp384", curve: "nistp384", point: point)
        case 66:
            let key = try P521.Signing.PrivateKey(rawRepresentation: leftPadded(info.scalar, to: 66))
            point = key.publicKey.x963Representation
            loaded = ecdsa(NIOSSHPrivateKey(p521Key: key), algorithm: "ecdsa-sha2-nistp521", curve: "nistp521", point: point)
        default:
            throw DatabaseError("Unsupported elliptic curve")
        }
        if let expected = info.publicPoint, Array(point) != expected {
            throw DatabaseError("The EC private key doesn’t match its public key")
        }
        return loaded
    }

    /// Restores leading zero bytes that some encoders drop from fixed-size scalars.
    static func leftPadded(_ magnitude: [UInt8], to length: Int) throws -> [UInt8] {
        let trimmed = Array(magnitude.drop(while: { $0 == 0 }))
        guard trimmed.count <= length else { throw DatabaseError("Invalid elliptic curve private key") }
        return [UInt8](repeating: 0, count: length - trimmed.count) + trimmed
    }

    // MARK: Building loaded keys

    static func ed25519(_ key: Curve25519.Signing.PrivateKey) -> SSHLoadedKey {
        var writer = SSHWireWriter()
        writer.writeString("ssh-ed25519")
        writer.writeString(Array(key.publicKey.rawRepresentation))
        return SSHLoadedKey(signingKeys: [NIOSSHPrivateKey(ed25519Key: key)], algorithm: "ssh-ed25519", publicKeyBlob: writer.bytes)
    }

    static func ecdsa(_ key: NIOSSHPrivateKey, algorithm: String, curve: String, point: Data) -> SSHLoadedKey {
        var writer = SSHWireWriter()
        writer.writeString(algorithm)
        writer.writeString(curve)
        writer.writeString(Array(point))
        return SSHLoadedKey(signingKeys: [key], algorithm: algorithm, publicKeyBlob: writer.bytes)
    }

    static func rsa(_ key: _RSA.Signing.PrivateKey) throws -> SSHLoadedKey {
        let primitives = try key.publicKey.getKeyPrimitives()
        let n = Array(primitives.modulus)
        let e = Array(primitives.publicExponent)
        return SSHLoadedKey(signingKeys: SSHRSAKeys.signingKeys(key, modulus: n, publicExponent: e),
                            algorithm: "ssh-rsa",
                            publicKeyBlob: SSHRSAKeys.publicBlob(modulus: n, publicExponent: e))
    }
}

/// Parser for the "openssh-key-v1" private key container (PROTOCOL.key in the OpenSSH sources).
enum OpenSSHKeyParser {
    private static let magic = Array("openssh-key-v1\0".utf8)

    private struct Cipher {
        enum Mode { case none, ctr, cbc, gcm }
        var mode: Mode
        var keyLength: Int
        var ivLength: Int
        var blockSize: Int
        var tagLength: Int

        init?(name: String) {
            switch name {
            case "none": self.init(.none, key: 0, iv: 0, block: 8)
            case "aes128-ctr": self.init(.ctr, key: 16, iv: 16, block: 16)
            case "aes192-ctr": self.init(.ctr, key: 24, iv: 16, block: 16)
            case "aes256-ctr": self.init(.ctr, key: 32, iv: 16, block: 16)
            case "aes128-cbc": self.init(.cbc, key: 16, iv: 16, block: 16)
            case "aes192-cbc": self.init(.cbc, key: 24, iv: 16, block: 16)
            case "aes256-cbc": self.init(.cbc, key: 32, iv: 16, block: 16)
            case "aes128-gcm@openssh.com": self.init(.gcm, key: 16, iv: 12, block: 16, tag: 16)
            case "aes256-gcm@openssh.com": self.init(.gcm, key: 32, iv: 12, block: 16, tag: 16)
            default: return nil
            }
        }

        private init(_ mode: Mode, key: Int, iv: Int, block: Int, tag: Int = 0) {
            self.mode = mode
            keyLength = key
            ivLength = iv
            blockSize = block
            tagLength = tag
        }
    }

    static func parse(_ blob: [UInt8], passphrase: String, displayPath: String) throws -> SSHLoadedKey {
        let name = (displayPath as NSString).lastPathComponent
        let damaged = DatabaseError("The private key file “\(name)” is damaged or not a valid OpenSSH key.")

        var reader = SSHWireReader(blob)
        guard reader.consume(magic),
              let cipherName = reader.readUTF8(),
              let kdfName = reader.readUTF8(),
              let kdfOptions = reader.readString(),
              let keyCount = reader.readUInt32()
        else { throw damaged }
        guard keyCount == 1 else {
            throw DatabaseError("Key files containing several keys aren’t supported.")
        }
        guard let publicBlob = reader.readString(), let encryptedLength = reader.readUInt32() else { throw damaged }

        guard let cipher = Cipher(name: cipherName) else {
            throw DatabaseError("This key is encrypted with “\(cipherName)”, which Dbee doesn’t support.",
                                detail: "Re-encrypt it with AES (keeping your passphrase) using: ssh-keygen -p -Z aes256-ctr -f \"\(displayPath)\"")
        }
        guard var section = reader.readBytes(count: Int(encryptedLength)),
              let tag = reader.readBytes(count: cipher.tagLength)
        else { throw damaged }
        defer { section.secureWipe() }

        if cipher.mode != .none {
            guard kdfName == "bcrypt" else {
                throw DatabaseError("This key uses the “\(kdfName)” key derivation, which Dbee doesn’t support.")
            }
            guard !passphrase.isEmpty else {
                throw DatabaseError("This private key is protected by a passphrase.",
                                    detail: "Enter the key’s passphrase in the SSH settings and connect again.")
            }
            var options = SSHWireReader(kdfOptions)
            guard let salt = options.readString(), let rounds = options.readUInt32(), rounds > 0 else { throw damaged }
            guard section.count % cipher.blockSize == 0 else { throw damaged }

            var derived = try bcryptPBKDF(passphrase: passphrase, salt: salt, rounds: rounds,
                                          length: cipher.keyLength + cipher.ivLength)
            defer { derived.secureWipe() }
            let key = SymmetricKey(data: derived.prefix(cipher.keyLength))
            let iv = Array(derived.suffix(cipher.ivLength))
            do {
                var plaintext = try decrypt(section, tag: tag, cipher: cipher, key: key, iv: iv)
                section.secureWipe()
                section = Array(plaintext)
                plaintext.secureWipe()
            } catch {
                throw wrongPassphrase
            }
        }

        var body = SSHWireReader(section)
        guard let check1 = body.readUInt32(), let check2 = body.readUInt32() else { throw damaged }
        guard check1 == check2 else {
            throw cipher.mode == .none ? damaged : wrongPassphrase
        }
        guard let keyType = body.readUTF8() else { throw damaged }

        let loaded = try parsePrivateKey(type: keyType, reader: &body, damaged: damaged)
        guard loaded.publicKeyBlob == publicBlob else {
            throw DatabaseError("The private key file “\(name)” is damaged.",
                                detail: "Its public and private parts don’t match.")
        }
        return loaded
    }

    private static var wrongPassphrase: DatabaseError {
        DatabaseError("Incorrect passphrase for the private key.", detail: "Check the passphrase and try again.")
    }

    private static func parsePrivateKey(type: String, reader: inout SSHWireReader, damaged: DatabaseError) throws -> SSHLoadedKey {
        switch type {
        case "ssh-ed25519":
            guard let publicKey = reader.readString(), publicKey.count == 32,
                  var secret = reader.readString(), secret.count == 64
            else { throw damaged }
            defer { secret.secureWipe() }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
            guard Array(key.publicKey.rawRepresentation) == publicKey else { throw damaged }
            return SSHKeyLoader.ed25519(key)

        case "ssh-rsa":
            guard let n = reader.readMPInt(), let e = reader.readMPInt(),
                  var d = reader.readMPInt(), var iqmp = reader.readMPInt(),
                  var p = reader.readMPInt(), var q = reader.readMPInt()
            else { throw damaged }
            defer {
                d.secureWipe()
                iqmp.secureWipe()
                p.secureWipe()
                q.secureWipe()
            }
            guard let key = try? _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q) else { throw damaged }
            return try SSHKeyLoader.rsa(key)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let curve = reader.readUTF8(), let point = reader.readString(), var scalar = reader.readMPInt() else {
                throw damaged
            }
            defer { scalar.secureWipe() }
            switch curve {
            case "nistp256":
                let key = try P256.Signing.PrivateKey(rawRepresentation: SSHKeyLoader.leftPadded(scalar, to: 32))
                guard Array(key.publicKey.x963Representation) == point else { throw damaged }
                return SSHKeyLoader.ecdsa(NIOSSHPrivateKey(p256Key: key), algorithm: type, curve: curve, point: key.publicKey.x963Representation)
            case "nistp384":
                let key = try P384.Signing.PrivateKey(rawRepresentation: SSHKeyLoader.leftPadded(scalar, to: 48))
                guard Array(key.publicKey.x963Representation) == point else { throw damaged }
                return SSHKeyLoader.ecdsa(NIOSSHPrivateKey(p384Key: key), algorithm: type, curve: curve, point: key.publicKey.x963Representation)
            case "nistp521":
                let key = try P521.Signing.PrivateKey(rawRepresentation: SSHKeyLoader.leftPadded(scalar, to: 66))
                guard Array(key.publicKey.x963Representation) == point else { throw damaged }
                return SSHKeyLoader.ecdsa(NIOSSHPrivateKey(p521Key: key), algorithm: type, curve: curve, point: key.publicKey.x963Representation)
            default:
                throw damaged
            }

        case "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com":
            throw DatabaseError("Hardware security keys (FIDO/U2F) aren’t supported for SSH tunnels.",
                                detail: "Use an Ed25519, ECDSA or RSA key stored in a file.")
        case "ssh-dss":
            throw DatabaseError("DSA keys aren’t supported.",
                                detail: "OpenSSH has removed DSA support. Generate a new key with: ssh-keygen -t ed25519")
        default:
            throw DatabaseError("The key type “\(type)” isn’t supported.",
                                detail: "Use an Ed25519, ECDSA or RSA key.")
        }
    }

    private static func decrypt(_ ciphertext: [UInt8], tag: [UInt8], cipher: Cipher, key: SymmetricKey, iv: [UInt8]) throws -> Data {
        switch cipher.mode {
        case .none:
            return Data(ciphertext)
        case .ctr:
            return try AES._CTR.decrypt(ciphertext, using: key, nonce: AES._CTR.Nonce(nonceBytes: iv))
        case .cbc:
            return try AES._CBC.decrypt(ciphertext, using: key, iv: AES._CBC.IV(ivBytes: iv), noPadding: true)
        case .gcm:
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        }
    }

    // MARK: bcrypt_pbkdf

    private static let installSHA512: Void = {
        citadel_set_crypto_hash_sha512 { output, input, length in
            guard let output else { return }
            let digest = SHA512.hash(data: UnsafeRawBufferPointer(start: input, count: Int(length)))
            digest.withUnsafeBytes { raw in
                output.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: SHA512.byteCount)
            }
        }
    }()

    /// OpenSSH's bcrypt_pbkdf, via the C implementation bundled with Citadel.
    static func bcryptPBKDF(passphrase: String, salt: [UInt8], rounds: UInt32, length: Int) throws -> [UInt8] {
        _ = installSHA512
        var password = Array(passphrase.utf8)
        defer { password.secureWipe() }
        var output = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pass in
            salt.withUnsafeBufferPointer { salt in
                citadel_bcrypt_pbkdf(pass.baseAddress, pass.count, salt.baseAddress, salt.count, &output, length, rounds)
            }
        }
        guard status == 0 else {
            output.secureWipe()
            throw DatabaseError("Couldn’t derive the key from the passphrase.")
        }
        return output
    }
}

/// Just enough DER to pull the private scalar out of SEC1 ("EC PRIVATE KEY") and PKCS#8 EC keys.
enum SSHKeyDER {
    private struct Node {
        var tag: UInt8
        var content: ArraySlice<UInt8>
    }

    /// Reads one TLV from the start of `bytes`, returning it and the remaining bytes.
    private static func read(_ bytes: ArraySlice<UInt8>) -> (Node, ArraySlice<UInt8>)? {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { return nil }
        let tag = bytes[index]
        index += 1
        guard index < bytes.endIndex else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, bytes.endIndex - index >= count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard bytes.endIndex - index >= length else { return nil }
        let content = bytes[index..<index + length]
        return (Node(tag: tag, content: content), bytes[(index + length)...])
    }

    private static func children(_ content: ArraySlice<UInt8>) -> [Node] {
        var nodes: [Node] = []
        var rest = content
        while !rest.isEmpty, let (node, remaining) = read(rest) {
            nodes.append(node)
            rest = remaining
        }
        return nodes
    }

    struct ECPrivateKeyInfo {
        var scalar: [UInt8]
        /// Uncompressed public point, when the encoding includes it.
        var publicPoint: [UInt8]?
        /// Field element size in bytes: 32 (P-256), 48 (P-384) or 66 (P-521).
        var curveByteCount: Int
    }

    /// SEC1: SEQUENCE { INTEGER 1, OCTET STRING key, [0] params?, [1] BIT STRING publicKey? }
    /// PKCS#8: SEQUENCE { INTEGER 0, SEQUENCE { OID ecPublicKey, params }, OCTET STRING { SEC1 } }
    static func ecPrivateKey(fromSEC1OrPKCS8 der: [UInt8], outerParameters: [UInt8]? = nil) -> ECPrivateKeyInfo? {
        guard let (outer, _) = read(der[...]), outer.tag == 0x30 else { return nil }
        let fields = children(outer.content)
        guard fields.count >= 2, fields[0].tag == 0x02 else { return nil }

        if fields[0].content.elementsEqual([0]), fields.count >= 3, fields[1].tag == 0x30, fields[2].tag == 0x04 {
            // id-ecPublicKey 1.2.840.10045.2.1
            let ecPublicKeyOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
            let algorithm = children(fields[1].content)
            guard algorithm.count == 2, algorithm[0].tag == 0x06, algorithm[0].content.elementsEqual(ecPublicKeyOID) else {
                return nil
            }
            var parameters = [algorithm[1].tag] + encodedLength(algorithm[1].content.count)
            parameters += algorithm[1].content
            return ecPrivateKey(fromSEC1OrPKCS8: Array(fields[2].content), outerParameters: parameters)
        }

        guard fields[0].content.elementsEqual([1]), fields[1].tag == 0x04 else { return nil }
        let scalar = Array(fields[1].content)
        var publicPoint: [UInt8]?
        var parameters = outerParameters.flatMap { read($0[...])?.0 }
        for field in fields.dropFirst(2) {
            switch field.tag {
            case 0xA0:
                parameters = read(field.content)?.0
            case 0xA1:
                if let (bits, _) = read(field.content), bits.tag == 0x03, bits.content.first == 0 {
                    publicPoint = Array(bits.content.dropFirst())
                }
            default:
                break
            }
        }

        let size: Int? = if let publicPoint, publicPoint.first == 0x04 {
            (publicPoint.count - 1) / 2
        } else if let parameters {
            curveByteCount(parameters)
        } else {
            nil
        }
        guard let size = size ?? [32, 48, 66].first(where: { scalar.count <= $0 }) else { return nil }
        return ECPrivateKeyInfo(scalar: scalar, publicPoint: publicPoint, curveByteCount: size)
    }

    /// Curve size from named-curve OID or explicit parameters (via the prime's length).
    private static func curveByteCount(_ parameters: Node) -> Int? {
        if parameters.tag == 0x06 {
            switch Array(parameters.content) {
            case [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]: return 32  // prime256v1
            case [0x2B, 0x81, 0x04, 0x00, 0x22]: return 48                    // secp384r1
            case [0x2B, 0x81, 0x04, 0x00, 0x23]: return 66                    // secp521r1
            default: return nil
            }
        }
        // ECParameters ::= SEQUENCE { version, fieldID SEQUENCE { OID, prime INTEGER }, ... }
        guard parameters.tag == 0x30 else { return nil }
        let items = children(parameters.content)
        guard items.count >= 2, items[1].tag == 0x30 else { return nil }
        let field = children(items[1].content)
        guard field.count >= 2, field[1].tag == 0x02 else { return nil }
        return field[1].content.drop(while: { $0 == 0 }).count
    }

    private static func encodedLength(_ length: Int) -> [UInt8] {
        guard length >= 0x80 else { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
