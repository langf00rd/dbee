import Foundation

/// SQL text generation for a specific engine. Pure functions, no I/O.
///
/// Generated statements have no trailing semicolon. Escaping works on Unicode scalars, never on
/// `Character`s, so a quote followed by a combining mark is still escaped. Literals mean the same
/// whatever the session settings: a Postgres value containing a backslash is written as E'…' with the
/// backslash doubled, so `standard_conforming_strings = off` can't turn it into an escape, and a MySQL
/// value containing a backslash or NUL is written as hex (`_utf8mb4 X'…'`), so it is stored as typed
/// with or without `NO_BACKSLASH_ESCAPES`. Quotes are always doubled, never backslash-escaped.
struct SQLDialect: Sendable {
    var kind: DatabaseKind

    /// "name" for Postgres/SQLite/CQL (and Redis/MongoDB/Meilisearch, where it is only used for display and
    /// exports), `name` for MySQL and ClickHouse, with embedded quote characters doubled (backslash-escaped for
    /// ClickHouse, which reads backslashes as escapes inside identifiers too).
    /// No engine allows NUL in identifiers, so NUL becomes U+FFFD: the statement then fails with
    /// "no such object" instead of being truncated or matching a different object.
    func quoteIdentifier(_ name: String) -> String {
        let quote: Unicode.Scalar = kind == .mysql || kind == .clickhouse ? "`" : "\""
        var out = String.UnicodeScalarView()
        out.append(quote)
        for scalar in name.unicodeScalars {
            switch scalar {
            case quote:
                out.append(kind == .clickhouse ? "\\" : quote)
                out.append(quote)
            case "\\" where kind == .clickhouse:
                out.append("\\")
                out.append("\\")
            case "\0":
                out.append("\u{FFFD}")
            default:
                out.append(scalar)
            }
        }
        out.append(quote)
        return String(out)
    }

    /// schema.table, each part quoted. Omits the schema when nil. A MongoDB collection is written the way
    /// the query editor reads it: db.getCollection("name"); a Meilisearch index as its path, /indexes/name.
    func qualifiedName(_ table: TableRef) -> String {
        if kind == .mongodb { return "db.getCollection(" + BSONFormatting.quote(table.name) + ")" }
        if kind == .meilisearch { return "/indexes/" + HTTPWire.escape(table.name) }
        let name = quoteIdentifier(table.name)
        guard let schema = table.schema else { return name }
        return quoteIdentifier(schema) + "." + name
    }

    /// NULL for nil, otherwise a string literal that reads back as exactly `value` ('it''s').
    ///
    /// NUL cannot appear raw in SQL text (drivers and servers treat it as a terminator), so it is
    /// encoded per engine: MySQL writes the whole value as `_utf8mb4 X'…'` (also used for backslashes,
    /// see the type comment), and SQLite a parenthesized `'a' || char(0) || 'b'` expression that
    /// round-trips the value. Postgres text cannot hold NUL at all, so it gets `chr(0)`, which makes
    /// the server reject the statement rather than silently store or match a different value.
    func literal(_ value: CellValue) -> String {
        guard let value else { return "NULL" }
        let scalars = value.unicodeScalars
        switch kind {
        case .mysql:
            guard scalars.contains("\\") || scalars.contains("\0") else { return Self.standardQuoted(scalars) }
            let hex = value.utf8.map { String(format: "%02X", $0) }.joined()
            return "_utf8mb4 X'" + hex + "'"
        case .clickhouse:
            // ClickHouse always reads backslash escapes in string literals, so backslashes and NUL are escaped.
            var out = String.UnicodeScalarView()
            out.append("'")
            for scalar in scalars {
                switch scalar {
                case "'": out.append(contentsOf: "''".unicodeScalars)
                case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
                case "\0": out.append(contentsOf: "\\0".unicodeScalars)
                default: out.append(scalar)
                }
            }
            out.append("'")
            return String(out)
        case .scylla, .meilisearch:
            // CQL strings have no escapes; text holding NUL is written as its bytes.
            guard kind == .scylla, scalars.contains("\0") else { return Self.standardQuoted(scalars) }
            return "blobAsText(0x" + value.utf8.map { String(format: "%02x", $0) }.joined() + ")"
        case .postgres, .sqlite, .redis, .mongodb:
            let quote: (Substring.UnicodeScalarView) -> String = { [kind] part in
                Self.standardQuoted(part, escapingBackslashes: kind == .postgres && part.contains("\\"))
            }
            guard scalars.contains("\0") else { return quote(scalars[...]) }
            let nul = kind == .postgres ? "chr(0)" : "char(0)"
            let parts = scalars.split(separator: "\0", omittingEmptySubsequences: false)
            return "(" + parts.map(quote).joined(separator: " || \(nul) || ") + ")"
        }
    }

