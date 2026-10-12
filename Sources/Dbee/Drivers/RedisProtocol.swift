import Foundation
import NIOCore

/// A reply in the Redis serialization protocol. RESP3 types are read too, in case a server sends them
/// unasked, and folded into their RESP2 shapes.
indirect enum RESPValue: Equatable, Sendable {
    case simple(String)
    case error(String)
    case integer(Int64)
    case bulk([UInt8]?)
    case array([RESPValue]?)
    case double(Double)

    var string: String? {
        switch self {
        case .simple(let text), .error(let text): text
        case .integer(let value): String(value)
        case .double(let value): RedisFormatting.number(value)
        case .bulk(let bytes?): String(decoding: bytes, as: UTF8.self)
        case .bulk(nil), .array: nil
        }
    }

    var integer: Int64? {
        switch self {
        case .integer(let value): value
        case .bulk, .simple: string.flatMap { Int64($0) }
        default: nil
        }
    }

    var elements: [RESPValue] {
        if case .array(let items?) = self { return items }
        return []
    }
}

enum RESPParser {
    /// Parses one complete reply, or returns nil (leaving `buffer` as it was) when more bytes are needed.
    static func parse(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        var copy = buffer
        guard let value = try value(&copy) else { return nil }
        buffer = copy
        return value
    }

    private static func value(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        guard let type = buffer.readInteger(as: UInt8.self), let line = readLine(&buffer) else { return nil }
        switch type {
        case UInt8(ascii: "+"):
            return .simple(line)
        case UInt8(ascii: "-"), UInt8(ascii: "!"):
            if type == UInt8(ascii: "!") {
                guard let count = Int(line), let bytes = readBlob(&buffer, count: count) else { return nil }
                return .error(String(decoding: bytes, as: UTF8.self))
            }
            return .error(line)
        case UInt8(ascii: ":"):
            guard let value = Int64(line) else { throw WireConnection.Failure.malformed("bad integer “\(line)”") }
            return .integer(value)
        case UInt8(ascii: "("):
            return .bulk(Array(line.utf8))
        case UInt8(ascii: ","):
            return .double(Double(line) ?? .nan)
        case UInt8(ascii: "#"):
            return .integer(line == "t" ? 1 : 0)
        case UInt8(ascii: "_"):
            return .bulk(nil)
        case UInt8(ascii: "$"), UInt8(ascii: "="):
            guard let count = Int(line) else { throw WireConnection.Failure.malformed("bad length “\(line)”") }
            if count < 0 { return .bulk(nil) }
            guard var bytes = readBlob(&buffer, count: count) else { return nil }
            // Verbatim strings start with a three-letter format and a colon ("txt:").
            if type == UInt8(ascii: "="), bytes.count >= 4 { bytes.removeFirst(4) }
            return .bulk(bytes)
        case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"), UInt8(ascii: "%"), UInt8(ascii: "|"):
            guard var count = Int(line) else { throw WireConnection.Failure.malformed("bad length “\(line)”") }
            if count < 0 { return .array(nil) }
            // Maps and attributes hold key/value pairs; they become flat arrays as in RESP2.
            if type == UInt8(ascii: "%") || type == UInt8(ascii: "|") { count *= 2 }
            var items: [RESPValue] = []
            items.reserveCapacity(min(count, 1024))
            for _ in 0..<count {
                guard let item = try value(&buffer) else { return nil }
                items.append(item)
            }
            // An attribute only annotates the reply that follows it.
            if type == UInt8(ascii: "|") { return try value(&buffer) }
            return .array(items)
        default:
            throw WireConnection.Failure.malformed("unknown reply type “\(Character(Unicode.Scalar(type)))”")
        }
    }

    private static func readLine(_ buffer: inout ByteBuffer) -> String? {
        let view = buffer.readableBytesView
        guard let cr = view.firstIndex(of: UInt8(ascii: "\r")), view.index(after: cr) < view.endIndex,
              view[view.index(after: cr)] == UInt8(ascii: "\n") else { return nil }
        let length = cr - view.startIndex
        let line = buffer.readString(length: length) ?? ""
        buffer.moveReaderIndex(forwardBy: 2)
        return line
    }

    private static func readBlob(_ buffer: inout ByteBuffer, count: Int) -> [UInt8]? {
        guard buffer.readableBytes >= count + 2, let bytes = buffer.readBytes(length: count) else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)
        return bytes
    }

    /// A command as a RESP array of bulk strings.
    static func encode(_ arguments: [[UInt8]], into buffer: inout ByteBuffer) {
        buffer.writeString("*\(arguments.count)\r\n")
        for argument in arguments {
            buffer.writeString("$\(argument.count)\r\n")
            buffer.writeBytes(argument)
            buffer.writeString("\r\n")
        }
    }
}

