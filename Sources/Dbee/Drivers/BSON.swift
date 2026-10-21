import Foundation
import NIOCore

/// A BSON value, as MongoDB stores and sends it.
indirect enum BSONValue: Equatable, Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(subtype: UInt8, data: [UInt8])
    case undefined
    case objectId([UInt8])
    case bool(Bool)
    /// Milliseconds since 1970.
    case date(Int64)
    case null
    case regex(pattern: String, options: String)
    case javascript(String)
    case int32(Int32)
    case timestamp(UInt64)
    case int64(Int64)
    case decimal128([UInt8])
    case minKey
    case maxKey

    var document: BSONDocument? {
        if case .document(let document) = self { return document }
        return nil
    }

    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// Any numeric value that is a whole number Int can hold, as an Int. A fractional or out-of-range
    /// double is nil rather than truncated or trapping.
    var int: Int? {
        switch self {
        case .int32(let value): Int(value)
        case .int64(let value): Int(value)
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .int32, .int64: int.map { $0 != 0 }
        case .double(let value): value != 0
        default: nil
        }
    }

    var array: [BSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// A short name for the type, as `$type` and the structure view use them.
    var typeName: String {
        switch self {
        case .double: "double"
        case .string: "string"
        case .document: "object"
        case .array: "array"
        case .binary: "binData"
        case .undefined: "undefined"
        case .objectId: "objectId"
        case .bool: "bool"
        case .date: "date"
        case .null: "null"
        case .regex: "regex"
        case .javascript: "javascript"
        case .int32: "int"
        case .timestamp: "timestamp"
        case .int64: "long"
        case .decimal128: "decimal"
        case .minKey: "minKey"
        case .maxKey: "maxKey"
        }
    }
}

