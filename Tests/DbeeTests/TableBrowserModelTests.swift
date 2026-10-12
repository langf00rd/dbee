import Foundation
import Testing
@testable import Dbee

@MainActor
@Suite("TableBrowserModel")
struct TableBrowserModelTests {
    private let table = TableRef(schema: "public", name: "users")

    private nonisolated static func column(_ name: String, pk: Bool = false, nullable: Bool = true) -> ColumnInfo {
        ColumnInfo(name: name, dataType: "text", isNullable: nullable, defaultValue: nil, isPrimaryKey: pk, comment: nil)
    }

    private nonisolated static let usersStructure = TableStructure(
        columns: [column("id", pk: true, nullable: false), column("name"), column("email")],
        indexes: [],
        foreignKeys: [],
        ddl: nil
    )

    /// Never connected; the model only needs it for the dialect (Postgres when unconnected).
    /// Held here because the model references its session unowned.
    private let session = DatabaseSession()

    private func makeModel(
        columns: [String] = ["id", "name", "email"],
        rows: [[CellValue]] = [["1", "Ann", "ann@example.com"], ["2", "Bob", nil], ["3", "O'Neil", "o@example.com"]],
        structure: TableStructure? = TableBrowserModelTests.usersStructure,
        kind: TableKind = .table
    ) -> TableBrowserModel {
        let model = TableBrowserModel(session: session, table: table)
        model.replaceLoadedPage(columns: columns, rows: rows, structure: structure, kind: kind)
        return model
    }

    // MARK: Updates

