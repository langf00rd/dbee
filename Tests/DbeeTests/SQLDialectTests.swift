import Foundation
import SQLite3
import Testing
@testable import Dbee

@Suite struct SQLDialectTests {
    let pg = SQLDialect(kind: .postgres)
    let my = SQLDialect(kind: .mysql)
    let lite = SQLDialect(kind: .sqlite)
    let users = TableRef(schema: "public", name: "users")
    let plain = TableRef(schema: nil, name: "users")

    // MARK: Identifiers

    @Test func binaryColumnsUseHexLiterals() {
        let key = [("id", CellValue("\\x0aFF"))]
        #expect(my.delete(plain, key: key, binaryColumns: ["id"]) == "DELETE FROM `users` WHERE `id` = X'0aFF'")
        #expect(lite.update(plain, changes: [("data", "\\x")], key: key, binaryColumns: ["id", "data"])
                == "UPDATE \"users\" SET \"data\" = X'' WHERE \"id\" = X'0aFF'")
        // Postgres parses '\x…' (here E'\\x…') as bytea already.
        #expect(pg.delete(plain, key: key, binaryColumns: ["id"]) == #"DELETE FROM "users" WHERE "id" = E'\\x0aFF'"#)
        // Not binary, not hex, odd length or NULL: an ordinary literal (hex text on MySQL, for the backslash).
        #expect(my.literal("\\x0a", binary: false) == "_utf8mb4 X'5C783061'")
        #expect(my.literal("hello", binary: true) == "'hello'")
        #expect(my.literal("\\x0g", binary: true) == "_utf8mb4 X'5C783067'")
        #expect(lite.literal("\\xabc", binary: true) == #"'\xabc'"#)
        #expect(my.literal(nil, binary: true) == "NULL")
        #expect(my.insert(plain, values: [("id", "\\x01"), ("name", "\\x01")], binaryColumns: ["id"])
                == #"INSERT INTO `users` (`id`, `name`) VALUES (X'01', _utf8mb4 X'5C783031')"#)
    }

    @Test func recognisesBinaryTypes() {
        #expect(SQLDialect.isBinaryType("bytea", kind: .postgres))
        #expect(!SQLDialect.isBinaryType("text", kind: .postgres))
        for type in ["binary(16)", "VARBINARY(255)", "blob", "tinyblob", "mediumblob", "longblob"] {
            #expect(SQLDialect.isBinaryType(type, kind: .mysql), "\(type)")
        }
        #expect(!SQLDialect.isBinaryType("varchar(20)", kind: .mysql))
        #expect(SQLDialect.isBinaryType("BLOB", kind: .sqlite))
        #expect(!SQLDialect.isBinaryType("", kind: .sqlite))
    }

    @Test func quotesIdentifiers() {
        #expect(pg.quoteIdentifier("users") == "\"users\"")
        #expect(lite.quoteIdentifier("users") == "\"users\"")
        #expect(my.quoteIdentifier("users") == "`users`")
        #expect(pg.quoteIdentifier("") == "\"\"")
        #expect(pg.quoteIdentifier("Mixed Case") == "\"Mixed Case\"")
    }

    @Test func doublesEmbeddedIdentifierQuotes() {
        #expect(pg.quoteIdentifier("a\"b") == "\"a\"\"b\"")
        #expect(lite.quoteIdentifier("\"\"") == "\"\"\"\"\"\"")
        #expect(my.quoteIdentifier("a`b") == "`a``b`")
        // The other engine's quote character is not special.
        #expect(pg.quoteIdentifier("a`b") == "\"a`b\"")
        #expect(my.quoteIdentifier("a\"b") == "`a\"b`")
    }

    @Test func escapesQuoteFollowedByCombiningMark() {
        // `"` + U+0301 is a single Character; escaping must still see the quote scalar.
        let name = "x\"\u{301}; DROP TABLE t; --"
        #expect(pg.quoteIdentifier(name) == "\"x\"\"\u{301}; DROP TABLE t; --\"")
        #expect(my.quoteIdentifier("x`\u{301}") == "`x``\u{301}`")
    }

    @Test(arguments: DatabaseKind.sqlKinds)
    func identifierNULBecomesReplacementCharacter(kind: DatabaseKind) {
        let quoted = SQLDialect(kind: kind).quoteIdentifier("a\0b")
        #expect(!quoted.unicodeScalars.contains("\0"))
        #expect(quoted.contains("a\u{FFFD}b"))
    }

    @Test func qualifiedNames() {
        #expect(pg.qualifiedName(users) == "\"public\".\"users\"")
        #expect(pg.qualifiedName(plain) == "\"users\"")
        #expect(my.qualifiedName(plain) == "`users`")
        #expect(my.qualifiedName(TableRef(schema: "shop", name: "or`ders")) == "`shop`.`or``ders`")
        #expect(lite.qualifiedName(TableRef(schema: "main", name: "t")) == "\"main\".\"t\"")
    }

    // MARK: Literals

    @Test(arguments: DatabaseKind.sqlKinds)
    func nullAndPlainLiterals(kind: DatabaseKind) {
        let d = SQLDialect(kind: kind)
        #expect(d.literal(nil) == "NULL")
        #expect(d.literal("") == "''")
        #expect(d.literal("NULL") == "'NULL'")
        #expect(d.literal("it's") == "'it''s'")
        #expect(d.literal("''") == "''''''")
        #expect(d.literal("héllo 😀 世界") == "'héllo 😀 世界'")
        #expect(d.literal("a;b -- c /* d */") == "'a;b -- c /* d */'")
    }

    @Test func backslashHandling() {
        // SQLite treats backslashes literally.
        #expect(lite.literal("C:\\dir\\") == "'C:\\dir\\'")
        // Postgres writes E'' with doubled backslashes, which reads the same whatever
        // standard_conforming_strings is set to. Values without a backslash keep the plain form.
        #expect(pg.literal("C:\\dir\\") == #"E'C:\\dir\\'"#)
        #expect(pg.literal("\\x0a1b") == #"E'\\x0a1b'"#)
        #expect(pg.literal("\\' OR 1=1 --") == #"E'\\'' OR 1=1 --'"#)
        #expect(pg.literal("a\\\0b'") == #"(E'a\\' || chr(0) || 'b''')"#)
        // MySQL writes such values as hex, so NO_BACKSLASH_ESCAPES can't change what is stored or matched.
        #expect(my.literal("C:\\dir\\") == "_utf8mb4 X'433A5C6469725C'")
        #expect(my.literal("\\'") == "_utf8mb4 X'5C27'")
        #expect(my.literal("it\\'s") == "_utf8mb4 X'69745C2773'")
        #expect(my.literal("é\\") == "_utf8mb4 X'C3A95C'")
    }

    @Test func quoteFollowedByCombiningMarkIsEscaped() {
        let value = "'\u{301} OR 1=1 --"
        #expect(pg.literal(value) == "'''\u{301} OR 1=1 --'")
        #expect(my.literal(value) == "'''\u{301} OR 1=1 --'")
    }

    @Test func nulBytesNeverAppearRaw() {
        #expect(my.literal("a\0b") == "_utf8mb4 X'610062'")
        #expect(lite.literal("a\0b") == "('a' || char(0) || 'b')")
        #expect(lite.literal("\0") == "('' || char(0) || '')")
        #expect(lite.literal("x'\0") == "('x''' || char(0) || '')")
        #expect(pg.literal("a\0b") == "('a' || chr(0) || 'b')")
        for kind in DatabaseKind.sqlKinds {
            #expect(!SQLDialect(kind: kind).literal("\0\0x\0").unicodeScalars.contains("\0"))
        }
    }

    /// Every literal must lex as exactly one string token, whatever it contains.
    @Test(arguments: DatabaseKind.sqlKinds)
    func literalsNeverBreakOut(kind: DatabaseKind) {
        let d = SQLDialect(kind: kind)
        let nasty = ["'", "\\", "\\'", "'\\", "';--", "\\'; DROP TABLE t; --", "$$", "$a$;", "/*", "*/;",
                     "\"", "`", "#", "\n;\n", "''';", "\\\\'", "'\u{301};", "\0';", "😀';"]
        for value in nasty {
            let sql = "SELECT \(d.literal(value)) FROM t WHERE x = \(d.literal(value + value))"
            let statements = SQLSplitter.split(sql + "; SELECT 2", kind: kind)
            #expect(statements.map(\.text) == [sql, "SELECT 2"], "value: \(value.debugDescription)")
        }
    }

    // MARK: Paging

    @Test func selectPageWithoutFilterOrSort() {
        #expect(pg.selectPage(users, filter: nil, sort: nil, limit: 100, offset: 0)
            == "SELECT * FROM \"public\".\"users\" LIMIT 100 OFFSET 0")
        #expect(my.selectPage(plain, filter: "   \n", sort: nil, limit: 50, offset: 150)
            == "SELECT * FROM `users` LIMIT 50 OFFSET 150")
        #expect(lite.selectPage(plain, filter: "", sort: nil, limit: 10, offset: 20)
            == "SELECT * FROM \"users\" LIMIT 10 OFFSET 20")
    }

    @Test func selectPageWrapsFilterAndSorts() {
        #expect(pg.selectPage(users, filter: " age > 30 OR name = 'x' ", sort: GridSort(column: "name", ascending: true), limit: 100, offset: 200)
            == "SELECT * FROM \"public\".\"users\" WHERE (age > 30 OR name = 'x') ORDER BY \"name\" ASC LIMIT 100 OFFSET 200")
        #expect(my.selectPage(plain, filter: "id < 5", sort: GridSort(column: "cre`ated", ascending: false), limit: 1, offset: 0)
            == "SELECT * FROM `users` WHERE (id < 5) ORDER BY `cre``ated` DESC LIMIT 1 OFFSET 0")
    }

    @Test func selectPageHandlesTrailingSemicolonsAndComments() {
        #expect(lite.selectPage(plain, filter: "id = 1 ; ;", sort: nil, limit: 5, offset: 0)
            == "SELECT * FROM \"users\" WHERE (id = 1) LIMIT 5 OFFSET 0")
        #expect(lite.selectPage(plain, filter: ";", sort: nil, limit: 5, offset: 0)
            == "SELECT * FROM \"users\" LIMIT 5 OFFSET 0")
        #expect(pg.selectPage(plain, filter: "id = 1 -- note", sort: nil, limit: 5, offset: 0)
            == "SELECT * FROM \"users\" WHERE (id = 1 -- note\n) LIMIT 5 OFFSET 0")
        #expect(my.selectPage(plain, filter: "id = 1 # note", sort: nil, limit: 5, offset: 0)
            == "SELECT * FROM `users` WHERE (id = 1 # note\n) LIMIT 5 OFFSET 0")
    }

    @Test func selectPageClampsNegativeValues() {
        #expect(pg.selectPage(plain, filter: nil, sort: nil, limit: -1, offset: -10)
            == "SELECT * FROM \"users\" LIMIT 0 OFFSET 0")
    }

    @Test func countStatements() {
        #expect(pg.count(users, filter: nil) == "SELECT COUNT(*) FROM \"public\".\"users\"")
        #expect(my.count(plain, filter: "\t") == "SELECT COUNT(*) FROM `users`")
        #expect(lite.count(plain, filter: "a = 1 OR b = 2") == "SELECT COUNT(*) FROM \"users\" WHERE (a = 1 OR b = 2)")
    }

    // MARK: DML

    @Test func updateStatements() {
        #expect(pg.update(users, changes: [("name", "O'Brien"), ("note", nil)], key: [("id", "1"), ("tenant", nil)])
            == "UPDATE \"public\".\"users\" SET \"name\" = 'O''Brien', \"note\" = NULL WHERE \"id\" = '1' AND \"tenant\" IS NULL")
        #expect(my.update(plain, changes: [("path", "C:\\")], key: [("id", "7")])
            == "UPDATE `users` SET `path` = _utf8mb4 X'433A5C' WHERE `id` = '7'")
    }

    @Test func keyConditions() {
        #expect(pg.keyCondition([("id", "1"), ("tenant", nil)]) == #""id" = '1' AND "tenant" IS NULL"#)
        #expect(my.keyCondition([("id", "\\x0aFF")], binaryColumns: ["id"]) == "`id` = X'0aFF'")
        #expect(lite.keyCondition([]) == "1 = 0")
    }

    @Test func deleteStatements() {
        #expect(pg.delete(users, key: [("id", "1")]) == "DELETE FROM \"public\".\"users\" WHERE \"id\" = '1'")
        #expect(lite.delete(plain, key: [("a", nil), ("b", "x")]) == "DELETE FROM \"users\" WHERE \"a\" IS NULL AND \"b\" = 'x'")
    }

    @Test(arguments: DatabaseKind.sqlKinds)
    func emptyKeyNeverMatchesRows(kind: DatabaseKind) {
        let d = SQLDialect(kind: kind)
        #expect(d.delete(plain, key: []) == "DELETE FROM \(d.qualifiedName(plain)) WHERE 1 = 0")
        #expect(d.update(plain, changes: [("a", "1")], key: [])
            == "UPDATE \(d.qualifiedName(plain)) SET \(d.quoteIdentifier("a")) = '1' WHERE 1 = 0")
    }

    @Test func insertStatements() {
        #expect(pg.insert(users, values: [("name", "x"), ("age", nil)])
            == "INSERT INTO \"public\".\"users\" (\"name\", \"age\") VALUES ('x', NULL)")
        #expect(my.insert(plain, values: [("a`b", "\\")]) == "INSERT INTO `users` (`a``b`) VALUES (_utf8mb4 X'5C')")
    }

    @Test func insertWithoutValues() {
        #expect(pg.insert(users, values: []) == "INSERT INTO \"public\".\"users\" DEFAULT VALUES")
        #expect(lite.insert(plain, values: []) == "INSERT INTO \"users\" DEFAULT VALUES")
        #expect(my.insert(plain, values: []) == "INSERT INTO `users` () VALUES ()")
    }

    // MARK: DDL

    @Test func truncateStatements() {
        #expect(pg.truncate(users) == "TRUNCATE TABLE \"public\".\"users\"")
        #expect(my.truncate(plain) == "TRUNCATE TABLE `users`")
        #expect(lite.truncate(plain) == "DELETE FROM \"users\"")
    }

    @Test func dropStatements() {
        #expect(pg.drop(users, kind: .table) == "DROP TABLE \"public\".\"users\"")
        #expect(pg.drop(users, kind: .view) == "DROP VIEW \"public\".\"users\"")
        #expect(pg.drop(users, kind: .materializedView) == "DROP MATERIALIZED VIEW \"public\".\"users\"")
        #expect(my.drop(plain, kind: .table) == "DROP TABLE `users`")
        #expect(my.drop(plain, kind: .view) == "DROP VIEW `users`")
        #expect(lite.drop(plain, kind: .view) == "DROP VIEW \"users\"")
        #expect(lite.drop(plain, kind: .materializedView) == "DROP VIEW \"users\"")
    }

    @Test func transactionStatements() {
        #expect(pg.beginTransaction == "BEGIN")
        #expect(lite.beginTransaction == "BEGIN")
        #expect(my.beginTransaction == "START TRANSACTION")
        #expect(my.commit == "COMMIT")
        #expect(pg.rollback == "ROLLBACK")
    }

    // MARK: Executed against a real SQLite engine

    static let trickyValues: [String] = [
        "", "plain", "it's", "''", "\\", "C:\\path\\", "\\'", "'; DROP TABLE t; --", "/* x */", "$$a$$",
        "\"quoted\"", "`tick`", "line1\nline2\r\n", "tab\there", "😀🎉👩‍👩‍👧", "'\u{301}", "e\u{301}",
        "世界", "a\0b", "\0", "\0'\0", "NULL",
    ]

    @Test func sqliteRoundTripsTrickyValuesAndIdentifiers() throws {
        let db = try DialectTestDatabase()
        let table = TableRef(schema: "main", name: "we\"ird; table")
        let column = "va\"l ue"
        try db.exec("CREATE TABLE \(lite.qualifiedName(table)) (id INTEGER PRIMARY KEY, \(lite.quoteIdentifier(column)) TEXT)")
        for (index, value) in Self.trickyValues.enumerated() {
            try db.exec(lite.insert(table, values: [("id", String(index)), (column, value)]))
        }
        try db.exec(lite.insert(table, values: [("id", "999"), (column, nil)]))

        let rows = try db.rows("SELECT \(lite.quoteIdentifier(column)) FROM \(lite.qualifiedName(table)) ORDER BY id")
        #expect(rows.map { $0[0] } == Self.trickyValues.map(Optional.some) + [nil])

        // Each value can be found again through a WHERE built from literals.
        for value in Self.trickyValues {
            let sql = "SELECT COUNT(*) FROM \(lite.qualifiedName(table)) WHERE \(lite.quoteIdentifier(column)) = \(lite.literal(value))"
            #expect(try db.rows(sql) == [["1"]], "value: \(value.debugDescription)")
        }
    }

    @Test func sqliteExecutesGeneratedDML() throws {
        let db = try DialectTestDatabase()
        let table = TableRef(schema: nil, name: "items")
        try db.exec("CREATE TABLE items (a TEXT, b TEXT, n INTEGER DEFAULT 42)")
        try db.exec(lite.insert(table, values: [("a", "1"), ("b", nil)]))
        try db.exec(lite.insert(table, values: [("a", "2"), ("b", "x")]))
        try db.exec(lite.insert(table, values: []))
        #expect(try db.rows(lite.count(table, filter: nil)) == [["3"]])
        #expect(try db.rows(lite.count(table, filter: "n = 42 AND a IS NULL")) == [["1"]])

        try db.exec(lite.update(table, changes: [("b", "it's")], key: [("a", "1"), ("b", nil)]))
        #expect(db.changes == 1)
        #expect(try db.rows("SELECT b FROM items WHERE a = '1'") == [["it's"]])

        try db.exec(lite.update(table, changes: [("b", "zzz")], key: []))
        #expect(db.changes == 0)
        try db.exec(lite.delete(table, key: []))
        #expect(db.changes == 0)

        let page = try db.rows(lite.selectPage(table, filter: "a IS NOT NULL -- only real rows", sort: GridSort(column: "a", ascending: false), limit: 1, offset: 1))
        #expect(page == [["1", "it's", "42"]])

        try db.exec(lite.delete(table, key: [("a", nil)]))
        #expect(db.changes == 1)
        try db.exec(lite.truncate(table))
        #expect(try db.rows(lite.count(table, filter: nil)) == [["0"]])

        try db.exec("CREATE VIEW v AS SELECT * FROM items")
        try db.exec(lite.drop(TableRef(schema: nil, name: "v"), kind: .view))
        try db.exec(lite.drop(table, kind: .table))
        #expect(try db.rows("SELECT COUNT(*) FROM sqlite_master") == [["0"]])
    }

    @Test func sqliteKeepsNULInsideLiterals() throws {
        let db = try DialectTestDatabase()
        #expect(try db.rows("SELECT hex(\(lite.literal("a\0b"))), length(CAST(\(lite.literal("\0\0")) AS BLOB))") == [["610062", "2"]])
    }
}

