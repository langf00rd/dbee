import Foundation
import NIOCore

/// Frames and values of the CQL native protocol, version 4 (ScyllaDB, and Cassandra 2.2 and later).
enum CQLProtocol {
    static let version: UInt8 = 0x04

    enum Opcode: UInt8 {
        case error = 0x00
        case startup = 0x01
        case ready = 0x02
        case authenticate = 0x03
        case options = 0x05
        case supported = 0x06
        case query = 0x07
        case result = 0x08
        case event = 0x0C
        case authChallenge = 0x0E
        case authResponse = 0x0F
        case authSuccess = 0x10
    }

    /// Consistency levels, as cqlsh's CONSISTENCY command names them.
    static let consistencyLevels: [(name: String, code: UInt16)] = [
        ("ANY", 0x0000), ("ONE", 0x0001), ("TWO", 0x0002), ("THREE", 0x0003), ("QUORUM", 0x0004), ("ALL", 0x0005),
        ("LOCAL_QUORUM", 0x0006), ("EACH_QUORUM", 0x0007), ("SERIAL", 0x0008), ("LOCAL_SERIAL", 0x0009),
        ("LOCAL_ONE", 0x000A),
    ]

    static func consistencyName(_ code: UInt16) -> String {
        consistencyLevels.first { $0.code == code }?.name ?? String(code)
    }

    struct Frame {
        var opcode: UInt8
        var stream: Int16
        var body: ByteBuffer
    }

    /// Longest frame Dbee accepts (the protocol's own limit is 256 MB).
    static let maxFrameLength = 256 * 1024 * 1024