/// An ordered BSON document. Field order matters to MongoDB (the command name comes first).
struct BSONDocument: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    var fields: [(key: String, value: BSONValue)] = []

    init() {}

    init(_ fields: [(String, BSONValue)]) {
        self.fields = fields.map { (key: $0.0, value: $0.1) }
    }

    init(dictionaryLiteral elements: (String, BSONValue)...) {
        fields = elements.map { (key: $0.0, value: $0.1) }
    }

    static func == (lhs: BSONDocument, rhs: BSONDocument) -> Bool {
        lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    var isEmpty: Bool { fields.isEmpty }
    var keys: [String] { fields.map(\.key) }

    subscript(key: String) -> BSONValue? {
        get { fields.first { $0.key == key }?.value }
        set {
            if let index = fields.firstIndex(where: { $0.key == key }) {
                if let newValue { fields[index].value = newValue } else { fields.remove(at: index) }
            } else if let newValue {
                fields.append((key: key, value: newValue))
            }
        }
    }

    // MARK: Encoding

    func encode(into buffer: inout ByteBuffer) {
        let start = buffer.writerIndex
        buffer.writeInteger(Int32(0), endianness: .little)
        for (key, value) in fields {
            Self.encode(key: key, value: value, into: &buffer)
        }
        buffer.writeInteger(UInt8(0))
        buffer.setInteger(Int32(buffer.writerIndex - start), at: start, endianness: .little)
    }

    private static func cString(_ text: String, into buffer: inout ByteBuffer) {
        // Keys can't contain NUL; cut there rather than writing a corrupt document.
        buffer.writeBytes(text.utf8.prefix { $0 != 0 })
        buffer.writeInteger(UInt8(0))
    }

    private static func encode(key: String, value: BSONValue, into buffer: inout ByteBuffer) {
        func header(_ type: UInt8) {
            buffer.writeInteger(type)
            cString(key, into: &buffer)
        }
        switch value {
        case .double(let number):
            header(0x01)
            buffer.writeInteger(number.bitPattern, endianness: .little)
        case .string(let text):
            header(0x02)
            writeString(text, into: &buffer)
        case .document(let document):
            header(0x03)
            document.encode(into: &buffer)
        case .array(let items):
            header(0x04)
            BSONDocument(items.enumerated().map { (String($0.offset), $0.element) }).encode(into: &buffer)
        case .binary(let subtype, let data):
            header(0x05)
            buffer.writeInteger(Int32(data.count), endianness: .little)
            buffer.writeInteger(subtype)
            buffer.writeBytes(data)
        case .undefined:
            header(0x06)
        case .objectId(let bytes):
            header(0x07)
            buffer.writeBytes(bytes.count == 12 ? bytes : Array(bytes.prefix(12)) + Array(repeating: 0, count: max(0, 12 - bytes.count)))
        case .bool(let flag):
            header(0x08)
            buffer.writeInteger(UInt8(flag ? 1 : 0))
        case .date(let milliseconds):
            header(0x09)
            buffer.writeInteger(milliseconds, endianness: .little)
        case .null:
            header(0x0A)
        case .regex(let pattern, let options):
            header(0x0B)
            cString(pattern, into: &buffer)
            cString(String(options.sorted()), into: &buffer)
        case .javascript(let code):
            header(0x0D)
            writeString(code, into: &buffer)
        case .int32(let number):
            header(0x10)
            buffer.writeInteger(number, endianness: .little)
        case .timestamp(let stamp):
            header(0x11)
            buffer.writeInteger(stamp, endianness: .little)
        case .int64(let number):
            header(0x12)
            buffer.writeInteger(number, endianness: .little)
        case .decimal128(let bytes):
            header(0x13)
            buffer.writeBytes(bytes.count == 16 ? bytes : Array(repeating: 0, count: 16))
        case .minKey:
            header(0xFF)
        case .maxKey:
            header(0x7F)
        }
    }

    private static func writeString(_ text: String, into buffer: inout ByteBuffer) {
        let bytes = Array(text.utf8)
        buffer.writeInteger(Int32(bytes.count + 1), endianness: .little)
        buffer.writeBytes(bytes)
        buffer.writeInteger(UInt8(0))
    }

    // MARK: Decoding

    /// Reads one document, moving the reader index past it.
    static func decode(from buffer: inout ByteBuffer) throws -> BSONDocument {
        guard let length = buffer.getInteger(at: buffer.readerIndex, endianness: .little, as: Int32.self),
              length >= 5, buffer.readableBytes >= Int(length),
              var body = buffer.readSlice(length: Int(length)) else {
            throw malformed("truncated document")
        }
        body.moveReaderIndex(forwardBy: 4)
        var document = BSONDocument()
        while true {
            guard let type = body.readInteger(as: UInt8.self) else { throw malformed("unterminated document") }
            if type == 0 { break }
            let key = try readCString(&body)
            document.fields.append((key: key, value: try readValue(type: type, from: &body)))
        }
        return document
    }

    private static func malformed(_ reason: String) -> WireConnection.Failure {
        .malformed("invalid BSON (\(reason))")
    }

    private static func readCString(_ buffer: inout ByteBuffer) throws -> String {
        guard let end = buffer.readableBytesView.firstIndex(of: 0) else { throw malformed("unterminated string") }
        let text = buffer.readString(length: end - buffer.readerIndex) ?? ""
        buffer.moveReaderIndex(forwardBy: 1)
        return text
    }

    private static func readString(_ buffer: inout ByteBuffer) throws -> String {
        guard let length = buffer.readInteger(endianness: .little, as: Int32.self), length >= 1,
              let bytes = buffer.readBytes(length: Int(length)) else { throw malformed("bad string") }
        return String(decoding: bytes.dropLast(), as: UTF8.self)
    }

    private static func readValue(type: UInt8, from buffer: inout ByteBuffer) throws -> BSONValue {
        func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
            guard let value = buffer.readInteger(endianness: .little, as: T.self) else { throw malformed("truncated number") }
            return value
        }
        switch type {
        case 0x01: return .double(Double(bitPattern: try integer(UInt64.self)))
        case 0x02, 0x0E: return .string(try readString(&buffer))
        case 0x03: return .document(try decode(from: &buffer))
        case 0x04: return .array(try decode(from: &buffer).fields.map(\.value))
        case 0x05:
            let length = try integer(Int32.self)
            guard length >= 0, let subtype = buffer.readInteger(as: UInt8.self),
                  let data = buffer.readBytes(length: Int(length)) else { throw malformed("bad binary") }
            return .binary(subtype: subtype, data: data)
        case 0x06: return .undefined
        case 0x07:
            guard let bytes = buffer.readBytes(length: 12) else { throw malformed("bad ObjectId") }
            return .objectId(bytes)
        case 0x08: return .bool(try integer(UInt8.self) != 0)
        case 0x09: return .date(try integer(Int64.self))
        case 0x0A: return .null
        case 0x0B: return .regex(pattern: try readCString(&buffer), options: try readCString(&buffer))
        case 0x0C:
            // DBPointer (deprecated): namespace and ObjectId.
            let namespace = try readString(&buffer)
            guard let id = buffer.readBytes(length: 12) else { throw malformed("bad DBPointer") }
            return .document(["$ref": .string(namespace), "$id": .objectId(id)])
        case 0x0D: return .javascript(try readString(&buffer))
        case 0x0F:
            // Code with scope: total length, code, scope document. The scope is dropped for display.
            _ = try integer(Int32.self)
            let code = try readString(&buffer)
            _ = try decode(from: &buffer)
            return .javascript(code)
        case 0x10: return .int32(try integer(Int32.self))
        case 0x11: return .timestamp(try integer(UInt64.self))
        case 0x12: return .int64(try integer(Int64.self))
        case 0x13:
            guard let bytes = buffer.readBytes(length: 16) else { throw malformed("bad Decimal128") }
            return .decimal128(bytes)
        case 0xFF: return .minKey
        case 0x7F: return .maxKey
        default: throw malformed("unknown type 0x\(String(type, radix: 16))")
        }
    }
}

