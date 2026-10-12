import AppKit
import SwiftUI

/// Data source, delegate, context-menu and edit controller for `ResultsGrid`.
///
/// Keeps its own snapshot of the grid's inputs so `update(with:)` can decide cheaply what to refresh:
/// a new column list rebuilds the columns, a new data generation or row count reloads, and anything else
/// (edited values, highlights, focus) reconfigures only the row views AppKit currently has, preserving
/// scroll position, selection and an in-progress inline edit.
@MainActor
final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    private var parent: ResultsGrid
    private weak var tableView: GridTableView?

    private var columns: [String] = []
    private var rows: [[CellValue]] = []
    private var rowsIdentity = BufferIdentity(count: 0, address: 0)
    private var editedCells: Set<GridCell> = []
    private var rowStates: [Int: GridRowState] = [:]
    private var sort: GridSort?
    private var isEditable = false
    private var showsRowNumbers = false
    private var hasColumns = false
    private var dataGeneration = 0
    private var numericColumnsInput: Set<Int>?
    /// Right-aligned data columns, from `numericColumns` or inferred from the rows.
    private var numericColumns: Set<Int> = []
    private var lastRevealID: Int?

    /// Mirror of the `focusedCell` binding.
    private var focus: GridCell?
    /// The cell currently drawn with a focus ring.
    private var ringCell: GridCell?
    private var isApplyingUpdate = false
    private var selectionWriteBackPending = false
    private var editSession: EditSession?
    private var menuTarget: MenuTarget?
    private var headerMenuColumn: Int?

    private struct EditSession {
        var cell: GridCell
        var original: CellValue
        weak var view: GridCellView?
    }

    private struct MenuTarget {
        var row: Int
        /// Data column index, nil when the click was on the row-number gutter.
        var column: Int?
        var rows: IndexSet
    }

    /// Identity of an array's storage. Callers' arrays are copy-on-write and we keep a reference to the
    /// buffer, so any mutation on their side produces a different address.
    private struct BufferIdentity: Equatable {
        var count: Int
        var address: Int

        init(count: Int, address: Int) {
            self.count = count
            self.address = address
        }

        init<Element>(_ array: [Element]) {
            count = array.count
            address = array.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        }
    }

    private static let rowNumberID = NSUserInterfaceItemIdentifier("dbee.rowNumber")

    private static func identifier(for dataIndex: Int) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dbee.column.\(dataIndex)")
    }

    init(_ parent: ResultsGrid) {
        self.parent = parent
    }

    var canDeleteRows: Bool { isEditable && parent.onDeleteRows != nil }

    /// Destination for copy actions; tests substitute a private pasteboard.
    var pasteboard: NSPasteboard = .general

    // MARK: Lifecycle

    func attach(to tableView: GridTableView) {
        self.tableView = tableView
        tableView.grid = self
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = GridMetrics.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.allowsTypeSelect = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.setAccessibilityLabel("Results")

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked(_:))
        tableView.doubleAction = #selector(tableDoubleClicked(_:))

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
    }

    func detach() {
        endEditing(commit: false, refocus: false)
        guard let tableView else { return }
        tableView.dataSource = nil
        tableView.delegate = nil
        tableView.target = nil
        tableView.grid = nil
    }

    func update(with grid: ResultsGrid) {
        parent = grid
        guard let tableView else { return }
        isApplyingUpdate = true
        defer { isApplyingUpdate = false }

        let identity = BufferIdentity(grid.rows)
        let isFirstUpdate = !hasColumns
        let columnsChanged = !hasColumns || grid.columns != columns || grid.showsRowNumbers != showsRowNumbers
        let generationChanged = grid.dataGeneration != dataGeneration
        let countChanged = grid.rows.count != rows.count
        let rowsChanged = identity != rowsIdentity
        let decorationsChanged = grid.isEditable != isEditable || grid.editedCells != editedCells || grid.rowStates != rowStates
        let numericChanged = grid.numericColumns != numericColumnsInput

        if let session = editSession {
            if columnsChanged || generationChanged || !grid.isEditable || session.cell.row >= grid.rows.count {
                endEditing(commit: false, refocus: false)
            } else if countChanged {
                // A row was added or removed elsewhere (e.g. the Add Row button, which doesn't take focus):
                // keep what the user typed. Deferred, since the edit callback mutates the host's state.
                endEditing(commit: true, refocus: false, deferred: true)
            }
        }

        columns = grid.columns
        rows = grid.rows
        rowsIdentity = identity
        editedCells = grid.editedCells
        rowStates = grid.rowStates
        isEditable = grid.isEditable
        showsRowNumbers = grid.showsRowNumbers
        dataGeneration = grid.dataGeneration
        numericColumnsInput = grid.numericColumns
        focus = grid.focusedCell

        if columnsChanged || generationChanged || numericChanged || (grid.numericColumns == nil && countChanged) {
            numericColumns = grid.numericColumns ?? GridNumeric.inferColumns(columnCount: columns.count, rows: rows)
        }

        if columnsChanged {
            hasColumns = true
            ringCell = nil
            rebuildColumns()
            tableView.reloadData()
            if !rows.isEmpty { tableView.scrollRowToVisible(0) }
            if tableView.numberOfColumns > 0 { tableView.scrollColumnToVisible(0) }
        } else if generationChanged {
            // New page, sort or filter with the same columns: start at the top, keep the user's column widths.
            ringCell = nil
            updateHeaderAlignment()
            updateRowNumberWidth()
            tableView.reloadData()
            if !rows.isEmpty { tableView.scrollRowToVisible(0) }
        } else if countChanged {
            ringCell = nil
            updateRowNumberWidth()
            tableView.reloadData()
            if numericChanged || grid.numericColumns == nil { updateHeaderAlignment() }
        } else if rowsChanged || decorationsChanged || numericChanged {
            if numericChanged { updateHeaderAlignment() }
            refreshAvailableRows()
        }

        if columnsChanged || grid.sort != sort {
            sort = grid.sort
            updateSortIndicators()
        }
        syncSelection(grid.selectedRows)
        handleRevealRequest(grid.revealRequest, isFirstUpdate: isFirstUpdate)
    }

    /// Acts on each reveal request once. A request already present when the grid is created is stale
    /// (e.g. the view was rebuilt), so it is only recorded.
    private func handleRevealRequest(_ request: GridRevealRequest?, isFirstUpdate: Bool) {
        guard let request, request.id != lastRevealID else { return }
        lastRevealID = request.id
        guard !isFirstUpdate, let tableView, request.row >= 0, request.row < rows.count else { return }
        tableView.scrollRowToVisible(request.row)
        guard request.beginsEditing, isEditable else { return }
        // After the current SwiftUI update, since editing moves first responder and writes the focus binding.
        Task { @MainActor [weak self] in
            guard let self, request.row < self.rows.count, let column = self.displayedDataColumns().first else { return }
            self.beginEditing(GridCell(row: request.row, column: column))
        }
    }

    // MARK: Columns

    private func rebuildColumns() {
        guard let tableView else { return }
        while let column = tableView.tableColumns.last {
            tableView.removeTableColumn(column)
        }
        if showsRowNumbers {
            let column = GridTableColumn(dataIndex: -1, identifier: Self.rowNumberID)
            column.title = ""
            column.resizingMask = []
            column.width = rowNumberWidth()
            column.minWidth = column.width
            column.headerCell.setAccessibilityLabel("Row Number")
            tableView.addTableColumn(column)
        }
        let samples = sampleRows(limit: 100, spread: 50)
        for (index, name) in columns.enumerated() {
            let column = GridTableColumn(dataIndex: index, identifier: Self.identifier(for: index))
            column.title = name
            column.headerToolTip = name
            column.headerCell.lineBreakMode = .byTruncatingTail
            column.headerCell.alignment = alignment(forColumn: index)
            column.resizingMask = .userResizingMask
            column.minWidth = GridMetrics.minColumnWidth
            column.maxWidth = 100_000
            column.width = measuredWidth(
                column: index,
                header: name,
                headerFont: column.headerCell.font,
                rows: samples,
                characterLimit: 60,
                maxWidth: GridMetrics.maxInitialColumnWidth
            )
            tableView.addTableColumn(column)
        }
    }

    /// The first `limit` rows plus up to `spread` evenly spaced rows from the rest.
    private func sampleRows(limit: Int, spread: Int) -> [Int] {
        var result = Array(0..<min(limit, rows.count))
        if rows.count > limit {
            let step = max(1, (rows.count - limit) / spread)
            result.append(contentsOf: stride(from: limit, to: rows.count, by: step))
        }
        return result
    }

    private func measuredWidth(column: Int, header: String, headerFont: NSFont?, rows sample: [Int], characterLimit: Int, maxWidth: CGFloat) -> CGFloat {
        let headerAttributes: [NSAttributedString.Key: Any] = [.font: headerFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        // Header text plus room for the sort indicator.
        var width = ceil((header as NSString).size(withAttributes: headerAttributes).width) + 28

        // Only measure the few longest values; byte length is an O(1) proxy for width.
        var longest: [String] = []
        var hasNull = false
        for row in sample {
            guard let value = value(row: row, column: column) else {
                hasNull = true
                continue
            }
            if longest.count < 3 {
                longest.append(value)
                longest.sort { $0.utf8.count > $1.utf8.count }
            } else if value.utf8.count > longest[2].utf8.count {
                longest[2] = value
                longest.sort { $0.utf8.count > $1.utf8.count }
            }
        }
        // Label insets, the text field's own padding (~2pt a side) and a little air.
        let padding = GridMetrics.cellInset * 2 + 12
        let attributes: [NSAttributedString.Key: Any] = [.font: GridMetrics.font]
        for value in longest {
            let text = GridText.display(value, limit: characterLimit).text
            width = max(width, ceil((text as NSString).size(withAttributes: attributes).width) + padding)
        }
        if hasNull {
            let nullWidth = ("NULL" as NSString).size(withAttributes: [.font: GridMetrics.nullFont]).width
            width = max(width, ceil(nullWidth) + padding)
        }
        return min(max(width, GridMetrics.minColumnWidth), maxWidth)
    }

    private func rowNumberWidth() -> CGFloat {
        let digits = String(max(rows.count, 1)).count
        let sample = String(repeating: "8", count: max(digits, 2)) as NSString
        let width = sample.size(withAttributes: [.font: GridMetrics.rowNumberFont]).width
        return ceil(width) + GridMetrics.rowNumberTrailingInset + 10
    }

    private func updateRowNumberWidth() {
        guard showsRowNumbers, let tableView, let column = tableView.tableColumn(withIdentifier: Self.rowNumberID) else { return }
        let width = rowNumberWidth()
        if column.width != width {
            column.minWidth = width
            column.width = width
        }
    }

    private func alignment(forColumn index: Int) -> NSTextAlignment {
        numericColumns.contains(index) ? .right : .natural
    }

    private func updateHeaderAlignment() {
        guard let tableView else { return }
        for case let column as GridTableColumn in tableView.tableColumns where !column.isRowNumber {
            let wanted = alignment(forColumn: column.dataIndex)
            if column.headerCell.alignment != wanted {
                column.headerCell.alignment = wanted
                tableView.headerView?.needsDisplay = true
            }
        }
    }

    private func updateSortIndicators() {
        guard let tableView else { return }
        let sortedColumn = sort.flatMap { $0.index(in: columns) }
        for case let column as GridTableColumn in tableView.tableColumns {
            var image: NSImage?
            if let sort, !column.isRowNumber, column.dataIndex == sortedColumn {
                image = NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
            }
            tableView.setIndicatorImage(image, in: column)
        }
    }

    /// Data column indices in on-screen order.
    private func displayedDataColumns() -> [Int] {
        guard let tableView else { return [] }
        return tableView.tableColumns.compactMap { column in
            guard let column = column as? GridTableColumn, !column.isRowNumber else { return nil }
            return column.dataIndex
        }
    }

    private func displayIndex(forDataIndex index: Int) -> Int? {
        guard let tableView else { return nil }
        let position = tableView.column(withIdentifier: Self.identifier(for: index))
        return position >= 0 ? position : nil
    }

    private func dataIndex(atTableColumn index: Int) -> Int? {
        guard let tableView, index >= 0, index < tableView.numberOfColumns,
              let column = tableView.tableColumns[index] as? GridTableColumn, !column.isRowNumber else { return nil }
        return column.dataIndex
    }

    // MARK: Data

    private func value(row: Int, column: Int) -> CellValue {
        guard row >= 0, row < rows.count else { return nil }
        let values = rows[row]
        return column >= 0 && column < values.count ? values[column] : nil
    }

    private func configure(_ view: GridCellView, row: Int, column: Int) {
        let cell = GridCell(row: row, column: column)
        view.show(
            value(row: row, column: column),
            column: column < columns.count ? columns[column] : "",
            struckThrough: rowStates[row] == .deleted,
            alignment: alignment(forColumn: column)
        )
        view.highlightColor = editedCells.contains(cell) ? GridMetrics.editedCellColor : nil
        view.showsFocusRing = ringCell == cell
    }

    /// Reconfigures every row view AppKit currently holds, without reloading (keeps scroll, selection and inline edits).
    private func refreshAvailableRows() {
        guard let tableView else { return }
        let tableColumns = tableView.tableColumns
        let editingCell = editSession?.cell
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row >= 0, row < rows.count else { return }
            (rowView as? GridRowView)?.rowState = rowStates[row] ?? .normal
            for (position, tableColumn) in tableColumns.enumerated() {
                guard let column = tableColumn as? GridTableColumn, !column.isRowNumber else { continue }
                if let editingCell, editingCell.row == row, editingCell.column == column.dataIndex { continue }
                if let view = rowView.view(atColumn: position) as? GridCellView {
                    configure(view, row: row, column: column.dataIndex)
                }
            }
        }
    }

    private func cellView(at cell: GridCell) -> GridCellView? {
        guard let tableView, let position = displayIndex(forDataIndex: cell.column),
              cell.row >= 0, cell.row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: position, row: cell.row, makeIfNecessary: false) as? GridCellView
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn as? GridTableColumn else { return nil }
        if column.isRowNumber {
            let view = tableView.makeView(withIdentifier: GridRowNumberView.reuseID, owner: nil) as? GridRowNumberView ?? GridRowNumberView()
            view.show(row: row)
            return view
        }
        let view = tableView.makeView(withIdentifier: GridCellView.reuseID, owner: nil) as? GridCellView ?? GridCellView()
        view.endEditing()
        configure(view, row: row, column: column.dataIndex)
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: GridRowView.reuseID, owner: nil) as? GridRowView ?? {
            let view = GridRowView()
            view.identifier = GridRowView.reuseID
            return view
        }()
        view.rowState = rowStates[row] ?? .normal
        return view
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = tableColumn as? GridTableColumn, !column.isRowNumber,
              column.dataIndex < columns.count, let onSort = parent.onSort else { return }
        let name = columns[column.dataIndex]
        let next: GridSort?
        let index = column.dataIndex
        if let sort, sort.isOn(name, at: index) {
            next = sort.ascending ? GridSort(column: name, ascending: false, columnIndex: index) : nil
        } else {
            next = GridSort(column: name, ascending: true, columnIndex: index)
        }
        onSort(next)
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        guard showsRowNumbers else { return true }
        return columnIndex != 0 && newColumnIndex != 0
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        guard column >= 0, column < tableView.numberOfColumns,
              let tableColumn = tableView.tableColumns[column] as? GridTableColumn else { return 100 }
        if tableColumn.isRowNumber { return rowNumberWidth() }
        let visible = tableView.rows(in: tableView.visibleRect)
        var sample = Array(visible.location..<min(visible.location + visible.length, rows.count))
        sample.append(contentsOf: sampleRows(limit: 200, spread: 800))
        return measuredWidth(
            column: tableColumn.dataIndex,
            header: tableColumn.title,
            headerFont: tableColumn.headerCell.font,
            rows: sample,
            characterLimit: 120,
            maxWidth: GridMetrics.maxFittedColumnWidth
        )
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView else { return }
        if isApplyingUpdate {
            updateFocusRing()
            return
        }
        let selection = tableView.selectedRowIndexes
        if parent.selectedRows != selection {
            parent.selectedRows = selection
        }
        let row = tableView.selectedRow
        guard row >= 0 else {
            setFocus(nil)
            return
        }
        var column = focus?.column ?? displayedDataColumns().first
        if tableView.clickedRow == row, let clicked = dataIndex(atTableColumn: tableView.clickedColumn) {
            column = clicked
        }
        if let column {
            setFocus(GridCell(row: row, column: column))
        } else {
            setFocus(nil)
        }
    }

    // MARK: Selection & focus

    private func syncSelection(_ wanted: IndexSet) {
        guard let tableView else { return }
        var valid = wanted
        if let last = wanted.last, last >= rows.count {
            valid = wanted.intersection(IndexSet(integersIn: 0..<rows.count))
        }
        if tableView.selectedRowIndexes != valid {
            tableView.selectRowIndexes(valid, byExtendingSelection: false)
        }
        if tableView.selectedRowIndexes != wanted {
            scheduleSelectionWriteBack()
        }
        updateFocusRing()
    }

    /// Pushes the table's selection back into the binding after an update clipped it (never during the update itself).
    private func scheduleSelectionWriteBack() {
        guard !selectionWriteBackPending else { return }
        selectionWriteBackPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectionWriteBackPending = false
            guard let tableView = self.tableView else { return }
            let selection = tableView.selectedRowIndexes
            if self.parent.selectedRows != selection {
                self.parent.selectedRows = selection
            }
        }
    }

    private func setFocus(_ cell: GridCell?) {
        if cell != focus {
            focus = cell
            if !isApplyingUpdate, parent.focusedCell != cell {
                parent.focusedCell = cell
            }
        }
        updateFocusRing()
    }

    private func updateFocusRing() {
        guard let tableView else { return }
        var wanted: GridCell?
        if let focus, focus.row >= 0, focus.row < rows.count, focus.column < columns.count,
           tableView.isRowSelected(focus.row), editSession?.cell != focus {
            wanted = focus
        }
        guard wanted != ringCell else { return }
        if let ringCell { cellView(at: ringCell)?.showsFocusRing = false }
        ringCell = wanted
        if let wanted { cellView(at: wanted)?.showsFocusRing = true }
    }

    /// The focused cell if its row is selected, otherwise the first visible column of the last selected row.
    private func activeCell() -> GridCell? {
        guard let tableView else { return nil }
        if let focus, focus.row < rows.count, tableView.isRowSelected(focus.row) { return focus }
        let row = tableView.selectedRow
        guard row >= 0, let column = focus?.column ?? displayedDataColumns().first else { return nil }
        return GridCell(row: row, column: column)
    }

    private func moveFocus(by delta: Int) -> Bool {
        guard let tableView, let current = activeCell() else { return false }
        let order = displayedDataColumns()
        guard let position = order.firstIndex(of: current.column) else { return false }
        let target = min(max(position + delta, 0), order.count - 1)
        let cell = GridCell(row: current.row, column: order[target])
        setFocus(cell)
        if let column = displayIndex(forDataIndex: cell.column) {
            tableView.scrollColumnToVisible(column)
        }
        return true
    }

    // MARK: Mouse & keyboard

    @objc private func tableClicked(_ sender: Any?) {
        guard let tableView else { return }
        let row = tableView.clickedRow
        guard row >= 0, tableView.isRowSelected(row),
              let column = dataIndex(atTableColumn: tableView.clickedColumn) ?? focus?.column ?? displayedDataColumns().first
        else { return }
        setFocus(GridCell(row: row, column: column))
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard let tableView, isEditable, tableView.clickedRow >= 0,
              let column = dataIndex(atTableColumn: tableView.clickedColumn) else { return }
        beginEditing(GridCell(row: tableView.clickedRow, column: column))
    }

    /// Returns true when the event was handled.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let tableView else { return false }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch event.keyCode {
        case 36, 76: // Return, Enter
            guard modifiers.isEmpty, isEditable, let cell = activeCell() else { return false }
            beginEditing(cell)
            return true
        case 51, 117: // Delete, Forward Delete
            guard modifiers.subtracting(.command).isEmpty, canDeleteRows, tableView.numberOfSelectedRows > 0 else { return false }
            deleteSelectedRows()
            return true
        case 123, 124: // Left, Right
            guard modifiers.isEmpty else { return false }
            return moveFocus(by: event.keyCode == 123 ? -1 : 1)
        default:
            return false
        }
    }

    func deleteSelectedRows() {
        guard canDeleteRows, let tableView else { return }
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { return }
        parent.onDeleteRows?(selection)
    }

    // MARK: Inline editing

    func beginEditing(_ cell: GridCell) {
        guard let tableView, isEditable, cell.row >= 0, cell.row < rows.count, cell.column < columns.count,
              rowStates[cell.row] != .deleted,
              let position = displayIndex(forDataIndex: cell.column) else { return }
        endEditing(commit: true, refocus: true)
        if !tableView.isRowSelected(cell.row) {
            tableView.selectRowIndexes(IndexSet(integer: cell.row), byExtendingSelection: false)
        }
        setFocus(cell)
        tableView.scrollRowToVisible(cell.row)
        tableView.scrollColumnToVisible(position)
        guard let view = tableView.view(atColumn: position, row: cell.row, makeIfNecessary: true) as? GridCellView else { return }
        let original = value(row: cell.row, column: cell.column)
        editSession = EditSession(cell: cell, original: original, view: view)
        updateFocusRing()
        view.showsFocusRing = false
        view.beginEditing(original, delegate: self)
        tableView.window?.makeFirstResponder(view.label)
    }

    /// Ends the inline edit. `refocus` returns keyboard focus to the table (Return, Tab, Escape).
    /// `deferred` reports the committed value after the current run-loop turn (used during `update(with:)`).
    private func endEditing(commit: Bool, refocus: Bool, deferred: Bool = false) {
        guard let session = editSession else { return }
        editSession = nil
        let view = session.view
        let text = view?.label.stringValue ?? ""
        let window = tableView?.window
        if let label = view?.label, label.currentEditor() != nil {
            // Still in the field editor: end that session first so AppKit doesn't keep a stale editor around.
            if commit {
                window?.makeFirstResponder(tableView)
            } else {
                label.abortEditing()
                if refocus { window?.makeFirstResponder(tableView) }
            }
        } else if refocus {
            window?.makeFirstResponder(tableView)
        }
        view?.endEditing()
        if let current = cellView(at: session.cell) {
            configure(current, row: session.cell.row, column: session.cell.column)
        }
        updateFocusRing()

        guard commit else { return }
        let changed = session.original.map { $0 != text } ?? !text.isEmpty
        guard changed else { return }
        if deferred {
            Task { @MainActor [weak self] in self?.parent.onEdit?(session.cell, text) }
        } else {
            parent.onEdit?(session.cell, text)
        }
    }

    /// The next (or previous) cell in on-screen column order, wrapping across rows.
    private func neighbour(of cell: GridCell, forward: Bool) -> GridCell? {
        let order = displayedDataColumns()
        guard let position = order.firstIndex(of: cell.column) else { return nil }
        if forward {
            if position + 1 < order.count { return GridCell(row: cell.row, column: order[position + 1]) }
            return cell.row + 1 < rows.count ? GridCell(row: cell.row + 1, column: order[0]) : nil
        } else {
            if position > 0 { return GridCell(row: cell.row, column: order[position - 1]) }
            return cell.row > 0 ? GridCell(row: cell.row - 1, column: order[order.count - 1]) : nil
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let session = editSession, control === session.view?.label else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false, refocus: true)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(commit: true, refocus: true)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let next = neighbour(of: session.cell, forward: commandSelector == #selector(NSResponder.insertTab(_:)))
            endEditing(commit: true, refocus: true)
            if let next { beginEditing(next) }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let session = editSession, let field = notification.object as? NSTextField, field === session.view?.label else { return }
        endEditing(commit: true, refocus: false)
    }

    // MARK: Clipboard

    func copySelectedRows(includeHeader: Bool) {
        guard let tableView, tableView.numberOfSelectedRows > 0 else { return }
        copy(rows: tableView.selectedRowIndexes, format: .tsv, includeHeader: includeHeader)
    }

    private func copy(rows indexes: IndexSet, format: ResultExporter.Format, includeHeader: Bool = true) {
        let order = displayedDataColumns()
        let names = order.map { columns[$0] }
        let selected: [[CellValue]] = indexes.compactMap { row in
            guard row < rows.count else { return nil }
            let values = rows[row]
            return order.map { $0 < values.count ? values[$0] : nil }
        }
        let text = ResultExporter.string(
            columns: names,
            rows: selected,
            format: format,
            dialect: parent.insertTarget?.dialect,
            table: parent.insertTarget?.table,
            includeHeader: includeHeader
        )
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if format == .tsv {
            pasteboard.setString(text, forType: NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text"))
        }
    }

    // MARK: Context menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView else { return }
        if menu === tableView.headerView?.menu {
            buildHeaderMenu(menu)
        } else {
            buildRowMenu(menu)
        }
    }

    private func buildRowMenu(_ menu: NSMenu) {
        guard let tableView else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else {
            menuTarget = nil
            return
        }
        let targetRows = tableView.isRowSelected(row) ? tableView.selectedRowIndexes : IndexSet(integer: row)
        let column = dataIndex(atTableColumn: tableView.clickedColumn)
        menuTarget = MenuTarget(row: row, column: column, rows: targetRows)
        let plural = targetRows.count > 1

        if column != nil {
            menu.addItem(item("Copy", #selector(menuCopyValue(_:)), symbol: "doc.on.doc"))
        }
        menu.addItem(item(plural ? "Copy Rows" : "Copy Row", #selector(menuCopyRows(_:))))
        menu.addItem(item(plural ? "Copy Rows with Headers" : "Copy Row with Headers", #selector(menuCopyRowsWithHeaders(_:))))
        var formats: [(String, ResultExporter.Format)] = [("Copy as CSV", .csv), ("Copy as JSON", .json), ("Copy as Markdown", .markdown)]
        if parent.insertTarget != nil { formats.append(("Copy as SQL INSERT", .sqlInsert)) }
        for (title, format) in formats {
            let menuItem = item(title, #selector(menuCopyAs(_:)))
            menuItem.representedObject = format.rawValue
            menu.addItem(menuItem)
        }

        if isEditable {
            let canEditValues = column != nil && parent.onEdit != nil
            if canEditValues || canDeleteRows { menu.addItem(.separator()) }
            if canEditValues {
                menu.addItem(item("Set to NULL", #selector(menuSetNull(_:))))
                menu.addItem(item("Set to Empty String", #selector(menuSetEmpty(_:))))
            }
            if canDeleteRows {
                menu.addItem(item(plural ? "Delete \(targetRows.count.formatted()) Rows" : "Delete Row", #selector(menuDeleteRows(_:)), symbol: "trash"))
            }
        }

        if column != nil {
            menu.addItem(.separator())
            menu.addItem(item("Show in Inspector", #selector(menuShowInInspector(_:)), symbol: "sidebar.trailing"))
        }
    }

    private func buildHeaderMenu(_ menu: NSMenu) {
        guard let tableView, let header = tableView.headerView, let event = NSApp.currentEvent else { return }
        let position = header.column(at: header.convert(event.locationInWindow, from: nil))
        guard let column = dataIndex(atTableColumn: position), column < columns.count else {
            headerMenuColumn = nil
            return
        }
        headerMenuColumn = column
        if parent.onSort != nil {
            let ascending = item("Sort Ascending", #selector(menuSort(_:)))
            ascending.tag = 1
            let descending = item("Sort Descending", #selector(menuSort(_:)))
            descending.tag = 2
            if let sort, sort.isOn(columns[column], at: column) {
                (sort.ascending ? ascending : descending).state = .on
            }
            menu.addItem(ascending)
            menu.addItem(descending)
            if sort != nil {
                let clear = item("Remove Sort", #selector(menuSort(_:)))
                clear.tag = 0
                menu.addItem(clear)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Copy Column Name", #selector(menuCopyColumnName(_:)), symbol: "doc.on.doc"))
        menu.addItem(item("Size to Fit", #selector(menuSizeToFit(_:))))
    }

    private func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if #available(macOS 26.0, *), let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func menuCopyValue(_ sender: NSMenuItem) {
        guard let target = menuTarget, let column = target.column else { return }
        pasteboard.clearContents()
        pasteboard.setString(value(row: target.row, column: column) ?? "", forType: .string)
    }

    @objc private func menuCopyRows(_ sender: NSMenuItem) {
        guard let target = menuTarget else { return }
        copy(rows: target.rows, format: .tsv, includeHeader: false)
    }

    @objc private func menuCopyRowsWithHeaders(_ sender: NSMenuItem) {
        guard let target = menuTarget else { return }
        copy(rows: target.rows, format: .tsv, includeHeader: true)
    }

    @objc private func menuCopyAs(_ sender: NSMenuItem) {
        guard let target = menuTarget,
              let raw = sender.representedObject as? String,
              let format = ResultExporter.Format(rawValue: raw) else { return }
        copy(rows: target.rows, format: format)
    }

    @objc private func menuSetNull(_ sender: NSMenuItem) {
        setValue(nil)
    }

    @objc private func menuSetEmpty(_ sender: NSMenuItem) {
        setValue("")
    }

    private func setValue(_ newValue: CellValue) {
        guard isEditable, let target = menuTarget, let column = target.column, let onEdit = parent.onEdit else { return }
        endEditing(commit: true, refocus: false)
        for row in target.rows where row < rows.count && rowStates[row] != .deleted {
            if value(row: row, column: column) != newValue {
                onEdit(GridCell(row: row, column: column), newValue)
            }
        }
    }

    @objc private func menuDeleteRows(_ sender: NSMenuItem) {
        guard canDeleteRows, let target = menuTarget else { return }
        endEditing(commit: false, refocus: false)
        parent.onDeleteRows?(target.rows)
    }

    @objc private func menuShowInInspector(_ sender: NSMenuItem) {
        guard let tableView, let target = menuTarget, let column = target.column else { return }
        if !tableView.isRowSelected(target.row) {
            tableView.selectRowIndexes(IndexSet(integer: target.row), byExtendingSelection: false)
        }
        setFocus(GridCell(row: target.row, column: column))
        parent.onShowInspector?()
    }

    @objc private func menuSort(_ sender: NSMenuItem) {
        guard let column = headerMenuColumn, column < columns.count, let onSort = parent.onSort else { return }
        switch sender.tag {
        case 1: onSort(GridSort(column: columns[column], ascending: true, columnIndex: column))
        case 2: onSort(GridSort(column: columns[column], ascending: false, columnIndex: column))
        default: onSort(nil)
        }
    }

    @objc private func menuCopyColumnName(_ sender: NSMenuItem) {
        guard let column = headerMenuColumn, column < columns.count else { return }
        pasteboard.clearContents()
        pasteboard.setString(columns[column], forType: .string)
    }

    @objc private func menuSizeToFit(_ sender: NSMenuItem) {
        guard let tableView, let column = headerMenuColumn, let position = displayIndex(forDataIndex: column) else { return }
        tableView.tableColumns[position].width = self.tableView(tableView, sizeToFitWidthOfColumn: position)
    }
}