    /// Like `literal(_:)`, but for a binary column (see `isBinaryType`) a value in the drivers' "\x0a1b…"
    /// display form becomes a hex literal on MySQL and SQLite, so it is written and matched as those bytes
    /// rather than as the text "\x0a1b". Postgres already parses '\x…' as bytea, so it keeps `literal(_:)`.
    func literal(_ value: CellValue, binary: Bool) -> String {
        guard binary, kind != .postgres, let value, let hex = Self.hexDigits(value) else { return literal(value) }
        return "X'" + hex + "'"
    }

    /// Whether a column's declared type stores bytes that the drivers display as "\x…" hex:
    /// bytea (Postgres), BINARY/VARBINARY/BLOB (MySQL), or a BLOB declared type (SQLite).
    static func isBinaryType(_ dataType: String, kind: DatabaseKind) -> Bool {
        let type = dataType.lowercased()
        switch kind {
        case .postgres: return type == "bytea"
        case .mysql: return type.hasPrefix("binary") || type.hasPrefix("varbinary") || type.hasSuffix("blob")
        case .sqlite: return type.contains("blob")
        case .clickhouse, .scylla, .redis, .mongodb, .meilisearch: return false
        }
    }

    /// Like `literal(_:)`, but for a BIT column (see `isBitType`) the unsigned integer the MySQL driver
    /// displays is written as a number. Quoted, '1' would be stored as the bytes of the text (49 in a BIT(8),
    /// an error in a BIT(1)). A value that isn't such a number keeps `literal(_:)`.
    func literal(_ value: CellValue, bit: Bool) -> String {
        guard bit, let value, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let number = UInt64(value) else {
            return literal(value)
        }
        return String(number)
    }

    /// Whether a column is MySQL/MariaDB BIT(n), which the driver displays as its unsigned integer value.
    static func isBitType(_ dataType: String, kind: DatabaseKind) -> Bool {
        guard kind == .mysql else { return false }
        let type = dataType.lowercased()
        return type == "bit" || type.hasPrefix("bit(")
    }

    /// `value` written for `column`, as bytes for a binary column and as a number for a BIT column.
    private func literal(_ value: CellValue, column: String, binaryColumns: Set<String>, bitColumns: Set<String>) -> String {
        bitColumns.contains(column) ? literal(value, bit: true) : literal(value, binary: binaryColumns.contains(column))
    }

    /// The hex digits of a "\x…" display value, or nil when `value` isn't one.
    private static func hexDigits(_ value: String) -> String? {
        guard value.hasPrefix("\\x") else { return nil }
        let digits = value.utf8.dropFirst(2)
        let isHex = digits.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
        guard isHex, digits.count % 2 == 0 else { return nil }
        return String(decoding: digits, as: UTF8.self)
    }

    /// SELECT * FROM t [WHERE filter] [ORDER BY col ASC|DESC] LIMIT n OFFSET m
    /// `filter` is a raw user-supplied WHERE expression (without the WHERE keyword), or nil/blank.
    /// The filter is wrapped in parentheses; trailing semicolons are ignored. Negative limit/offset
    /// are clamped to 0.
    func selectPage(_ table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) -> String {
        var sql = "SELECT * FROM " + qualifiedName(table) + whereClause(filter)
        if let sort {
            sql += " ORDER BY " + quoteIdentifier(sort.column) + (sort.ascending ? " ASC" : " DESC")
        }
        sql += " LIMIT \(max(0, limit)) OFFSET \(max(0, offset))"
        return sql
    }

    /// SELECT COUNT(*) FROM t [WHERE filter]
    func count(_ table: TableRef, filter: String?) -> String {
        "SELECT COUNT(*) FROM " + qualifiedName(table) + whereClause(filter)
    }