    static func frame(_ opcode: Opcode, stream: Int16, body: ByteBuffer) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(version)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(stream)
        buffer.writeInteger(opcode.rawValue)
        buffer.writeInteger(Int32(body.readableBytes))
        var body = body
        buffer.writeBuffer(&body)
        return buffer
    }

    /// The next response frame, or nil until all of it has arrived. Warnings, tracing ids and custom payloads
    /// the server put before the body are skipped.
    static func parseFrame(_ buffer: inout ByteBuffer) throws -> Frame? {
        guard buffer.readableBytes >= 9 else { return nil }
        let start = buffer.readerIndex
        let versionByte = buffer.getInteger(at: start, as: UInt8.self)!
        let flags = buffer.getInteger(at: start + 1, as: UInt8.self)!
        let stream = buffer.getInteger(at: start + 2, as: Int16.self)!
        let opcode = buffer.getInteger(at: start + 4, as: UInt8.self)!
        let length = Int(buffer.getInteger(at: start + 5, as: Int32.self)!)
        guard versionByte & 0x80 != 0 else { throw WireConnection.Failure.malformed("not a CQL response") }
        guard length >= 0, length <= maxFrameLength else { throw WireConnection.Failure.malformed("frame length \(length)") }
        guard buffer.readableBytes >= 9 + length else { return nil }
        if versionByte & 0x7F != version {
            // The server speaks another protocol version; its error frame (if it is one) says which.
            buffer.moveReaderIndex(forwardBy: 9)
            var body = buffer.readSlice(length: length)!
            let message = opcode == Opcode.error.rawValue ? (try? readError(&body))?.message : nil
            throw DatabaseError("The server doesn't speak version 4 of the CQL protocol.",
                                detail: message ?? "Dbee needs ScyllaDB, or Cassandra 2.2 or later.")
        }
        buffer.moveReaderIndex(forwardBy: 9)
        var body = buffer.readSlice(length: length)!
        if flags & 0x02 != 0 { _ = body.readSlice(length: 16) }
        if flags & 0x08 != 0 { _ = try readStringList(&body) }
        if flags & 0x04 != 0 {
            let count = try readShort(&body)
            for _ in 0..<count {
                _ = try readString(&body)
                _ = try readBytes(&body)
            }
        }
        return Frame(opcode: opcode, stream: stream, body: body)
    }

    // MARK: Writing

    static func writeString(_ value: String, to buffer: inout ByteBuffer) {
        let bytes = Array(value.utf8)
        buffer.writeInteger(UInt16(clamping: bytes.count))
        buffer.writeBytes(bytes.prefix(Int(UInt16.max)))
    }

    static func writeLongString(_ value: String, to buffer: inout ByteBuffer) {
        let bytes = Array(value.utf8)
        buffer.writeInteger(Int32(bytes.count))
        buffer.writeBytes(bytes)
    }

    static func writeBytes(_ value: [UInt8]?, to buffer: inout ByteBuffer) {
        guard let value else {
            buffer.writeInteger(Int32(-1))
            return
        }
        buffer.writeInteger(Int32(value.count))
        buffer.writeBytes(value)
    }

    static func startupBody() -> ByteBuffer {
        var body = ByteBuffer()
        body.writeInteger(UInt16(1))
        writeString("CQL_VERSION", to: &body)
        writeString("3.0.0", to: &body)
        return body
    }

    /// PasswordAuthenticator's SASL PLAIN token: NUL, user, NUL, password.
    static func authResponseBody(username: String, password: String) -> ByteBuffer {
        var body = ByteBuffer()
        writeBytes([0] + Array(username.utf8) + [0] + Array(password.utf8), to: &body)
        return body
    }

    static func queryBody(_ statement: String, consistency: UInt16, pageSize: Int, pagingState: [UInt8]?) -> ByteBuffer {
        var body = ByteBuffer()
        writeLongString(statement, to: &body)
        body.writeInteger(consistency)
        var flags: UInt8 = 0x04
        if pagingState != nil { flags |= 0x08 }
        body.writeInteger(flags)
        body.writeInteger(Int32(clamping: max(1, pageSize)))
        if let pagingState { writeBytes(pagingState, to: &body) }
        return body
    }

    // MARK: Reading

    private static func truncated() -> Error { WireConnection.Failure.malformed("truncated CQL frame") }

    static func readShort(_ buffer: inout ByteBuffer) throws -> Int {
        guard let value = buffer.readInteger(as: UInt16.self) else { throw truncated() }
        return Int(value)
    }

    static func readInt(_ buffer: inout ByteBuffer) throws -> Int {
        guard let value = buffer.readInteger(as: Int32.self) else { throw truncated() }
        return Int(value)
    }

    static func readString(_ buffer: inout ByteBuffer) throws -> String {
        let length = try readShort(&buffer)
        guard let text = buffer.readString(length: length) else { throw truncated() }
        return text
    }

    static func readStringList(_ buffer: inout ByteBuffer) throws -> [String] {
        try (0..<readShort(&buffer)).map { _ in try readString(&buffer) }
    }

    static func readStringMultimap(_ buffer: inout ByteBuffer) throws -> [String: [String]] {
        var map: [String: [String]] = [:]
        for _ in 0..<(try readShort(&buffer)) {
            let key = try readString(&buffer)
            map[key] = try readStringList(&buffer)
        }
        return map
    }

    /// [bytes]: nil for a negative length (CQL null).
    static func readBytes(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        let length = try readInt(&buffer)
        guard length >= 0 else { return nil }
        guard let slice = buffer.readSlice(length: length) else { throw truncated() }
        return slice
    }

    struct ServerError: Error {
        var code: Int
        var message: String

        var name: String {
            switch code {
            case 0x0000: "Server error"
            case 0x000A: "Protocol error"
            case 0x0100: "Bad credentials"
            case 0x1000: "Unavailable"
            case 0x1001: "Overloaded"
            case 0x1002: "Is bootstrapping"
            case 0x1003: "Truncate error"
            case 0x1100: "Write timeout"
            case 0x1200: "Read timeout"
            case 0x1300: "Read failure"
            case 0x1400: "Function failure"
            case 0x1500: "Write failure"
            case 0x2000: "Syntax error"
            case 0x2100: "Unauthorized"
            case 0x2200: "Invalid"
            case 0x2300: "Config error"
            case 0x2400: "Already exists"
            case 0x2500: "Unprepared"
            default: String(format: "Error 0x%04X", code)
            }
        }

        var databaseError: DatabaseError { DatabaseError(message, detail: name) }
    }

    static func readError(_ body: inout ByteBuffer) throws -> ServerError {
        let code = try readInt(&body)
        return ServerError(code: code, message: try readString(&body))
    }

    // MARK: Results

    indirect enum DataType: Equatable, Sendable {
        case native(UInt16)
        case custom(String)
        case list(DataType)
        case set(DataType)
        case map(DataType, DataType)
        case udt(name: String, fields: [UDTField])
        case tuple([DataType])

        struct UDTField: Equatable, Sendable {
            var name: String
            var type: DataType
        }

        var name: String {
            switch self {
            case .native(let id): Self.nativeNames[id] ?? String(format: "0x%04X", id)
            case .custom(let name): "'\(name)'"
            case .list(let element): "list<\(element.name)>"
            case .set(let element): "set<\(element.name)>"
            case .map(let key, let value): "map<\(key.name), \(value.name)>"
            case .udt(let name, _): name
            case .tuple(let elements): "tuple<\(elements.map(\.name).joined(separator: ", "))>"
            }
        }

        static let nativeNames: [UInt16: String] = [
            0x0001: "ascii", 0x0002: "bigint", 0x0003: "blob", 0x0004: "boolean", 0x0005: "counter",
            0x0006: "decimal", 0x0007: "double", 0x0008: "float", 0x0009: "int", 0x000B: "timestamp",
            0x000C: "uuid", 0x000D: "text", 0x000E: "varint", 0x000F: "timeuuid", 0x0010: "inet", 0x0011: "date",
            0x0012: "time", 0x0013: "smallint", 0x0014: "tinyint", 0x0015: "duration",
        ]
    }

    static func readType(_ buffer: inout ByteBuffer, depth: Int = 0) throws -> DataType {
        guard depth < 64 else { throw WireConnection.Failure.malformed("type nested too deeply") }
        let id = UInt16(try readShort(&buffer))
        switch id {
        case 0x0000: return .custom(try readString(&buffer))
        case 0x0020: return .list(try readType(&buffer, depth: depth + 1))
        case 0x0021: return .map(try readType(&buffer, depth: depth + 1), try readType(&buffer, depth: depth + 1))
        case 0x0022: return .set(try readType(&buffer, depth: depth + 1))
        case 0x0030:
            _ = try readString(&buffer)
            let name = try readString(&buffer)
            let fields = try (0..<readShort(&buffer)).map { _ in
                DataType.UDTField(name: try readString(&buffer), type: try readType(&buffer, depth: depth + 1))
            }
            return .udt(name: name, fields: fields)
        case 0x0031:
            return .tuple(try (0..<readShort(&buffer)).map { _ in try readType(&buffer, depth: depth + 1) })
        default:
            return .native(id)
        }
    }

    enum Result {
        case void
        case rows(Rows)
        case setKeyspace(String)
        case schemaChange
        case other
    }

    struct Rows {
        var columns: [String]
        var types: [DataType]
        var rows: [[CellValue]]
        /// Where the next page starts; nil on the last page.
        var pagingState: [UInt8]?
    }

    static func readResult(_ body: inout ByteBuffer) throws -> Result {
        switch try readInt(&body) {
        case 0x0001:
            return .void
        case 0x0002:
            return .rows(try readRows(&body))
        case 0x0003:
            return .setKeyspace(try readString(&body))
        case 0x0005:
            return .schemaChange
        default:
            return .other
        }
    }

    static func readRows(_ body: inout ByteBuffer) throws -> Rows {
        let flags = try readInt(&body)
        let columnCount = try readInt(&body)
        var pagingState: [UInt8]?
        if flags & 0x0002 != 0, let state = try readBytes(&body) { pagingState = Array(state.readableBytesView) }
        var columns: [String] = []
        var types: [DataType] = []
        if flags & 0x0004 == 0 {
            let global = flags & 0x0001 != 0
            if global {
                _ = try readString(&body)
                _ = try readString(&body)
            }
            for _ in 0..<columnCount {
                if !global {
                    _ = try readString(&body)
                    _ = try readString(&body)
                }
                columns.append(try readString(&body))
                types.append(try readType(&body))
            }
        }
        let rowCount = try readInt(&body)
        var rows: [[CellValue]] = []
        rows.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            var row: [CellValue] = []
            row.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                let value = try readBytes(&body)
                row.append(value.map { CQLFormatting.text(Array($0.readableBytesView), type: types.indices.contains(column) ? types[column] : .native(0x0003)) })
            }
            rows.append(row)
        }
        return Rows(columns: columns, types: types, rows: rows, pagingState: pagingState)
    }
}

