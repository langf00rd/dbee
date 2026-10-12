import AppKit
import SwiftUI

/// Query workspace for one tab: the SQL editor on top, results below (resizable split), a status bar,
/// a row inspector on the trailing edge and Run / Run All / Stop / History toolbar items.
struct QueryEditorView: View {
    @Bindable var session: DatabaseSession
    @Bindable var tab: QueryTab

    var body: some View {
        QueryWorkspace(session: session, tab: tab)
            .id(tab.id)
    }
}

// MARK: - Workspace

private struct QueryWorkspace: View {
    var session: DatabaseSession
    @Bindable var tab: QueryTab

    @State private var results = QueryResultsModel()
    /// Plain reference so caret movement doesn't re-render the workspace.
    @State private var selection: EditorSelection
    @State private var showHistory = false
    @AppStorage("queryEditor.showInspector") private var showInspector = false
    @AppStorage("queryEditor.editorFraction") private var editorFraction = QueryEditorSplitCoordinator.defaultFraction

    init(session: DatabaseSession, tab: QueryTab) {
        self.session = session
        _tab = Bindable(tab)
        _selection = State(initialValue: EditorSelection(tab: tab))
    }

    var body: some View {
        QueryEditorSplit(topFraction: $editorFraction) {
            QueryEditorPane(session: session, tab: tab, selection: selection.binding, onRun: run(all:))
        } bottom: {
            QueryResultsPane(session: session, tab: tab, model: results, onShowInspector: { showInspector = true })
        }
        .inspector(isPresented: $showInspector) {
            QueryRowInspector(tab: tab, model: results)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 480)
        }
        .toolbar { toolbar }
        .onChange(of: tab.selectedResultID) { results.reset() }
    }

    private var canRun: Bool { session.isConnected && !tab.isRunning }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                run(all: false)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .help("Run the selection, or the statement at the cursor (⌘↩)")
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canRun)

            Button {
                run(all: true)
            } label: {
                Label("Run All", systemImage: "play.square.stack")
            }
            .help("Run every statement in the editor (⇧⌘↩)")
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!canRun)

            Button {
                QueryRunner.stop(tab, session: session)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop the running query (⌘.)")
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!tab.isRunning)

            Button {
                showHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Query History")
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                QueryHistoryView(session: session, tab: tab)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .help(showInspector ? "Hide the row inspector (⌥⌘0)" : "Show the row inspector (⌥⌘0)")
        }
    }

    /// Runs the whole script, or the selection, or the statement at the cursor.
    private func run(all: Bool) {
        guard canRun else { return }
        let script = tab.sql
        let length = (script as NSString).length
        let range = selection.range
        var sql = script
        var baseOffset = 0
        if !all {
            if range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= length {
                sql = (script as NSString).substring(with: range)
                baseOffset = range.location
            } else if let statement = SQLSplitter.statement(at: min(range.location, length), in: script, kind: session.kind) {
                sql = statement.text
                baseOffset = statement.range.location
            } else {
                return
            }
        }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let session = session
        let tab = tab
        QueryRunner.start(tab, statementCount: SQLSplitter.split(sql, kind: session.kind).count) {
            await session.run(sql, in: tab, baseOffset: baseOffset)
        }
    }
}

/// The editor's selection, kept outside SwiftUI's dependency tracking and remembered per tab while the
/// window is open (switching tabs recreates the editor).
@MainActor
private final class EditorSelection {
    private static var remembered: [UUID: NSRange] = [:]

    private let tabID: UUID
    var range: NSRange {
        didSet { Self.remembered[tabID] = range }
    }

    init(tab: QueryTab) {
        tabID = tab.id
        range = Self.remembered[tab.id] ?? NSRange(location: (tab.sql as NSString).length, length: 0)
    }

    var binding: Binding<NSRange> {
        Binding(get: { self.range }, set: { self.range = $0 })
    }
}

/// Keeps each tab's running task reachable so Stop works even after the view was recreated, and
/// remembers how many statements the tab's last run had (for "Statement 3 of 5 failed").
@MainActor
private enum QueryRunner {
    private static var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private static var statementCounts: [UUID: Int] = [:]