    /// UPDATE t SET a = 'x', b = NULL WHERE pk1 = '1' AND pk2 IS NULL
    /// `changes` and `key` are ordered (column, value) pairs.
    ///
    /// Precondition: callers pass a non-empty `changes` and a non-empty `key` that identifies the row.
    /// An empty `key` yields `WHERE 1 = 0`, so a caller bug can never rewrite a whole table.
    /// `binaryColumns` names columns whose "\x…" display values must be written back as bytes (see `literal(_:binary:)`),
    /// `bitColumns` BIT columns whose values are written as numbers (see `literal(_:bit:)`).
    func update(_ table: TableRef, changes: [(String, CellValue)], key: [(String, CellValue)],
                binaryColumns: Set<String> = [], bitColumns: Set<String> = []) -> String {
        let assignments = changes
            .map { quoteIdentifier($0.0) + " = " + literal($0.1, column: $0.0, binaryColumns: binaryColumns, bitColumns: bitColumns) }
            .joined(separator: ", ")
        return "UPDATE " + qualifiedName(table) + " SET " + assignments
            + keyClause(key, binaryColumns: binaryColumns, bitColumns: bitColumns)
    }

    /// DELETE FROM t WHERE pk1 = '1' AND ...
    ///
    /// Precondition: `key` is non-empty. An empty `key` yields `WHERE 1 = 0`, so a caller bug can
    /// never empty a table.
    func delete(_ table: TableRef, key: [(String, CellValue)], binaryColumns: Set<String> = [],
                bitColumns: Set<String> = []) -> String {
        "DELETE FROM " + qualifiedName(table) + keyClause(key, binaryColumns: binaryColumns, bitColumns: bitColumns)
    }

    /// INSERT INTO t (a, b) VALUES ('x', NULL). With no values: INSERT INTO t DEFAULT VALUES
    /// (MySQL: INSERT INTO t () VALUES ()).
    func insert(_ table: TableRef, values: [(String, CellValue)], binaryColumns: Set<String> = [],
                bitColumns: Set<String> = []) -> String {
        let target = "INSERT INTO " + qualifiedName(table)
        guard !values.isEmpty else {
            return target + (kind == .mysql ? " () VALUES ()" : " DEFAULT VALUES")
        }
        let columns = values.map { quoteIdentifier($0.0) }.joined(separator: ", ")
        let literals = values
            .map { literal($0.1, column: $0.0, binaryColumns: binaryColumns, bitColumns: bitColumns) }
            .joined(separator: ", ")
        return target + " (" + columns + ") VALUES (" + literals + ")"
    }

    /// TRUNCATE TABLE t; SQLite has no TRUNCATE, so it uses DELETE FROM t. MongoDB and Meilisearch delete
    /// every document; Redis empties the current database, since its keys are the only table.
    func truncate(_ table: TableRef) -> String {
        switch kind {
        case .postgres, .mysql, .clickhouse, .scylla: "TRUNCATE TABLE " + qualifiedName(table)
        case .meilisearch: "DELETE " + qualifiedName(table) + "/documents"
        case .sqlite: "DELETE FROM " + qualifiedName(table)
        case .mongodb: qualifiedName(table) + ".deleteMany({})"
        case .redis: "FLUSHDB"
        }
    }

    /// DROP TABLE / DROP VIEW, or DROP MATERIALIZED VIEW on Postgres (other engines have none).
    func drop(_ table: TableRef, kind tableKind: TableKind) -> String {
        let name = qualifiedName(table)
        if kind == .mongodb { return name + ".drop()" }
        if kind == .meilisearch { return "DELETE " + name }
        switch tableKind {
        case .table, .collection, .keys, .searchIndex: return "DROP TABLE " + name
        case .view: return "DROP VIEW " + name
        case .materializedView:
            return (kind == .postgres || kind == .scylla ? "DROP MATERIALIZED VIEW " : "DROP VIEW ") + name
        }
    }

    /// Statements that open/commit/rollback a transaction for this engine.
    var beginTransaction: String { kind == .mysql ? "START TRANSACTION" : "BEGIN" }
    var commit: String { "COMMIT" }
    var rollback: String { "ROLLBACK" }

    // MARK: - Helpers

