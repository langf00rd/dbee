import AppKit
import SwiftUI

/// Identifies one cell in a grid. `row` is the index into the `rows` array passed to the grid.
struct GridCell: Hashable, Sendable {
    var row: Int
    var column: Int
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
///   (the caller decides whether to sort client-side or re-query).
/// - NULL renders as a dimmed "NULL". Long values are truncated to one line.
/// - When `isEditable`, double-click / Return edits a cell; committing calls `onEdit`.
/// - Context menu: Copy, Copy as CSV / JSON / SQL INSERT (rows), Set to NULL (editable), Delete Rows (editable), Show in Inspector.
/// - ⌘C copies selected rows as TSV.
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

    func makeNSView(context: Context) -> NSScrollView { NSScrollView() }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// Serialises result sets for the clipboard and for export files.
enum ResultExporter {
    enum Format: String, CaseIterable, Identifiable {
        case csv, tsv, json, sqlInsert, markdown
        var id: String { rawValue }
    }

    static func string(columns: [String], rows: [[CellValue]], format: Format, dialect: SQLDialect? = nil, table: TableRef? = nil) -> String {
        fatalError("TODO")
    }

    /// Shows an NSSavePanel and writes the file. Runs on the main actor.
    @MainActor static func export(columns: [String], rows: [[CellValue]], suggestedName: String, dialect: SQLDialect? = nil, table: TableRef? = nil) {}
}
