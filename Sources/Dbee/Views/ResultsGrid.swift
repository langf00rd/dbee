import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Identifies one cell in a grid. `row` is the index into the `rows` array passed to the grid.
struct GridCell: Hashable, Sendable {
    var row: Int
    var column: Int
}

/// One-shot request to scroll a row into view and optionally start editing its first visible column.
/// The grid acts on each `id` once, so hosts bump the id for every new request.
struct GridRevealRequest: Equatable, Sendable {
    var id: Int
    var row: Int
    var beginsEditing = false
}

/// Visual state for a row in an editable grid.
enum GridRowState: Sendable {
    case normal
    case inserted
    case deleted
}

/// High-performance NSTableView-backed grid for arbitrary result sets.
///
/// - Columns are created dynamically from `columns`. Column header click reports a sort through `onSort`
///   (the caller decides whether to sort client-side or re-query). Clicking cycles ascending → descending → none.
/// - NULL renders as a dimmed "NULL". Long values are truncated to one line.
/// - When `isEditable`, double-click / Return edits a cell; committing calls `onEdit`. Tab / Shift-Tab commit and
///   move to the next / previous cell, Escape cancels. Delete removes the selected rows through `onDeleteRows`.
/// - Context menu: Copy, Copy as CSV / JSON / SQL INSERT (rows), Set to NULL (editable), Delete Rows (editable), Show in Inspector.
///   Actions apply to the selection when the clicked row is selected, otherwise to the clicked row only.
/// - ⌘C copies the selected rows as TSV *without* a header row (TablePlus / Sequel Ace behaviour);
///   "Copy with Headers" in the context menu includes it. Columns are copied in their on-screen order.
/// - Left / Right arrows move the focused cell; `focusedCell` follows clicks and keyboard selection.
/// - Numeric columns are right-aligned: `numericColumns` when given, otherwise inferred from the values.
/// - Changing `dataGeneration` marks a new data set with the same shape (next page, new sort): the grid
///   reloads and scrolls back to the first row. Edits to the current data must not change it.
///
/// Updates are cheap: columns are rebuilt only when the column list changes, and rows are compared by
/// array buffer identity (never element by element), so SwiftUI may call `updateNSView` freely.
struct ResultsGrid: NSViewRepresentable {
    var columns: [String]
    var rows: [[CellValue]]
    var isEditable: Bool = false
    /// Cells with uncommitted edits, highlighted.
    var editedCells: Set<GridCell> = []
    /// Per-row state for inserted/deleted highlighting, keyed by row index.
    var rowStates: [Int: GridRowState] = [:]
    var sort: GridSort? = nil
    @Binding var selectedRows: IndexSet
    /// Cell that was last clicked, used by the inspector.
    @Binding var focusedCell: GridCell?
    var onSort: ((GridSort?) -> Void)? = nil
    var onEdit: ((GridCell, CellValue) -> Void)? = nil
    var onDeleteRows: ((IndexSet) -> Void)? = nil
    /// Used for "Copy as SQL INSERT". nil hides that menu item.
    var insertTarget: (dialect: SQLDialect, table: TableRef)? = nil
    /// Shows a leading row-number column.
    var showsRowNumbers: Bool = true
    /// Called by the "Show in Inspector" menu item after it focuses the clicked cell, so the host can reveal its inspector.
    var onShowInspector: (() -> Void)? = nil
    /// Indices into `columns` holding numbers (right-aligned). nil infers them from the first rows.
    var numericColumns: Set<Int>? = nil
    var dataGeneration: Int = 0
    var revealRequest: GridRevealRequest? = nil

    func makeCoordinator() -> GridCoordinator { GridCoordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        context.coordinator.attach(to: tableView)
        context.coordinator.update(with: self)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: GridCoordinator) {
        coordinator.detach()
    }
}

