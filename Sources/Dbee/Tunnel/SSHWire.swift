import Foundation

/// Minimal reader for the SSH binary encoding (RFC 4251 §5): uint32, string and mpint.
struct SSHWireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 { value = value << 8 | UInt32(bytes[offset + i]) }
        offset += 4
        return value
    }

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// Reads an SSH `string` (uint32 length + bytes).
    mutating func readString() -> [UInt8]? {
        let start = offset
        guard let length = readUInt32(), let value = readBytes(count: Int(length)) else {
            offset = start
            return nil
        }
        return value
    }

    mutating func readUTF8() -> String? {
        readString().flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Reads an SSH `mpint` as an unsigned big-endian magnitude without leading zero bytes.
    mutating func readMPInt() -> [UInt8]? {
        guard let raw = readString() else { return nil }
        return Array(raw.drop(while: { $0 == 0 }))
    }

    /// Checks for and consumes a fixed prefix.
    mutating func consume(_ prefix: [UInt8]) -> Bool {
        guard remaining >= prefix.count, Array(bytes[offset..<offset + prefix.count]) == prefix else { return false }
        offset += prefix.count
        return true
    }
}

/// Minimal writer for the SSH binary encoding.
struct SSHWireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeUInt32(_ value: UInt32) {
        bytes += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    mutating func writeString<C: Collection>(_ value: C) where C.Element == UInt8 {
        writeUInt32(UInt32(value.count))
        bytes += value
    }

    mutating func writeString(_ value: String) {
        writeString(Array(value.utf8))
    }

    /// Writes an unsigned big-endian magnitude as a positive SSH `mpint`.
    mutating func writeMPInt<C: Collection>(_ magnitude: C) where C.Element == UInt8 {
        let trimmed = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = trimmed.first, first & 0x80 != 0 {
            writeString([0] + trimmed)
        } else {
            writeString(trimmed)
        }
    }
}

extension Array where Element == UInt8 {
    /// Best-effort overwrite of secret material before the buffer is released.
    mutating func secureWipe() {
        for i in indices { self[i] = 0 }
        removeAll()
    }
}

extension Data {
    /// Best-effort overwrite of secret material before the buffer is released.
    mutating func secureWipe() {
        resetBytes(in: startIndex..<endIndex)
        removeAll()
    }
}