    @Test func editUsesOriginalPrimaryKey() {
        let model = makeModel()
        model.setValue("Robert", at: GridCell(row: 1, column: 1))
        #expect(model.pendingStatements() == [
            #"UPDATE "public"."users" SET "name" = 'Robert' WHERE "id" = '2'"#,
        ])
        #expect(model.changeCount == 1)
        #expect(model.hasChanges)
    }

    @Test func editingPrimaryKeyStillTargetsOriginalRow() {
        let model = makeModel()
        model.setValue("20", at: GridCell(row: 1, column: 0))
        model.setValue("Bobby", at: GridCell(row: 1, column: 1))
        #expect(model.pendingStatements() == [
            #"UPDATE "public"."users" SET "id" = '20', "name" = 'Bobby' WHERE "id" = '2'"#,
        ])
        #expect(model.changeCount == 1)
    }

    @Test func settingNullAndEscapingQuotes() {
        let model = makeModel()
        model.setValue(nil, at: GridCell(row: 0, column: 2))
        model.setValue("it's", at: GridCell(row: 2, column: 1))
        #expect(model.pendingStatements() == [
            #"UPDATE "public"."users" SET "email" = NULL WHERE "id" = '1'"#,
            #"UPDATE "public"."users" SET "name" = 'it''s' WHERE "id" = '3'"#,
        ])
    }

    @Test func nullCellBecomesValueAndBack() {
        let model = makeModel()
        model.setValue("bob@example.com", at: GridCell(row: 1, column: 2))
        #expect(model.pendingStatements() == [
            #"UPDATE "public"."users" SET "email" = 'bob@example.com' WHERE "id" = '2'"#,
        ])
        model.setValue(nil, at: GridCell(row: 1, column: 2))
        #expect(model.pendingStatements().isEmpty)
        #expect(!model.hasChanges)
    }

    @Test func emptyStringIsNotNull() {
        let model = makeModel()
        model.setValue("", at: GridCell(row: 1, column: 2))
        #expect(model.pendingStatements() == [
            #"UPDATE "public"."users" SET "email" = '' WHERE "id" = '2'"#,
        ])
    }

    @Test func settingOriginalValueRemovesEdit() {
        let model = makeModel()
        model.setValue("Annie", at: GridCell(row: 0, column: 1))
        model.setValue("Ann", at: GridCell(row: 0, column: 1))
        #expect(model.pendingStatements().isEmpty)
        #expect(model.editedCells.isEmpty)
    }

    @Test func compositeKeyWithNullUsesIsNull() {
        let structure = TableStructure(
            columns: [Self.column("tenant", pk: true), Self.column("code", pk: true), Self.column("label")],
            indexes: [], foreignKeys: [], ddl: nil
        )
        let model = makeModel(
            columns: ["tenant", "code", "label"],
            rows: [[nil, "A", "Alpha"]],
            structure: structure
        )
        model.setValue("Alfa", at: GridCell(row: 0, column: 2))
        #expect(model.pendingStatements() == [
            #"UPDATE "public"."users" SET "label" = 'Alfa' WHERE "tenant" IS NULL AND "code" = 'A'"#,
        ])
    }

    // MARK: Deletes and inserts

    @Test func deleteUsesOriginalKeyAndSkipsEditsOfDeletedRows() {
        let model = makeModel()
        model.setValue("99", at: GridCell(row: 0, column: 0))
        model.deleteRows(IndexSet([0, 2]))
        #expect(model.pendingStatements() == [
            #"DELETE FROM "public"."users" WHERE "id" = '1'"#,
            #"DELETE FROM "public"."users" WHERE "id" = '3'"#,
        ])
        #expect(model.changeCount == 2)
        #expect(model.rowStates == [0: .deleted, 2: .deleted])
        // Deleted rows can't be edited.
        model.setValue("Nope", at: GridCell(row: 2, column: 1))
        #expect(model.pendingStatements().count == 2)
    }

    @Test func insertOnlyIncludesColumnsTheUserSet() {
        let model = makeModel()
        let row = try! #require(model.insertRow())
        #expect(row == 3)
        model.setValue("Cat", at: GridCell(row: row, column: 1))
        #expect(model.pendingStatements() == [
            #"INSERT INTO "public"."users" ("name") VALUES ('Cat')"#,
        ])
    }

    @Test func insertWithExplicitNullAndUntouchedRow() {
        let model = makeModel()
        let first = try! #require(model.insertRow())
        model.setValue(nil, at: GridCell(row: first, column: 2))
        model.setValue("7", at: GridCell(row: first, column: 0))
        model.insertRow()
        #expect(model.pendingStatements() == [
            #"INSERT INTO "public"."users" ("id", "email") VALUES ('7', NULL)"#,
            #"INSERT INTO "public"."users" DEFAULT VALUES"#,
        ])
        #expect(model.changeCount == 2)
    }

    @Test func statementsRunDeletesThenUpdatesThenInserts() {
        let model = makeModel()
        let inserted = try! #require(model.insertRow())
        model.setValue("2", at: GridCell(row: inserted, column: 0))
        model.setValue("Ann B", at: GridCell(row: 0, column: 1))
        model.deleteRows(IndexSet(integer: 1))
        #expect(model.pendingStatements() == [
            #"DELETE FROM "public"."users" WHERE "id" = '2'"#,
            #"UPDATE "public"."users" SET "name" = 'Ann B' WHERE "id" = '1'"#,
            #"INSERT INTO "public"."users" ("id") VALUES ('2')"#,
        ])
        #expect(model.changeCount == 3)
    }

    @Test func deletingAnInsertedRowDropsIt() {
        let model = makeModel()
        let first = try! #require(model.insertRow())
        let second = try! #require(model.insertRow())
        model.setValue("second", at: GridCell(row: second, column: 1))
        model.deleteRows(IndexSet(integer: first))
        #expect(model.insertedRows.count == 1)
        #expect(model.pendingStatements() == [
            #"INSERT INTO "public"."users" ("name") VALUES ('second')"#,
        ])
        #expect(model.gridRows.count == 4)
        #expect(model.rowStates == [3: .inserted])
        #expect(model.editedCells == [GridCell(row: 3, column: 1)])
    }

    // MARK: Grid mapping

    @Test func gridShowsEditsAndInsertedRowsAfterLoadedRows() {
        let model = makeModel()
        model.setValue("Bobby", at: GridCell(row: 1, column: 1))
        let row = try! #require(model.insertRow())
        model.setValue("New", at: GridCell(row: row, column: 1))
        #expect(model.rows[1][1] == "Bob")
        #expect(model.gridRows[1][1] == "Bobby")
        #expect(model.gridRows[3] == [nil, "New", nil])
        #expect(model.editedCells == [GridCell(row: 1, column: 1), GridCell(row: 3, column: 1)])
        #expect(model.rowStates == [3: .inserted])
    }

    // MARK: Reverting

    @Test func revertCellAndRows() {
        let model = makeModel()
        model.setValue("A", at: GridCell(row: 0, column: 1))
        model.setValue("a@x", at: GridCell(row: 0, column: 2))
        #expect(model.canRevert(cell: GridCell(row: 0, column: 1)))
        model.revert(cell: GridCell(row: 0, column: 1))
        #expect(model.pendingStatements() == [
            #"UPDATE "public"."users" SET "email" = 'a@x' WHERE "id" = '1'"#,
        ])

        model.deleteRows(IndexSet(integer: 2))
        let inserted = try! #require(model.insertRow())
        #expect(model.canRevert(rows: IndexSet([0, 2, inserted])))
        model.revertRows(IndexSet([0, 2, inserted]))
        #expect(!model.hasChanges)
        #expect(model.gridRows == model.rows)
    }

    @Test func revertInsertedCellReturnsColumnToDefault() {
        let model = makeModel()
        let row = try! #require(model.insertRow())
        model.setValue("x", at: GridCell(row: row, column: 1))
        model.revert(cell: GridCell(row: row, column: 1))
        #expect(model.pendingStatements() == [#"INSERT INTO "public"."users" DEFAULT VALUES"#])
    }

    @Test func discardClearsEverything() {
        let model = makeModel()
        model.setValue("A", at: GridCell(row: 0, column: 1))
        model.deleteRows(IndexSet(integer: 1))
        model.insertRow()
        model.discard()
        #expect(!model.hasChanges)
        #expect(model.pendingStatements().isEmpty)
        #expect(model.rowStates.isEmpty)
        #expect(model.gridRows == model.rows)
    }

    @Test func undoAndRedoRestorePendingChanges() {
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.setValue("A", at: GridCell(row: 0, column: 1))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        model.deleteRows(IndexSet(integer: 1))
        undo.endUndoGrouping()
        #expect(model.changeCount == 2)

        undo.undo()
        #expect(model.deletedRows.isEmpty)
        #expect(model.changeCount == 1)
        undo.undo()
        #expect(!model.hasChanges)
        undo.redo()
        #expect(model.gridRows[0][1] == "A")
    }

    // MARK: Editability

    @Test func tableWithoutPrimaryKeyIsReadOnly() {
        let structure = TableStructure(columns: [Self.column("a"), Self.column("b")], indexes: [], foreignKeys: [], ddl: nil)
        let model = makeModel(columns: ["a", "b"], rows: [["1", "2"]], structure: structure)
        #expect(!model.isEditable)
        #expect(model.readOnlyReason == "This table has no primary key, so rows can't be edited safely.")
        model.setValue("x", at: GridCell(row: 0, column: 0))
        #expect(model.insertRow() == nil)
        model.deleteRows(IndexSet(integer: 0))
        #expect(!model.hasChanges)
        #expect(model.pendingStatements().isEmpty)
    }

    @Test func viewsAreReadOnly() {
        let model = makeModel(kind: .view)
        #expect(!model.isEditable)
        #expect(model.readOnlyReason == "Views are read-only.")
        model.setValue("x", at: GridCell(row: 0, column: 1))
        #expect(!model.hasChanges)
    }

    @Test func missingKeyColumnInResultIsReadOnly() {
        let model = makeModel(columns: ["name", "email"], rows: [["Ann", nil]])
        #expect(!model.isEditable)
        #expect(model.pendingStatements().isEmpty)
    }

    // MARK: Filter building

    @Test func filterExpressions() {
        let model = makeModel()
        var draft = TableBrowserModel.FilterDraft(column: "name", op: .equal, value: "O'Neil")
        #expect(model.filterExpression(for: draft) == #""name" = 'O''Neil'"#)
        draft.op = .notEqual
        #expect(model.filterExpression(for: draft) == #""name" <> 'O''Neil'"#)
        draft.op = .greaterOrEqual
        draft.value = "5"
        #expect(model.filterExpression(for: draft) == #""name" >= '5'"#)
        draft.op = .like
        draft.value = "A%"
        #expect(model.filterExpression(for: draft) == #"CAST("name" AS TEXT) LIKE 'A%'"#)
        draft.op = .notLike
        #expect(model.filterExpression(for: draft) == #"CAST("name" AS TEXT) NOT LIKE 'A%'"#)
        draft.op = .isNull
        #expect(model.filterExpression(for: draft) == #""name" IS NULL"#)
        draft.op = .isNotNull
        #expect(model.filterExpression(for: draft) == #""name" IS NOT NULL"#)
        draft.op = .in
        draft.value = "1, 2 ,, 3"
        #expect(model.filterExpression(for: draft) == #""name" IN ('1', '2', '3')"#)
        draft.value = " , "
        #expect(model.filterExpression(for: draft) == nil)
        draft.column = #"we"ird"#
        draft.op = .isNull
        #expect(model.filterExpression(for: draft) == #""we""ird" IS NULL"#)
    }

    @Test func filterColumnDefaultsToPrimaryKey() {
        let model = makeModel(columns: ["name", "id", "email"], rows: [])
        #expect(model.filterDraft.column == "id")
    }

    // MARK: Paging text

    @Test func rowRangeDescriptionBeforeCount() {
        let model = makeModel()
        #expect(model.rowRangeDescription == "1–3")
        #expect(!model.hasNextPage)
    }
}

