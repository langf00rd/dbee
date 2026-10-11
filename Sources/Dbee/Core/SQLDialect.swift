import Foundation

/// SQL text generation for a specific engine. Pure functions, no I/O.
struct SQLDialect: Sendable {
    var kind: DatabaseKind

    /// "name" for Postgres/SQLite, `name` for MySQL, with embedded quote characters doubled.
    func quoteIdentifier(_ name: String) -> String {
        fatalError("TODO")
    }

    /// schema.table, each part quoted. Omits the schema when nil.
    func qualifiedName(_ table: TableRef) -> String {
        fatalError("TODO")
    }

    /// NULL for nil, otherwise a correctly escaped string literal ('it''s'; MySQL also escapes backslashes).
    func literal(_ value: CellValue) -> String {
        fatalError("TODO")
    }

    /// SELECT * FROM t [WHERE filter] [ORDER BY col ASC|DESC] LIMIT n OFFSET m
    /// `filter` is a raw user-supplied WHERE expression (without the WHERE keyword), or nil/blank.
    func selectPage(_ table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) -> String {
        fatalError("TODO")
    }

    /// SELECT COUNT(*) FROM t [WHERE filter]
    func count(_ table: TableRef, filter: String?) -> String {
        fatalError("TODO")
    }

    /// UPDATE t SET a = 'x', b = NULL WHERE pk1 = '1' AND pk2 IS NULL
    /// `changes` and `key` are ordered (column, value) pairs.
    func update(_ table: TableRef, changes: [(String, CellValue)], key: [(String, CellValue)]) -> String {
        fatalError("TODO")
    }

    /// DELETE FROM t WHERE pk1 = '1' AND ...
    func delete(_ table: TableRef, key: [(String, CellValue)]) -> String {
        fatalError("TODO")
    }

    /// INSERT INTO t (a, b) VALUES ('x', NULL). With no values: INSERT INTO t DEFAULT VALUES
    /// (MySQL: INSERT INTO t () VALUES ()).
    func insert(_ table: TableRef, values: [(String, CellValue)]) -> String {
        fatalError("TODO")
    }

    func truncate(_ table: TableRef) -> String {
        fatalError("TODO")
    }

    func drop(_ table: TableRef, kind: TableKind) -> String {
        fatalError("TODO")
    }

    /// Statements that open/commit/rollback a transaction for this engine.
    var beginTransaction: String { kind == .mysql ? "START TRANSACTION" : "BEGIN" }
    var commit: String { "COMMIT" }
    var rollback: String { "ROLLBACK" }
}

/// Splits a SQL script into individual statements on top-level semicolons.
/// Must respect: single-quoted strings (with '' escapes, and backslash escapes for MySQL),
/// double-quoted identifiers, MySQL backticks, -- and # (MySQL) line comments, /* */ block comments,
/// Postgres dollar-quoted strings ($$...$$, $tag$...$tag$), and E'..' strings with backslash escapes.
/// Returned statements are trimmed, exclude the trailing semicolon, and empty / comment-only statements are dropped.
enum SQLSplitter {
    struct Statement: Equatable, Sendable {
        var text: String
        /// UTF-16 range of the statement text within the original script (for highlighting / run-at-cursor).
        var range: NSRange
    }

    static func split(_ script: String, kind: DatabaseKind) -> [Statement] {
        fatalError("TODO")
    }

    /// The statement containing (or immediately preceding) the given UTF-16 cursor offset.
    static func statement(at cursor: Int, in script: String, kind: DatabaseKind) -> Statement? {
        fatalError("TODO")
    }
}
