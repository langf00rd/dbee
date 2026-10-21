import Foundation
import Testing
@testable import Dbee

@Suite("SQLiteDriver")
struct SQLiteDriverTests {
    // MARK: Writes past the row limit

    /// A write is stepped to the end even past the row limit, so a deferred constraint that fails at
    /// completion is reported instead of a successful, truncated RETURNING result.
    @Test func truncatedReturningSurfacesDeferredFailure() async throws {
        try await withDatabase { driver, _ in
            _ = try await driver.execute("PRAGMA foreign_keys = ON", maxRows: 0)
            _ = try await driver.execute("CREATE TABLE parent(id INTEGER PRIMARY KEY)", maxRows: 0)
            _ = try await driver.execute("CREATE TABLE child(p REFERENCES parent DEFERRABLE INITIALLY DEFERRED)", maxRows: 0)
            await #expect(throws: DatabaseError.self) {
                try await driver.execute("INSERT INTO child VALUES(1),(2),(3) RETURNING p", maxRows: 1)
            }
            let count = try await driver.execute("SELECT count(*) FROM child", maxRows: 0)
            #expect(count.rows == [["0"]])
            await driver.close()
        }
    }

    @Test func truncatedReturningCommitsEveryRow() async throws {
        try await withDatabase { driver, _ in
            _ = try await driver.execute("CREATE TABLE t(v INTEGER)", maxRows: 0)
            let result = try await driver.execute("INSERT INTO t VALUES(1),(2),(3) RETURNING v", maxRows: 1)
            #expect(result.rows == [["1"]])
            #expect(result.truncated)
            let count = try await driver.execute("SELECT count(*) FROM t", maxRows: 0)
            #expect(count.rows == [["3"]])
            // A read still stops at the limit.
            let read = try await driver.execute("SELECT v FROM t ORDER BY v", maxRows: 2)
            #expect(read.rows == [["1"], ["2"]])
            #expect(read.truncated)
            await driver.close()
        }
    }

    // MARK: Helpers

    private static func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbee-sqlite-test-\(UUID().uuidString).sqlite").path
    }

    private static func remove(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Creates a fresh temp-file database, runs `body`, then closes and deletes it.
    private func withDatabase(_ body: (SQLiteDriver, String) async throws -> Void) async throws {
        let path = Self.tempPath()
        defer { Self.remove(path) }
        let driver = try SQLiteDriver.open(path: path, create: true)
        do {
            try await body(driver, path)
        } catch {
            await driver.close()
            throw error
        }
        await driver.close()
    }

    @discardableResult
    private func exec(_ driver: SQLiteDriver, _ sql: String, maxRows: Int = 1_000) async throws -> QueryResult {
        try await driver.execute(sql, maxRows: maxRows)
    }

    private func scalar(_ driver: SQLiteDriver, _ sql: String) async throws -> CellValue {
        try await exec(driver, sql).rows.first?.first ?? nil
    }

    private func expectDatabaseError(
        _ body: () async throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> DatabaseError? {
        do {
            try await body()
            Issue.record("Expected a DatabaseError", sourceLocation: sourceLocation)
            return nil
        } catch let error as DatabaseError {
            return error
        } catch {
            Issue.record("Expected a DatabaseError, got \(error)", sourceLocation: sourceLocation)
            return nil
        }
    }

    // MARK: Opening

    @Test func openMissingFileFailsWithoutCreatingIt() async {
        let path = Self.tempPath()
        defer { Self.remove(path) }
        let error = await expectDatabaseError { _ = try SQLiteDriver.open(path: path) }
        #expect(error?.message.contains("doesn't exist") == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func openWithCreateMakesTheFile() async throws {
        let path = Self.tempPath()
        defer { Self.remove(path) }
        let driver = try SQLiteDriver.open(path: path, create: true)
        #expect(FileManager.default.fileExists(atPath: path))
        try await exec(driver, "CREATE TABLE t (a)")
        await driver.close()

        let reopened = try SQLiteDriver.open(path: path)
        #expect(try await reopened.listSchemas().first?.tables.map(\.ref.name) == ["t"])
        await reopened.close()
    }

    @Test func openRejectsNonDatabaseFile() async throws {
        let path = Self.tempPath()
        defer { Self.remove(path) }
        let junk = String(repeating: "This is definitely not a SQLite database file. ", count: 100)
        try junk.write(toFile: path, atomically: true, encoding: .utf8)
        let error = await expectDatabaseError { _ = try SQLiteDriver.open(path: path) }
        #expect(error?.message.contains("isn't a SQLite database") == true)
        #expect(error?.detail?.contains("file is not a database") == true)
        #expect(error?.detail?.contains("SQLITE_NOTADB") == true)
    }

    @Test func openRejectsDirectoriesAndEmptyPaths() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbee-sqlite-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folderError = await expectDatabaseError { _ = try SQLiteDriver.open(path: dir.path) }
        #expect(folderError?.message.contains("is a folder") == true)
        let emptyError = await expectDatabaseError { _ = try SQLiteDriver.open(path: "   ") }
        #expect(emptyError?.message == "No database file selected")
    }

    @Test func resolvedPathExpandsTildeAndFileURLs() {
        let home = NSHomeDirectory()
        #expect(SQLiteDriver.resolvedPath("~/data/app.db") == home + "/data/app.db")
        #expect(SQLiteDriver.resolvedPath("  /tmp/x.db\n") == "/tmp/x.db")
        #expect(SQLiteDriver.resolvedPath("file:///tmp/my%20db.sqlite") == "/tmp/my db.sqlite")
        #expect(SQLiteDriver.resolvedPath(":memory:") == ":memory:")
    }

    @Test func asyncConnectOpensAndReportsErrors() async throws {
        let path = Self.tempPath()
        defer { Self.remove(path) }
        let driver = try await SQLiteDriver.connect(path: path, create: true)
        #expect(!driver.isReadOnly)
        #expect(try await scalar(driver, "SELECT 'ok'") == "ok")
        await driver.close()
        await #expect(throws: DatabaseError.self) { _ = try await SQLiteDriver.connect(path: path + ".missing") }
    }

    @Test func writeProtectedFileOpensReadOnly() async throws {
        let path = Self.tempPath()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            Self.remove(path)
        }
        let writer = try SQLiteDriver.open(path: path, create: true)
        try await exec(writer, "CREATE TABLE t (a)")
        await writer.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)

        let reader = try SQLiteDriver.open(path: path)
        #expect(reader.isReadOnly)
        #expect(try await scalar(reader, "SELECT count(*) FROM t") == "0")
        let error = await expectDatabaseError { try await exec(reader, "INSERT INTO t VALUES (1)") }
        #expect(error?.message.contains("readonly") == true)
        #expect(error?.detail?.hasPrefix("SQLITE_READONLY") == true)
        await reader.close()
    }

    @Test func inMemoryDatabaseWorks() async throws {
        let driver = try SQLiteDriver.open(path: ":memory:")
        #expect(try await scalar(driver, "SELECT 1 + 1") == "2")
        await driver.close()
    }

    @Test func metadataBasics() async throws {
        try await withDatabase { db, _ in
            let version = try await db.serverVersion()
            #expect(version.hasPrefix("SQLite 3."))
            #expect(try await db.currentDatabase() == "main")
            #expect(try await db.listDatabases() == ["main"])
            #expect(db.kind == .sqlite)
        }
    }

    @Test func pragmasAreApplied() async throws {
        try await withDatabase { db, _ in
            let foreignKeys = try await scalar(db, "PRAGMA foreign_keys")
            let busyTimeout = try await scalar(db, "PRAGMA busy_timeout")
            #expect(foreignKeys == "1")
            #expect(busyTimeout == "5000")
        }
    }

    // MARK: Values

    @Test func everyStorageClassRendersAsText() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE v (i INTEGER, r REAL, s TEXT, b BLOB, n)")
            try await exec(db, "INSERT INTO v VALUES (42, 0.1, 'héllo 🐝', x'00ff10AB', NULL)")
            try await exec(db, "INSERT INTO v VALUES (-9223372036854775808, 3.0, '', x'', 'x')")
            try await exec(db, "INSERT INTO v VALUES (9223372036854775807, 1.5e300, 'line1' || char(10) || 'line2', zeroblob(2), 7)")

            let result = try await exec(db, "SELECT i, r, s, b, n FROM v ORDER BY rowid")
            #expect(result.isRowSet)
            #expect(result.columns == ["i", "r", "s", "b", "n"])
            #expect(result.rows.count == 3)
            #expect(result.rows[0] == ["42", "0.1", "héllo 🐝", "\\x00ff10ab", nil])
            #expect(result.rows[1] == ["-9223372036854775808", "3.0", "", "\\x", "x"])
            #expect(result.rows[2] == ["9223372036854775807", "1.5e+300", "line1\nline2", "\\x0000", "7"])
            #expect(result.rowsAffected == nil)
            #expect(!result.truncated)
            #expect(result.duration >= 0)
        }
    }

    @Test func expressionsAliasesAndEmbeddedNul() async throws {
        try await withDatabase { db, _ in
            let result = try await exec(db, #"SELECT 1 AS "odd ""name""", NULL AS nada, 'a' || char(0) || 'b' AS nul, 0.1 + 0.2 AS sum"#)
            #expect(result.columns == ["odd \"name\"", "nada", "nul", "sum"])
            #expect(result.rows[0][0] == "1")
            #expect(result.rows[0][1] == nil)
            #expect(result.rows[0][2] == "a\u{0}b")
            // The shortest round-trip text, without SQLite's 17-digit noise.
            #expect(result.rows[0][3] == "0.30000000000000004")
            let sums = try await exec(db, "SELECT 32383.08, 2.5 * 2, 1e308 * 10, 0.00001")
            #expect(sums.rows[0] == ["32383.08", "5.0", "Inf", "1e-05"])
        }
    }

    @Test func largeBlobIsFullyHexEncoded() async throws {
        try await withDatabase { db, _ in
            let value = try await scalar(db, "SELECT randomblob(100000)")
            #expect(value?.count == 2 + 200_000)
            #expect(value?.hasPrefix("\\x") == true)
            #expect(value?.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase } == true)
        }
    }

    // MARK: Statements

    @Test func rowsAffectedForDMLOnly() async throws {
        try await withDatabase { db, _ in
            let create = try await exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
            #expect(create.rowsAffected == nil)
            #expect(!create.isRowSet)

            #expect(try await exec(db, "INSERT INTO t (v) VALUES ('a'), ('b'), ('c')").rowsAffected == 3)
            #expect(try await exec(db, "UPDATE t SET v = 'z' WHERE id >= 2").rowsAffected == 2)
            #expect(try await exec(db, "UPDATE t SET v = 'q' WHERE id > 100").rowsAffected == 0)
            #expect(try await exec(db, "REPLACE INTO t (id, v) VALUES (1, 'r')").rowsAffected == 1)
            #expect(try await exec(db, "WITH old AS (SELECT 3 AS id) DELETE FROM t WHERE id IN (SELECT id FROM old)").rowsAffected == 1)
            #expect(try await exec(db, "/* hi */ -- there\n DELETE FROM t").rowsAffected == 2)

            // DDL after DML must not report the stale DML count.
            #expect(try await exec(db, "CREATE INDEX t_v ON t (v)").rowsAffected == nil)
            #expect(try await exec(db, "DROP INDEX t_v").rowsAffected == nil)
        }
    }

    @Test func returningProducesRows() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
            let result = try await exec(db, "INSERT INTO t (v) VALUES ('a'), ('b') RETURNING id, v")
            #expect(result.columns == ["id", "v"])
            #expect(result.rows == [["1", "a"], ["2", "b"]])
        }
    }

    @Test func maxRowsTruncates() async throws {
        try await withDatabase { db, _ in
            let series = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10) SELECT x FROM c"
            let limited = try await exec(db, series, maxRows: 4)
            #expect(limited.rows.map { $0[0] } == ["1", "2", "3", "4"])
            #expect(limited.truncated)
            #expect(limited.summary.contains("limited"))

            let exact = try await exec(db, series, maxRows: 10)
            #expect(exact.rows.count == 10)
            #expect(!exact.truncated)

            let unlimited = try await exec(db, series, maxRows: 0)
            #expect(unlimited.rows.count == 10)
            #expect(!unlimited.truncated)
        }
    }

    @Test func onlyTheFirstStatementRuns() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE t (a INTEGER)")
            try await exec(db, "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)")
            #expect(try await scalar(db, "SELECT count(*) FROM t") == "1")

            let result = try await exec(db, "-- leading comment\n  SELECT 'first';  SELECT 'second'; -- trailing\n")
            #expect(result.rows == [["first"]])
            #expect(try await exec(db, "SELECT 5;   \n\t").rows == [["5"]])
            #expect(try await exec(db, ";; SELECT 6").rows == [["6"]])
        }
    }

    @Test func emptyStatementIsANoOp() async throws {
        try await withDatabase { db, _ in
            let result = try await exec(db, "  -- nothing here\n /* at all */ ")
            #expect(result.columns.isEmpty)
            #expect(result.rows.isEmpty)
            #expect(result.rowsAffected == nil)
        }
    }

    @Test func transactionsSpanCalls() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE t (a)")
            try await exec(db, "BEGIN")
            try await exec(db, "INSERT INTO t VALUES (1)")
            #expect(try await scalar(db, "SELECT count(*) FROM t") == "1")
            try await exec(db, "ROLLBACK")
            #expect(try await scalar(db, "SELECT count(*) FROM t") == "0")
        }
    }

    // MARK: Errors

    @Test func syntaxErrorsCarryTheExtendedCode() async throws {
        try await withDatabase { db, _ in
            let error = await expectDatabaseError { try await exec(db, "SELEC 1") }
            #expect(error?.message.contains("syntax error") == true)
            #expect(error?.detail == "SQLITE_ERROR (1)")

            let missing = await expectDatabaseError { try await exec(db, "SELECT * FROM nope") }
            #expect(missing?.message.contains("no such table") == true)
        }
    }

    @Test func constraintErrors() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE p (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL)")
            try await exec(db, "CREATE TABLE c (pid INTEGER REFERENCES p (id))")
            try await exec(db, "INSERT INTO p VALUES (1, 'a@example.com')")

            let unique = await expectDatabaseError { try await exec(db, "INSERT INTO p VALUES (2, 'a@example.com')") }
            #expect(unique?.message.contains("UNIQUE constraint failed") == true)
            #expect(unique?.detail == "SQLITE_CONSTRAINT_UNIQUE (2067)")

            let notNull = await expectDatabaseError { try await exec(db, "INSERT INTO p VALUES (3, NULL)") }
            #expect(notNull?.detail == "SQLITE_CONSTRAINT_NOTNULL (1299)")

            let foreignKey = await expectDatabaseError { try await exec(db, "INSERT INTO c VALUES (99)") }
            #expect(foreignKey?.message.contains("FOREIGN KEY constraint failed") == true)
            #expect(foreignKey?.detail == "SQLITE_CONSTRAINT_FOREIGNKEY (787)")

            // The connection is still usable after errors.
            #expect(try await scalar(db, "SELECT count(*) FROM p") == "1")
        }
    }

    // MARK: Schema

    @Test func listSchemasSortsAndHidesInternalTables() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE beta (id INTEGER PRIMARY KEY AUTOINCREMENT, v)")
            try await exec(db, "CREATE TABLE Alpha (x)")
            try await exec(db, "CREATE TABLE sqliteish (x)")
            try await exec(db, "CREATE VIEW gamma AS SELECT * FROM beta")
            try await exec(db, "CREATE INDEX alpha_x ON Alpha (x)")
            try await exec(db, "INSERT INTO beta (v) VALUES (1)")
            try await exec(db, "ANALYZE")

            let schemas = try await db.listSchemas()
            #expect(schemas.count == 1)
            #expect(schemas[0].name == "main")
            let tables = schemas[0].tables
            #expect(tables.map(\.ref.name) == ["Alpha", "beta", "gamma", "sqliteish"])
            #expect(tables.map(\.kind) == [.table, .table, .view, .table])
            #expect(tables.allSatisfy { $0.ref.schema == nil })
        }
    }

    @Test func attachedDatabasesAreListed() async throws {
        try await withDatabase { db, _ in
            let other = Self.tempPath()
            defer { Self.remove(other) }
            try await exec(db, "ATTACH DATABASE '\(other)' AS \"o\"\"ther\"")
            try await exec(db, "CREATE TABLE \"o\"\"ther\".items (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
            #expect(try await db.listDatabases() == ["main", "o\"ther"])

            let structure = try await db.tableStructure(TableRef(schema: "o\"ther", name: "items"))
            #expect(structure.columns.map(\.name) == ["id", "label"])
            #expect(structure.ddl?.contains("CREATE TABLE items") == true)
            try await exec(db, "DETACH DATABASE \"o\"\"ther\"")
        }
    }

    @Test func structureWithCompositeKeysIndexesAndForeignKeys() async throws {
        try await withDatabase { db, _ in
            try await exec(db, """
                CREATE TABLE parent (
                    region TEXT NOT NULL,
                    code INTEGER NOT NULL,
                    label TEXT DEFAULT 'none',
                    PRIMARY KEY (code, region)
                )
                """)
            try await exec(db, "CREATE UNIQUE INDEX parent_label_idx ON parent (label)")
            try await exec(db, "CREATE INDEX parent_lower_label ON parent (lower(label))")
            try await exec(db, """
                CREATE TABLE child (
                    id INTEGER PRIMARY KEY,
                    p_region TEXT,
                    p_code INTEGER,
                    note TEXT UNIQUE,
                    amount REAL NOT NULL DEFAULT 0,
                    FOREIGN KEY (p_code, p_region) REFERENCES parent (code, region) ON DELETE CASCADE ON UPDATE SET NULL
                )
                """)
            try await exec(db, "CREATE TABLE implicit_ref (pc, pr, FOREIGN KEY (pc, pr) REFERENCES parent)")
            try await exec(db, "CREATE TRIGGER child_ai AFTER INSERT ON child BEGIN SELECT 1; END")

            let parent = try await db.tableStructure(TableRef(schema: nil, name: "parent"))
            #expect(parent.columns.map(\.name) == ["region", "code", "label"])
            #expect(parent.columns.map(\.dataType) == ["TEXT", "INTEGER", "TEXT"])
            #expect(parent.columns.map(\.isNullable) == [false, false, true])
            #expect(parent.columns.map(\.isPrimaryKey) == [true, true, false])
            #expect(parent.columns[2].defaultValue == "'none'")
            #expect(parent.columns[0].defaultValue == nil)
            #expect(Set(parent.primaryKey) == ["code", "region"])

            let pk = try #require(parent.indexes.first)
            #expect(pk.isPrimary)
            #expect(pk.isUnique)
            #expect(pk.columns == ["code", "region"])
            #expect(pk.definition == "PRIMARY KEY (code, region)")

            let labelIndex = try #require(parent.indexes.first { $0.name == "parent_label_idx" })
            #expect(labelIndex.isUnique && !labelIndex.isPrimary)
            #expect(labelIndex.columns == ["label"])
            #expect(labelIndex.definition?.hasPrefix("CREATE UNIQUE INDEX parent_label_idx") == true)

            let expressionIndex = try #require(parent.indexes.first { $0.name == "parent_lower_label" })
            #expect(!expressionIndex.isUnique)
            #expect(expressionIndex.columns == ["(expression)"])
            #expect(parent.foreignKeys.isEmpty)
            #expect(parent.ddl?.hasPrefix("CREATE TABLE parent") == true)
            #expect(parent.ddl?.contains("CREATE UNIQUE INDEX parent_label_idx ON parent (label);") == true)

            let child = try await db.tableStructure(TableRef(schema: nil, name: "child"))
            #expect(child.primaryKey == ["id"])
            #expect(child.columns.first { $0.name == "amount" }?.defaultValue == "0")
            #expect(child.columns.first { $0.name == "amount" }?.isNullable == false)

            let rowidKey = try #require(child.indexes.first)
            #expect(rowidKey.isPrimary && rowidKey.columns == ["id"])
            let uniqueNote = try #require(child.indexes.first { $0.columns == ["note"] })
            #expect(uniqueNote.isUnique && !uniqueNote.isPrimary)
            #expect(uniqueNote.definition == "UNIQUE (note)")

            #expect(child.foreignKeys.count == 1)
            let fk = try #require(child.foreignKeys.first)
            #expect(fk.columns == ["p_code", "p_region"])
            #expect(fk.referencedTable == TableRef(schema: nil, name: "parent"))
            #expect(fk.referencedColumns == ["code", "region"])
            #expect(fk.onDelete == "CASCADE")
            #expect(fk.onUpdate == "SET NULL")
            #expect(fk.name == "child_p_code_p_region_fkey")
            #expect(child.ddl?.contains("CREATE TRIGGER child_ai") == true)

            let implicit = try await db.tableStructure(TableRef(schema: nil, name: "implicit_ref"))
            #expect(implicit.columns.map(\.dataType) == ["", ""])
            #expect(implicit.foreignKeys.first?.referencedColumns == ["code", "region"])
            #expect(implicit.foreignKeys.first?.onDelete == "NO ACTION")
            #expect(implicit.primaryKey.isEmpty)
            #expect(implicit.indexes.isEmpty)
        }
    }

    @Test func multipleForeignKeysAreGroupedSeparately() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE a (id INTEGER PRIMARY KEY)")
            try await exec(db, "CREATE TABLE b (x INTEGER, y INTEGER, PRIMARY KEY (x, y))")
            try await exec(db, """
                CREATE TABLE link (
                    a1 INTEGER REFERENCES a (id),
                    a2 INTEGER REFERENCES a (id),
                    bx INTEGER, b_y INTEGER,
                    FOREIGN KEY (bx, b_y) REFERENCES b (x, y)
                )
                """)
            let structure = try await db.tableStructure(TableRef(schema: nil, name: "link"))
            let byColumns = Dictionary(uniqueKeysWithValues: structure.foreignKeys.map { ($0.columns, $0) })
            #expect(structure.foreignKeys.count == 3)
            #expect(byColumns[["a1"]]?.referencedColumns == ["id"])
            #expect(byColumns[["a2"]]?.referencedTable.name == "a")
            #expect(byColumns[["bx", "b_y"]]?.referencedColumns == ["x", "y"])
            #expect(Set(structure.foreignKeys.map(\.name)).count == 3)
        }
    }

    @Test func structureOfViewsGeneratedColumnsAndQuotedNames() async throws {
        try await withDatabase { db, _ in
            try await exec(db, #"CREATE TABLE "we""ird table" ("the ""col""" TEXT, n INTEGER, twice INTEGER GENERATED ALWAYS AS (n * 2) STORED)"#)
            try await exec(db, #"CREATE VIEW "v'iew" AS SELECT n, twice FROM "we""ird table""#)

            let table = try await db.tableStructure(TableRef(schema: nil, name: "we\"ird table"))
            #expect(table.columns.map(\.name) == ["the \"col\"", "n", "twice"])
            #expect(table.columns[2].comment == "Generated column (stored)")
            #expect(table.columns[0].comment == nil)
            #expect(table.ddl?.contains("GENERATED ALWAYS") == true)

            let view = try await db.tableStructure(TableRef(schema: nil, name: "v'iew"))
            #expect(view.columns.map(\.name) == ["n", "twice"])
            #expect(view.indexes.isEmpty)
            #expect(view.foreignKeys.isEmpty)
            #expect(view.ddl?.hasPrefix("CREATE VIEW") == true)
        }
    }

    @Test func structureOfMissingTableFails() async throws {
        try await withDatabase { db, _ in
            let error = await expectDatabaseError { _ = try await db.tableStructure(TableRef(schema: nil, name: "ghost")) }
            #expect(error?.message.contains("ghost") == true)
        }
    }

    // MARK: Cancellation and concurrency

    private static let endlessQuery = """
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000000000) SELECT count(*) FROM c
        """

    @Test(.timeLimit(.minutes(1)))
    func cancelCurrentQueryInterruptsTheRunningStatement() async throws {
        try await withDatabase { db, _ in
            let query = Task { try await db.execute(Self.endlessQuery, maxRows: 10) }
            // The statement may not have started yet, so keep interrupting until it ends.
            let canceller = Task {
                while !Task.isCancelled {
                    await db.cancelCurrentQuery()
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            let outcome = await query.result
            canceller.cancel()
            switch outcome {
            case .success:
                Issue.record("The query should have been interrupted")
            case .failure(let error):
                #expect((error as? DatabaseError)?.message == "Query cancelled")
                #expect((error as? DatabaseError)?.detail == "SQLITE_INTERRUPT (9)")
            }
            // The connection is reusable afterwards, and a stray interrupt while idle is harmless.
            await db.cancelCurrentQuery()
            let answer = try await scalar(db, "SELECT 42")
            #expect(answer == "42")
        }
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func longQueriesDoNotBlockTheMainActor() async throws {
        try await withDatabase { db, _ in
            let query = Task { try await db.execute(Self.endlessQuery, maxRows: 10) }
            // This test runs on the main actor: reaching the next lines while the query runs proves it isn't blocked.
            try await Task.sleep(for: .milliseconds(100))
            var ticks = 0
            for _ in 0..<5 {
                await Task.yield()
                ticks += 1
            }
            #expect(ticks == 5)
            let canceller = Task.detached {
                while !Task.isCancelled {
                    await db.cancelCurrentQuery()
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            _ = await query.result
            canceller.cancel()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func taskCancellationInterruptsItsOwnStatement() async throws {
        try await withDatabase { db, _ in
            let query = Task { try await db.execute(Self.endlessQuery, maxRows: 10) }
            try await Task.sleep(for: .milliseconds(200))
            query.cancel()
            let outcome = await query.result
            if case .success = outcome { Issue.record("The query should have been cancelled") }
            #expect(try await scalar(db, "SELECT 1") == "1")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledQueuedCallIsSkipped() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE t (a)")
            let blocker = Task { try await db.execute(Self.endlessQuery, maxRows: 10) }
            try await Task.sleep(for: .milliseconds(100))
            let queued = Task { try await db.execute("INSERT INTO t VALUES (1)", maxRows: 0) }
            try await Task.sleep(for: .milliseconds(100))
            queued.cancel()
            blocker.cancel()
            _ = await blocker.result
            switch await queued.result {
            case .success:
                Issue.record("The queued INSERT should have been skipped")
            case .failure(let error):
                #expect(error is CancellationError)
            }
            let count = try await scalar(db, "SELECT count(*) FROM t")
            #expect(count == "0")
        }
    }

    @Test func concurrentCallsAreSerialized() async throws {
        try await withDatabase { db, _ in
            try await exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<200 {
                    group.addTask {
                        _ = try await db.execute("INSERT INTO t (v) VALUES (\(i))", maxRows: 0)
                    }
                    group.addTask {
                        _ = try await db.execute("SELECT count(*) FROM t", maxRows: 1)
                    }
                    if i.isMultiple(of: 50) {
                        group.addTask { _ = try await db.listSchemas() }
                        group.addTask { _ = try await db.tableStructure(TableRef(schema: nil, name: "t")) }
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await scalar(db, "SELECT count(*) FROM t") == "200")
            #expect(try await scalar(db, "SELECT sum(v) FROM t") == String((0..<200).reduce(0, +)))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func closeIsIdempotentAndInterruptsLongQueries() async throws {
        let path = Self.tempPath()
        defer { Self.remove(path) }
        let db = try SQLiteDriver.open(path: path, create: true)
        let query = Task { try await db.execute(Self.endlessQuery, maxRows: 10) }
        try await Task.sleep(for: .milliseconds(150))
        await db.close()
        await db.close()
        if case .success = await query.result { Issue.record("The query should have been interrupted by close()") }

        let error = await expectDatabaseError { _ = try await db.execute("SELECT 1", maxRows: 1) }
        #expect(error?.message.contains("closed") == true)
        await db.close()
    }

    @Test func leadingKeywordSkipsCommentsAndWhitespace() {
        #expect(SQLiteDriver.leadingKeyword("  insert into t") == "INSERT")
        #expect(SQLiteDriver.leadingKeyword("-- note\r\n/* block\n */ update t") == "UPDATE")
        #expect(SQLiteDriver.leadingKeyword("/* unterminated") == "")
        #expect(SQLiteDriver.leadingKeyword("(SELECT 1)") == "")
    }
}