/// End-to-end: real DatabaseSession + SQLite driver on a temporary file.
@MainActor
@Suite("TableBrowserModel SQLite", .serialized)
struct TableBrowserModelSQLiteTests {
    private struct Timeout: Error {}

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Creates a database with `setup`, connects a session to it and runs `body`.
    private func withDatabase(_ setup: [String], _ body: (DatabaseSession) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbee-tbm-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let driver = try SQLiteDriver.open(path: path, create: true)
        for sql in setup { _ = try await driver.execute(sql, maxRows: 0) }
        await driver.close()

        let session = DatabaseSession()
        var config = ConnectionConfig()
        config.kind = .sqlite
        config.filePath = path
        session.connect(config)
        try await waitFor {
            if case .failed = session.phase { return true }
            return session.isConnected && !session.isLoadingSchema
        }
        try #require(session.isConnected)
        try await body(session)
        await session.disconnect()
    }

    private static let people = [
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT DEFAULT 'none')",
        "INSERT INTO people (id, name, note) VALUES (1, 'Ann', 'a'), (2, 'Bob', NULL), (3, 'Cy', 'c')",
    ]

    @Test func loadEditAndCommit() async throws {
        try await withDatabase(Self.people) { session in
            let model = session.browserModel(for: TableRef(schema: nil, name: "people"))
            await model.load()
            #expect(model.errorMessage == nil)
            #expect(model.columns == ["id", "name", "note"])
            #expect(model.rows.count == 3)
            #expect(model.structure?.primaryKey == ["id"])
            #expect(model.isEditable)
            try await waitFor { !model.isCounting }
            #expect(model.totalCount == 3)
            #expect(model.rowRangeDescription == "3 rows")

            model.setValue("10", at: GridCell(row: 0, column: 0))
            model.setValue("Robert", at: GridCell(row: 1, column: 1))
            model.setValue(nil, at: GridCell(row: 0, column: 2))
            model.deleteRows(IndexSet(integer: 2))
            let inserted = try #require(model.insertRow())
            model.setValue("Dora", at: GridCell(row: inserted, column: 1))
            #expect(model.changeCount == 4)

            await model.commit()
            #expect(model.commitError == nil)
            #expect(!model.hasChanges)
            #expect(model.rows == [["2", "Robert", nil], ["10", "Ann", nil], ["11", "Dora", "none"]])
            try await waitFor { !model.isCounting }
            #expect(model.totalCount == 3)
        }
    }

    @Test func failedCommitRollsBackAndKeepsChanges() async throws {
        try await withDatabase(Self.people) { session in
            let model = session.browserModel(for: TableRef(schema: nil, name: "people"))
            await model.load()
            model.setValue("Annie", at: GridCell(row: 0, column: 1))
            model.setValue("Bobby", at: GridCell(row: 1, column: 1))
            // Someone else deletes Bob before we commit.
            _ = try await session.execute("DELETE FROM people WHERE id = 2", recordHistory: false)

            await model.commit()
            #expect(model.commitError?.contains("no longer exists") == true)
            #expect(model.changeCount == 2)
            let check = try await session.execute("SELECT name FROM people ORDER BY id", recordHistory: false)
            #expect(check.rows == [["Ann"], ["Cy"]])

            // A constraint violation is reported and also rolls back.
            model.discard()
            model.setValue(nil, at: GridCell(row: 0, column: 1))
            await model.commit()
            #expect(model.commitError != nil)
            #expect(model.hasChanges)
        }
    }

    @Test func filterSortAndPaging() async throws {
        let setup = [
            "CREATE TABLE n (id INTEGER PRIMARY KEY, label TEXT)",
            "INSERT INTO n (label) WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < \(AppSettings.shared.pageSize * 2 + 5)) SELECT 'row ' || x FROM c",
        ]
        try await withDatabase(setup) { session in
            let model = session.browserModel(for: TableRef(schema: nil, name: "n"))
            let size = model.pageSize
            await model.load()
            #expect(model.rows.count == size)
            try await waitFor { !model.isCounting }
            #expect(model.totalCount == size * 2 + 5)
            #expect(model.lastPageIndex == 2)
            #expect(model.rowRangeDescription == "1–\(size.formatted()) of \((size * 2 + 5).formatted()) rows")

            await model.nextPage()
            #expect(model.page == 1)
            #expect(model.rows.first?.first == String(size + 1))
            await model.lastPage()
            #expect(model.rows.count == 5)
            #expect(!model.hasNextPage)
            await model.previousPage()
            #expect(model.page == 1)
            await model.firstPage()
            #expect(model.rows.first?.first == "1")

            await model.setSort(GridSort(column: "id", ascending: false))
            #expect(model.page == 0)
            #expect(model.rows.first?.first == String(size * 2 + 5))

            let draft = TableBrowserModel.FilterDraft(column: "label", op: .in, value: "row 3, row 4")
            await model.setFilter(model.filterExpression(for: draft))
            #expect(model.rows.map { $0[0] } == ["4", "3"])
            try await waitFor { !model.isCounting }
            #expect(model.totalCount == 2)

            await model.setFilter("  where id <= 2; ")
            #expect(model.filter == "id <= 2;")
            #expect(model.rows.map { $0[0] } == ["2", "1"])

            await model.setFilter("nonexistent_column = 1")
            #expect(model.errorMessage != nil)
            #expect(model.rowRangeDescription.isEmpty)
            await model.setFilter(nil)
            #expect(model.errorMessage == nil)
            #expect(model.rows.count == size)
        }
    }

    @Test func blobKeysAndCellsRoundTripAsBytes() async throws {
        let setup = [
            "CREATE TABLE blobs (id BLOB PRIMARY KEY, payload BLOB, note TEXT)",
            "INSERT INTO blobs VALUES (X'00ff', X'0102', 'a'), (X'0a', NULL, 'b')",
        ]
        try await withDatabase(setup) { session in
            let model = session.browserModel(for: TableRef(schema: nil, name: "blobs"))
            await model.load()
            #expect(model.rows == [["\\x00ff", "\\x0102", "a"], ["\\x0a", nil, "b"]])
            #expect(model.isEditable)

            model.setValue("changed", at: GridCell(row: 0, column: 2))
            model.setValue("\\xbeef", at: GridCell(row: 0, column: 1))
            model.deleteRows(IndexSet(integer: 1))
            await model.commit()
            #expect(model.commitError == nil)
            let check = try await session.execute("SELECT hex(id), hex(payload), typeof(payload), note FROM blobs", recordHistory: false)
            #expect(check.rows == [["00FF", "BEEF", "blob", "changed"]])
        }
    }

    @Test func tableWithoutKeyAndViewsAreReadOnly() async throws {
        let setup = [
            "CREATE TABLE loose (a TEXT, b TEXT)",
            "INSERT INTO loose VALUES ('x', 'y')",
            "CREATE VIEW loose_view AS SELECT * FROM loose",
        ]
        try await withDatabase(setup) { session in
            let loose = session.browserModel(for: TableRef(schema: nil, name: "loose"))
            await loose.load()
            #expect(loose.rows == [["x", "y"]])
            #expect(loose.readOnlyReason == "This table has no primary key, so rows can't be edited safely.")

            let view = session.browserModel(for: TableRef(schema: nil, name: "loose_view"))
            await view.load()
            #expect(view.rows == [["x", "y"]])
            #expect(view.readOnlyReason == "Views are read-only.")
        }
    }

    // MARK: Sharing the session's connection

    /// Keeps SQLite busy for a while (a few hundred ms) so other callers queue up behind it.
    private static let slow = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000000) SELECT count(*) FROM c"

    /// Another tab's write waits for a table commit instead of landing inside its transaction,
    /// so the commit's rollback can't take it along.
    @Test func otherTabWriteSurvivesRolledBackCommit() async throws {
        try await withDatabase([
            "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)",
            "CREATE TABLE audit (msg TEXT)",
        ]) { session in
            let commit = Task { @MainActor in
                try await session.executeInTransaction([Self.slow, "INSERT INTO t (id, v) VALUES (1, NULL)"])
            }
            try await Task.sleep(for: .milliseconds(50))
            let other = try await session.execute("INSERT INTO audit (msg) VALUES ('kept')")
            #expect(other.rowsAffected == 1)
            await #expect(throws: (any Error).self) { try await commit.value }
            let rows = try await session.execute("SELECT count(*) FROM audit", recordHistory: false).rows
            #expect(rows == [["1"]])
        }
    }

    /// Stop in one tab leaves the statement another tab is running alone.
    @Test func stopOnlyInterruptsItsOwnTab() async throws {
        try await withDatabase([]) { session in
            let first = session.newQueryTab(sql: Self.slow)
            let second = session.newQueryTab(sql: "SELECT 1")
            let firstRun = Task { @MainActor in await session.run(first.sql, in: first) }
            try await Task.sleep(for: .milliseconds(50))
            let secondRun = Task { @MainActor in await session.run(second.sql, in: second) }
            try await Task.sleep(for: .milliseconds(20))
            // What Stop does for the second tab.
            secondRun.cancel()
            await session.cancelRunningQuery(in: second)
            await firstRun.value
            await secondRun.value
            #expect(first.errorMessage == nil)
            #expect(first.results.first?.rows == [["5000000"]])
            #expect(second.errorMessage == "Query stopped")
        }
    }

    /// A table commit must not end a transaction the user opened in a query tab.
    @Test func commitRefusedWhileQueryTabTransactionIsOpen() async throws {
        try await withDatabase(Self.people) { session in
            let tab = session.newQueryTab()
            await session.run("BEGIN; UPDATE people SET note = 'pending' WHERE id = 3", in: tab)
            #expect(tab.errorMessage == nil)

            let model = session.browserModel(for: TableRef(schema: nil, name: "people"))
            await model.load()
            model.setValue("Annie", at: GridCell(row: 0, column: 1))
            await model.commit()
            #expect(model.commitError?.contains("transaction is open") == true)
            #expect(model.hasChanges)

            await session.run("ROLLBACK", in: tab)
            let note = try await session.execute("SELECT note FROM people WHERE id = 3", recordHistory: false)
            #expect(note.rows == [["c"]])
            await model.commit()
            #expect(model.commitError == nil)
        }
    }

    /// DDL from a query tab marks table browsers stale: a clean one reloads when shown again, one with
    /// pending edits can't commit them. A table that no longer exists is dropped and deselected.
    @Test func ddlInvalidatesTableBrowsers() async throws {
        let setup = Self.people + ["CREATE TABLE other (id INTEGER PRIMARY KEY, a TEXT)", "CREATE TABLE gone (id INTEGER PRIMARY KEY)"]
        try await withDatabase(setup) { session in
            let people = TableRef(schema: nil, name: "people")
            let other = TableRef(schema: nil, name: "other")
            let gone = TableRef(schema: nil, name: "gone")
            let edited = session.browserModel(for: people)
            await edited.load()
            edited.setValue("Annie", at: GridCell(row: 0, column: 1))
            let clean = session.browserModel(for: other)
            await clean.load()
            await session.browserModel(for: gone).load()

            let tab = session.newQueryTab()
            session.selection = .table(gone)
            await session.run("ALTER TABLE people DROP COLUMN note; ALTER TABLE other ADD COLUMN b TEXT; DROP TABLE gone", in: tab)
            #expect(tab.errorMessage == nil)
            #expect(session.browserModels[gone] == nil)
            #expect(clean.readOnlyReason == "The table changed. Reload to edit.")
            await clean.load()
            #expect(clean.columns == ["id", "a", "b"])
            #expect(clean.isEditable)
            #expect(session.selection == .query(tab.id))
            #expect(session.browserModels[people] === edited)
            #expect(edited.readOnlyReason == "The table changed. Reload to edit.")
            await edited.commit()
            #expect(edited.commitError != nil)
            #expect(edited.hasChanges)

            await edited.reload()
            #expect(edited.columns == ["id", "name"])
            #expect(edited.isEditable)
        }
    }

    /// The model holds its session weakly; work that outlives the session fails instead of crashing.
    @Test func modelOutlivingItsSessionReportsNotConnected() async throws {
        var model: TableBrowserModel?
        do {
            let session = DatabaseSession()
            model = TableBrowserModel(session: session, table: TableRef(schema: nil, name: "people"))
            model?.replaceLoadedPage(columns: ["id", "name"], rows: [["1", "Ann"]], structure: TableStructure(
                columns: [
                    ColumnInfo(name: "id", dataType: "integer", isNullable: false, defaultValue: nil, isPrimaryKey: true, comment: nil),
                    ColumnInfo(name: "name", dataType: "text", isNullable: true, defaultValue: nil, isPrimaryKey: false, comment: nil),
                ],
                indexes: [], foreignKeys: [], ddl: nil
            ))
            model?.setValue("Annie", at: GridCell(row: 0, column: 1))
        }
        let orphan = try #require(model)
        await orphan.commit()
        #expect(orphan.commitError == "Not connected")
        await orphan.reload()
        #expect(orphan.errorMessage == "Not connected")
    }

    @Test func transactionStatementsAreTracked() {
        let effect = { (sql: String, kind: DatabaseKind) in DatabaseSession.transactionEffect(sql, kind: kind) }
        #expect(effect("BEGIN", .postgres) == true)
        #expect(effect("begin immediate", .sqlite) == true)
        #expect(effect("START TRANSACTION READ ONLY", .mysql) == true)
        #expect(effect("COMMIT", .mysql) == false)
        #expect(effect("end transaction", .sqlite) == false)
        #expect(effect("ROLLBACK", .postgres) == false)
        #expect(effect("ROLLBACK TO SAVEPOINT a", .postgres) == nil)
        #expect(effect("COMMIT AND CHAIN", .mysql) == nil)
        #expect(effect("COMMIT AND NO CHAIN", .mysql) == false)
        #expect(effect("ABORT", .postgres) == false)
        #expect(effect("SELECT 1", .postgres) == nil)
        #expect(DatabaseSession.mayChangeMySQLDatabase("use `shop`"))
        #expect(DatabaseSession.mayChangeMySQLDatabase("DROP  DATABASE x"))
        #expect(!DatabaseSession.mayChangeMySQLDatabase("DROP TABLE x"))
        #expect(DatabaseSession.isSchemaChanging("COMMENT ON TABLE a IS 'x'"))
    }

    /// A host key accepted once is accepted again for the same host and port on reconnect, without
    /// asking; a different key, or one that conflicts with known_hosts, still goes to the user.
    @Test func acceptedHostKeyIsPinnedForTheSession() async {
        final class Recorder: HostKeyVerifier, @unchecked Sendable {
            var calls = 0
            func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool {
                calls += 1
                return knownHostsStatus == .unknown
            }
        }
        @MainActor final class Pins { var keys: Set<String> = [] }
        let recorder = Recorder()
        let pins = Pins()
        func verifier() -> SessionPinningVerifier {
            SessionPinningVerifier(base: recorder, accepted: pins.keys) { pins.keys.insert($0) }
        }
        #expect(await verifier().confirmHostKey(host: "vps", port: 22, keyType: "ED25519", fingerprint: "SHA256:a", knownHostsStatus: .unknown))
        #expect(recorder.calls == 1)
        #expect(await verifier().confirmHostKey(host: "VPS", port: 22, keyType: "ED25519", fingerprint: "SHA256:a", knownHostsStatus: .unknown))
        #expect(recorder.calls == 1)
        #expect(await verifier().confirmHostKey(host: "vps", port: 22, keyType: "ED25519", fingerprint: "SHA256:b", knownHostsStatus: .unknown))
        #expect(recorder.calls == 2)
        #expect(!(await verifier().confirmHostKey(host: "vps", port: 22, keyType: "ED25519", fingerprint: "SHA256:a", knownHostsStatus: .mismatch)))
        #expect(recorder.calls == 3)
    }
}

