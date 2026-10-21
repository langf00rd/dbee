import Foundation

/// A statement typed in the MongoDB query editor, in the subset of mongosh syntax Dbee understands.
enum MongoStatement: Equatable {
    /// A raw command document (`{ ping: 1 }`), run with runCommand on the current database.
    case command(BSONDocument)
    case showDatabases
    case showCollections
    case use(String)
    /// `db.<collection>.<method>(args).<chained>(args)…`
    case collection(name: String, method: String, arguments: [BSONValue], chain: [MongoCall])
    /// `db.<method>(args)`
    case database(method: String, arguments: [BSONValue])
}

struct MongoCall: Equatable {
    var method: String
    var arguments: [BSONValue]
}

/// Parses mongosh-style statements and the relaxed JSON they use: unquoted keys, single-quoted strings,
/// trailing commas, comments, and the shell's constructors (ObjectId, ISODate, NumberLong, NumberDecimal,
/// Timestamp, BinData, UUID, MinKey, MaxKey) and /regex/ literals.
struct MongoShellParser {
    private let s: [Unicode.Scalar]
    private var i = 0

    init(_ text: String) {
        s = Array(text.unicodeScalars)
    }

    static func statement(_ text: String) throws -> MongoStatement {
        var parser = MongoShellParser(text)
        let statement = try parser.parseStatement()
        parser.skipBlank()
        if parser.i < parser.s.count, parser.s[parser.i] == ";" { parser.i += 1 }
        parser.skipBlank()
        guard parser.i >= parser.s.count else { throw parser.error("Unexpected text after the statement") }
        return statement
    }

    /// One value (a filter, a document), with nothing else after it.
    static func value(_ text: String) throws -> BSONValue {
        var parser = MongoShellParser(text)
        let value = try parser.parseValue()
        parser.skipBlank()
        guard parser.i >= parser.s.count else { throw parser.error("Unexpected text after the value") }
        return value
    }

    // MARK: Statements

    private mutating func parseStatement() throws -> MongoStatement {
        skipBlank()
        guard i < s.count else { throw DatabaseError("Enter a MongoDB command.") }
        if s[i] == "{" {
            guard case .document(let document) = try parseValue() else { throw error("Expected a command document") }
            return .command(document)
        }
        let word = identifier()
        switch word {
        case "show":
            skipBlank()
            let what = identifier()
            switch what {
            case "dbs", "databases": return .showDatabases
            case "collections", "tables": return .showCollections
            default: throw DatabaseError("Dbee understands “show dbs” and “show collections”.")
            }
        case "use":
            skipBlank()
            let start = i
            while i < s.count, !s[i].properties.isWhitespace, s[i] != ";" { i += 1 }
            let name = String(String.UnicodeScalarView(s[start..<i]))
            guard !name.isEmpty else { throw error("Expected a database name after use") }
            return .use(name)
        case "db":
            return try parseDatabaseExpression()
        case "":
            throw error("Expected a command")
        default:
            throw DatabaseError("Dbee runs statements that start with db., show, use, or a { command } document.",
                                detail: "“\(word)” isn't one of them.")
        }
    }

    private mutating func parseDatabaseExpression() throws -> MongoStatement {
        var collection: String?
        skipBlank()
        if peek("[") {
            i += 1
            guard case .string(let name) = try parseValue() else { throw error("Expected a collection name") }
            try expect("]")
            collection = name
        } else {
            try expect(".")
            let name = try requireIdentifier()
            skipBlank()
            if peek("(") {
                let arguments = try parseArguments()
                if name == "getCollection" || name == "getSiblingDB" {
                    guard name == "getCollection", case .string(let collectionName)? = arguments.first else {
                        throw DatabaseError("Dbee doesn't support db.\(name)(). Use “use <database>” to switch databases.")
                    }
                    collection = collectionName
                } else {
                    skipBlank()
                    guard i >= s.count || s[i] == ";" else { throw error("Unexpected text after db.\(name)()") }
                    return .database(method: name, arguments: arguments)
                }
            } else {
                collection = name
            }
        }
        guard let collection else { throw error("Expected a collection") }
        skipBlank()
        // Dotted collection names (db.system.users.find) continue until the call.
        var name = collection
        var method = ""
        while true {
            try expect(".")
            let part = try requireIdentifier()
            skipBlank()
            if peek("(") {
                method = part
                break
            }
            name += "." + part
        }
        let arguments = try parseArguments()
        var chain: [MongoCall] = []
        skipBlank()
        while peek(".") {
            i += 1
            let chained = try requireIdentifier()
            skipBlank()
            chain.append(MongoCall(method: chained, arguments: try parseArguments()))
            skipBlank()
        }
        return .collection(name: name, method: method, arguments: arguments, chain: chain)
    }