/// CQL values as text, the way cqlsh shows them: collections and UDTs as CQL literals, blobs as 0x…, timestamps
/// in UTC.
enum CQLFormatting {
    static func text(_ bytes: [UInt8], type: CQLProtocol.DataType) -> String {
        switch type {
        case .native(let id):
            return native(bytes, id: id)
        case .custom:
            return hex(bytes)
        case .list(let element), .set(let element):
            let (open, close) = if case .list = type { ("[", "]") } else { ("{", "}") }
            guard let items = try? elements(bytes, count: nil) else { return hex(bytes) }
            return open + items.map { literal($0, type: element) }.joined(separator: ", ") + close
        case .map(let key, let value):
            guard let items = try? elements(bytes, count: nil, perEntry: 2) else { return hex(bytes) }
            let pairs = stride(from: 0, to: items.count, by: 2).map {
                literal(items[$0], type: key) + ": " + literal(items[$0 + 1], type: value)
            }
            return "{" + pairs.joined(separator: ", ") + "}"
        case .udt(_, let fields):
            // A UDT value may have fewer fields than its type when fields were added later.
            guard let items = try? elements(bytes, count: fields.count, allowFewer: true) else { return hex(bytes) }
            let parts = zip(fields, items).map { field, value in field.name + ": " + literal(value, type: field.type) }
            return "{" + parts.joined(separator: ", ") + "}"
        case .tuple(let types):
            guard let items = try? elements(bytes, count: types.count, allowFewer: true) else { return hex(bytes) }
            return "(" + zip(types, items).map { literal($1, type: $0) }.joined(separator: ", ") + ")"
        }
    }