/// Live servers, enabled only when DBEE_TB_PG_PORT / DBEE_TB_MYSQL_PORT are set (with DBEE_TB_USER,
/// DBEE_TB_PASSWORD and DBEE_TB_DATABASE). Nothing about the connection is stored in the source.
@MainActor
@Suite("TableBrowserModel Live", .serialized)
struct TableBrowserModelLiveTests {
    nonisolated private static let env = ProcessInfo.processInfo.environment
    private struct Timeout: Error {}

    /// One retry for the Docker Desktop lost-greeting artifact described on `MySQLTestServer.connect`.
    private func connect(_ kind: DatabaseKind, port: String) async throws -> DatabaseSession {
        do {
            return try await connectOnce(kind, port: port)
        } catch let error as DatabaseError where MySQLTestServer.isLostGreeting(error) {
            return try await connectOnce(kind, port: port)
        }
    }

    private func connectOnce(_ kind: DatabaseKind, port: String) async throws -> DatabaseSession {
        let session = DatabaseSession()
        var config = ConnectionConfig()
        config.kind = kind
        config.host = "127.0.0.1"
        config.port = Int(port) ?? kind.defaultPort
        config.username = Self.env["DBEE_TB_USER"] ?? ""
        config.password = Self.env["DBEE_TB_PASSWORD"] ?? ""
        config.database = Self.env["DBEE_TB_DATABASE"] ?? ""
        config.tls = .disabled
        session.connect(config)
        config.wipeSecrets()
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            if case .failed(let message) = session.phase { throw DatabaseError(message) }
            if session.isConnected, !session.isLoadingSchema { return session }
            if ContinuousClock.now > deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForCount(_ model: TableBrowserModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isCounting {
            if ContinuousClock.now > deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(.enabled(if: env["DBEE_TB_PG_PORT"] != nil))
    func postgresEditing() async throws {
        let session = try await connect(.postgres, port: Self.env["DBEE_TB_PG_PORT"]!)
        for sql in [
            "DROP VIEW IF EXISTS tb_items_view",
            "DROP TABLE IF EXISTS tb_items",
            "DROP TABLE IF EXISTS tb_pairs",
            """
            CREATE TABLE tb_items (id serial PRIMARY KEY, name text NOT NULL, qty integer, active boolean DEFAULT true,
            meta jsonb, created_at timestamptz NOT NULL DEFAULT now())
            """,
            "INSERT INTO tb_items (name, qty, meta) VALUES ('apple', 10, '{\"a\":1}'), ('banana', NULL, NULL), ('it''s', 12, NULL)",
            "CREATE TABLE tb_pairs (a integer, b text, label text, PRIMARY KEY (a, b))",
            "INSERT INTO tb_pairs VALUES (1, 'x', 'one-x'), (1, 'y', 'one-y')",
            "CREATE VIEW tb_items_view AS SELECT * FROM tb_items",
        ] {
            _ = try await session.execute(sql, recordHistory: false)
        }
        await session.refreshSchema()

        let model = session.browserModel(for: TableRef(schema: "public", name: "tb_items"))
        await model.setSort(GridSort(column: "id", ascending: true))
        #expect(model.errorMessage == nil)
        #expect(model.columns == ["id", "name", "qty", "active", "meta", "created_at"])
        #expect(model.isEditable)
        try await waitForCount(model)
        #expect(model.totalCount == 3)

        model.setValue("apricot", at: GridCell(row: 0, column: 1))
        model.setValue("42", at: GridCell(row: 0, column: 2))
        model.setValue(nil, at: GridCell(row: 0, column: 4))
        model.setValue("f", at: GridCell(row: 1, column: 3))
        model.setValue("20", at: GridCell(row: 2, column: 0))
        let inserted = try #require(model.insertRow())
        model.setValue("cherry", at: GridCell(row: inserted, column: 1))
        model.setValue("{\"k\": [1, 2]}", at: GridCell(row: inserted, column: 4))
        await model.commit()
        #expect(model.commitError == nil)

        let check = try await session.execute(
            "SELECT id, name, qty, active, meta::text, created_at IS NOT NULL FROM tb_items ORDER BY id", recordHistory: false
        )
        #expect(check.rows.count == 4)
        #expect(check.rows[0][1] == "apricot" && check.rows[0][2] == "42" && check.rows[0][4] == nil)
        #expect(check.rows[1][1] == "banana" && ["f", "false"].contains(check.rows[1][3] ?? ""))
        #expect(check.rows[2][0] == "4" && check.rows[2][1] == "cherry" && check.rows[2][4] == #"{"k": [1, 2]}"#)
        #expect(check.rows[3][0] == "20" && check.rows[3][1] == "it's")

        // LIKE on an integer column works through the text cast.
        let like = TableBrowserModel.FilterDraft(column: "id", op: .like, value: "2%")
        await model.setFilter(model.filterExpression(for: like))
        #expect(model.errorMessage == nil)
        #expect(model.rows.map { $0[0] } == ["2", "20"])

        // Stale key: the row vanishes before commit, so nothing is saved.
        await model.setFilter(nil)
        model.setValue("ghost", at: GridCell(row: 0, column: 1))
        model.setValue("apricot 2", at: GridCell(row: 1, column: 1))
        _ = try await session.execute("DELETE FROM tb_items WHERE id = 2", recordHistory: false)
        await model.commit()
        #expect(model.commitError != nil)
        #expect(model.hasChanges)
        let names = try await session.execute("SELECT name FROM tb_items WHERE id = 1", recordHistory: false)
        #expect(names.rows == [["apricot"]])

        // Composite key with an edited key column.
        let pairs = session.browserModel(for: TableRef(schema: "public", name: "tb_pairs"))
        await pairs.setSort(GridSort(column: "b", ascending: true))
        pairs.setValue("z", at: GridCell(row: 1, column: 1))
        pairs.deleteRows(IndexSet(integer: 0))
        await pairs.commit()
        #expect(pairs.commitError == nil)
        #expect(pairs.rows == [["1", "z", "one-y"]])

        let view = session.browserModel(for: TableRef(schema: "public", name: "tb_items_view"))
        await view.load()
        #expect(view.readOnlyReason == "Views are read-only.")

        for sql in ["DROP VIEW tb_items_view", "DROP TABLE tb_items", "DROP TABLE tb_pairs"] {
            _ = try await session.execute(sql, recordHistory: false)
        }
        await session.disconnect()
    }

    @Test(.enabled(if: env["DBEE_TB_MYSQL_PORT"] != nil))
    func mysqlEditing() async throws {
        let session = try await connect(.mysql, port: Self.env["DBEE_TB_MYSQL_PORT"]!)
        for sql in [
            "DROP TABLE IF EXISTS tb_items",
            """
            CREATE TABLE tb_items (id int AUTO_INCREMENT PRIMARY KEY, name varchar(50) NOT NULL,
            price decimal(8,2), note text, created_at timestamp DEFAULT CURRENT_TIMESTAMP)
            """,
            #"INSERT INTO tb_items (name, price, note) VALUES ('apple', 1.50, 'back\\slash'), ('banana', NULL, NULL)"#,
        ] {
            _ = try await session.execute(sql, recordHistory: false)
        }
        await session.refreshSchema()

        let model = session.browserModel(for: TableRef(schema: nil, name: "tb_items"))
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.isEditable)
        #expect(model.rows.first?[3] == #"back\slash"#)

        // "1.5" equals the stored 1.50, so MySQL reports 0 changed rows; that must not fail the commit.
        model.setValue("1.5", at: GridCell(row: 0, column: 2))
        model.setValue(#"it's a \ path"#, at: GridCell(row: 1, column: 3))
        let inserted = try #require(model.insertRow())
        model.setValue("cherry", at: GridCell(row: inserted, column: 1))
        await model.commit()
        #expect(model.commitError == nil)

        let check = try await session.execute("SELECT id, name, price, note FROM tb_items ORDER BY id", recordHistory: false)
        #expect(check.rows == [
            ["1", "apple", "1.50", #"back\slash"#],
            ["2", "banana", nil, #"it's a \ path"#],
            ["3", "cherry", nil, nil],
        ])

        model.deleteRows(IndexSet(integer: 0))
        await model.commit()
        #expect(model.commitError == nil)
        try await waitForCount(model)
        #expect(model.totalCount == 2)

        _ = try await session.execute("DROP TABLE tb_items", recordHistory: false)
        await session.disconnect()
    }

    /// With standard_conforming_strings off, a backslash in a key or value must still be data, never an
    /// escape that ends the string early.
    @Test(.enabled(if: env["DBEE_TB_PG_PORT"] != nil))
    func postgresLiteralsWithoutStandardConformingStrings() async throws {
        let session = try await connect(.postgres, port: Self.env["DBEE_TB_PG_PORT"]!)
        for sql in [
            "SET standard_conforming_strings = off",
            "DROP TABLE IF EXISTS tb_bs",
            "CREATE TABLE tb_bs (k text PRIMARY KEY, v text)",
            #"INSERT INTO tb_bs VALUES (E'\\'' OR k = ''b'' --', 'one'), ('b', 'two')"#,
        ] {
            _ = try await session.execute(sql, recordHistory: false)
        }
        await session.refreshSchema()
        let model = session.browserModel(for: TableRef(schema: "public", name: "tb_bs"))
        await model.setSort(GridSort(column: "v", ascending: true))
        #expect(model.rows.first?[0] == #"\' OR k = 'b' --"#)
        model.setValue(#"C:\new"#, at: GridCell(row: 0, column: 1))
        await model.commit()
        #expect(model.commitError == nil)
        let check = try await session.execute("SELECT v FROM tb_bs ORDER BY v COLLATE \"C\"", recordHistory: false)
        #expect(check.rows == [[#"C:\new"#], ["two"]])
        _ = try await session.execute("DROP TABLE tb_bs", recordHistory: false)
        await session.disconnect()
    }

    /// A database switch opens the new connection first: a failure leaves the working one in place.
    @Test(.enabled(if: env["DBEE_TB_PG_PORT"] != nil))
    func postgresDatabaseSwitchKeepsConnectionOnFailure() async throws {
        let session = try await connect(.postgres, port: Self.env["DBEE_TB_PG_PORT"]!)
        let original = session.currentDatabase
        await session.switchDatabase("dbee_no_such_database")
        #expect(session.isConnected)
        #expect(session.currentDatabase == original)
        #expect(session.schemaError?.contains("dbee_no_such_database") == true)
        let still = try await session.execute("SELECT current_database()", recordHistory: false)
        #expect(still.rows == [[original]])

        await session.switchDatabase("postgres")
        #expect(session.isConnected)
        #expect(session.currentDatabase == "postgres")
        #expect(session.config?.database == "postgres")
        #expect(session.schemaError == nil)
        let switched = try await session.execute("SELECT current_database()", recordHistory: false)
        #expect(switched.rows == [["postgres"]])
        await session.disconnect()
    }

    /// Under NO_BACKSLASH_ESCAPES, backslashes in values and keys are stored and matched as typed, and an
    /// UPDATE that matches no row fails instead of reporting success (MySQL reports 0 changed rows both
    /// for that and for an unchanged row; `mysqlEditing` covers the unchanged case).
    @Test(.enabled(if: env["DBEE_TB_MYSQL_PORT"] != nil))
    func mysqlBackslashesAndVanishedRows() async throws {
        let session = try await connect(.mysql, port: Self.env["DBEE_TB_MYSQL_PORT"]!)
        for sql in [
            "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'",
            "DROP TABLE IF EXISTS tb_bs",
            "CREATE TABLE tb_bs (k varchar(20) PRIMARY KEY, v varchar(20))",
            #"INSERT INTO tb_bs VALUES ('a\b', 'one'), ('c', 'two')"#,
        ] {
            _ = try await session.execute(sql, recordHistory: false)
        }
        await session.refreshSchema()
        let model = session.browserModel(for: TableRef(schema: nil, name: "tb_bs"))
        await model.setSort(GridSort(column: "k", ascending: true))
        #expect(model.rows == [[#"a\b"#, "one"], ["c", "two"]])
        model.setValue(#"C:\path"#, at: GridCell(row: 0, column: 1))
        await model.commit()
        #expect(model.commitError == nil)
        let check = try await session.execute("SELECT v, HEX(v) FROM tb_bs WHERE k = 'a\\b'", recordHistory: false)
        #expect(check.rows == [[#"C:\path"#, "433A5C70617468"]])

        // Vanished row: another client deletes it before the commit.
        model.setValue("ghost", at: GridCell(row: 1, column: 1))
        _ = try await session.execute("DELETE FROM tb_bs WHERE k = 'c'", recordHistory: false)
        await model.commit()
        #expect(model.commitError?.contains("no longer exists") == true)
        #expect(model.hasChanges)

        _ = try await session.execute("DROP TABLE tb_bs", recordHistory: false)
        await session.disconnect()
    }

    /// `USE` in a query tab moves the session (picker, sidebar, table browsers) to that database.
    @Test(.enabled(if: env["DBEE_TB_MYSQL_PORT"] != nil))
    func mysqlUseInQueryTabFollowsServer() async throws {
        let session = try await connect(.mysql, port: Self.env["DBEE_TB_MYSQL_PORT"]!)
        let original = session.currentDatabase
        let browsed = session.browserModel(for: TableRef(schema: nil, name: "anything"))
        let tab = session.newQueryTab()
        await session.run("USE information_schema", in: tab)
        #expect(tab.errorMessage == nil)
        #expect(session.currentDatabase == "information_schema")
        #expect(session.config?.database == "information_schema")
        #expect(session.browserModels.values.contains { $0 === browsed } == false)
        await session.run("USE `\(original)`", in: tab)
        #expect(session.currentDatabase == original)
        await session.disconnect()
    }

    /// BINARY keys are shown as "\\x…"; edits and deletes must match the bytes, not that text.
    @Test(.enabled(if: env["DBEE_TB_MYSQL_PORT"] != nil))
    func mysqlBinaryKeys() async throws {
        let session = try await connect(.mysql, port: Self.env["DBEE_TB_MYSQL_PORT"]!)
        for sql in [
            "DROP TABLE IF EXISTS tb_bin",
            "CREATE TABLE tb_bin (id binary(2) PRIMARY KEY, payload varbinary(8), note varchar(10))",
            "INSERT INTO tb_bin VALUES (X'00ff', X'01', 'a'), (X'0a0b', NULL, 'b')",
        ] {
            _ = try await session.execute(sql, recordHistory: false)
        }
        await session.refreshSchema()

        let model = session.browserModel(for: TableRef(schema: nil, name: "tb_bin"))
        await model.load()
        #expect(model.rows == [["\\x00ff", "\\x01", "a"], ["\\x0a0b", nil, "b"]])
        model.setValue("changed", at: GridCell(row: 0, column: 2))
        model.setValue("\\xbeef", at: GridCell(row: 0, column: 1))
        model.deleteRows(IndexSet(integer: 1))
        await model.commit()
        #expect(model.commitError == nil)

        let check = try await session.execute("SELECT HEX(id), HEX(payload), note FROM tb_bin", recordHistory: false)
        #expect(check.rows == [["00FF", "BEEF", "changed"]])
        _ = try await session.execute("DROP TABLE tb_bin", recordHistory: false)
        await session.disconnect()
    }
}