/// Minimal in-memory SQLite connection for executing generated SQL in tests.
private final class DialectTestDatabase {
    struct Failure: Error, CustomStringConvertible { var description: String }

    private var db: OpaquePointer?

    init() throws {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw Failure(description: "open failed") }
    }

    deinit { sqlite3_close(db) }

    var changes: Int32 { sqlite3_changes(db) }

    func exec(_ sql: String) throws {
        _ = try rows(sql)
    }

    /// Runs exactly one statement (fails if the SQL contains more than one) and returns its rows as text.
    func rows(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        let length = sql.utf8.count
        try sql.withCString { pointer in
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(db, pointer, Int32(length), &statement, &tail) == SQLITE_OK else {
                throw Failure(description: String(cString: sqlite3_errmsg(db)))
            }
            if let tail, tail - pointer != length {
                sqlite3_finalize(statement)
                throw Failure(description: "more than one statement")
            }
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
            var row: [String?] = []
            for column in 0..<sqlite3_column_count(statement) {
                if sqlite3_column_type(statement, column) == SQLITE_NULL {
                    row.append(nil)
                } else if let text = sqlite3_column_text(statement, column) {
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row.append(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
                } else {
                    row.append("")
                }
            }
            result.append(row)
        }
        return result
    }
}

@Suite struct SQLDialectBitTests {
    private let my = SQLDialect(kind: .mysql)
    private let table = TableRef(schema: nil, name: "t")