    /// A value inside a collection: strings and dates quoted, null as null.
    private static func literal(_ bytes: [UInt8]?, type: CQLProtocol.DataType) -> String {
        guard let bytes else { return "null" }
        let value = text(bytes, type: type)
        switch type {
        case .native(let id) where [0x0001, 0x000D, 0x0010, 0x0011, 0x0012, 0x000B].contains(id):
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        default:
            return value
        }
    }

    /// Elements of a collection ([int] count, then [bytes] each, or a key and a value each for a map) or of a
    /// UDT/tuple ([bytes] each, `count` of them).
    private static func elements(_ bytes: [UInt8], count: Int?, perEntry: Int = 1, allowFewer: Bool = false) throws -> [[UInt8]?] {
        var buffer = ByteBuffer(bytes: bytes)
        let n = try count ?? CQLProtocol.readInt(&buffer) * perEntry
        guard n >= 0, n <= bytes.count + 1 else { throw WireConnection.Failure.malformed("bad collection") }
        var items: [[UInt8]?] = []
        for _ in 0..<n {
            if allowFewer, buffer.readableBytes == 0 { break }
            items.append(try CQLProtocol.readBytes(&buffer).map { Array($0.readableBytesView) })
        }
        return items
    }

    private static func native(_ b: [UInt8], id: UInt16) -> String {
        switch id {
        case 0x0001, 0x000D: // ascii, text
            return String(decoding: b, as: UTF8.self)
        case 0x0002, 0x0005, 0x0009, 0x0013, 0x0014: // bigint, counter, int, smallint, tinyint
            guard [1, 2, 4, 8].contains(b.count) else { return hex(b) }
            return String(signedInteger(b))
        case 0x0004:
            return b.first.map { $0 != 0 ? "true" : "false" } ?? hex(b)
        case 0x0006:
            guard b.count >= 4 else { return hex(b) }
            let scale = Int(signedInteger(Array(b[0..<4])))
            return decimal(unscaled: varint(Array(b[4...])), scale: scale)
        case 0x0007:
            guard b.count == 8 else { return hex(b) }
            return formatDouble(Double(bitPattern: UInt64(bitPattern: signedInteger(b))))
        case 0x0008:
            guard b.count == 4 else { return hex(b) }
            let value = Float(bitPattern: UInt32(truncatingIfNeeded: signedInteger(b)))
            return value.isFinite && value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
        case 0x000B:
            guard b.count == 8 else { return hex(b) }
            return timestamp(milliseconds: signedInteger(b))
        case 0x000C, 0x000F:
            guard b.count == 16 else { return hex(b) }
            let digits = b.map { String(format: "%02x", $0) }.joined()
            var out = ""
            for (index, character) in digits.enumerated() {
                if [8, 12, 16, 20].contains(index) { out += "-" }
                out.append(character)
            }
            return out
        case 0x000E:
            return varint(b)
        case 0x0010:
            return inet(b) ?? hex(b)
        case 0x0011:
            guard b.count == 4 else { return hex(b) }
            let raw = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
            let days = Int64(raw) - (1 << 31)
            return day(days)
        case 0x0012:
            guard b.count == 8 else { return hex(b) }
            let nanos = signedInteger(b)
            let seconds = nanos / 1_000_000_000
            return String(format: "%02lld:%02lld:%02lld.%09lld", seconds / 3600, seconds / 60 % 60, seconds % 60,
                          nanos % 1_000_000_000)
        case 0x0015:
            return duration(b) ?? hex(b)
        default:
            return hex(b)
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A big-endian two's complement integer of 1 to 8 bytes.
    static func signedInteger(_ bytes: [UInt8]) -> Int64 {
        guard let first = bytes.first else { return 0 }
        var value: Int64 = first & 0x80 != 0 ? -1 : 0
        for byte in bytes { value = (value << 8) | Int64(byte) }
        return value
    }

    /// A varint (big-endian two's complement of any length) in decimal.
    static func varint(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "0" }
        if bytes.count <= 8 { return String(signedInteger(bytes)) }
        let negative = bytes[0] & 0x80 != 0
        var magnitude = bytes
        if negative {
            // Two's complement: invert and add one.
            magnitude = magnitude.map { ~$0 }
            var index = magnitude.count - 1
            while index >= 0 {
                let (sum, overflow) = magnitude[index].addingReportingOverflow(1)
                magnitude[index] = sum
                if !overflow { break }
                index -= 1
            }
        }
        var digits: [UInt8] = []
        while magnitude.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in magnitude.indices {
                let value = remainder << 8 | Int(magnitude[index])
                magnitude[index] = UInt8(value / 10)
                remainder = value % 10
            }
            digits.append(UInt8(remainder))
        }
        let text = digits.reversed().map { String($0) }.joined()
        return (negative ? "-" : "") + (text.isEmpty ? "0" : text)
    }