/// Serialises result sets for the clipboard and for export files.
///
/// Conventions (all formats use "\n" line endings, including CSV):
/// - CSV: RFC 4180 quoting. Fields containing `,` `"` CR or LF are quoted with `"` doubled. NULL is an empty unquoted
///   field and the empty string is `""`, so the two stay distinguishable (PostgreSQL `COPY … CSV` convention).
/// - TSV: PostgreSQL text-format escaping: `\` → `\\`, tab → `\t`, LF → `\n`, CR → `\r`. NULL is an empty field.
/// - JSON: an array of objects in column order. Values are always JSON strings (types are never guessed) and NULL is
///   `null`. Duplicate column names get a `_2`, `_3`… suffix so keys stay unique.
/// - SQL INSERT: one statement per row, using the dialect's identifier quoting and literals. Without a dialect,
///   ANSI double-quoted identifiers and `'…'` literals are used; without a table the name is `"table"`.
/// - Markdown: a GitHub-flavoured pipe table. `|` is escaped, line breaks become `<br>`, NULL is `NULL`.
enum ResultExporter {
    enum Format: String, CaseIterable, Identifiable {
        case csv, tsv, json, sqlInsert, markdown
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .csv: "CSV"
            case .tsv: "TSV (Tab-Separated)"
            case .json: "JSON"
            case .sqlInsert: "SQL INSERT Statements"
            case .markdown: "Markdown Table"
            }
        }

        var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .tsv: "tsv"
            case .json: "json"
            case .sqlInsert: "sql"
            case .markdown: "md"
            }
        }

        var contentType: UTType {
            switch self {
            case .csv: .commaSeparatedText
            case .tsv: .tabSeparatedText
            case .json: .json
            case .sqlInsert: UTType(filenameExtension: "sql", conformingTo: .plainText) ?? .plainText
            case .markdown: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
            }
        }
    }

    /// `includeHeader` applies to CSV and TSV only (Markdown tables always have a header).
    static func string(columns: [String], rows: [[CellValue]], format: Format, dialect: SQLDialect? = nil, table: TableRef? = nil, includeHeader: Bool = true) -> String {
        switch format {
        case .csv: delimited(columns: columns, rows: rows, separator: ",", includeHeader: includeHeader, escape: csvField)
        case .tsv: delimited(columns: columns, rows: rows, separator: "\t", includeHeader: includeHeader, escape: tsvField)
        case .json: json(columns: columns, rows: rows)
        case .sqlInsert: sqlInsert(columns: columns, rows: rows, dialect: dialect, table: table)
        case .markdown: markdown(columns: columns, rows: rows)
        }
    }

    /// Shows an NSSavePanel and writes the file. Runs on the main actor.
    @MainActor static func export(columns: [String], rows: [[CellValue]], suggestedName: String, dialect: SQLDialect? = nil, table: TableRef? = nil) {
        let panel = NSSavePanel()
        panel.title = "Export Results"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false

        let accessory = ExportFormatAccessory(selected: lastFormat)
        panel.accessoryView = accessory.view
        let baseName = sanitizedFileName(suggestedName)
        let apply: (Format) -> Void = { [weak panel] format in
            guard let panel else { return }
            panel.allowedContentTypes = [format.contentType]
            // Swap only our own extensions, so names like "public.users" keep their dot.
            var name = panel.nameFieldStringValue
            let ext = (name as NSString).pathExtension.lowercased()
            if Format.allCases.contains(where: { $0.fileExtension == ext }) {
                name = (name as NSString).deletingPathExtension
            }
            panel.nameFieldStringValue = (name.isEmpty ? baseName : name) + "." + format.fileExtension
        }
        panel.nameFieldStringValue = baseName
        apply(accessory.format)
        accessory.onChange = apply

        let window = NSApp.keyWindow
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            let format = accessory.format
            guard response == .OK, let url = panel.url else { return }
            lastFormat = format
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                    let text = string(columns: columns, rows: rows, format: format, dialect: dialect, table: table)
                    return Result { try Data(text.utf8).write(to: url, options: .atomic) }
                }.value
                if case .failure(let error) = result {
                    let alert = NSAlert(error: error)
                    alert.messageText = "The results couldn't be exported."
                    alert.informativeText = error.localizedDescription
                    if let window, window.isVisible {
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// Format last chosen in the export panel. In memory only.
    @MainActor private static var lastFormat: Format = .csv

    private static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Results" : cleaned
    }

    // MARK: Delimited text

    private static func delimited(columns: [String], rows: [[CellValue]], separator: String, includeHeader: Bool, escape: (CellValue) -> String) -> String {
        var out = ""
        if includeHeader {
            out += columns.map { escape($0) }.joined(separator: separator)
            out += "\n"
        }
        for row in rows {
            var first = true
            for index in columns.indices {
                if !first { out += separator }
                first = false
                out += escape(index < row.count ? row[index] : nil)
            }
            out += "\n"
        }
        return out
    }

    static func csvField(_ value: CellValue) -> String {
        guard let value else { return "" }
        if value.isEmpty { return "\"\"" }
        let needsQuotes = value.utf8.contains { $0 == 0x2C || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func tsvField(_ value: CellValue) -> String {
        guard let value else { return "" }
        guard value.utf8.contains(where: { $0 == 0x5C || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) else { return value }
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out.append(contentsOf: #"\\"#.unicodeScalars)
            case "\t": out.append(contentsOf: #"\t"#.unicodeScalars)
            case "\n": out.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": out.append(contentsOf: #"\r"#.unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: JSON

    private static func json(columns: [String], rows: [[CellValue]]) -> String {
        guard !rows.isEmpty else { return "[]\n" }
        let keys = uniqueKeys(columns).map(jsonString)
        var out = "[\n"
        for (rowIndex, row) in rows.enumerated() {
            out += "  {"
            if keys.isEmpty {
                out += "}"
            } else {
                out += "\n"
                for (index, key) in keys.enumerated() {
                    out += "    " + key + ": "
                    if index < row.count, let value = row[index] {
                        out += jsonString(value)
                    } else {
                        out += "null"
                    }
                    out += index == keys.count - 1 ? "\n" : ",\n"
                }
                out += "  }"
            }
            out += rowIndex == rows.count - 1 ? "\n" : ",\n"
        }
        out += "]\n"
        return out
    }

    /// Makes column names unique for use as JSON keys: id, id → id, id_2.
    static func uniqueKeys(_ columns: [String]) -> [String] {
        var used = Set<String>()
        return columns.map { name in
            var key = name
            var suffix = 2
            while used.contains(key) {
                key = "\(name)_\(suffix)"
                suffix += 1
            }
            used.insert(key)
            return key
        }
    }

    /// A JSON string literal (RFC 8259): quotes, backslashes and control characters escaped, everything else verbatim.
    static func jsonString(_ value: String) -> String {
        guard value.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }) else { return "\"" + value + "\"" }
        var out = String.UnicodeScalarView()
        out.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: #"\""#.unicodeScalars)
            case "\\": out.append(contentsOf: #"\\"#.unicodeScalars)
            case "\n": out.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": out.append(contentsOf: #"\r"#.unicodeScalars)
            case "\t": out.append(contentsOf: #"\t"#.unicodeScalars)
            case "\u{08}": out.append(contentsOf: #"\b"#.unicodeScalars)
            case "\u{0C}": out.append(contentsOf: #"\f"#.unicodeScalars)
            case let s where s.value < 0x20:
                out.append(contentsOf: String(format: "\\u%04x", s.value).unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        out.append("\"")
        return String(out)
    }

    // MARK: SQL

    private static func sqlInsert(columns: [String], rows: [[CellValue]], dialect: SQLDialect?, table: TableRef?) -> String {
        guard !columns.isEmpty else { return "" }
        let quote: (String) -> String = dialect.map { d in { d.quoteIdentifier($0) } } ?? ansiIdentifier
        let literal: (CellValue) -> String = dialect.map { d in { d.literal($0) } } ?? ansiLiteral
        let tableName: String
        switch (dialect, table) {
        case let (dialect?, table?): tableName = dialect.qualifiedName(table)
        case let (nil, table?): tableName = ([table.schema, table.name] as [String?]).compactMap { $0 }.map(ansiIdentifier).joined(separator: ".")
        case (_, nil): tableName = quote("table")
        }
        let head = "INSERT INTO \(tableName) (\(columns.map(quote).joined(separator: ", "))) VALUES ("
        var out = ""
        for row in rows {
            out += head
            var first = true
            for index in columns.indices {
                if !first { out += ", " }
                first = false
                out += literal(index < row.count ? row[index] : nil)
            }
            out += ");\n"
        }
        return out
    }

    private static func ansiIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func ansiLiteral(_ value: CellValue) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: Markdown

    private static func markdown(columns: [String], rows: [[CellValue]]) -> String {
        guard !columns.isEmpty else { return "" }
        var out = "| " + columns.map { markdownCell($0) }.joined(separator: " | ") + " |\n"
        out += "|" + String(repeating: " --- |", count: columns.count) + "\n"
        for row in rows {
            out += "| "
            out += columns.indices.map { index in
                guard index < row.count, let value = row[index] else { return "NULL" }
                return markdownCell(value)
            }.joined(separator: " | ")
            out += " |\n"
        }
        return out
    }

    static func markdownCell(_ value: String) -> String {
        guard !value.isEmpty else { return " " }
        guard value.utf8.contains(where: { $0 == 0x7C || $0 == 0x0A || $0 == 0x0D }) else { return value }
        return value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }
}

/// Save-panel accessory with a format popup.
@MainActor
private final class ExportFormatAccessory: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onChange: ((ResultExporter.Format) -> Void)?

    var format: ResultExporter.Format {
        let index = popup.indexOfSelectedItem
        return ResultExporter.Format.allCases.indices.contains(index) ? ResultExporter.Format.allCases[index] : .csv
    }

    init(selected: ResultExporter.Format) {
        for format in ResultExporter.Format.allCases {
            popup.addItem(withTitle: format.displayName)
        }
        popup.selectItem(at: ResultExporter.Format.allCases.firstIndex(of: selected) ?? 0)
        popup.setAccessibilityLabel("Export Format")

        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.frame.size = stack.fittingSize
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(formatChanged(_:))
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        onChange?(format)
    }
}