    static func statementCount(of tab: QueryTab) -> Int? { statementCounts[tab.id] }

    static func start(_ tab: QueryTab, statementCount: Int, _ work: @escaping @MainActor () async -> Void) {
        let id = tab.id
        statementCounts[id] = statementCount
        let token = UUID()
        let task = Task { @MainActor in
            await work()
            if tasks[id]?.token == token { tasks[id] = nil }
        }
        tasks[id] = (token, task)
    }

    static func stop(_ tab: QueryTab, session: DatabaseSession) {
        tasks[tab.id]?.task.cancel()
        // Only this tab's own statement: another tab's query or a table load keeps running.
        Task { await session.cancelRunningQuery(in: tab) }
    }
}

// MARK: - Editor pane

private struct QueryEditorPane: View {
    var session: DatabaseSession
    @Bindable var tab: QueryTab
    var selection: Binding<NSRange>
    var onRun: (Bool) -> Void

    @State private var words = CompletionWordCache()

    var body: some View {
        SQLTextView(
            text: $tab.sql,
            kind: session.kind,
            fontSize: CGFloat(session.settings.editorFontSize),
            completionWords: words.words(schemas: session.schemas, results: tab.results),
            errorRange: tab.failedStatementRange,
            selectedRange: selection,
            onRun: onRun
        )
        .onChange(of: tab.sql) {
            // The failed range no longer points at the right text once the script changes.
            if tab.failedStatementRange != nil { tab.failedStatementRange = nil }
        }
    }
}

/// Completion words (schema, table and result column names), rebuilt only when their sources change.
@MainActor
private final class CompletionWordCache {
    private var schemas: [SchemaInfo] = []
    private var columns: [String] = []
    private var cached: [String] = []

    func words(schemas: [SchemaInfo], results: [QueryResult]) -> [String] {
        let columns = results.flatMap(\.columns)
        if schemas == self.schemas, columns == self.columns { return cached }
        self.schemas = schemas
        self.columns = columns
        var seen = Set<String>()
        var words: [String] = []
        for name in schemas.map(\.name) + schemas.flatMap({ $0.tables.map(\.ref.name) }) + columns
        where seen.insert(name).inserted {
            words.append(name)
        }
        cached = words
        return words
    }
}

// MARK: - Results pane

/// Display state shared by the results grid, the status bar and the inspector.
@MainActor @Observable
private final class QueryResultsModel {
    var sort: GridSort?
    var selectedRows = IndexSet()
    var focusedCell: GridCell?

    @ObservationIgnored private var cacheKey: (id: QueryResult.ID, sort: GridSort)?
    @ObservationIgnored private var cachedRows: [[CellValue]] = []

    /// The result's rows in display order (sorted client-side when a sort is set). Memoised.
    func rows(for result: QueryResult) -> [[CellValue]] {
        guard let sort, let column = sort.index(in: result.columns) else { return result.rows }
        if let key = cacheKey, key.id == result.id, key.sort == sort { return cachedRows }
        let sorted = QueryResultSorter.sorted(result.rows, column: column, ascending: sort.ascending)
        cacheKey = (result.id, sort)
        cachedRows = sorted
        return sorted
    }

    func clearSelection() {
        selectedRows = []
        focusedCell = nil
    }

    func reset() {
        sort = nil
        clearSelection()
        cacheKey = nil
        cachedRows = []
    }
}

private extension QueryTab {
    var displayedResult: QueryResult? {
        results.first { $0.id == selectedResultID } ?? results.last
    }
}