    /// '...' with embedded single quotes doubled (standard SQL). With `escapingBackslashes` (Postgres only)
    /// it is E'...' with backslashes doubled too, which reads the same under either
    /// `standard_conforming_strings` setting.
    private static func standardQuoted<S: Sequence<Unicode.Scalar>>(_ scalars: S, escapingBackslashes: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        if escapingBackslashes { out.append("E") }
        out.append("'")
        for scalar in scalars {
            if scalar == "'" || (escapingBackslashes && scalar == "\\") { out.append(scalar) }
            out.append(scalar)
        }
        out.append("'")
        return String(out)
    }

    /// " WHERE (filter)" or "" for a nil/blank filter.
    private func whereClause(_ filter: String?) -> String {
        guard var expression = filter?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        while expression.hasSuffix(";") {
            expression = String(expression.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !expression.isEmpty else { return "" }
        // A trailing line comment would otherwise swallow the closing parenthesis.
        let hasLineComment = expression.contains("--") || expression.contains("//")
            || ((kind == .mysql || kind == .clickhouse) && expression.contains("#"))
        return " WHERE (" + expression + (hasLineComment ? "\n)" : ")")
    }

    /// "a = 'x' AND b IS NULL" (the condition `update`/`delete` target a row with), or "1 = 0" when
    /// `key` is empty.
    func keyCondition(_ key: [(String, CellValue)], binaryColumns: Set<String> = [], bitColumns: Set<String> = []) -> String {
        guard !key.isEmpty else { return "1 = 0" }
        return key.map { column, value in
            quoteIdentifier(column) + (value == nil
                ? " IS NULL"
                : " = " + literal(value, column: column, binaryColumns: binaryColumns, bitColumns: bitColumns))
        }.joined(separator: " AND ")
    }

    /// " WHERE a = 'x' AND b IS NULL", or " WHERE 1 = 0" when `key` is empty.
    private func keyClause(_ key: [(String, CellValue)], binaryColumns: Set<String>, bitColumns: Set<String>) -> String {
        " WHERE " + keyCondition(key, binaryColumns: binaryColumns, bitColumns: bitColumns)
    }
}

/// Splits a SQL script into individual statements on top-level semicolons.
/// Must respect: single-quoted strings (with '' escapes, and backslash escapes for MySQL),
/// double-quoted identifiers, MySQL backticks, -- and # (MySQL) line comments, /* */ block comments,
/// Postgres dollar-quoted strings ($$...$$, $tag$...$tag$), and E'..' strings with backslash escapes.
/// Returned statements are trimmed, exclude the trailing semicolon, and empty / comment-only statements are dropped.
///
/// Beyond that it follows each engine's own client: nested block comments and parenthesis depth
/// (`CREATE RULE ... DO (a; b)`) for Postgres, `--` comments only before whitespace for MySQL,
/// SQLite backtick and [bracket] identifiers, and BEGIN ... END bodies that contain semicolons:
/// SQLite `CREATE TRIGGER`, Postgres `CREATE FUNCTION/PROCEDURE ... BEGIN ATOMIC` and MySQL
/// `CREATE PROCEDURE/FUNCTION/TRIGGER/EVENT`. The MySQL client's `DELIMITER` command is honoured.
/// "Trimmed" means leading/trailing whitespace and comments are excluded, except comments the
/// server executes (MySQL `/*! */`, optimizer hints `/*+ */`).
/// Works on UTF-8 bytes in a single pass; ranges are exact UTF-16 offsets into the original script.
enum SQLSplitter {
    struct Statement: Equatable, Sendable {
        var text: String
        /// UTF-16 range of the statement text within the original script (for highlighting / run-at-cursor).
        var range: NSRange
    }

    static func split(_ script: String, kind: DatabaseKind) -> [Statement] {
        switch kind {
        case .redis: return CommandScript.splitRedis(script)
        case .mongodb: return CommandScript.splitMongo(script)
        case .scylla: return CommandScript.splitCQL(script)
        case .meilisearch: return CommandScript.splitHTTP(script)
        case .postgres, .mysql, .sqlite, .clickhouse: break
        }
        var script = script
        return script.withUTF8 { bytes in
            var scanner = SQLScanner(bytes: bytes, kind: kind)
            return scanner.statements()
        }
    }

    /// The statement containing (or immediately preceding) the given UTF-16 cursor offset.
    /// A cursor touching either end of a statement counts as inside it. In whitespace, comments or
    /// after the last semicolon it picks the closest preceding statement, else the next one.
    static func statement(at cursor: Int, in script: String, kind: DatabaseKind) -> Statement? {
        let statements = split(script, kind: kind)
        if let containing = statements.first(where: { $0.range.location <= cursor && cursor <= NSMaxRange($0.range) }) {
            return containing
        }
        return statements.last(where: { NSMaxRange($0.range) <= cursor }) ?? statements.first
    }
}

// MARK: - Scanner

/// Byte-level SQL lexer used by `SQLSplitter`. Only tracks what matters for finding statement
/// boundaries; everything outside strings, identifiers and comments is opaque.
private struct SQLScanner {
    private enum Header {
        /// No word seen yet.
        case start
        /// Seen CREATE (plus modifiers such as OR REPLACE / TEMP).
        case afterCreate
        /// MySQL: inside a DEFINER = user@host clause.
        case definer
        /// A routine/trigger whose BEGIN ... END body may contain semicolons.
        case routine
        /// Any other statement.
        case other
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private let count: Int
    private let kind: DatabaseKind
    private var i = 0
    private var ranges: [Range<Int>] = []

    /// MySQL client delimiter set with DELIMITER; nil means ";".
    private var delimiter: [UInt8]?

    // Per-statement state.
    private var start = -1
    private var end = 0
    private var parenDepth = 0
    private var header = Header.start
    private var definerWords = 0
    private var blockDepth = 0
    private var afterEnd = false
    private var endClosedBlock = false

    init(bytes: UnsafeBufferPointer<UInt8>, kind: DatabaseKind) {
        self.bytes = bytes
        self.count = bytes.count
        self.kind = kind
    }

    mutating func statements() -> [SQLSplitter.Statement] {
        scan()
        let bytes = bytes
        var result: [SQLSplitter.Statement] = []
        result.reserveCapacity(ranges.count)
        var mappedByte = 0
        var mappedUTF16 = 0
        func utf16Offset(_ byte: Int) -> Int {
            while mappedByte < byte {
                let b = bytes[mappedByte]
                if b & 0xC0 != 0x80 { mappedUTF16 += b >= 0xF0 ? 2 : 1 }
                mappedByte += 1
            }
            return mappedUTF16
        }
        for range in ranges {
            let location = utf16Offset(range.lowerBound)
            let length = utf16Offset(range.upperBound) - location
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
            result.append(.init(text: text, range: NSRange(location: location, length: length)))
        }
        return result
    }

    // MARK: Main loop

    private mutating func scan() {
        while i < count {
            let c = bytes[i]
            if let delimiter, c == delimiter[0], matches(delimiter, at: i) {
                finishStatement()
                i += delimiter.count
                continue
            }
            switch c {
            case 0x20, 0x09...0x0D:
                i += 1
            case ASCII.semicolon:
                if delimiter == nil, blockDepth == 0, kind != .postgres || parenDepth == 0 {
                    finishStatement()
                } else {
                    mark(i, i + 1)
                }
                i += 1
            case ASCII.singleQuote:
                markToken(upTo: quotedEnd(from: i, backslashEscapes: kind == .mysql || kind == .clickhouse))
            case ASCII.doubleQuote:
                markToken(upTo: quotedEnd(from: i, backslashEscapes: kind == .mysql || kind == .clickhouse))
            case ASCII.backtick where kind != .postgres:
                markToken(upTo: quotedEnd(from: i, backslashEscapes: kind == .clickhouse))
            case ASCII.openBracket where kind == .sqlite:
                var j = i + 1
                while j < count, bytes[j] != ASCII.closeBracket { j += 1 }
                markToken(upTo: min(j + 1, count))
            case ASCII.minus where peek(1) == ASCII.minus && (kind != .mysql || i + 2 >= count || bytes[i + 2] <= 0x20):
                skipLineComment()
            case ASCII.hash where kind == .mysql || kind == .clickhouse:
                skipLineComment()
            case ASCII.slash where peek(1) == ASCII.star:
                blockComment()
            case ASCII.dollar where kind == .postgres:
                markToken(upTo: dollarQuotedEnd(from: i) ?? i + 1)
            case ASCII.openParen:
                parenDepth += 1
                markToken(upTo: i + 1)
            case ASCII.closeParen:
                parenDepth = max(0, parenDepth - 1)
                markToken(upTo: i + 1)
            case _ where isIdentifierStart(c):
                word()
            case ASCII.zero...ASCII.nine:
                // Numbers (and MySQL identifiers that start with a digit) are never keywords.
                // In Postgres a `$` after a number starts a dollar quote, as in psql.
                markToken(upTo: wordEnd(from: i + 1, allowDollar: kind != .postgres))
            default:
                markToken(upTo: i + 1)
            }
        }
        finishStatement()
    }

    private mutating func finishStatement() {
        if start >= 0 {
            // Only an unterminated string or comment running to the end of input can end in whitespace.
            while end > start, bytes[end - 1] == 0x20 || (0x09...0x0D).contains(bytes[end - 1]) { end -= 1 }
            ranges.append(start..<end)
        }
        start = -1
        parenDepth = 0
        header = .start
        definerWords = 0
        blockDepth = 0
        afterEnd = false
        endClosedBlock = false
    }

    /// Records bytes s..<e as statement content.
    private mutating func mark(_ s: Int, _ e: Int) {
        if start < 0 { start = s }
        end = e
        afterEnd = false
    }

    private mutating func markToken(upTo e: Int) {
        mark(i, e)
        i = e
    }

    // MARK: Tokens

    private func peek(_ offset: Int) -> UInt8? {
        i + offset < count ? bytes[i + offset] : nil
    }

    private func matches(_ pattern: [UInt8], at position: Int) -> Bool {
        guard position + pattern.count <= count else { return false }
        for k in 0..<pattern.count where bytes[position + k] != pattern[k] { return false }
        return true
    }

    private func isIdentifierStart(_ c: UInt8) -> Bool {
        (c | 0x20) >= ASCII.a && (c | 0x20) <= ASCII.z || c == ASCII.underscore || c >= 0x80
            || (c == ASCII.dollar && kind != .postgres)
    }

    private func isIdentifierPart(_ c: UInt8) -> Bool {
        (c | 0x20) >= ASCII.a && (c | 0x20) <= ASCII.z || c >= ASCII.zero && c <= ASCII.nine
            || c == ASCII.underscore || c == ASCII.dollar || c >= 0x80
    }

    /// End of the identifier/number run starting at `from`, stopping early at a custom delimiter.
    private func wordEnd(from: Int, allowDollar: Bool = true) -> Int {
        var j = from
        while j < count, isIdentifierPart(bytes[j]), allowDollar || bytes[j] != ASCII.dollar {
            if let delimiter, bytes[j] == delimiter[0], matches(delimiter, at: j) { break }
            j += 1
        }
        return j
    }

    /// Index just past the closing quote of the quoted run opening at `from` (or the end of input).
    /// A doubled quote character is an escaped quote.
    private func quotedEnd(from: Int, backslashEscapes: Bool) -> Int {
        let quote = bytes[from]
        var j = from + 1
        while j < count {
            let c = bytes[j]
            if c == ASCII.backslash && backslashEscapes {
                j += 2
            } else if c == quote {
                if j + 1 < count, bytes[j + 1] == quote {
                    j += 2
                } else {
                    return j + 1
                }
            } else {
                j += 1
            }
        }
        return count
    }

    /// For a Postgres `$tag$` opening at `from`, the index just past the matching closing tag
    /// (or the end of input). nil when `from` does not start a dollar quote (e.g. `$1`).
    private func dollarQuotedEnd(from: Int) -> Int? {
        var j = from + 1
        if j < count, isIdentifierStart(bytes[j]) {
            j += 1
            while j < count, isIdentifierPart(bytes[j]), bytes[j] != ASCII.dollar { j += 1 }
        }
        guard j < count, bytes[j] == ASCII.dollar else { return nil }
        let tagLength = j - from + 1
        var k = j + 1
        while k < count {
            if bytes[k] == ASCII.dollar, k + tagLength <= count,
               memcmp(bytes.baseAddress! + k, bytes.baseAddress! + from, tagLength) == 0 {
                return k + tagLength
            }
            k += 1
        }
        return count
    }

    private mutating func skipLineComment() {
        while i < count, bytes[i] != ASCII.newline { i += 1 }
    }

    private mutating func blockComment() {
        let s = i
        let nested = kind == .postgres
        // Comments the server acts on: MySQL /*! */ and /*M! */ executable comments, /*+ */ hints.
        let third = peek(2)
        let executable = (kind != .sqlite && third == ASCII.plus)
            || (kind == .mysql && (third == ASCII.bang || (third == ASCII.upperM && peek(3) == ASCII.bang)))
        var depth = 1
        var j = i + 2
        while j < count {
            if bytes[j] == ASCII.star, j + 1 < count, bytes[j + 1] == ASCII.slash {
                j += 2
                depth -= 1
                if depth == 0 { break }
            } else if nested, bytes[j] == ASCII.slash, j + 1 < count, bytes[j + 1] == ASCII.star {
                j += 2
                depth += 1
            } else {
                j += 1
            }
        }
        i = min(j, count)
        if executable { mark(s, i) }
    }

    private mutating func word() {
        let s = i
        let e = wordEnd(from: i + 1)
        // Postgres E'...' strings use backslash escapes.
        if kind == .postgres, e - s == 1, bytes[s] | 0x20 == ASCII.e, e < count, bytes[e] == ASCII.singleQuote {
            i = e
            mark(s, quotedEnd(from: e, backslashEscapes: true))
            i = end
            return
        }
        if kind == .mysql, start < 0, delimiterCommand(wordStart: s, wordEnd: e) { return }
        let wasAfterEnd = afterEnd
        mark(s, e)
        i = e
        keyword(s, e, wasAfterEnd: wasAfterEnd)
    }

    // MARK: Statement structure

    /// MySQL client `DELIMITER xyz` line at the start of a statement. Returns false (leaving it to be
    /// sent as ordinary text) when the word is not DELIMITER or no delimiter follows.
    private mutating func delimiterCommand(wordStart s: Int, wordEnd e: Int) -> Bool {
        guard isKeyword(s, e, Keyword.delimiter), e < count, bytes[e] == 0x20 || bytes[e] == 0x09 else { return false }
        var j = e
        while j < count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
        let tokenStart = j
        while j < count, bytes[j] > 0x20 { j += 1 }
        guard j > tokenStart else { return false }
        let token = Array(bytes[tokenStart..<j])
        delimiter = token == [ASCII.semicolon] ? nil : token
        while j < count, bytes[j] != ASCII.newline { j += 1 }
        i = j
        return true
    }

    /// Recognises routine headers and tracks BEGIN/CASE ... END depth inside routine bodies
    /// (the same heuristic psql uses for BEGIN ATOMIC).
    private mutating func keyword(_ s: Int, _ e: Int, wasAfterEnd: Bool) {
        if header == .other { return }
        // Qualified names such as NEW.end are never keywords.
        if (s > 0 && bytes[s - 1] == ASCII.dot) || (e < count && bytes[e] == ASCII.dot) {
            if header != .routine { header = .other }
            return
        }
        switch header {
        case .start:
            header = isKeyword(s, e, Keyword.create) ? .afterCreate : .other
        case .afterCreate:
            header = routineHeader(s, e)
        case .definer:
            if isRoutineKeyword(s, e) {
                header = .routine
            } else {
                definerWords += 1
                if definerWords > 4 || isKeyword(s, e, Keyword.view) { header = .other }
            }
        case .routine:
            if parenDepth == 0 { trackBlock(s, e, wasAfterEnd: wasAfterEnd) }
        case .other:
            break
        }
    }

    private func routineHeader(_ s: Int, _ e: Int) -> Header {
        switch kind {
        case .postgres:
            if isKeyword(s, e, Keyword.or) || isKeyword(s, e, Keyword.replace) { return .afterCreate }
        case .sqlite, .clickhouse, .scylla, .redis, .mongodb, .meilisearch:
            if isKeyword(s, e, Keyword.temp) || isKeyword(s, e, Keyword.temporary) { return .afterCreate }
        case .mysql:
            if isKeyword(s, e, Keyword.or) || isKeyword(s, e, Keyword.replace) || isKeyword(s, e, Keyword.aggregate) {
                return .afterCreate
            }
            if isKeyword(s, e, Keyword.definer) { return .definer }
        }
        return isRoutineKeyword(s, e) ? .routine : .other
    }

    private func isRoutineKeyword(_ s: Int, _ e: Int) -> Bool {
        switch kind {
        case .postgres:
            isKeyword(s, e, Keyword.function) || isKeyword(s, e, Keyword.procedure)
        case .sqlite, .redis, .mongodb, .meilisearch:
            isKeyword(s, e, Keyword.trigger)
        case .clickhouse, .scylla:
            false
        case .mysql:
            isKeyword(s, e, Keyword.procedure) || isKeyword(s, e, Keyword.function)
                || isKeyword(s, e, Keyword.trigger) || isKeyword(s, e, Keyword.event)
        }
    }

    private mutating func trackBlock(_ s: Int, _ e: Int, wasAfterEnd: Bool) {
        // MySQL closes compound statements with END IF / END LOOP / END WHILE / END REPEAT / END CASE.
        // Only BEGIN and CASE are counted as openers, so undo the decrement for the others.
        if kind == .mysql, wasAfterEnd {
            if isKeyword(s, e, Keyword.if) || isKeyword(s, e, Keyword.loop)
                || isKeyword(s, e, Keyword.while) || isKeyword(s, e, Keyword.repeat) {
                if endClosedBlock { blockDepth += 1 }
                return
            }
            if isKeyword(s, e, Keyword.case) { return }
        }
        if isKeyword(s, e, Keyword.begin) {
            blockDepth += 1
        } else if isKeyword(s, e, Keyword.case) {
            // CASE ... END only matters once inside a body; before it (e.g. a trigger's WHEN) it is balanced.
            if blockDepth > 0 { blockDepth += 1 }
        } else if isKeyword(s, e, Keyword.end) {
            endClosedBlock = blockDepth > 0
            if endClosedBlock { blockDepth -= 1 }
            afterEnd = true
        }
    }

    /// ASCII case-insensitive comparison of bytes s..<e with a lowercase keyword.
    private func isKeyword(_ s: Int, _ e: Int, _ keyword: [UInt8]) -> Bool {
        guard e - s == keyword.count else { return false }
        for k in 0..<keyword.count where bytes[s + k] | 0x20 != keyword[k] { return false }
        return true
    }
}

private enum Keyword {
    static let aggregate = Array("aggregate".utf8)
    static let begin = Array("begin".utf8)
    static let `case` = Array("case".utf8)
    static let create = Array("create".utf8)
    static let definer = Array("definer".utf8)
    static let delimiter = Array("delimiter".utf8)
    static let end = Array("end".utf8)
    static let event = Array("event".utf8)
    static let function = Array("function".utf8)
    static let `if` = Array("if".utf8)
    static let loop = Array("loop".utf8)
    static let or = Array("or".utf8)
    static let procedure = Array("procedure".utf8)
    static let `repeat` = Array("repeat".utf8)
    static let replace = Array("replace".utf8)
    static let temp = Array("temp".utf8)
    static let temporary = Array("temporary".utf8)
    static let trigger = Array("trigger".utf8)
    static let view = Array("view".utf8)
    static let `while` = Array("while".utf8)
}

private enum ASCII {
    static let newline = UInt8(ascii: "\n")
    static let bang = UInt8(ascii: "!")
    static let doubleQuote = UInt8(ascii: "\"")
    static let hash = UInt8(ascii: "#")
    static let dollar = UInt8(ascii: "$")
    static let singleQuote = UInt8(ascii: "'")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let star = UInt8(ascii: "*")
    static let plus = UInt8(ascii: "+")
    static let minus = UInt8(ascii: "-")
    static let dot = UInt8(ascii: ".")
    static let slash = UInt8(ascii: "/")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let semicolon = UInt8(ascii: ";")
    static let upperM = UInt8(ascii: "M")
    static let openBracket = UInt8(ascii: "[")
    static let backslash = UInt8(ascii: "\\")
    static let closeBracket = UInt8(ascii: "]")
    static let underscore = UInt8(ascii: "_")
    static let backtick = UInt8(ascii: "`")
    static let a = UInt8(ascii: "a")
    static let e = UInt8(ascii: "e")
    static let z = UInt8(ascii: "z")
}
