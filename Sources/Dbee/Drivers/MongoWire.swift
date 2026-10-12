import CommonCrypto
import CryptoKit
import Foundation
import NIOCore

/// MongoDB's wire protocol: OP_MSG requests and replies (MongoDB 3.6 and later).
enum MongoWire {
    static let opMsg: Int32 = 2013
    static let opReply: Int32 = 1
    /// Larger than any reply the server sends (its limit is 48 MB per message).
    static let maxMessageSize = 64 * 1024 * 1024

    /// An OP_MSG with a single body section.
    static func message(_ document: BSONDocument, requestID: Int32) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(Int32(0), endianness: .little)
        buffer.writeInteger(requestID, endianness: .little)
        buffer.writeInteger(Int32(0), endianness: .little)
        buffer.writeInteger(opMsg, endianness: .little)
        buffer.writeInteger(UInt32(0), endianness: .little)
        buffer.writeInteger(UInt8(0))
        document.encode(into: &buffer)
        buffer.setInteger(Int32(buffer.writerIndex), at: 0, endianness: .little)
        return buffer
    }

    /// One complete reply's body document, or nil when more bytes are needed.
    static func parseReply(_ buffer: inout ByteBuffer) throws -> (responseTo: Int32, body: BSONDocument)? {
        guard buffer.readableBytes >= 16,
              let length = buffer.getInteger(at: buffer.readerIndex, endianness: .little, as: Int32.self) else { return nil }
        guard length >= 21, Int(length) <= maxMessageSize else {
            throw WireConnection.Failure.malformed("a message of \(length) bytes")
        }
        guard buffer.readableBytes >= Int(length), var message = buffer.readSlice(length: Int(length)) else { return nil }
        message.moveReaderIndex(forwardBy: 8)
        guard let responseTo = message.readInteger(endianness: .little, as: Int32.self),
              let opCode = message.readInteger(endianness: .little, as: Int32.self) else {
            throw WireConnection.Failure.malformed("a short message header")
        }
        switch opCode {
        case opMsg:
            guard let flags = message.readInteger(endianness: .little, as: UInt32.self) else {
                throw WireConnection.Failure.malformed("a short message")
            }
            let end = message.writerIndex - (flags & 1 != 0 ? 4 : 0)
            var body: BSONDocument?
            while message.readerIndex < end {
                guard let kind = message.readInteger(as: UInt8.self) else { break }
                if kind == 0 {
                    let document = try BSONDocument.decode(from: &message)
                    if body == nil { body = document }
                } else {
                    guard let size = message.getInteger(at: message.readerIndex, endianness: .little, as: Int32.self),
                          size >= 4 else { throw WireConnection.Failure.malformed("a bad message section") }
                    message.moveReaderIndex(forwardBy: Int(size))
                }
            }
            guard let body else { throw WireConnection.Failure.malformed("a reply without a body") }
            return (responseTo, body)
        case opReply:
            message.moveReaderIndex(forwardBy: 20)
            return (responseTo, try BSONDocument.decode(from: &message))
        default:
            throw WireConnection.Failure.malformed("message type \(opCode)")
        }
    }
}

/// SCRAM-SHA-256 and SCRAM-SHA-1 (RFC 5802 / 7677), the way MongoDB uses them.
struct MongoSCRAM {
    enum Mechanism: String {
        case sha256 = "SCRAM-SHA-256"
        case sha1 = "SCRAM-SHA-1"
    }

    let mechanism: Mechanism
    let username: String
    let password: String
    let clientNonce: String

    init(mechanism: Mechanism, username: String, password: String,
         clientNonce: String = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()) {
        self.mechanism = mechanism
        self.username = username
        self.password = password
        self.clientNonce = clientNonce
    }

    var clientFirstBare: String {
        let name = username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        return "n=\(name),r=\(clientNonce)"
    }

    var clientFirst: [UInt8] { Array(("n,," + clientFirstBare).utf8) }

    /// The client-final message for the server's first message, and the server signature to expect back.
    func clientFinal(serverFirst: String) throws -> (message: [UInt8], serverSignature: Data) {
        let fields = Self.fields(serverFirst)
        guard let nonce = fields["r"], nonce.hasPrefix(clientNonce),
              let saltText = fields["s"], let salt = Data(base64Encoded: saltText),
              let iterationText = fields["i"], let iterations = Int(iterationText), iterations > 0 else {
            throw DatabaseError("MongoDB sent an unexpected authentication reply.")
        }
        let secret: String = switch mechanism {
        case .sha1: Insecure.MD5.hash(data: Data("\(username):mongo:\(password)".utf8)).map { String(format: "%02x", $0) }.joined()
        case .sha256: password
        }
        let salted = try pbkdf2(Data(secret.utf8), salt: salt, iterations: iterations)
        let clientKey = hmac(salted, Data("Client Key".utf8))
        let storedKey = hash(clientKey)
        let withoutProof = "c=biws,r=\(nonce)"
        let authMessage = Data("\(clientFirstBare),\(serverFirst),\(withoutProof)".utf8)
        let signature = hmac(storedKey, authMessage)
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
        let serverKey = hmac(salted, Data("Server Key".utf8))
        let serverSignature = hmac(serverKey, authMessage)
        return (Array("\(withoutProof),p=\(proof.base64EncodedString())".utf8), serverSignature)
    }

    static func fields(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in message.split(separator: ",") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            result[String(part[..<equals])] = String(part[part.index(after: equals)...])
        }
        return result
    }

    private func hmac(_ key: Data, _ message: Data) -> Data {
        switch mechanism {
        case .sha256: Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case .sha1: Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        }
    }

    private func hash(_ data: Data) -> Data {
        switch mechanism {
        case .sha256: Data(SHA256.hash(data: data))
        case .sha1: Data(Insecure.SHA1.hash(data: data))
        }
    }

    private func pbkdf2(_ password: Data, salt: Data, iterations: Int) throws -> Data {
        let length = mechanism == .sha256 ? 32 : 20
        let algorithm = CCPseudoRandomAlgorithm(mechanism == .sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1)
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         algorithm, UInt32(iterations),
                                         output.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw DatabaseError("Couldn't derive the login key.") }
        return derived
    }
}
