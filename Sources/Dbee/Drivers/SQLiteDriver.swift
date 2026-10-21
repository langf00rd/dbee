import Foundation
import SQLite3

/// SQLite driver built directly on the system SQLite3 C API.
///
/// Every database call runs on a private serial queue, so statements never interleave (transactions and
/// temp tables behave like a terminal client) and the caller's actor is never blocked. The only call made
/// from other threads is `sqlite3_interrupt`, guarded by `lock` so it can never touch a closed handle.
/// No SQLite logging, tracing or profiling hooks are ever installed.
final class SQLiteDriver: DatabaseDriver, @unchecked Sendable {
    let kind: DatabaseKind = .sqlite
    /// True when SQLite opened the main database read-only (e.g. a write-protected file).
    let isReadOnly: Bool

    private let queue = DispatchQueue(label: "dbee.sqlite", qos: .userInitiated)
    /// Guards `handle`, `isClosed` and `running`. `handle` is only ever set to nil on `queue`.
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var isClosed = false
    /// The operation currently executing on `queue`, if any.
    private var running: OperationToken?

    /// Identity token for one queued call, used to route task cancellation to the right statement.
    private final class OperationToken: @unchecked Sendable {
        /// Set (under the driver's lock) when the caller's task is cancelled while still queued.
        var isCancelled = false
    }