private struct QueryResultsPane: View {
    var session: DatabaseSession
    @Bindable var tab: QueryTab
    @Bindable var model: QueryResultsModel
    var onShowInspector: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Above the picker: the error belongs to the script, not to the selected result.
            if let error = tab.errorMessage, !tab.results.isEmpty {
                QueryErrorView(message: error, compact: true, context: failureContext)
                Divider()
            }
            if tab.results.count > 1 {
                resultPicker
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result = tab.displayedResult {
            if result.isRowSet {
                ResultsGrid(
                    columns: result.columns,
                    rows: model.rows(for: result),
                    sort: model.sort,
                    selectedRows: $model.selectedRows,
                    focusedCell: $model.focusedCell,
                    onSort: { sort in
                        model.sort = sort
                        model.clearSelection()
                    },
                    onShowInspector: onShowInspector
                )
                .id(result.id)
            } else {
                ContentUnavailableView {
                    Label(QueryResultLabels.verb(for: result), systemImage: "checkmark.circle")
                } description: {
                    Text(result.summary)
                }
            }
        } else if let error = tab.errorMessage {
            QueryErrorView(message: error, compact: false, context: failureContext)
        } else if tab.isRunning {
            ProgressView("Running…")
                .controlSize(.small)
        } else {
            Text("Run a query with ⌘↩")
                .foregroundStyle(.tertiary)
        }
    }

    /// "Statement 3 of 3 failed", when a script stopped after some statements succeeded.
    private var failureContext: String? {
        QueryResultLabels.failure(succeeded: tab.results.count, total: QueryRunner.statementCount(of: tab))
    }

