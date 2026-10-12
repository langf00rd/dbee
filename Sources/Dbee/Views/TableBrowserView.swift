import AppKit
import SwiftUI

/// Browses one table: a filter bar, the editable grid, a pending-changes bar and a paging status bar,
/// with a Data/Structure switch in the toolbar and a row inspector.
struct TableBrowserView: View {
    @Bindable var model: TableBrowserModel

    @Environment(\.undoManager) private var undoManager
    @State private var showInspector = false
    @State private var showSpinner = false
    @State private var showPreview = false
    @State private var confirmCommit = false
    @State private var pendingNavigation: PendingNavigation?
    /// Bumped whenever a page finishes loading, so the grid scrolls to the top and the inspector drops its draft.
    @State private var pageGeneration = 0
    @State private var revealRequest: GridRevealRequest?

    /// A page/filter/sort change waiting for the user to confirm discarding uncommitted changes.
    private struct PendingNavigation {
        let run: @MainActor () async -> Void
    }

    var body: some View {
        content
            .toolbar { toolbarContent }
            .inspector(isPresented: inspectorBinding) {
                inspector
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 520)
            }
            .task(id: ObjectIdentifier(model)) {
                model.undoManager = undoManager
                await model.load()
            }
            .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
            .onChange(of: model.isLoading) { wasLoading, isLoading in
                if wasLoading, !isLoading { pageGeneration += 1 }
            }
            .task(id: model.isLoading) {
                guard model.isLoading else {
                    showSpinner = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled, model.isLoading { showSpinner = true }
            }
            .sheet(isPresented: $showPreview) {
                TableBrowserSQLPreview(statements: model.pendingStatements(), tableName: model.table.name)
            }
            .confirmationDialog(
                discardTitle,
                isPresented: Binding(get: { pendingNavigation != nil }, set: { if !$0 { pendingNavigation = nil } }),
                titleVisibility: .visible,
                presenting: pendingNavigation
            ) { navigation in
                Button("Discard Changes", role: .destructive) {
                    Task { await navigation.run() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Loading other rows replaces the current page, so changes you haven't committed will be lost.")
            }
    }

    @ViewBuilder private var content: some View {
        switch model.displayMode {
        case .data:
            dataContent
        case .structure:
            StructureView(session: model.session, table: model.table)
        }
    }

    private var dataContent: some View {
        VStack(spacing: 0) {
            TableBrowserFilterBar(model: model) { expression in
                navigate { await model.setFilter(expression) }
            }
            Divider()
            gridArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hasChanges {
                Divider()
                pendingBar
            }
            Divider()
            statusBar
        }
        .background {
            // ⌘S lives here rather than on the Commit button, which only exists once an edit is staged:
            // a value still being typed into a cell is saved too.
            Button("Commit Changes", action: commitShortcut)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isCommitting || !(model.hasChanges || model.isEditable))
                .hidden()
                .accessibilityHidden(true)
        }
    }

    // MARK: Grid

    @ViewBuilder private var gridArea: some View {
        ZStack {
            if let error = model.errorMessage, !model.isLoading {
                ContentUnavailableView {
                    Label("Couldn't Load Rows", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                        .textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await model.reload() } }
                    if !model.filter.isEmpty {
                        Button("Clear Filter") {
                            model.filterDraft.value = ""
                            model.filterDraft.rawText = ""
                            Task { await model.setFilter(nil) }
                        }
                    }
                }
            } else if model.hasLoaded {
                ResultsGrid(
                    columns: model.columns,
                    rows: model.gridRows,
                    isEditable: model.isEditable,
                    editedCells: model.editedCells,
                    rowStates: model.rowStates,
                    sort: model.sort,
                    selectedRows: $model.selectedRows,
                    focusedCell: $model.focusedCell,
                    onSort: { sort in navigate { await model.setSort(sort) } },
                    onEdit: { cell, value in model.setValue(value, at: cell) },
                    onDeleteRows: { rows in model.deleteRows(rows) },
                    insertTarget: (dialect: model.dialect, table: model.table),
                    onShowInspector: { showInspector = true },
                    numericColumns: numericColumns,
                    dataGeneration: pageGeneration,
                    revealRequest: revealRequest
                )
                if model.gridRows.isEmpty, !model.isLoading {
                    Text(model.filter.isEmpty ? "No Rows" : "No Matching Rows")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            if showSpinner {
                ProgressView()
                    .accessibilityLabel("Loading rows")
            }
        }
    }

    // MARK: Pending changes bar

    private var pendingBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.commitError {
                Label {
                    Text(error)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .help(error)
            }
            HStack(spacing: 8) {
                Label(changeSummary, systemImage: "pencil")
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isCommitting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Committing changes")
                }
                Button("Preview SQL…") { showPreview = true }
                Menu {
                    Button("Revert Cell") {
                        if let cell = model.focusedCell { model.revert(cell: cell) }
                    }
                    .disabled(!(model.focusedCell.map(model.canRevert(cell:)) ?? false))
                    Button("Revert Selected Rows") { model.revertRows(model.selectedRows) }
                        .disabled(!model.canRevert(rows: model.selectedRows))
                    Divider()
                    Button("Discard All Changes") { model.discard() }
                } label: {
                    Text("Discard")
                } primaryAction: {
                    model.discard()
                }
                .fixedSize()
                .help("Discard all uncommitted changes")
                Button("Commit", action: requestCommit)
                    .buttonStyle(.borderedProminent)
                    .help("Save changes to the database (⌘S)")
            }
            .disabled(model.isCommitting)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $confirmCommit,
            titleVisibility: .visible
        ) {
            Button("Delete and Commit", role: .destructive) {
                Task { await model.commit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rows will be permanently deleted from \(model.table.name) along with your other changes. This can't be undone.")
        }
    }

    private var changeSummary: String {
        let n = model.changeCount
        return "\(n.formatted()) uncommitted change\(n == 1 ? "" : "s")"
    }

    private var deleteConfirmationTitle: String {
        let n = model.deleteCount
        return "Delete \(n.formatted()) row\(n == 1 ? "" : "s")?"
    }

    private var discardTitle: String {
        let n = model.changeCount
        return "Discard \(n.formatted()) uncommitted change\(n == 1 ? "" : "s")?"
    }

    /// Ends an in-progress cell edit, staging what was typed. Borderless buttons don't take focus, so actions
    /// that change the grid call this first rather than let the grid drop the half-typed value.
    private func endPendingCellEdit() {
        // Only the grid's own field editor: the filter bar's text fields keep focus.
        if let window = NSApp.keyWindow, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           (editor.delegate as? NSTextField) is GridLabel {
            window.makeFirstResponder(nil)
        }
    }

    /// ⌘S: stages a value still being typed, then commits if there is anything to commit.
    private func commitShortcut() {
        endPendingCellEdit()
        guard model.hasChanges, !model.isCommitting else { return }
        requestCommit()
    }

    private func requestCommit() {
        // Ends an in-progress cell edit first, so the half-typed value is part of the commit.
        endPendingCellEdit()
        if model.deleteCount > 0, model.session.settings.confirmDestructiveActions {
            confirmCommit = true
        } else {
            Task { await model.commit() }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button(action: addRow) {
                    Label("Add Row", systemImage: "plus")
                        .frame(width: 18, height: 16)
                }
                .disabled(!model.isEditable)
                .help(model.readOnlyReason ?? "Add a row")

                Button {
                    endPendingCellEdit()
                    model.deleteRows(model.selectedRows)
                } label: {
                    Label("Delete Selected Rows", systemImage: "minus")
                        .frame(width: 18, height: 16)
                }
                .disabled(!model.isEditable || model.selectedRows.isEmpty)
                .help(model.readOnlyReason ?? (model.selectedRows.isEmpty ? "Select rows to delete them" : "Delete the selected rows"))
            }
            .labelStyle(.iconOnly)

            if model.hasLoaded, let reason = model.readOnlyReason, reason != "Loading…" {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(reason)
                    .accessibilityLabel("Read-only. \(reason)")
            }

            Divider()
                .frame(height: 14)

            Text(model.rowRangeDescription)
                .monospacedDigit()
            if model.isCounting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Counting rows…")
                    .accessibilityLabel("Counting rows")
            }
            if let duration = model.lastQueryDuration {
                Text(QueryResult.format(duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Time taken to load this page")
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button { navigate { await model.firstPage() } } label: {
                    Label("First Page", systemImage: "chevron.backward.to.line")
                }
                .disabled(!model.hasPreviousPage || model.isLoading)
                .help("First Page")

                Button { navigate { await model.previousPage() } } label: {
                    Label("Previous Page", systemImage: "chevron.backward")
                }
                .disabled(!model.hasPreviousPage || model.isLoading)
                .help("Previous Page")

                Button { navigate { await model.nextPage() } } label: {
                    Label("Next Page", systemImage: "chevron.forward")
                }
                .disabled(!model.hasNextPage || model.isLoading)
                .help("Next Page")

                Button { navigate { await model.lastPage() } } label: {
                    Label("Last Page", systemImage: "chevron.forward.to.line")
                }
                .disabled(model.lastPageIndex == nil || model.lastPageIndex == model.page || model.isLoading)
                .help(model.lastPageIndex == nil ? "Last Page (available once rows are counted)" : "Last Page")

                Button { navigate { await model.reload() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .help("Reload rows and structure")
                .padding(.leading, 6)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
    }

    /// Appends a row, scrolls it into view and starts editing its first column.
    private func addRow() {
        endPendingCellEdit()
        guard let row = model.insertRow() else { return }
        model.selectedRows = [row]
        model.focusedCell = GridCell(row: row, column: 0)
        revealRequest = GridRevealRequest(id: (revealRequest?.id ?? 0) + 1, row: row, beginsEditing: true)
    }

    /// Columns right-aligned in the grid, from the structure's types; nil (inferred from values) until it loads.
    private var numericColumns: Set<Int>? {
        guard model.structure != nil else { return nil }
        return Set(model.columns.indices.filter { model.dataType(ofColumn: $0).map(GridNumeric.isNumericType) ?? false })
    }

    /// Runs a page/filter/sort change, asking first when it would throw away uncommitted changes.
    private func navigate(_ action: @escaping @MainActor () async -> Void) {
        endPendingCellEdit()
        if model.hasChanges {
            pendingNavigation = PendingNavigation(run: action)
        } else {
            Task { await action() }
        }
    }

    // MARK: Toolbar & inspector

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.displayMode) {
                ForEach(TableBrowserModel.DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the table's rows or its structure")
        }
        // Without a spacer, a primary-action item follows the principal picker instead of sitting at the
        // trailing edge, where the query editor (and Finder, Mail, Xcode) keep the inspector toggle.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(model.displayMode != .data)
            .help(showInspector ? "Hide Inspector (⌥⌘0)" : "Show Inspector (⌥⌘0)")
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showInspector && model.displayMode == .data },
            set: { showInspector = $0 }
        )
    }

    /// The focused row when it is part of the selection, otherwise the first selected row.
    private var inspectedRow: Int? {
        let rows = model.gridRows
        if let cell = model.focusedCell, rows.indices.contains(cell.row),
           model.selectedRows.isEmpty || model.selectedRows.contains(cell.row) {
            return cell.row
        }
        if let first = model.selectedRows.first, rows.indices.contains(first) { return first }
        return nil
    }

    private var inspector: some View {
        let row = inspectedRow
        let canEdit = row.map { model.isEditable && !model.isDeletedRow($0) } ?? false
        return RowInspectorView(
            columns: model.columns,
            row: row.map { model.gridRows[$0] },
            rowID: row.map { InspectedRowID(page: pageGeneration, row: $0) },
            focusedColumn: row != nil && model.focusedCell?.row == row ? model.focusedCell?.column : nil,
            onEdit: canEdit ? { column, value in
                guard let row else { return }
                model.setValue(value, at: GridCell(row: row, column: column))
            } : nil
        )
    }
}

/// Identity of the row shown in the inspector: a row index is only meaningful within one loaded page.
private struct InspectedRowID: Hashable {
    var page: Int
    var row: Int
}

// MARK: - Filter bar

/// Finder/Mail-style filter bar: column, operator and value, or a raw SQL WHERE expression.
private struct TableBrowserFilterBar: View {
    @Bindable var model: TableBrowserModel
    var apply: (String?) -> Void

    private typealias Operator = TableBrowserModel.FilterOperator

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(model.filter.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .help(model.filter.isEmpty ? "No filter applied" : "Filtered: \(model.filter)")
                .accessibilityLabel(model.filter.isEmpty ? "No filter applied" : "Filter applied")

            if model.filterDraft.isRaw {
                Text("WHERE")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("Expression", text: $model.filterDraft.rawText, prompt: Text("id > 10 AND name LIKE 'A%'"))
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(applyDraft)
            } else {
                Picker("Column", selection: $model.filterDraft.column) {
                    ForEach(model.columns, id: \.self) { column in
                        Text(column).tag(column)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.columns.isEmpty)
                .help("Column to filter on")

                Picker("Operator", selection: $model.filterDraft.op) {
                    ForEach(Operator.allCases) { op in
                        Text(op.rawValue).tag(op)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Comparison")

                if model.filterDraft.op.needsValue {
                    TextField("Value", text: $model.filterDraft.value, prompt: Text(valuePrompt))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(applyDraft)
                } else {
                    Spacer()
                }
            }

            Toggle(isOn: rawModeBinding) {
                Label("SQL", systemImage: "chevron.left.forwardslash.chevron.right")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help(model.filterDraft.isRaw ? "Use the column filter" : "Write the WHERE clause in SQL")

            Button("Apply", action: applyDraft)
                .disabled(!canApply)
            Button("Clear", action: clear)
                .disabled(model.filter.isEmpty && model.filterDraft.value.isEmpty && model.filterDraft.rawText.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var valuePrompt: String {
        switch model.filterDraft.op {
        case .like, .notLike: "%text%"
        case .in: "a, b, c"
        default: "Value"
        }
    }

    private var canApply: Bool {
        if model.filterDraft.isRaw { return true }
        return model.filterExpression(for: model.filterDraft) != nil
    }

    /// Switching to SQL pre-fills the expression from the applied filter or the column filter.
    private var rawModeBinding: Binding<Bool> {
        Binding(
            get: { model.filterDraft.isRaw },
            set: { isRaw in
                if isRaw, model.filterDraft.rawText.isEmpty {
                    let draft = model.filterDraft
                    let fromDraft = draft.op.needsValue && draft.value.isEmpty ? nil : model.filterExpression(for: draft)
                    model.filterDraft.rawText = model.filter.isEmpty ? (fromDraft ?? "") : model.filter
                }
                model.filterDraft.isRaw = isRaw
            }
        )
    }

    private func applyDraft() {
        guard canApply else { return }
        let draft = model.filterDraft
        let expression = draft.isRaw ? draft.rawText : model.filterExpression(for: draft)
        apply(expression)
    }

    private func clear() {
        model.filterDraft.value = ""
        model.filterDraft.rawText = ""
        if !model.filter.isEmpty { apply(nil) }
    }
}

// MARK: - SQL preview

/// Sheet listing the exact statements a commit will run.
private struct TableBrowserSQLPreview: View {
    let statements: [String]
    let tableName: String
    @Environment(\.dismiss) private var dismiss

    private var script: String {
        statements.map { $0 + ";" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pending Changes to \(tableName)")
                    .font(.headline)
                Text("\(statements.count.formatted()) statement\(statements.count == 1 ? "" : "s"), run in a single transaction.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            TableBrowserCodeView(text: script)
                .accessibilityLabel("Pending SQL statements")
            Divider()
            HStack {
                Button {
                    TableBrowserPasteboard.copy(script)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 320, idealHeight: 440)
    }
}

// MARK: - Shared helpers

/// Read-only, selectable, monospaced text backed by NSTextView (fast for long scripts, supports Find).
struct TableBrowserCodeView: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textColor = .textColor
            textView.textContainerInset = NSSize(width: 6, height: 8)
            textView.font = Self.font
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.font = Self.font
    }

    private static var font: NSFont {
        .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
}

@MainActor
enum TableBrowserPasteboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