    private mutating func parseArguments() throws -> [BSONValue] {
        try expect("(")
        var arguments: [BSONValue] = []
        skipBlank()
        if peek(")") {
            i += 1
            return arguments
        }
        while true {
            arguments.append(try parseValue())
            skipBlank()
            if peek(",") {
                i += 1
                skipBlank()
                if peek(")") { i += 1; return arguments }
                continue
            }
            try expect(")")
            return arguments
        }
    }

    // MARK: Values

    mutating func parseValue() throws -> BSONValue {
        skipBlank()
        guard i < s.count else { throw error("Expected a value") }
        let c = s[i]
        switch c {
        case "{": return .document(try parseDocument())
        case "[": return .array(try parseArray())
        case "\"", "'": return .string(try parseString())
        case "/": return try parseRegex()
        case "-", "+", ".", "0"..."9": return try parseNumber()
        default:
            let word = identifier()
            guard !word.isEmpty else { throw error("Unexpected “\(c)”") }
            return try parseWord(word)
        }
    }

    private mutating func parseDocument() throws -> BSONDocument {
        try expect("{")
        var document = BSONDocument()
        while true {
            skipBlank()
            if peek("}") {
                i += 1
                return document
            }
            let key: String
            if peek("\"") || peek("'") {
                key = try parseString()
            } else {
                key = identifier(allowingDigitsFirst: true)
                guard !key.isEmpty else { throw error("Expected a field name") }
            }
            try expect(":")
            document.fields.append((key: key, value: try parseValue()))
            skipBlank()
            if peek(",") {
                i += 1
            } else {
                try expect("}")
                return document
            }
        }
    }

    private mutating func parseArray() throws -> [BSONValue] {
        try expect("[")
        var items: [BSONValue] = []
        while true {
            skipBlank()
            if peek("]") {
                i += 1
                return items
            }
            items.append(try parseValue())
            skipBlank()
            if peek(",") {
                i += 1
            } else {
                try expect("]")
                return items
            }
        }
    }

    private mutating func parseString() throws -> String {
        let quote = s[i]
        i += 1
        var out = String.UnicodeScalarView()
        while i < s.count {
            let c = s[i]
            if c == quote {
                i += 1
                return String(out)
            }
            if c == "\\", i + 1 < s.count {
                let e = s[i + 1]
                i += 2
                switch e {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "0": out.append("\0")
                case "u":
                    guard let scalar = try unicodeEscape() else { throw error("Bad \\u escape") }
                    out.append(scalar)
                case "x":
                    guard i + 2 <= s.count, let value = UInt32(String(String.UnicodeScalarView(s[i..<i + 2])), radix: 16),
                          let scalar = Unicode.Scalar(value) else { throw error("Bad \\x escape") }
                    i += 2
                    out.append(scalar)
                case "\n": break
                default: out.append(e)
                }
                continue
            }
            out.append(c)
            i += 1
        }
        throw error("Unterminated string")
    }

