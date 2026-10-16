import Foundation

/// A parsed JSON value that keeps object keys in the order the server sent them (JSONSerialization doesn't,
/// which would shuffle a result grid's columns) and numbers as written, so large integers stay exact.
indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number's literal text.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var object: JSONObject? { if case .object(let o) = self { o } else { nil } }
    var int: Int? {
        if case .number(let text) = self { return Int(text) ?? Double(text).flatMap { Int(exactly: $0) } }
        return nil
    }

    /// A grid cell: strings without quotes, null as NULL, arrays and objects as compact JSON.
    var cell: CellValue {
        switch self {
        case .null: nil
        case .bool(let value): value ? "true" : "false"
        case .number(let text): text
        case .string(let text): text
        case .array, .object: json
        }
    }

    /// Compact JSON, with a space after `:` and `,` so it reads well in a cell.
    var json: String {
        var out = ""
        write(to: &out, indent: nil, level: 0)
        return out
    }

    /// JSON indented by two spaces.
    var pretty: String {
        var out = ""
        write(to: &out, indent: "  ", level: 0)
        return out
    }

    /// "array", "object", "string"…, for a column's inferred type.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private func write(to out: inout String, indent: String?, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): out += Self.quote(text)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: indent, count: level + 1) }
                item.write(to: &out, indent: indent, level: level + 1)
            }
            if let indent { out += "\n" + String(repeating: indent, count: level) }
            out += "]"
        case .object(let object):
            guard !object.fields.isEmpty else { out += "{}"; return }
            out += "{"
            for (index, field) in object.fields.enumerated() {
                if index > 0 { out += indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: indent, count: level + 1) }
                out += Self.quote(field.key) + ": "
                field.value.write(to: &out, indent: indent, level: level + 1)
            }
            if let indent { out += "\n" + String(repeating: indent, count: level) }
            out += "}"
        }
    }

    /// A JSON string literal for `text`.
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

    // MARK: Parsing

    struct ParseError: LocalizedError {
        var message: String
        var offset: Int
        var errorDescription: String? { "\(message) at byte \(offset + 1)" }
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Array(text.utf8))
    }

    static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.i == bytes.count else { throw ParseError(message: "Unexpected text after the JSON value", offset: parser.i) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWhitespace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        func fail(_ message: String) -> ParseError { ParseError(message: message, offset: i) }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw fail("JSON nested too deeply") }
            guard i < bytes.count else { throw fail("Unexpected end of JSON") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var fields: [JSONObject.Field] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(JSONObject(fields: fields)) }
                while true {
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("Expected a key") }
                    let key = try string()
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("Expected “:”") }
                    i += 1
                    skipWhitespace()
                    fields.append(JSONObject.Field(key: key, value: try value(depth: depth + 1)))
                    skipWhitespace()
                    guard i < bytes.count else { throw fail("Unexpected end of JSON") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(JSONObject(fields: fields)) }
                    throw fail("Expected “,” or “}”")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [JSONValue] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    items.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard i < bytes.count else { throw fail("Unexpected end of JSON") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw fail("Expected “,” or “]”")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                let start = i
                if bytes[i] == UInt8(ascii: "-") { i += 1 }
                let isNumberByte: (UInt8) -> Bool = {
                    ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e")
                        || $0 == UInt8(ascii: "E") || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-")
                }
                while i < bytes.count, isNumberByte(bytes[i]) { i += 1 }
                let text = String(decoding: bytes[start..<i], as: UTF8.self)
                guard Double(text) != nil else { i = start; throw fail("Bad number") }
                return .number(text)
            default:
                throw fail("Unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let utf8 = Array(word.utf8)
            guard i + utf8.count <= bytes.count, Array(bytes[i..<(i + utf8.count)]) == utf8 else { throw fail("Unexpected word") }
            i += utf8.count
        }

        mutating func string() throws -> String {
            i += 1
            var out: [UInt8] = []
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c != UInt8(ascii: "\\") {
                    out.append(c)
                    i += 1
                    continue
                }
                guard i + 1 < bytes.count else { break }
                let escape = bytes[i + 1]
                i += 2
                switch escape {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), i + 1 < bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8))
                default: out.append(escape)
                }
            }
            throw fail("Unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
                throw fail("Bad \\u escape")
            }
            i += 4
            return value
        }
    }
}

/// A JSON object's fields in their original order.
struct JSONObject: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var key: String
        var value: JSONValue
    }

    var fields: [Field]

    var keys: [String] { fields.map(\.key) }

    subscript(key: String) -> JSONValue? {
        fields.first { $0.key == key }?.value
    }
}