    @Test func bitColumnsAreWrittenAsNumbers() {
        #expect(my.update(table, changes: [("flag", "1")], key: [("id", "1")], bitColumns: ["flag"])
            == "UPDATE `t` SET `flag` = 1 WHERE `id` = '1'")
        #expect(my.insert(table, values: [("id", "2"), ("mask", "255")], bitColumns: ["mask"])
            == "INSERT INTO `t` (`id`, `mask`) VALUES ('2', 255)")
        #expect(my.delete(table, key: [("bits", "18446744073709551615")], bitColumns: ["bits"])
            == "DELETE FROM `t` WHERE `bits` = 18446744073709551615")
        #expect(my.keyCondition([("bits", "0")], bitColumns: ["bits"]) == "`bits` = 0")
        #expect(my.literal(nil, bit: true) == "NULL")
    }

    @Test func nonNumericBitInputStaysQuoted() {
        #expect(my.literal("abc", bit: true) == "'abc'")
        #expect(my.literal("-1", bit: true) == "'-1'")
        #expect(my.literal("1; DROP TABLE t", bit: true) == "'1; DROP TABLE t'")
        #expect(my.literal("18446744073709551616", bit: true) == "'18446744073709551616'")
    }

    @Test func detectsBitTypes() {
        #expect(SQLDialect.isBitType("bit(1)", kind: .mysql))
        #expect(SQLDialect.isBitType("BIT(64)", kind: .mysql))
        #expect(SQLDialect.isBitType("bit", kind: .mysql))
        #expect(!SQLDialect.isBitType("bigint", kind: .mysql))
        #expect(!SQLDialect.isBitType("bit(1)", kind: .postgres))
    }
}