    private mutating func unicodeEscape() throws -> Unicode.Scalar? {
        func hex4() -> UInt32? {
            guard i + 4 <= s.count, let value = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else { return nil }
            i += 4
            return value
        }
        if peek("{") {
            i += 1
            let start = i
            while i < s.count, s[i] != "}" { i += 1 }
            guard i < s.count, let value = UInt32(String(String.UnicodeScalarView(s[start..<i])), radix: 16) else { return nil }
            i += 1
            return Unicode.Scalar(value)
        }
        guard let first = hex4() else { return nil }
        if (0xD800...0xDBFF).contains(first), i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
            i += 2
            guard let second = hex4(), (0xDC00...0xDFFF).contains(second) else { return nil }
            return Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
        }
        return Unicode.Scalar(first)
    }

    private mutating func parseRegex() throws -> BSONValue {
        i += 1
        var pattern = String.UnicodeScalarView()
        var inClass = false
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count {
                pattern.append(c)
                pattern.append(s[i + 1])
                i += 2
                continue
            }
            if c == "[" { inClass = true } else if c == "]" { inClass = false }
            if c == "/", !inClass { break }
            if c == "\n" { throw error("Unterminated regular expression") }
            pattern.append(c)
            i += 1
        }
        guard i < s.count else { throw error("Unterminated regular expression") }
        i += 1
        var options = ""
        while i < s.count, s[i].properties.isAlphabetic {
            options.unicodeScalars.append(s[i])
            i += 1
        }
        return .regex(pattern: String(pattern), options: String(options.sorted()))
    }

    private mutating func parseNumber() throws -> BSONValue {
        let start = i
        if peek("-") || peek("+") { i += 1 }
        let word = identifier()
        if word == "Infinity" {
            return .double(s[start] == "-" ? -.infinity : .infinity)
        }
        if !word.isEmpty { throw error("Unexpected “\(word)”") }
        if i + 1 < s.count, s[i] == "0", s[i + 1] == "x" || s[i + 1] == "X" {
            i += 2
            let digitsStart = i
            while i < s.count, s[i].properties.isASCIIHexDigit { i += 1 }
            guard let value = Int64(String(String.UnicodeScalarView(s[digitsStart..<i])), radix: 16) else { throw error("Bad number") }
            return integer(s[start] == "-" ? -value : value)
        }
        var isDouble = false
        while i < s.count {
            let c = s[i]
            if ("0"..."9").contains(c) || c == "_" {
                i += 1
            } else if c == "." || c == "e" || c == "E" {
                isDouble = true
                i += 1
                if (c == "e" || c == "E"), i < s.count, s[i] == "-" || s[i] == "+" { i += 1 }
            } else {
                break
            }
        }
        let text = String(String.UnicodeScalarView(s[start..<i])).replacingOccurrences(of: "_", with: "")
        if !isDouble, let value = Int64(text) { return integer(value) }
        guard let value = Double(text) else { throw error("Bad number “\(text)”") }
        return .double(value)
    }

    private func integer(_ value: Int64) -> BSONValue {
        if let small = Int32(exactly: value) { return .int32(small) }
        return .int64(value)
    }

    private mutating func parseWord(_ word: String) throws -> BSONValue {
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        case "undefined": return .undefined
        case "NaN": return .double(.nan)
        case "Infinity": return .double(.infinity)
        case "MinKey": skipCallParentheses(); return .minKey
        case "MaxKey": skipCallParentheses(); return .maxKey
        case "new":
            skipBlank()
            let constructor = identifier()
            guard !constructor.isEmpty else { throw error("Expected a constructor after new") }
            return try parseWord(constructor)
        default:
            break
        }
        skipBlank()
        guard peek("(") else { throw error("Unknown value “\(word)”") }
        let arguments = try parseArguments()
        func stringArgument() throws -> String {
            guard case .string(let text)? = arguments.first else { throw error("\(word)() needs a string") }
            return text
        }
        switch word {
        case "ObjectId", "ObjectID":
            if arguments.isEmpty { return .objectId(ObjectIdGenerator.next()) }
            let text = try stringArgument()
            guard let bytes = Self.hexBytes(text), bytes.count == 12 else { throw error("ObjectId needs 24 hex digits") }
            return .objectId(bytes)
        case "ISODate", "Date":
            if arguments.isEmpty { return .date(Int64(Date().timeIntervalSince1970 * 1000)) }
            if let milliseconds = arguments.first?.int { return .date(Int64(milliseconds)) }
            let text = try stringArgument()
            guard let milliseconds = Self.parseDate(text) else { throw error("Couldn't read the date “\(text)”") }
            return .date(milliseconds)
        case "NumberLong", "Long":
            if case .string(let text)? = arguments.first, let value = Int64(text) { return .int64(value) }
            guard let value = arguments.first?.int else { throw error("\(word)() needs a whole 64-bit number") }
            return .int64(Int64(value))
        case "NumberInt", "Int32":
            if case .string(let text)? = arguments.first, let value = Int32(text) { return .int32(value) }
            guard let value = arguments.first?.int, let small = Int32(exactly: value) else { throw error("\(word)() needs a 32-bit number") }
            return .int32(small)
        case "Double":
            if case .double(let value)? = arguments.first { return .double(value) }
            guard let value = arguments.first?.int else { throw error("Double() needs a number") }
            return .double(Double(value))
        case "NumberDecimal", "Decimal128":
            // Each numeric type is converted on its own, so a fraction is never cut to an integer.
            let text: String
            switch arguments.first {
            case .string(let value)?: text = value
            case .double(let value)?: text = String(value)
            case .int32(let value)?: text = String(value)
            case .int64(let value)?: text = String(value)
            default: throw error("\(word)() needs a number")
            }
            guard let bytes = Decimal128.bytes(text) else { throw error("Couldn't read the decimal “\(text)”") }
            return .decimal128(bytes)
        case "Timestamp":
            var parts: (time: Int, increment: Int)?
            if arguments.count == 2, let t = arguments[0].int, let increment = arguments[1].int {
                parts = (t, increment)
            } else if case .document(let document)? = arguments.first, let t = document["t"]?.int, let increment = document["i"]?.int {
                parts = (t, increment)
            }
            guard let parts else { throw error("Timestamp() needs a time and an increment") }
            // Both halves are unsigned 32-bit numbers.
            guard let time = UInt32(exactly: parts.time), let increment = UInt32(exactly: parts.increment) else {
                throw error("Timestamp() needs a time and an increment from 0 to 4294967295")
            }
            return .timestamp(UInt64(time) << 32 | UInt64(increment))
        case "BinData":
            guard arguments.count == 2, let subtype = arguments[0].int, case .string(let base64) = arguments[1],
                  let data = Data(base64Encoded: base64) else { throw error("BinData() needs a subtype and base64 text") }
            return .binary(subtype: UInt8(truncatingIfNeeded: subtype), data: Array(data))
        case "UUID":
            if arguments.isEmpty { return .binary(subtype: 4, data: Self.uuidBytes(UUID())) }
            guard let uuid = UUID(uuidString: try stringArgument()) else { throw error("Couldn't read the UUID") }
            return .binary(subtype: 4, data: Self.uuidBytes(uuid))
        case "RegExp":
            let pattern = try stringArgument()
            let options = arguments.count > 1 ? arguments[1].string ?? "" : ""
            return .regex(pattern: pattern, options: String(options.sorted()))
        default:
            throw error("Dbee doesn't know \(word)()")
        }
    }

    private mutating func skipCallParentheses() {
        let saved = i
        skipBlank()
        if peek("("), (try? parseArguments()) != nil { return }
        i = saved
    }

    static func hexBytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = 0
        while index < digits.count {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
    }

    private static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    /// ISO 8601 with or without time, fraction and zone; a missing zone means UTC, as in mongosh.
    static func parseDate(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formats: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime],
            [.withFullDate],
        ]
        for options in formats {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: trimmed) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        return nil
    }

    // MARK: Lexing

    private func peek(_ c: Unicode.Scalar) -> Bool { i < s.count && s[i] == c }

    private mutating func expect(_ c: Unicode.Scalar) throws {
        skipBlank()
        guard peek(c) else { throw error("Expected “\(c)”") }
        i += 1
    }

    private mutating func identifier(allowingDigitsFirst: Bool = false) -> String {
        let start = i
        while i < s.count {
            let c = s[i]
            let isLetter = c.properties.isAlphabetic || c == "_" || c == "$"
            let isDigit = ("0"..."9").contains(c)
            if isLetter || (isDigit && (i > start || allowingDigitsFirst)) {
                i += 1
            } else {
                break
            }
        }
        return String(String.UnicodeScalarView(s[start..<i]))
    }

    private mutating func requireIdentifier() throws -> String {
        skipBlank()
        let word = identifier()
        guard !word.isEmpty else { throw error("Expected a name") }
        return word
    }

    /// Skips whitespace and // and /* */ comments.
    mutating func skipBlank() {
        while i < s.count {
            if s[i].properties.isWhitespace {
                i += 1
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i = min(i + 2, s.count)
            } else {
                break
            }
        }
    }

    private func error(_ message: String) -> DatabaseError {
        // Line and column of the parser position, counted like an editor.
        var line = 1
        var column = 1
        for c in s.prefix(min(i, s.count)) {
            if c == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return DatabaseError(message + ".", detail: "At line \(line), column \(column).")
    }
}

/// ObjectIds made by the editor's ObjectId(): time, a per-launch random value and a counter, as drivers do.
enum ObjectIdGenerator {
    nonisolated(unsafe) private static var counter = UInt32.random(in: 0...0xFF_FFFF)
    private static let random: [UInt8] = (0..<5).map { _ in UInt8.random(in: 0...255) }
    private static let lock = NSLock()

    static func next() -> [UInt8] {
        let time = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        let count = lock.withLock {
            counter = (counter &+ 1) & 0xFF_FFFF
            return counter
        }
        return [UInt8(time >> 24), UInt8(time >> 16 & 0xFF), UInt8(time >> 8 & 0xFF), UInt8(time & 0xFF)]
            + random
            + [UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
    }
}