    private init(handle: OpaquePointer, isReadOnly: Bool) {
        self.handle = handle
        self.isReadOnly = isReadOnly
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: Opening

    /// Opens a database file read-write (SQLite falls back to read-only for write-protected files).
    /// The file must already exist unless `create` is true. `path` may start with `~` or be a `file://` URL;
    /// ":memory:" opens a private in-memory database.
    static func open(path: String, create: Bool = false) throws -> SQLiteDriver {
        let resolved = resolvedPath(path)
        guard !resolved.isEmpty else {
            throw DatabaseError("No database file selected", detail: "Choose a SQLite database file to open.")
        }
        let name = resolved == ":memory:" ? resolved : URL(fileURLWithPath: resolved).lastPathComponent

        if resolved != ":memory:" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw DatabaseError("“\(name)” is a folder", detail: "Choose a SQLite database file instead.")
                }
            } else if !create {
                throw DatabaseError(
                    "“\(name)” doesn't exist",
                    detail: "The database file may have been moved, renamed or deleted."
                )
            }
        }

        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if create { flags |= SQLITE_OPEN_CREATE }
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(resolved, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let error = openError(db, code: db.map { sqlite3_extended_errcode($0) } ?? rc, name: name)
            sqlite3_close_v2(db)
            throw error
        }
        sqlite3_extended_result_codes(db, 1)

        // Touch the schema so a non-database file fails now rather than on the first query. This runs
        // before the busy timeout is set, so a file locked by another process can't stall the caller.
        if sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) != SQLITE_OK {
            let code = sqlite3_extended_errcode(db)
            if code & 0xff != SQLITE_BUSY, code & 0xff != SQLITE_LOCKED {
                let error = openError(db, code: code, name: name)
                sqlite3_close_v2(db)
                throw error
            }
        }

        sqlite3_busy_timeout(db, 5_000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        return SQLiteDriver(handle: db, isReadOnly: sqlite3_db_readonly(db, "main") == 1)
    }

    /// `open(path:create:)` on a background thread, so a file on a slow volume never blocks the caller.
    static func connect(path: String, create: Bool = false) async throws -> SQLiteDriver {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try open(path: path, create: create) })
            }
        }
    }

    /// Trims the path, expands `~`, and turns `file://` URLs into plain paths.
    static func resolvedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == ":memory:" { return trimmed }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL.path
        }
        return ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func openError(_ db: OpaquePointer?, code: Int32, name: String) -> DatabaseError {
        let message = String(cString: db.map { sqlite3_errmsg($0) } ?? sqlite3_errstr(code))
        if code & 0xff == SQLITE_NOTADB {
            return DatabaseError(
                "“\(name)” isn't a SQLite database",
                detail: "\(message) [\(describe(code: code))]. The file may be encrypted or use another format."
            )
        }
        return DatabaseError("Couldn't open “\(name)”", detail: "\(message) [\(describe(code: code))]")
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        "SQLite " + String(cString: sqlite3_libversion())
    }

    func listDatabases() async throws -> [String] {
        try await perform { db in
            try Self.rows("SELECT name FROM pragma_database_list WHERE name <> 'temp' ORDER BY seq", on: db)
                .compactMap { $0.first ?? nil }
        }
    }

    func currentDatabase() async throws -> String { "main" }

    func listSchemas() async throws -> [SchemaInfo] {
        try await perform { db in
            let rows = try Self.rows(#"""
                SELECT name, type FROM main.sqlite_master
                WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\_%' ESCAPE '\'
                """#, on: db)
            let tables = rows.compactMap { row -> TableInfo? in
                guard let name = row[0] else { return nil }
                return TableInfo(ref: TableRef(schema: nil, name: name), kind: row[1] == "view" ? .view : .table)
            }
            .sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
            return [SchemaInfo(name: "main", tables: tables)]
        }
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        try await perform { db in try Self.structure(of: table, on: db) }
    }

    /// Runs the first statement in `sql`; any further statements are ignored. `maxRows <= 0` means no limit.
    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        try await perform { db in try Self.run(sql, maxRows: maxRows, on: db) }
    }

    /// SQLite leaves autocommit mode while a BEGIN is open. Safe off the queue (the handle is FULLMUTEX).
    var isInTransaction: Bool? {
        get async { lock.withLock { handle.map { sqlite3_get_autocommit($0) == 0 } } }
    }

    func cancelCurrentQuery() async {
        interrupt(onlyIf: nil)
    }

    func close() async {
        lock.withLock { isClosed = true }
        // Stop a long-running statement so closing isn't stuck behind it. Queued calls fail fast.
        interrupt(onlyIf: nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let db = self.lock.withLock {
                    let db = self.handle
                    self.handle = nil
                    return db
                }
                if let db { sqlite3_close_v2(db) }
                continuation.resume()
            }
        }
    }

    // MARK: Serialization

    /// Runs `body` on the driver's queue. If the calling task is cancelled while `body` is waiting in the
    /// queue it is skipped (CancellationError); if cancelled while running, its statement is interrupted.
    /// A task that is already cancelled when it calls in (e.g. issuing a ROLLBACK during cleanup) runs normally.
    private func perform<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        if Task.isCancelled { return try await enqueue(token: OperationToken(), body) }
        let token = OperationToken()
        return try await withTaskCancellationHandler {
            try await enqueue(token: token, body)
        } onCancel: {
            self.lock.withLock { token.isCancelled = true }
            self.interrupt(onlyIf: token)
        }
    }

    private func enqueue<T: Sendable>(
        token: OperationToken,
        _ body: @escaping @Sendable (OpaquePointer) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let start: Result<OpaquePointer, Error> = self.lock.withLock {
                    if token.isCancelled { return .failure(CancellationError()) }
                    guard !self.isClosed, let db = self.handle else {
                        return .failure(DatabaseError("The database connection is closed."))
                    }
                    self.running = token
                    return .success(db)
                }
                let db: OpaquePointer
                switch start {
                case .success(let handle): db = handle
                case .failure(let error):
                    continuation.resume(throwing: error)
                    return
                }
                let result = Result { try body(db) }
                self.lock.withLock { self.running = nil }
                continuation.resume(with: result)
            }
        }
    }

    /// Interrupts the running statement (only if it belongs to `token`, when given). Thread-safe.
    private func interrupt(onlyIf token: OperationToken?) {
        lock.withLock {
            guard let handle, let running else { return }
            if let token, token !== running { return }
            sqlite3_interrupt(handle)
        }
    }

    // MARK: Executing (on queue)

    private static func run(_ sql: String, maxRows: Int, on db: OpaquePointer) throws -> QueryResult {
        let start = DispatchTime.now()
        let limit = maxRows > 0 ? maxRows : Int.max
        guard let stmt = try prepareFirst(sql, on: db) else {
            return QueryResult(statement: sql, columns: [], rows: [], rowsAffected: nil, duration: elapsed(since: start))
        }
        var finalized = false
        defer { if !finalized { sqlite3_finalize(stmt) } }

        let columnCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<columnCount).map { i in
            sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "?column?"
        }
        // A write (e.g. INSERT … RETURNING) only commits, and can still fail on a deferred constraint,
        // once it is stepped to the end; only a read-only statement may stop at the row limit.
        let readOnly = sqlite3_stmt_readonly(stmt) != 0
        var rows: [[CellValue]] = []
        var truncated = false
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(db) }
            if rows.count >= limit {
                truncated = true
                if readOnly { break }
                continue
            }
            rows.append(readRow(stmt, columnCount: columnCount))
        }
        finalized = true
        guard sqlite3_finalize(stmt) == SQLITE_OK else { throw lastError(db) }

        // sqlite3_changes keeps the count of the last INSERT/UPDATE/DELETE, so only report it for DML.
        var rowsAffected: Int?
        if columnCount == 0, dataModifyingKeywords.contains(leadingKeyword(sql)) {
            rowsAffected = Int(sqlite3_changes64(db))
        }
        return QueryResult(
            statement: sql,
            columns: columns,
            rows: rows,
            rowsAffected: rowsAffected,
            duration: elapsed(since: start),
            truncated: truncated
        )
    }

    private static let dataModifyingKeywords: Set<String> = ["INSERT", "UPDATE", "DELETE", "REPLACE", "WITH"]

    /// Prepares the first non-empty statement in `sql`, or returns nil when there is only whitespace/comments.
    private static func prepareFirst(_ sql: String, on db: OpaquePointer) throws -> OpaquePointer? {
        try sql.withCString { base -> OpaquePointer? in
            var cursor = base
            while cursor.pointee != 0 {
                var stmt: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(db, cursor, -1, &stmt, &tail) == SQLITE_OK else {
                    sqlite3_finalize(stmt)
                    throw lastError(db)
                }
                if let stmt { return stmt }
                guard let tail, tail > cursor else { break }
                cursor = tail
            }
            return nil
        }
    }

    /// The first word of `sql`, uppercased, skipping whitespace and comments.
    static func leadingKeyword(_ sql: String) -> String {
        var rest = Substring(sql)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            if rest.hasPrefix("--") {
                rest = rest.drop(while: { !$0.isNewline })
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return "" }
                rest = rest[end.upperBound...]
            } else {
                break
            }
        }
        return rest.prefix(while: \.isLetter).uppercased()
    }

    private static func readRow(_ stmt: OpaquePointer, columnCount: Int) -> [CellValue] {
        var row: [CellValue] = []
        row.reserveCapacity(columnCount)
        for i in 0..<Int32(columnCount) {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL:
                row.append(nil)
            case SQLITE_INTEGER:
                row.append(String(sqlite3_column_int64(stmt, i)))
            case SQLITE_BLOB:
                row.append(hexString(stmt, i))
            case SQLITE_FLOAT:
                // The shortest text that reads back as the same value (as PostgreSQL and MySQL print floats).
                // SQLite's own conversion prints 17 digits, e.g. 32383.079999999998 for 32383.08.
                let value = sqlite3_column_double(stmt, i)
                row.append(value.isFinite ? value.description : text(stmt, i))
            default:
                row.append(text(stmt, i))
            }
        }
        return row
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String {
        guard let bytes = sqlite3_column_text(stmt, i) else { return "" }
        let count = Int(sqlite3_column_bytes(stmt, i))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// BLOB as "\x" followed by lowercase hex.
    private static func hexString(_ stmt: OpaquePointer, _ i: Int32) -> String {
        let raw = sqlite3_column_blob(stmt, i)
        let count = Int(sqlite3_column_bytes(stmt, i))
        guard count > 0, let raw else { return "\\x" }
        let bytes = UnsafeRawBufferPointer(start: raw, count: count)
        return String(unsafeUninitializedCapacity: 2 + 2 * count) { out in
            out[0] = UInt8(ascii: "\\")
            out[1] = UInt8(ascii: "x")
            var j = 2
            for byte in bytes {
                out[j] = hexDigits[Int(byte >> 4)]
                out[j + 1] = hexDigits[Int(byte & 0x0f)]
                j += 2
            }
            return j
        }
    }

    private static func elapsed(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Runs an internal query with bound text parameters and returns every row.
    private static func rows(_ sql: String, _ parameters: [String] = [], on db: OpaquePointer) throws -> [[CellValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw lastError(db)
        }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in parameters.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        var result: [[CellValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return result }
            guard rc == SQLITE_ROW else { throw lastError(db) }
            result.append(readRow(stmt, columnCount: columnCount))
        }
    }

    /// SQLITE_TRANSIENT: SQLite copies bound values before the call returns.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Structure (on queue)

    private static func structure(of table: TableRef, on db: OpaquePointer) throws -> TableStructure {
        let schema = table.schema ?? "main"
        let master = quoteIdentifier(schema) + ".sqlite_master"

        // Columns. hidden: 0 normal, 1 hidden virtual-table column, 2/3 generated virtual/stored.
        let columnRows = try rows(
            #"SELECT name, type, "notnull", dflt_value, pk, hidden FROM pragma_table_xinfo(?1, ?2) ORDER BY cid"#,
            [table.name, schema], on: db
        )
        guard !columnRows.isEmpty else { throw DatabaseError("No such table: \(table.name)") }
        var columns: [ColumnInfo] = []
        var primaryKey: [(ordinal: Int, name: String)] = []
        for row in columnRows where row[5] != "1" {
            let name = row[0] ?? ""
            let ordinal = Int(row[4] ?? "") ?? 0
            if ordinal > 0 { primaryKey.append((ordinal, name)) }
            let comment: String? = switch row[5] {
            case "2": "Generated column (virtual)"
            case "3": "Generated column (stored)"
            default: nil
            }
            columns.append(ColumnInfo(
                name: name,
                dataType: row[1] ?? "",
                isNullable: row[2] == "0",
                defaultValue: row[3],
                isPrimaryKey: ordinal > 0,
                comment: comment
            ))
        }
        let primaryKeyColumns = primaryKey.sorted { $0.ordinal < $1.ordinal }.map(\.name)

        // Indexes. origin: 'c' CREATE INDEX, 'u' UNIQUE constraint, 'pk' PRIMARY KEY constraint.
        let indexSQL = Dictionary(
            try rows("SELECT name, sql FROM \(master) WHERE type = 'index' AND tbl_name = ?1 COLLATE NOCASE",
                     [table.name], on: db)
                .compactMap { row in row[0].map { ($0, row[1]) } },
            uniquingKeysWith: { first, _ in first }
        )
        var indexes: [IndexInfo] = []
        for row in try rows(#"SELECT name, "unique", origin FROM pragma_index_list(?1, ?2)"#, [table.name, schema], on: db) {
            guard let name = row[0] else { continue }
            let indexColumns = try rows("SELECT name FROM pragma_index_info(?1, ?2) ORDER BY seqno", [name, schema], on: db)
                .map { $0[0] ?? "(expression)" }
            let isPrimary = row[2] == "pk"
            let isUnique = row[1] == "1"
            let definition = (indexSQL[name] ?? nil)
                ?? "\(isPrimary ? "PRIMARY KEY" : "UNIQUE") (\(indexColumns.joined(separator: ", ")))"
            indexes.append(IndexInfo(name: name, columns: indexColumns, isUnique: isUnique, isPrimary: isPrimary, definition: definition))
        }
        // An INTEGER PRIMARY KEY aliases the rowid and has no separate index; list it like other engines do.
        if !primaryKeyColumns.isEmpty, !indexes.contains(where: \.isPrimary) {
            indexes.append(IndexInfo(
                name: "PRIMARY KEY",
                columns: primaryKeyColumns,
                isUnique: true,
                isPrimary: true,
                definition: "PRIMARY KEY (\(primaryKeyColumns.joined(separator: ", ")))"
            ))
        }
        indexes.sort { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }

        let foreignKeys = try foreignKeys(of: table, schema: schema, on: db)

        // DDL: the CREATE statement followed by explicit indexes and triggers.
        let ddlParts = try rows("""
            SELECT sql FROM \(master)
            WHERE tbl_name = ?1 COLLATE NOCASE AND sql IS NOT NULL
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 0 WHEN 'index' THEN 1 ELSE 2 END, name
            """, [table.name], on: db)
            .compactMap { $0[0] }
        let ddl = ddlParts.isEmpty ? nil : ddlParts.map { $0 + ";" }.joined(separator: "\n\n")

        return TableStructure(columns: columns, indexes: indexes, foreignKeys: foreignKeys, ddl: ddl)
    }

    private static func foreignKeys(of table: TableRef, schema: String, on db: OpaquePointer) throws -> [ForeignKeyInfo] {
        let rows = try rows(#"""
            SELECT id, "table", "from", "to", on_update, on_delete
            FROM pragma_foreign_key_list(?1, ?2) ORDER BY id, seq
            """#, [table.name, schema], on: db)

        // Group the per-column rows by constraint id, keeping their order.
        var groups: [(id: String, rows: [[CellValue]])] = []
        for row in rows {
            let id = row[0] ?? ""
            if groups.last?.id == id {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append((id, [row]))
            }
        }

        var usedNames = Set<String>()
        return try groups.map { group in
            let first = group.rows[0]
            let parent = first[1] ?? ""
            let columns = group.rows.map { $0[2] ?? "" }
            var referenced = group.rows.map { $0[3] }
            // `REFERENCES parent` without a column list targets the parent's primary key.
            if referenced.contains(where: { $0 == nil }) {
                let parentKey = try Self.rows(
                    "SELECT name FROM pragma_table_xinfo(?1, ?2) WHERE pk > 0 ORDER BY pk", [parent, schema], on: db
                ).compactMap { $0[0] }
                referenced = referenced.enumerated().map { index, name in
                    name ?? (index < parentKey.count ? parentKey[index] : nil)
                }
            }
            // SQLite doesn't expose constraint names; use the Postgres-style default.
            var name = "\(table.name)_\(columns.joined(separator: "_"))_fkey"
            if !usedNames.insert(name).inserted {
                name += "_\(group.id)"
                usedNames.insert(name)
            }
            return ForeignKeyInfo(
                name: name,
                columns: columns,
                referencedTable: TableRef(schema: table.schema, name: parent),
                referencedColumns: referenced.map { $0 ?? "rowid" },
                onUpdate: first[4],
                onDelete: first[5]
            )
        }
    }

    // MARK: Errors

    /// The connection's last error: SQLite's message, with the extended result code as detail.
    private static func lastError(_ db: OpaquePointer) -> DatabaseError {
        let code = sqlite3_extended_errcode(db)
        if code & 0xff == SQLITE_INTERRUPT {
            return DatabaseError("Query cancelled", detail: describe(code: code))
        }
        return DatabaseError(String(cString: sqlite3_errmsg(db)), detail: describe(code: code))
    }

    /// "SQLITE_CONSTRAINT_UNIQUE (2067)", "SQLITE_ERROR (1)", …
    private static func describe(code: Int32) -> String {
        let primary = code & 0xff
        guard var name = primaryCodeNames[primary] else { return "SQLite error \(code)" }
        if primary == SQLITE_CONSTRAINT, let sub = constraintCodeNames[code >> 8] {
            name += "_" + sub
        }
        return "\(name) (\(code))"
    }

    private static let primaryCodeNames: [Int32: String] = [
        1: "SQLITE_ERROR", 2: "SQLITE_INTERNAL", 3: "SQLITE_PERM", 4: "SQLITE_ABORT", 5: "SQLITE_BUSY",
        6: "SQLITE_LOCKED", 7: "SQLITE_NOMEM", 8: "SQLITE_READONLY", 9: "SQLITE_INTERRUPT", 10: "SQLITE_IOERR",
        11: "SQLITE_CORRUPT", 12: "SQLITE_NOTFOUND", 13: "SQLITE_FULL", 14: "SQLITE_CANTOPEN", 15: "SQLITE_PROTOCOL",
        16: "SQLITE_EMPTY", 17: "SQLITE_SCHEMA", 18: "SQLITE_TOOBIG", 19: "SQLITE_CONSTRAINT", 20: "SQLITE_MISMATCH",
        21: "SQLITE_MISUSE", 22: "SQLITE_NOLFS", 23: "SQLITE_AUTH", 24: "SQLITE_FORMAT", 25: "SQLITE_RANGE",
        26: "SQLITE_NOTADB",
    ]

    private static let constraintCodeNames: [Int32: String] = [
        1: "CHECK", 2: "COMMITHOOK", 3: "FOREIGNKEY", 4: "FUNCTION", 5: "NOTNULL", 6: "PRIMARYKEY",
        7: "TRIGGER", 8: "UNIQUE", 9: "VTAB", 10: "ROWID", 11: "PINNED", 12: "DATATYPE",
    ]
}
