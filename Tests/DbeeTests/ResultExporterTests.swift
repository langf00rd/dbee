import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dbee

@Suite("ResultExporter")
struct ResultExporterTests {
    // MARK: CSV

    @Test func csvWritesHeaderAndRows() {
        let csv = ResultExporter.string(columns: ["id", "name"], rows: [["1", "Ada"], ["2", "Linus"]], format: .csv)
        #expect(csv == "id,name\n1,Ada\n2,Linus\n")
    }

    @Test func csvQuotesCommasQuotesAndLineBreaks() {
        let rows: [[CellValue]] = [["a,b", "say \"hi\"", "line1\nline2", "cr\rhere", "plain"]]
        let csv = ResultExporter.string(columns: ["c1", "c2", "c3", "c4", "c5"], rows: rows, format: .csv, includeHeader: false)
        #expect(csv == "\"a,b\",\"say \"\"hi\"\"\",\"line1\nline2\",\"cr\rhere\",plain\n")
    }

    @Test func csvDistinguishesNullFromEmptyString() {
        let csv = ResultExporter.string(columns: ["a", "b", "c"], rows: [[nil, "", "x"]], format: .csv, includeHeader: false)
        #expect(csv == ",\"\",x\n")
    }

    @Test func csvQuotesHeaderNames() {
        let csv = ResultExporter.string(columns: ["count(*)", "a,b", "q\""], rows: [], format: .csv)
        #expect(csv == "count(*),\"a,b\",\"q\"\"\"\n")
    }

    @Test func csvKeepsUnicodeVerbatim() {
        let csv = ResultExporter.string(columns: ["名前", "emoji"], rows: [["Zoë, 日本", "👩🏽‍💻"]], format: .csv)
        #expect(csv == "名前,emoji\n\"Zoë, 日本\",👩🏽‍💻\n")
    }

    @Test func csvPadsShortRowsWithNull() {
        let csv = ResultExporter.string(columns: ["a", "b"], rows: [["1"]], format: .csv, includeHeader: false)
        #expect(csv == "1,\n")
    }

    @Test func csvWithNoRowsIsHeaderOnly() {
        #expect(ResultExporter.string(columns: ["a"], rows: [], format: .csv) == "a\n")
        #expect(ResultExporter.string(columns: ["a"], rows: [], format: .csv, includeHeader: false) == "")
    }

    // MARK: TSV

    @Test func tsvEscapesTabsLineBreaksAndBackslashes() {
        let rows: [[CellValue]] = [["a\tb", "x\ny", "c:\\dir", "r\r", nil, "ok"]]
        let tsv = ResultExporter.string(columns: ["1", "2", "3", "4", "5", "6"], rows: rows, format: .tsv)
        #expect(tsv == "1\t2\t3\t4\t5\t6\na\\tb\tx\\ny\tc:\\\\dir\tr\\r\t\tok\n")
    }

    @Test func tsvWithoutHeaderForClipboard() {
        let tsv = ResultExporter.string(columns: ["a", "b"], rows: [["1", "2"], ["3", "4"]], format: .tsv, includeHeader: false)
        #expect(tsv == "1\t2\n3\t4\n")
    }

    // MARK: JSON