/// Splits a line typed in the query editor into command arguments the way redis-cli does: words separated
/// by spaces, "double quotes" with backslash escapes (\n, \t, \xHH, \"…) and 'single quotes' where only
/// \' is special.
enum RedisCommandLine {
    static func arguments(_ line: String) throws -> [[UInt8]] {
        var arguments: [[UInt8]] = []
        let bytes = Array(line.utf8)
        var i = 0
        let n = bytes.count

        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func hexValue(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x41...0x46: c - 0x41 + 10
            case 0x61...0x66: c - 0x61 + 10
            default: nil
            }
        }

        while i < n {
            while i < n, isSpace(bytes[i]) { i += 1 }
            guard i < n else { break }
            var argument: [UInt8] = []
            while i < n, !isSpace(bytes[i]) {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    var closed = false
                    while i < n {
                        let q = bytes[i]
                        if q == UInt8(ascii: "\\"), i + 1 < n {
                            let e = bytes[i + 1]
                            switch e {
                            case UInt8(ascii: "n"): argument.append(0x0A); i += 2
                            case UInt8(ascii: "r"): argument.append(0x0D); i += 2
                            case UInt8(ascii: "t"): argument.append(0x09); i += 2
                            case UInt8(ascii: "b"): argument.append(0x08); i += 2
                            case UInt8(ascii: "a"): argument.append(0x07); i += 2
                            case UInt8(ascii: "x") where i + 3 < n:
                                if let high = hexValue(bytes[i + 2]), let low = hexValue(bytes[i + 3]) {
                                    argument.append(high << 4 | low)
                                    i += 4
                                } else {
                                    argument.append(e)
                                    i += 2
                                }
                            default: argument.append(e); i += 2
                            }
                        } else if q == UInt8(ascii: "\"") {
                            i += 1
                            closed = true
                            break
                        } else {
                            argument.append(q)
                            i += 1
                        }
                    }
                    guard closed else { throw DatabaseError("Unbalanced quotes in the command.") }
                } else if c == UInt8(ascii: "'") {
                    i += 1
                    var closed = false
                    while i < n {
                        let q = bytes[i]
                        if q == UInt8(ascii: "\\"), i + 1 < n, bytes[i + 1] == UInt8(ascii: "'") {
                            argument.append(UInt8(ascii: "'"))
                            i += 2
                        } else if q == UInt8(ascii: "'") {
                            i += 1
                            closed = true
                            break
                        } else {
                            argument.append(q)
                            i += 1
                        }
                    }
                    guard closed else { throw DatabaseError("Unbalanced quotes in the command.") }
                } else {
                    argument.append(c)
                    i += 1
                }
            }
            arguments.append(argument)
        }
        return arguments
    }

    /// One argument written so `arguments(_:)` reads it back unchanged: bare when it is a plain word,
    /// otherwise double-quoted with escapes.
    static func quoted(_ argument: String) -> String {
        let plain = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value != 0x7F && $0 != "\"" && $0 != "'" && $0 != "\\"
        }
        if plain { return argument }
        var out = "\""
        for scalar in argument.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\x%02x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// Turns Redis replies into grid cells.
enum RedisFormatting {
    /// Text for a bulk string: the UTF-8 text when it is valid UTF-8, otherwise "\x…" hex like other
    /// drivers' binary values.
    static func text(_ bytes: [UInt8]) -> String {
        if !bytes.contains(0), let text = String(bytes: bytes, encoding: .utf8) { return text }
        return "\\x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func number(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// A cell for a scalar reply; nested arrays become JSON.
    static func cell(_ value: RESPValue) -> CellValue {
        switch value {
        case .bulk(nil), .array(nil): nil
        case .bulk(let bytes?): text(bytes)
        case .array: json(value)
        default: value.string
        }
    }

    /// JSON text for a reply, for nested arrays and for the browser's value column.
    static func json(_ value: RESPValue) -> String {
        jsonText(jsonObject(value))
    }

    static func jsonObject(_ value: RESPValue) -> Any {
        switch value {
        case .bulk(nil), .array(nil): NSNull()
        case .bulk(let bytes?): text(bytes)
        case .simple(let text), .error(let text): text
        case .integer(let number): number
        case .double(let number): number.isFinite ? number : String(number)
        case .array(let items?): items.map(jsonObject)
        }
    }

    /// Pairs [k1, v1, k2, v2…] as a JSON object, keeping the server's order.
    static func jsonPairs(_ items: [RESPValue]) -> String {
        var parts: [String] = []
        var index = 0
        while index + 1 < items.count {
            let key = jsonText(items[index].string ?? "")
            parts.append(key + ": " + jsonText(jsonObject(items[index + 1])))
            index += 2
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    static func jsonText(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else {
            return String(describing: object)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