// MARK: - Display

/// Shell-style text for BSON values: what the grid, the inspector and exports show.
enum BSONFormatting {
    /// A grid cell. Strings, numbers and booleans are shown as they are; documents and arrays as JSON in
    /// MongoDB's relaxed Extended JSON (so the inspector can pretty-print them); null as NULL.
    static func cell(_ value: BSONValue) -> CellValue {
        switch value {
        case .null, .undefined: nil
        case .string(let text): text
        case .objectId(let bytes): hex(bytes)
        case .date(let milliseconds): isoDate(milliseconds)
        case .document, .array: json(value)
        case .double(let number): number.isFinite ? jsonNumber(number) : String(number)
        case .int32(let number): String(number)
        case .int64(let number): String(number)
        case .bool(let flag): flag ? "true" : "false"
        case .decimal128(let bytes): Decimal128.string(bytes)
        case .binary(_, let data): "\\x" + hex(data)
        default: json(value)
        }
    }

    /// Relaxed Extended JSON, compact.
    static func json(_ value: BSONValue) -> String {
        switch value {
        case .double(let number):
            if number.isNaN { return #"{"$numberDouble": "NaN"}"# }
            if number.isInfinite { return #"{"$numberDouble": "\#(number < 0 ? "-" : "")Infinity"}"# }
            return jsonNumber(number)
        case .string(let text): return quote(text)
        case .document(let document): return json(document)
        case .array(let items): return "[" + items.map(json).joined(separator: ", ") + "]"
        case .binary(let subtype, let data):
            return #"{"$binary": {"base64": \#(quote(Data(data).base64EncodedString())), "subType": "\#(String(format: "%02x", subtype))"}}"#
        case .undefined: return #"{"$undefined": true}"#
        case .objectId(let bytes): return #"{"$oid": "\#(hex(bytes))"}"#
        case .bool(let flag): return flag ? "true" : "false"
        case .date(let milliseconds): return #"{"$date": "\#(isoDate(milliseconds))"}"#
        case .null: return "null"
        case .regex(let pattern, let options):
            return #"{"$regularExpression": {"pattern": \#(quote(pattern)), "options": \#(quote(options))}}"#
        case .javascript(let code): return #"{"$code": \#(quote(code))}"#
        case .int32(let number): return String(number)
        case .int64(let number): return String(number)
        case .timestamp(let stamp): return #"{"$timestamp": {"t": \#(stamp >> 32), "i": \#(stamp & 0xFFFF_FFFF)}}"#
        case .decimal128(let bytes): return #"{"$numberDecimal": "\#(Decimal128.string(bytes))"}"#
        case .minKey: return #"{"$minKey": 1}"#
        case .maxKey: return #"{"$maxKey": 1}"#
        }
    }

    static func json(_ document: BSONDocument) -> String {
        "{" + document.fields.map { quote($0.key) + ": " + json($0.value) }.joined(separator: ", ") + "}"
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isoDate(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return isoFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func jsonNumber(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(format: "%.1f", number) }
        return String(number)
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// IEEE 754-2008 decimal128 as MongoDB stores it (binary integer decimal encoding).
enum Decimal128 {
    static func string(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "NaN" }
        var low: UInt64 = 0
        var high: UInt64 = 0
        for i in 0..<8 { low |= UInt64(bytes[i]) << (8 * UInt64(i)) }
        for i in 0..<8 { high |= UInt64(bytes[8 + i]) << (8 * UInt64(i)) }
        let negative = high >> 63 == 1
        let combination = (high >> 58) & 0x1F
        if combination == 0x1F { return "NaN" }
        if combination == 0x1E { return negative ? "-Infinity" : "Infinity" }
        let exponent: Int
        var coefficientHigh: UInt64
        if (high >> 61) & 0x3 == 0x3 {
            // Non-canonical large coefficient: treated as zero.
            exponent = Int((high >> 47) & 0x3FFF) - 6176
            coefficientHigh = 0
            low = 0
        } else {
            exponent = Int((high >> 49) & 0x3FFF) - 6176
            coefficientHigh = high & 0x1_FFFF_FFFF_FFFF
        }
        // 113-bit coefficient to decimal digits by repeated division.
        var digits: [UInt8] = []
        var parts = [UInt32(coefficientHigh >> 32), UInt32(coefficientHigh & 0xFFFF_FFFF),
                     UInt32(low >> 32), UInt32(low & 0xFFFF_FFFF)]
        while parts.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for i in parts.indices {
                let value = (remainder << 32) | UInt64(parts[i])
                parts[i] = UInt32(value / 10)
                remainder = value % 10
            }
            digits.append(UInt8(remainder))
        }
        if digits.isEmpty { digits = [0] }
        var text = String(digits.reversed().map { Character(String($0)) })
        if exponent < 0 {
            let point = text.count + exponent
            if point > 0 {
                text.insert(".", at: text.index(text.startIndex, offsetBy: point))
            } else if point > -6 {
                text = "0." + String(repeating: "0", count: -point) + text
            } else {
                text += "E\(exponent)"
            }
        } else if exponent > 0 {
            text += "E+\(exponent)"
        }
        return (negative ? "-" : "") + text
    }

    /// Parses a plain decimal ("12.50", "-3E+2") into decimal128 bytes, or nil when it doesn't fit.
    static func bytes(_ text: String) -> [UInt8]? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if s.hasPrefix("-") { negative = true; s = s.dropFirst() } else if s.hasPrefix("+") { s = s.dropFirst() }
        var exponent = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let value = Int(s[s.index(after: e)...]) else { return nil }
            exponent = value
            s = s[..<e]
        }
        var digits = ""
        if let dot = s.firstIndex(of: ".") {
            let fraction = s[s.index(after: dot)...]
            digits = String(s[..<dot]) + fraction
            let (adjusted, overflow) = exponent.subtractingReportingOverflow(fraction.count)
            guard !overflow else { return nil }
            exponent = adjusted
        } else {
            digits = String(s)
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), digits.count <= 34 else { return nil }
        let (biased, overflow) = exponent.addingReportingOverflow(6176)
        guard !overflow, (0...0x2FFF).contains(biased) else { return nil }
        // Coefficient as a 128-bit number.
        var high: UInt64 = 0
        var low: UInt64 = 0
        for digit in digits.utf8 {
            let d = UInt64(digit - 0x30)
            // (high, low) = (high, low) * 10 + d
            let lowProduct = low.multipliedFullWidth(by: 10)
            let (newLow, carry) = lowProduct.low.addingReportingOverflow(d)
            high = high &* 10 &+ lowProduct.high &+ (carry ? 1 : 0)
            low = newLow
        }
        high |= UInt64(biased) << 49
        if negative { high |= 1 << 63 }
        var bytes: [UInt8] = []
        for i in 0..<8 { bytes.append(UInt8((low >> (8 * UInt64(i))) & 0xFF)) }
        for i in 0..<8 { bytes.append(UInt8((high >> (8 * UInt64(i))) & 0xFF)) }
        return bytes
    }
}