    @ViewBuilder
    private var resultPicker: some View {
        let picker = Picker("Result", selection: $tab.selectedResultID) {
            ForEach(Array(tab.results.enumerated()), id: \.element.id) { index, result in
                Text(QueryResultLabels.title(for: result, index: index))
                    .tag(Optional(result.id))
            }
        }
        .labelsHidden()
        .controlSize(.small)

        HStack {
            if tab.results.count <= 4 {
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                picker.pickerStyle(.menu).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if tab.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("Running…")
                    .foregroundStyle(.secondary)
            } else if tab.errorMessage != nil, !tab.results.isEmpty {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Stopped at statement \((tab.results.count + 1).formatted()) (error)")
                    .foregroundStyle(.secondary)
            } else if let result = tab.displayedResult {
                Text(result.summary)
                    .foregroundStyle(.secondary)
                    .help(result.truncated
                          ? "Only the first \(result.rows.count.formatted()) rows were read. Change the limit in Settings."
                          : result.summary)
                if result.isRowSet, !model.selectedRows.isEmpty {
                    Text("\(model.selectedRows.count.formatted()) selected")
                        .foregroundStyle(.tertiary)
                }
            } else if tab.errorMessage != nil {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Query failed")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let result = tab.displayedResult, result.isRowSet, !tab.isRunning {
                copyMenu(for: result)
                Button("Export…") {
                    ResultExporter.export(columns: result.columns, rows: model.rows(for: result),
                                          suggestedName: tab.title, dialect: session.dialect)
                }
                .buttonStyle(.borderless)
                .help("Export the result to a file")
            }
        }
        .font(.callout)
        .controlSize(.small)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func copyMenu(for result: QueryResult) -> some View {
        let scope = model.selectedRows.isEmpty
            ? "All Rows"
            : "\(model.selectedRows.count.formatted()) Selected Row\(model.selectedRows.count == 1 ? "" : "s")"
        return Menu("Copy") {
            Section(scope) {
                ForEach(QueryResultLabels.copyFormats, id: \.self) { format in
                    Button(QueryResultLabels.copyTitle(for: format)) { copy(result, as: format) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Copy rows to the clipboard")
    }

    private func copy(_ result: QueryResult, as format: ResultExporter.Format) {
        let rows = model.rows(for: result)
        let chosen = model.selectedRows.isEmpty
            ? rows
            : model.selectedRows.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        let text = ResultExporter.string(columns: result.columns, rows: chosen, format: format, dialect: session.dialect)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct QueryErrorView: View {
    var message: String
    /// Compact: a short banner above partial results. Otherwise fills the results area.
    var compact: Bool
    /// "Statement 3 of 3 failed", shown before the message when a script stopped part-way.
    var context: String?

    var body: some View {
        if compact {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error")
                Text(context.map { "\($0): \(message)" } ?? message)
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        } else if lines.count > 6 {
            // Long server errors (DETAIL, HINT, context) read poorly centred.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Label(context ?? "Query Failed", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    details(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } else {
            ContentUnavailableView {
                Label(context ?? "Query Failed", systemImage: "exclamationmark.triangle")
            } description: {
                details(alignment: .center)
                    .frame(maxWidth: 480)
            }
        }
    }

    private var lines: [Substring] {
        message.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The first line in the primary style, driver codes and details below it in secondary.
    private func details(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(lines.first.map(String.init) ?? message)
                .foregroundStyle(.primary)
            if lines.count > 1 {
                Text(lines.dropFirst().joined(separator: "\n"))
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }
}

private struct QueryRowInspector: View {
    var tab: QueryTab
    var model: QueryResultsModel

    var body: some View {
        if let result = tab.displayedResult, result.isRowSet {
            let rows = model.rows(for: result)
            let index = rowIndex(in: rows)
            RowInspectorView(
                columns: result.columns,
                row: index.map { rows[$0] },
                rowID: index.map { AnyHashable("\(result.id)#\($0)#\(String(describing: model.sort))") },
                focusedColumn: model.focusedCell?.column
            )
        } else {
            ContentUnavailableView {
                Label("No Row Selected", systemImage: "sidebar.right")
            } description: {
                Text("Run a query that returns rows, then select a row to inspect it.")
            }
        }
    }

    private func rowIndex(in rows: [[CellValue]]) -> Int? {
        if let focused = model.focusedCell?.row, model.selectedRows.contains(focused), rows.indices.contains(focused) {
            return focused
        }
        guard let first = model.selectedRows.first, rows.indices.contains(first) else { return nil }
        return first
    }
}

/// Titles for the result picker, status bar and copy menu.
enum QueryResultLabels {
    static let copyFormats: [ResultExporter.Format] = [.csv, .tsv, .json, .markdown]

    static func copyTitle(for format: ResultExporter.Format) -> String {
        switch format {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .sqlInsert: "SQL INSERT"
        }
    }

    /// "Statement 3 of 5 failed" when earlier statements of the run succeeded; nil for a lone statement.
    /// A run stops at the first error, so the failed statement directly follows the successful ones.
    static func failure(succeeded: Int, total: Int?) -> String? {
        guard succeeded > 0 || (total ?? 0) > 1 else { return nil }
        let failed = (succeeded + 1).formatted()
        if let total, total > succeeded { return "Statement \(failed) of \(total.formatted()) failed" }
        return "Statement \(failed) failed"
    }

    /// "Result 2 (12 rows)", "UPDATE (3 affected)", "CREATE".
    static func title(for result: QueryResult, index: Int) -> String {
        if result.isRowSet {
            let count = result.rows.count
            return "Result \(index + 1) (\(count.formatted()) row\(count == 1 ? "" : "s"))"
        }
        let verb = verb(for: result)
        if let affected = result.rowsAffected { return "\(verb) (\(affected.formatted()) affected)" }
        return verb
    }

    /// The statement's leading keyword (comments skipped), e.g. "UPDATE".
    static func verb(for result: QueryResult) -> String {
        let ns = String(result.statement.prefix(400)) as NSString
        let first = SQLHighlighter.tokens(in: ns, kind: .postgres).first { $0.kind != .comment }
        guard let first, first.kind == .keyword else { return "Statement" }
        return ns.substring(with: first.range).uppercased()
    }
}

/// Client-side ordering for read-only query results.
enum QueryResultSorter {
    /// Sorts by one column. Values compare numerically when both parse as numbers, otherwise with
    /// Finder-style string comparison. NULLs (and missing cells) always come last; ties keep their order.
    static func sorted(_ rows: [[CellValue]], column: Int, ascending: Bool) -> [[CellValue]] {
        let keys = rows.map { row -> SortKey in
            guard column < row.count, let value = row[column] else { return .null }
            if let number = number(from: value) { return .number(number, value) }
            return .text(value)
        }
        let order = keys.indices.sorted { a, b in
            switch (keys[a], keys[b]) {
            case (.null, .null): return a < b
            case (.null, _): return false
            case (_, .null): return true
            case let (lhs, rhs):
                let result = compare(lhs, rhs)
                if result == .orderedSame { return a < b }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        return order.map { rows[$0] }
    }

    private enum SortKey {
        case null
        case number(Double, String)
        case text(String)

        var text: String {
            switch self {
            case .null: ""
            case .number(_, let text), .text(let text): text
            }
        }
    }

    private static func compare(_ lhs: SortKey, _ rhs: SortKey) -> ComparisonResult {
        if case .number(let a, _) = lhs, case .number(let b, _) = rhs {
            return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        return lhs.text.localizedStandardCompare(rhs.text)
    }

    /// Parses plain decimal numbers ("42", "-3.5", "1e6"); rejects text such as "nan" or "inf".
    static func number(from value: String) -> Double? {
        guard let first = value.utf8.first,
              (first >= 0x30 && first <= 0x39) || first == 0x2D || first == 0x2B || first == 0x2E,
              let number = Double(value), number.isFinite else { return nil }
        return number
    }
}

// MARK: - Split view

/// NSSplitView-backed vertical split. SwiftUI's VSplitView ignores ideal sizes and always starts 50/50;
/// this keeps the divider at `topFraction` of the height (also across window resizes) and reports the
/// new fraction when the user finishes dragging.
private struct QueryEditorSplit<Top: View, Bottom: View>: NSViewRepresentable {
    @Binding var topFraction: Double
    var top: Top
    var bottom: Bottom

    init(topFraction: Binding<Double>, @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        _topFraction = topFraction
        self.top = top()
        self.bottom = bottom()
    }

    func makeCoordinator() -> QueryEditorSplitCoordinator { QueryEditorSplitCoordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = DividerTrackingSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        let topHost = NSHostingView(rootView: top)
        let bottomHost = NSHostingView(rootView: bottom)
        topHost.sizingOptions = []
        bottomHost.sizingOptions = []
        split.addSubview(topHost)
        split.addSubview(bottomHost)

        let coordinator = context.coordinator
        coordinator.fraction = min(max(topFraction, 0.1), 0.9)
        coordinator.onCommit = { topFraction = $0 }
        split.delegate = coordinator
        split.onDividerDragEnded = { [weak coordinator] in coordinator?.commit() }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        (split.subviews.first as? NSHostingView<Top>)?.rootView = top
        (split.subviews.last as? NSHostingView<Bottom>)?.rootView = bottom
        context.coordinator.onCommit = { topFraction = $0 }
    }
}

@MainActor
private final class QueryEditorSplitCoordinator: NSObject, NSSplitViewDelegate {
    /// Editor share of the height until the user drags the divider. Results get the larger part.
    nonisolated static let defaultFraction = 0.4
    var fraction = defaultFraction
    var onCommit: ((Double) -> Void)?
    private let minTop: CGFloat = 80
    private let minBottom: CGFloat = 110

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.subviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let size = splitView.bounds.size
        let divider = splitView.dividerThickness
        let available = max(0, size.height - divider)
        var topHeight = (available * fraction).rounded()
        if available >= minTop + minBottom {
            topHeight = min(max(topHeight, minTop), available - minBottom)
        }
        splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: size.width, height: topHeight)
        splitView.subviews[1].frame = NSRect(x: 0, y: topHeight + divider, width: size.width, height: available - topHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, minTop)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - splitView.dividerThickness - minBottom)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil,
              let split = notification.object as? NSSplitView, split.subviews.count == 2 else { return }
        let available = split.bounds.height - split.dividerThickness
        guard available > 0 else { return }
        fraction = Double(split.subviews[0].frame.height / available)
    }

    func commit() {
        onCommit?(fraction)
    }
}

/// Reports when a divider drag finishes (NSSplitView tracks the drag inside mouseDown).
private final class DividerTrackingSplitView: NSSplitView {
    var onDividerDragEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onDividerDragEnded?()
    }
}