    static func decimal(unscaled: String, scale: Int) -> String {
        var digits = unscaled
        let negative = digits.hasPrefix("-")
        if negative { digits.removeFirst() }
        if scale <= 0 {
            digits += String(repeating: "0", count: -scale)
        } else {
            if digits.count <= scale { digits = String(repeating: "0", count: scale - digits.count + 1) + digits }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
        }
        return (negative && digits != "0" ? "-" : "") + digits
    }

    private static func formatDouble(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    /// yyyy-MM-dd HH:mm:ss.SSSZ in UTC.
    static func timestamp(milliseconds: Int64) -> String {
        let (days, rest) = milliseconds.quotientAndRemainder(dividingBy: 86_400_000)
        let (dayOffset, millis) = rest < 0 ? (days - 1, rest + 86_400_000) : (days, rest)
        let seconds = millis / 1000
        return day(dayOffset) + String(format: " %02lld:%02lld:%02lld.%03lldZ", seconds / 3600, seconds / 60 % 60,
                                      seconds % 60, millis % 1000)
    }

    /// yyyy-MM-dd for a day count since 1970-01-01 (proleptic Gregorian, any year).
    static func day(_ days: Int64) -> String {
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04lld-%02lld-%02lld", y, m, d)
    }

    private static func inet(_ bytes: [UInt8]) -> String? {
        switch bytes.count {
        case 4:
            return bytes.map(String.init).joined(separator: ".")
        case 16:
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return nil }
            return String(cString: text)
        default:
            return nil
        }
    }

    /// Months, days and nanoseconds as zig-zag vints, written like Cassandra: 1y2mo3d4h5m6s7ms8us9ns.
    private static func duration(_ bytes: [UInt8]) -> String? {
        var index = 0
        func vint() -> Int64? {
            guard index < bytes.count else { return nil }
            let first = bytes[index]
            let extra = first.leadingZeroBitCount == 8 ? 0 : (~first).leadingZeroBitCount
            guard index + extra < bytes.count else { return nil }
            var value = UInt64(extra == 8 ? 0 : first & (0xFF >> extra))
            for offset in 0..<extra { value = value << 8 | UInt64(bytes[index + 1 + offset]) }
            index += 1 + extra
            return Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
        }
        guard let months = vint(), let days = vint(), let nanos = vint() else { return nil }
        let negative = months < 0 || days < 0 || nanos < 0
        var parts = ""
        func add(_ value: Int64, _ unit: String) { if value != 0 { parts += "\(value)\(unit)" } }
        add(abs(months) / 12, "y")
        add(abs(months) % 12, "mo")
        add(abs(days), "d")
        let n = abs(nanos)
        add(n / 3_600_000_000_000, "h")
        add(n / 60_000_000_000 % 60, "m")
        add(n / 1_000_000_000 % 60, "s")
        add(n / 1_000_000 % 1000, "ms")
        add(n / 1000 % 1000, "us")
        add(n % 1000, "ns")
        return (negative ? "-" : "") + (parts.isEmpty ? "0s" : parts)
    }
}