    @Test func jsonIsAnArrayOfOrderedObjectsWithStringValues() throws {
        let json = ResultExporter.string(columns: ["z", "a", "n"], rows: [["1", "x", nil], ["2", "", "3.50"]], format: .json)
        #expect(json == """
        [
          {
            "z": "1",
            "a": "x",
            "n": null
          },
          {
            "z": "2",
            "a": "",
            "n": "3.50"
          }
        ]

        """)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.count == 2)
        #expect(parsed[0]["n"] is NSNull)
        #expect(parsed[1]["n"] as? String == "3.50")
    }

    @Test func jsonEscapesQuotesBackslashesAndControlCharacters() throws {
        let value = "quote \" backslash \\ newline \n tab \t cr \r bell \u{07} nul \u{00} unicode é 🚀 slash /"
        let json = ResultExporter.string(columns: ["v"], rows: [[value]], format: .json)
        #expect(json.contains(#""quote \" backslash \\ newline \n tab \t cr \r bell \u0007 nul \u0000 unicode é 🚀 slash /""#))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
        #expect(parsed.first?["v"] == value)
    }

    @Test func jsonEscapesColumnNamesAndDeduplicatesThem() throws {
        let json = ResultExporter.string(columns: ["id", "id", "we\"ird", "id_2"], rows: [["1", "2", "3", "4"]], format: .json)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
        #expect(parsed.first == ["id": "1", "id_2": "2", "we\"ird": "3", "id_2_2": "4"])
    }

    @Test func jsonForEmptyResultIsEmptyArray() {
        #expect(ResultExporter.string(columns: ["a"], rows: [], format: .json) == "[]\n")
    }

    // MARK: SQL INSERT

    @Test func sqlInsertWithoutDialectUsesAnsiQuotingAndGenericTable() {
        let sql = ResultExporter.string(columns: ["id", "na\"me"], rows: [["1", "O'Brien"], ["2", nil]], format: .sqlInsert)
        #expect(sql == """
        INSERT INTO "table" ("id", "na""me") VALUES ('1', 'O''Brien');
        INSERT INTO "table" ("id", "na""me") VALUES ('2', NULL);

        """)
    }

    @Test func sqlInsertWithoutDialectQualifiesTable() {
        let sql = ResultExporter.string(columns: ["a"], rows: [["x"]], format: .sqlInsert, table: TableRef(schema: "public", name: "users"))
        #expect(sql == "INSERT INTO \"public\".\"users\" (\"a\") VALUES ('x');\n")
    }

    @Test func sqlInsertUsesPostgresDialect() {
        let sql = ResultExporter.string(
            columns: ["id", "note"],
            rows: [["1", "it's \\ fine"]],
            format: .sqlInsert,
            dialect: SQLDialect(kind: .postgres),
            table: TableRef(schema: "public", name: "notes")
        )
        // Literal escaping is the dialect's job (SQLDialectTests); the exporter must use it.
        let note = SQLDialect(kind: .postgres).literal("it's \\ fine")
        #expect(sql == "INSERT INTO \"public\".\"notes\" (\"id\", \"note\") VALUES ('1', \(note));\n")
    }

    @Test func sqlInsertUsesMySQLDialect() {
        let sql = ResultExporter.string(
            columns: ["id", "note"],
            rows: [["1", "it's \\ fine"], [nil, "x"]],
            format: .sqlInsert,
            dialect: SQLDialect(kind: .mysql),
            table: TableRef(schema: nil, name: "notes")
        )
        let note = SQLDialect(kind: .mysql).literal("it's \\ fine")
        #expect(sql == """
        INSERT INTO `notes` (`id`, `note`) VALUES ('1', \(note));
        INSERT INTO `notes` (`id`, `note`) VALUES (NULL, 'x');

        """)
    }

    @Test func sqlInsertWithDialectButNoTableUsesGenericName() {
        let sql = ResultExporter.string(columns: ["a"], rows: [["1"]], format: .sqlInsert, dialect: SQLDialect(kind: .mysql))
        #expect(sql == "INSERT INTO `table` (`a`) VALUES ('1');\n")
    }

    @Test func sqlInsertWithNoColumnsIsEmpty() {
        #expect(ResultExporter.string(columns: [], rows: [[]], format: .sqlInsert).isEmpty)
    }

    // MARK: Markdown

    @Test func markdownEscapesPipesAndLineBreaks() {
        let md = ResultExporter.string(columns: ["a|b", "c"], rows: [["x|y", "l1\nl2"], [nil, ""]], format: .markdown)
        #expect(md == """
        | a\\|b | c |
        | --- | --- |
        | x\\|y | l1<br>l2 |
        | NULL |   |

        """)
    }

    // MARK: Format metadata

    @Test func formatsHaveDistinctExtensions() {
        let extensions = ResultExporter.Format.allCases.map(\.fileExtension)
        #expect(Set(extensions).count == extensions.count)
        #expect(ResultExporter.Format.csv.contentType.conforms(to: .commaSeparatedText))
    }
}

@Suite("ResultExporter grid display text")
struct ResultExporterGridTextTests {
    @Test func plainValuesPassThrough() {
        let display = GridText.display("hello world")
        #expect(display == GridText.Display(text: "hello world", isMultiline: false, isClipped: false))
    }

    @Test func lineBreaksAndTabsBecomeSingleLine() {
        let display = GridText.display("a\nb\r\nc\rd\te")
        #expect(display.text == "a⏎b⏎c⏎d e")
        #expect(display.isMultiline)
        #expect(!display.isClipped)
    }

    @Test func longValuesAreClipped() {
        let display = GridText.display(String(repeating: "x", count: 1_000), limit: 10)
        #expect(display.text == "xxxxxxxxxx…")
        #expect(display.isClipped)
    }

    @Test func clippingCountsCharactersNotBytes() {
        let display = GridText.display(String(repeating: "é", count: 8), limit: 10)
        #expect(display.text == String(repeating: "é", count: 8))
        #expect(!display.isClipped)
    }
}

@Suite("ResultExporter inspector JSON formatting")
struct ResultExporterJSONPrettyPrinterTests {
    @Test func reindentsPreservingKeyOrderAndNumbers() {
        let pretty = JSONPrettyPrinter.format(#"{"z":1.50,"a":[1,2,{}],"big":12345678901234567890,"e":[]}"#)
        #expect(pretty == """
        {
          "z": 1.50,
          "a": [
            1,
            2,
            {}
          ],
          "big": 12345678901234567890,
          "e": []
        }
        """)
    }

    @Test func leavesStringContentsAlone() {
        let pretty = JSONPrettyPrinter.format(#"["a, {b}: [c]", "esc \" , }"]"#)
        #expect(pretty == """
        [
          "a, {b}: [c]",
          "esc \\" , }"
        ]
        """)
    }

    @Test func rejectsNonJSONAndScalars() {
        #expect(JSONPrettyPrinter.format("hello") == nil)
        #expect(JSONPrettyPrinter.format("42") == nil)
        #expect(JSONPrettyPrinter.format("{not json}") == nil)
        #expect(JSONPrettyPrinter.format("") == nil)
    }

    @Test func savingAFormattedEditKeepsTheOriginalLayout() throws {
        // Compact original: the edited, pretty-printed draft goes back to one compact line.
        let compact = #"{"a":1,"b":[1,2],"s":"x, y: z"}"#
        var draft = try #require(JSONPrettyPrinter.format(compact))
        draft = draft.replacingOccurrences(of: "\"a\": 1", with: "\"a\": 2")
        #expect(JSONPrettyPrinter.textToSave(draft, original: compact) == #"{"a":2,"b":[1,2],"s":"x, y: z"}"#)

        // Spaced one-line original (Postgres jsonb output style) keeps its spacing.
        let spaced = #"{"a": 1, "b": [1, 2]}"#
        draft = try #require(JSONPrettyPrinter.format(spaced)).replacingOccurrences(of: "\"a\": 1", with: "\"a\": 3")
        #expect(JSONPrettyPrinter.textToSave(draft, original: spaced) == #"{"a": 3, "b": [1, 2]}"#)

        // Multi-line originals, invalid drafts and NULL originals are saved as typed.
        let multiline = "{\n\"a\": 1\n}"
        #expect(JSONPrettyPrinter.textToSave("{\n  \"a\": 5\n}", original: multiline) == "{\n  \"a\": 5\n}")
        #expect(JSONPrettyPrinter.textToSave("{\n  \"a\": \n}", original: compact) == "{\n  \"a\": \n}")
        #expect(JSONPrettyPrinter.textToSave("[1, 2]", original: nil) == "[1, 2]")
    }
}

@Suite("ResultExporter numeric columns")
struct ResultExporterNumericColumnTests {
    @Test func numericTypes() {
        for type in ["integer", "BIGINT", "int(11) unsigned", "smallserial", "numeric(10,2)", "DECIMAL", "real",
                     "double precision", "float8", "money", "INTEGER"] {
            #expect(GridNumeric.isNumericType(type), "\(type)")
        }
        for type in ["text", "varchar(255)", "integer[]", "_int4", "int4range", "interval", "point", "tinyint(1)",
                     "boolean", "timestamp", "date", "json", ""] {
            #expect(!GridNumeric.isNumericType(type), "\(type)")
        }
    }

    @Test func inferredFromValues() {
        let rows: [[CellValue]] = [
            ["1", "Ada", "399.92", nil, "-3"],
            ["22", "Linus", nil, nil, "1e3"],
            ["303", "7", "0.5", nil, "x"],
        ]
        // All-NULL and mixed columns stay left-aligned.
        #expect(GridNumeric.inferColumns(columnCount: 5, rows: rows) == [0, 2])
        #expect(GridNumeric.inferColumns(columnCount: 2, rows: []) == [])
    }
}

/// Drives `ResultsGrid`'s coordinator against a real NSTableView in an offscreen window.
@MainActor
@Suite("ResultExporter grid behaviour", .serialized)
struct ResultExporterGridBehaviourTests {
    final class Recorder {
        var selection = IndexSet()
        var focus: GridCell?
        var edits: [(GridCell, CellValue)] = []
        var deleted: [IndexSet] = []
        var sorts: [GridSort?] = []
    }

    @MainActor
    struct Harness {
        let window: NSWindow
        let table: GridTableView
        let coordinator: GridCoordinator
        let pasteboard: NSPasteboard

        var copied: String? { pasteboard.string(forType: .string) }

        func close() {
            window.close()
            pasteboard.releaseGlobally()
        }
    }

    let columns = ["id", "name", "email", "bio", "created_at", "score"]
    let rows: [[CellValue]] = [
        ["1", "Ada Lovelace", "ada@example.com", "First programmer\nAnalytical Engine", "1843-01-01 00:00:00", "99.5"],
        ["2", "Linus", nil, "Kernel\thacker", "1991-08-25 12:00:00", "42"],
        ["3", "Grace Hopper", "grace@navy.mil", String(repeating: "COBOL ", count: 200), "1959-05-28 09:30:00", nil],
        ["4", "New Row", "", nil, nil, nil],
        ["5", "Deleted Person", "gone@example.com", "bye", "2001-01-01 00:00:00", "0"],
        ["6", "Zoë 日本 👩🏽‍💻", "zoe@example.jp", "{\"a\":1}", "2020-02-02 02:02:02", "-1"],
    ]

    func grid(
        _ recorder: Recorder,
        rows: [[CellValue]]? = nil,
        sort: GridSort? = nil,
        numericColumns: Set<Int>? = nil,
        generation: Int = 0,
        reveal: GridRevealRequest? = nil
    ) -> ResultsGrid {
        ResultsGrid(
            columns: columns,
            rows: rows ?? self.rows,
            isEditable: true,
            sort: sort,
            selectedRows: Binding(get: { recorder.selection }, set: { recorder.selection = $0 }),
            focusedCell: Binding(get: { recorder.focus }, set: { recorder.focus = $0 }),
            onSort: { recorder.sorts.append($0) },
            onEdit: { recorder.edits.append(($0, $1)) },
            onDeleteRows: { recorder.deleted.append($0) },
            insertTarget: (SQLDialect(kind: .postgres), TableRef(schema: "public", name: "users")),
            numericColumns: numericColumns,
            dataGeneration: generation,
            revealRequest: reveal
        )
    }

    /// `count` rows shaped like `rows`, numbered from `start`.
    func manyRows(_ count: Int, start: Int = 1) -> [[CellValue]] {
        (0..<count).map { ["\(start + $0)", "Name \(start + $0)", nil, nil, nil, "\($0)"] }
    }

    func firstVisibleRow(_ h: Harness) -> Int {
        h.table.rows(in: h.table.visibleRect).location
    }

    func host(_ grid: ResultsGrid) -> Harness {
        _ = NSApplication.shared
        let coordinator = grid.makeCoordinator()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dbee.tests.\(UUID().uuidString)"))
        coordinator.pasteboard = pasteboard
        let table = GridTableView()
        let scrollView = NSScrollView()
        scrollView.documentView = table
        coordinator.attach(to: table)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        coordinator.update(with: grid)
        window.layoutIfNeeded()
        window.makeFirstResponder(table)
        return Harness(window: window, table: table, coordinator: coordinator, pasteboard: pasteboard)
    }

    @Test func selectionFocusAndCopy() throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }

        h.table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(recorder.selection == [2])
        #expect(recorder.focus?.row == 2)

        // ⌘C: selected rows as TSV, no header, in on-screen column order.
        h.table.copy(nil)
        #expect(h.copied?.hasPrefix("3\tGrace Hopper\tgrace@navy.mil\t") == true)
        h.table.moveColumn(2, toColumn: 1) // column 0 is the row-number gutter
        h.table.copy(nil)
        #expect(h.copied?.hasPrefix("Grace Hopper\t3\t") == true)
    }

    @Test func updatesAreIncremental() throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }
        let columnsBefore = h.table.tableColumns

        // Same columns, same count, new values: refreshed in place, columns kept.
        var changed = rows
        changed[0][1] = "Countess Lovelace"
        h.coordinator.update(with: grid(recorder, rows: changed))
        let columnsKept = h.table.tableColumns.elementsEqual(columnsBefore, by: ===)
        #expect(columnsKept)
        let cell = try #require(h.table.view(atColumn: 2, row: 0, makeIfNecessary: false) as? GridCellView)
        #expect(cell.label.stringValue == "Countess Lovelace")

        // Rows shrinking below the selection clears it through the binding.
        recorder.selection = [4, 5]
        h.coordinator.update(with: grid(recorder, rows: Array(rows.prefix(5))))
        #expect(h.table.selectedRowIndexes == [4])
        h.coordinator.update(with: grid(recorder, rows: Array(rows.prefix(2))))
        #expect(h.table.selectedRowIndexes.isEmpty)
    }

    @Test func inlineEditingKeys() throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }

        func editor() throws -> (NSTextView, NSTextField) {
            let editor = try #require(h.window.firstResponder as? NSTextView)
            return (editor, try #require(editor.delegate as? NSTextField))
        }

        h.coordinator.beginEditing(GridCell(row: 0, column: 5))
        var (textView, field) = try editor()
        #expect(field.stringValue == "99.5")
        textView.string = "100"
        #expect(h.coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(recorder.edits.count == 1)
        #expect(recorder.edits.first?.0 == GridCell(row: 0, column: 5))
        #expect(recorder.edits.first?.1 == "100")

        // Tab from the last column wraps to the next row; Shift-Tab goes back.
        #expect(recorder.focus == GridCell(row: 1, column: 0))
        #expect(recorder.selection == [1])
        (textView, field) = try editor()
        #expect(h.coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(recorder.focus == GridCell(row: 0, column: 5))
        #expect(recorder.edits.count == 1)

        // Escape cancels without reporting and returns focus to the table.
        (textView, field) = try editor()
        textView.string = "discard me"
        #expect(h.coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(recorder.edits.count == 1)
        #expect(h.window.firstResponder === h.table)
        #expect(!field.isEditable)

        // Committing an untouched NULL cell reports nothing.
        h.coordinator.beginEditing(GridCell(row: 3, column: 3))
        h.window.makeFirstResponder(h.table)
        #expect(recorder.edits.count == 1)

        // Left arrow moves the focused column.
        let left = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, characters: "\u{F702}",
            charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123
        ))
        let before = try #require(recorder.focus)
        h.table.keyDown(with: left)
        #expect(recorder.focus == GridCell(row: before.row, column: before.column - 1))

        // Delete removes the selected rows.
        h.table.selectRowIndexes([0, 1], byExtendingSelection: false)
        h.table.delete(nil)
        #expect(recorder.deleted == [[0, 1]])
    }

    @Test func newDataGenerationScrollsToTopAndCancelsEdit() throws {
        let recorder = Recorder()
        let page1 = manyRows(200)
        let h = host(grid(recorder, rows: page1, generation: 1))
        defer { h.close() }
        h.table.scrollRowToVisible(199)
        #expect(firstVisibleRow(h) > 100)
        h.coordinator.beginEditing(GridCell(row: 199, column: 1))

        // Same columns and row count (next page): back to the first row, the old page's edit dropped.
        h.coordinator.update(with: grid(recorder, rows: manyRows(200, start: 201), generation: 2))
        #expect(firstVisibleRow(h) == 0)
        #expect(recorder.edits.isEmpty)
        h.window.layoutIfNeeded()
        let cell = try #require(h.table.view(atColumn: 2, row: 0, makeIfNecessary: false) as? GridCellView)
        #expect(cell.label.stringValue == "Name 201")
        #expect(!cell.label.isEditable)

        // An edit (same generation) keeps the scroll position.
        h.table.scrollRowToVisible(150)
        let position = firstVisibleRow(h)
        var edited = manyRows(200, start: 201)
        edited[150][1] = "Changed"
        h.coordinator.update(with: grid(recorder, rows: edited, generation: 2))
        #expect(firstVisibleRow(h) == position)
    }

    @Test func rowCountChangeKeepsTypedValue() async throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }
        h.coordinator.beginEditing(GridCell(row: 1, column: 1))
        let editor = try #require(h.window.firstResponder as? NSTextView)
        editor.string = "Linus Torvalds"

        // A row appended while the cell is still being edited (Add Row) commits the edit instead of dropping it.
        h.coordinator.update(with: grid(recorder, rows: rows + [[nil, nil, nil, nil, nil, nil]]))
        for _ in 0..<5 where recorder.edits.isEmpty { await Task.yield() }
        #expect(recorder.edits.count == 1)
        #expect(recorder.edits.first?.0 == GridCell(row: 1, column: 1))
        #expect(recorder.edits.first?.1 == "Linus Torvalds")
    }

    @Test func revealRequestScrollsToRowAndEditsIt() async throws {
        let recorder = Recorder()
        var data = manyRows(200)
        let request = GridRevealRequest(id: 1, row: 0, beginsEditing: true)
        // A request present when the grid is created is stale and ignored.
        let h = host(grid(recorder, rows: data, reveal: request))
        defer { h.close() }
        for _ in 0..<5 { await Task.yield() }
        #expect(!(h.window.firstResponder is NSTextView))

        data.append([nil, nil, nil, nil, nil, nil])
        h.coordinator.update(with: grid(recorder, rows: data, reveal: GridRevealRequest(id: 2, row: 200, beginsEditing: true)))
        #expect(h.table.rows(in: h.table.visibleRect).contains(200))
        for _ in 0..<5 where !(h.window.firstResponder is NSTextView) { await Task.yield() }
        let editor = try #require(h.window.firstResponder as? NSTextView)
        let field = try #require((editor.delegate as? NSTextField) as? GridLabel)
        #expect(field.columnName == "id")
        #expect(recorder.focus == GridCell(row: 200, column: 0))
    }

    @Test func numericColumnsAreRightAligned() throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }
        func alignment(_ name: String) throws -> (cell: NSTextAlignment, header: NSTextAlignment) {
            let position = h.table.column(withIdentifier: NSUserInterfaceItemIdentifier("dbee.column.\(try #require(columns.firstIndex(of: name)))"))
            let view = try #require(h.table.view(atColumn: position, row: 0, makeIfNecessary: true) as? GridCellView)
            return (view.label.alignment, h.table.tableColumns[position].headerCell.alignment)
        }
        // Inferred from values: id and score hold numbers only.
        #expect(try alignment("id") == (.right, .right))
        #expect(try alignment("score") == (.right, .right))
        #expect(try alignment("name") == (.natural, .natural))

        // Explicit column types win.
        h.coordinator.update(with: grid(recorder, numericColumns: [1]))
        #expect(try alignment("id") == (.natural, .natural))
        #expect(try alignment("name") == (.right, .right))
    }

    @Test func headerTitleAndCellTextShareALeftEdge() throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }
        let position = 2 // "name"; column 0 is the row-number gutter
        let header = h.table.tableColumns[position].headerCell
        let headerRect = try #require(h.table.headerView).headerRect(ofColumn: position)
        let titleX = header.titleRect(forBounds: headerRect).minX - headerRect.minX
        let view = try #require(h.table.view(atColumn: position, row: 0, makeIfNecessary: true) as? GridCellView)
        let label = view.label
        let cell = try #require(label.cell)
        let textX = label.frame.minX + cell.titleRect(forBounds: label.bounds).minX
        #expect(abs(textX - titleX) <= 2, "header text at \(titleX), cell text at \(textX)")
    }

    @Test func headerClickCyclesSort() throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }
        let name = try #require(h.table.tableColumns.first { $0.title == "name" })
        let index = try #require((name as? GridTableColumn)?.dataIndex)

        h.coordinator.tableView(h.table, didClick: name)
        #expect(recorder.sorts.last == GridSort(column: "name", ascending: true, columnIndex: index))
        h.coordinator.update(with: grid(recorder, sort: GridSort(column: "name", ascending: true)))
        #expect(h.table.indicatorImage(in: name) != nil)
        h.coordinator.tableView(h.table, didClick: name)
        #expect(recorder.sorts.last == GridSort(column: "name", ascending: false, columnIndex: index))
        h.coordinator.update(with: grid(recorder, sort: GridSort(column: "name", ascending: false)))
        h.coordinator.tableView(h.table, didClick: name)
        #expect(recorder.sorts.last == .some(nil))
        h.coordinator.update(with: grid(recorder, sort: nil))
        #expect(h.table.indicatorImage(in: name) == nil)
    }

    @Test func contextMenuTargetsClickedRowOrSelection() throws {
        let recorder = Recorder()
        let h = host(grid(recorder))
        defer { h.close() }
        h.table.selectRowIndexes([0, 1], byExtendingSelection: false)

        func menu(row: Int, column: Int) throws -> NSMenu {
            let rect = h.table.frameOfCell(atColumn: column, row: row)
            let point = h.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let menu = try #require(h.table.menu(for: event))
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu
        }
        func perform(_ menu: NSMenu, _ title: String) throws {
            let index = menu.indexOfItem(withTitle: title)
            try #require(index >= 0, "missing \(title) in \(menu.items.map(\.title))")
            menu.performActionForItem(at: index)
        }

        // Clicked row inside the selection: row actions apply to the whole selection.
        var m = try menu(row: 1, column: 2)
        try perform(m, "Copy")
        #expect(h.copied == "Linus")
        try perform(m, "Copy Rows with Headers")
        #expect(h.copied?.hasPrefix("id\tname\temail") == true)
        try perform(m, "Copy as SQL INSERT")
        #expect(h.copied?.hasPrefix(#"INSERT INTO "public"."users" ("id", "name""#) == true)
        try perform(m, "Set to NULL")
        #expect(recorder.edits.map(\.0) == [GridCell(row: 0, column: 1), GridCell(row: 1, column: 1)])
        try perform(m, "Delete 2 Rows")
        #expect(recorder.deleted == [[0, 1]])

        // Clicked row outside the selection: only that row.
        m = try menu(row: 4, column: 3)
        try perform(m, "Copy as JSON")
        #expect(h.copied?.contains("Deleted Person") == true)
        #expect(h.copied?.contains("Linus") == false)
        try perform(m, "Show in Inspector")
        #expect(recorder.focus == GridCell(row: 4, column: 2))
        #expect(recorder.selection == [4])

        // Row-number gutter: row items only.
        m = try menu(row: 2, column: 0)
        #expect(m.indexOfItem(withTitle: "Copy") < 0)
        #expect(m.indexOfItem(withTitle: "Copy Row") >= 0)
    }
}

@Suite("GridSort")
struct GridSortTests {
    @Test func duplicateColumnNamesSortByTheClickedOne() {
        let columns = ["id", "name", "id"]
        let second = GridSort(column: "id", ascending: true, columnIndex: 2)
        #expect(second.index(in: columns) == 2)
        #expect(second.isOn("id", at: 2))
        #expect(!second.isOn("id", at: 0))
        // Without an index (or with a stale one) the first column of that name is used.
        #expect(GridSort(column: "id", ascending: true).index(in: columns) == 0)
        #expect(GridSort(column: "id", ascending: true, columnIndex: 1).index(in: columns) == 0)
        #expect(GridSort(column: "id", ascending: true).isOn("id", at: 2))
    }
}
