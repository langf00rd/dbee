import Foundation
import Observation

/// State for browsing/editing one table: paging, filter, sort, loaded rows and pending edits.
///
/// Pending changes are keyed by row index into the loaded page, so any load that replaces the page
/// clears them. The view asks the user before navigating away from uncommitted changes.
@MainActor @Observable
final class TableBrowserModel {
    /// Weak: tasks started from the view (commit, paging) can outlive the window's session. Async work
    /// takes a strong reference for its own duration and stops with "Not connected" once it is gone.
    @ObservationIgnored private weak var owner: DatabaseSession?
    let table: TableRef
    let dialect: SQLDialect
    private let settings: AppSettings

    /// The session, for views, which only exist while it does. Model code uses `owner` instead.
    var session: DatabaseSession {
        guard let owner else { preconditionFailure("TableBrowserModel used after its session was released") }
        return owner
    }

    /// Data grid or structure tab, remembered per table.
    enum DisplayMode: String, CaseIterable, Identifiable {
        case data
        case structure

        var id: String { rawValue }
        var title: String { self == .data ? "Data" : "Structure" }
    }

    /// Operators offered by the filter bar's simple mode.
    enum FilterOperator: String, CaseIterable, Identifiable {
        case equal = "="
        case notEqual = "≠"
        case less = "<"
        case greater = ">"
        case lessOrEqual = "≤"
        case greaterOrEqual = "≥"
        case like = "LIKE"
        case notLike = "NOT LIKE"
        case isNull = "IS NULL"
        case isNotNull = "IS NOT NULL"
        case `in` = "IN"

        var id: String { rawValue }
        var needsValue: Bool { self != .isNull && self != .isNotNull }
    }

    /// The filter bar's editing state. Kept here (not in view state) so it survives switching tables.
    struct FilterDraft: Equatable {
        var column = ""
        var op: FilterOperator = .equal
        var value = ""
        var isRaw = false
        var rawText = ""
    }

    /// A row added in the grid but not yet inserted. Only `setColumns` go into the INSERT,
    /// so untouched columns get their defaults (serials, timestamps…).
    struct InsertedRow: Equatable {
        var values: [CellValue]
        var setColumns: Set<Int> = []
    }

    // MARK: Loaded page

    private(set) var columns: [String] = []
    /// Rows of the current page as loaded from the server (never modified by edits).
    private(set) var rows: [[CellValue]] = []
    private(set) var structure: TableStructure?
    private(set) var structureError: String?
    private(set) var tableKind: TableKind
    /// COUNT(*) for the current filter; nil while counting or when counting failed.
    private(set) var totalCount: Int?
    private(set) var isCounting = false
    private(set) var page = 0
    /// Offset of the loaded page, captured at load time.
    private(set) var loadedOffset = 0
    /// Applied WHERE expression (without the WHERE keyword); empty for none.
    private(set) var filter = ""
    private(set) var sort: GridSort?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Set when DDL ran elsewhere while this table had pending edits: the loaded structure and rows may
    /// no longer match the table, so edits are blocked until it is reloaded.
    private(set) var needsReload = false
    var errorMessage: String?
    private(set) var lastQueryDuration: TimeInterval?

    // MARK: View state kept per table

    var displayMode: DisplayMode = .data
    var filterDraft = FilterDraft()
    var selectedRows = IndexSet()
    var focusedCell: GridCell?

    // MARK: Pending changes

    /// Edits to loaded rows, keyed by (row index, column index).
    private(set) var edits: [GridCell: CellValue] = [:]
    private(set) var insertedRows: [InsertedRow] = []
    /// Indices of loaded rows marked for deletion.
    private(set) var deletedRows: Set<Int> = []
    private(set) var isCommitting = false
    var commitError: String?

    // MARK: Derived grid state (rebuilt on every change)

    /// Loaded rows with edits applied, followed by inserted rows.
    private(set) var gridRows: [[CellValue]] = []
    private(set) var editedCells: Set<GridCell> = []
    private(set) var rowStates: [Int: GridRowState] = [:]

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var countGeneration = 0
    @ObservationIgnored private var countTask: Task<Void, Never>?

    init(session: DatabaseSession, table: TableRef) {
        owner = session
        self.table = table
        dialect = session.dialect
        settings = session.settings
        tableKind = session.allTables.first { $0.ref == table }?.kind ?? .table
    }

    var pageSize: Int { max(1, settings.pageSize) }

    private func connectedSession() throws -> DatabaseSession {
        guard let owner else { throw DatabaseError("Not connected") }
        return owner
    }

    // MARK: Paging

    var hasPreviousPage: Bool { page > 0 }

    var hasNextPage: Bool {
        guard errorMessage == nil else { return false }
        if let totalCount { return loadedOffset + rows.count < totalCount }
        return rows.count >= pageSize
    }

    var lastPageIndex: Int? {
        totalCount.map { max(0, ($0 - 1) / pageSize) }
    }

    /// "1–200 of 12,345 rows", "1–200 of ?" while counting.
    var rowRangeDescription: String {
        guard hasLoaded, errorMessage == nil else { return "" }
        if rows.isEmpty {
            if let totalCount, totalCount > 0 { return "No rows on this page (\(totalCount.formatted()) in total)" }
            return "No rows"
        }
        if let totalCount, loadedOffset == 0, rows.count == totalCount {
            return "\(totalCount.formatted()) row\(totalCount == 1 ? "" : "s")"
        }
        let range = "\((loadedOffset + 1).formatted())–\((loadedOffset + rows.count).formatted())"
        if let totalCount { return "\(range) of \(totalCount.formatted()) row\(totalCount == 1 ? "" : "s")" }
        return isCounting ? "\(range) of ?" : range
    }

    // MARK: Loading

    /// Loads the first time the table is shown; later calls keep the cached page, unless the table
    /// changed meanwhile and there are no pending edits to lose.
    func load() async {
        guard !isLoading else { return }
        if hasLoaded {
            guard needsReload, !hasChanges else { return }
            await reload()
            return
        }
        await loadPage(refreshStructure: structure == nil, recount: totalCount == nil)
    }

    /// Called by the session after DDL ran in a query tab.
    func markStale() {
        needsReload = true
    }

    /// Refreshes structure, the current page and the row count. Discards pending changes.
    func reload() async {
        await loadPage(refreshStructure: true, recount: true)
    }

    func nextPage() async {
        guard hasNextPage else { return }
        page += 1
        await loadPage(refreshStructure: false, recount: false)
    }

    func previousPage() async {
        guard page > 0 else { return }
        page -= 1
        await loadPage(refreshStructure: false, recount: false)
    }

    func firstPage() async {
        guard page != 0 else { return }
        page = 0
        await loadPage(refreshStructure: false, recount: false)
    }

    func lastPage() async {
        guard let last = lastPageIndex, last != page else { return }
        page = last
        await loadPage(refreshStructure: false, recount: false)
    }

    /// Applies a raw WHERE expression (nil/blank clears it) and goes back to the first page.
    /// A leading WHERE keyword is accepted and dropped.
    func setFilter(_ expression: String?) async {
        var text = expression?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.range(of: #"^where\s"#, options: [.regularExpression, .caseInsensitive]) != nil {
            text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        filter = text
        page = 0
        await loadPage(refreshStructure: false, recount: true)
    }

    func setSort(_ newSort: GridSort?) async {
        sort = newSort
        page = 0
        await loadPage(refreshStructure: false, recount: false)
    }

    private func loadPage(refreshStructure: Bool, recount: Bool) async {
        generation += 1
        let current = generation
        isLoading = true
        errorMessage = nil
        clearPending()
        if recount { invalidateCount() }

        if refreshStructure || structure == nil {
            do {
                let loaded = try await connectedSession().structure(of: table)
                guard current == generation else { return }
                structure = loaded
                structureError = nil
                needsReload = false
            } catch {
                guard current == generation else { return }
                structureError = DatabaseSession.describe(error)
            }
            tableKind = owner?.allTables.first { $0.ref == table }?.kind ?? tableKind
        }

        let limit = pageSize
        let offset = page * limit
        let currentFilter = filter.isEmpty ? nil : filter
        do {
            let result: QueryResult
            if dialect.kind.pagesWithSQL {
                let sql = dialect.selectPage(table, filter: currentFilter, sort: sort, limit: limit, offset: offset)
                result = try await connectedSession().execute(sql, maxRows: limit, recordHistory: false)
            } else {
                result = try await connectedSession().page(of: table, filter: currentFilter, sort: sort, limit: limit, offset: offset)
            }
            guard current == generation else { return }
            // Some drivers report no columns for an empty result; the structure still knows them.
            columns = result.columns.isEmpty ? (structure?.columns.map(\.name) ?? []) : result.columns
            rows = result.rows
            loadedOffset = offset
            lastQueryDuration = result.duration
            hasLoaded = true
            isLoading = false
            selectedRows = []
            focusedCell = nil
            resetFilterColumnIfNeeded()
            clearPending()
            if recount || (totalCount == nil && !isCounting) { startCount() }
        } catch {
            guard current == generation else { return }
            errorMessage = DatabaseSession.describe(error)
            isLoading = false
        }
    }

    /// Forgets the current count and ignores any count still running.
    private func invalidateCount() {
        countTask?.cancel()
        countTask = nil
        countGeneration += 1
        totalCount = nil
        isCounting = false
    }

    /// Counts rows in a separate task so a slow COUNT(*) never holds back the page.
    private func startCount() {
        invalidateCount()
        let current = countGeneration
        let currentFilter = filter.isEmpty ? nil : filter
        let sql = dialect.count(table, filter: currentFilter)
        let isSQL = dialect.kind.pagesWithSQL
        let table = table
        isCounting = true
        countTask = Task { [weak self] in
            guard let self else { return }
            let count: Int?
            if isSQL {
                let result = try? await connectedSession().execute(sql, maxRows: 1, recordHistory: false)
                let text = result?.rows.first?.first ?? nil
                count = text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else {
                count = (try? await connectedSession().rowCount(of: table, filter: currentFilter)) ?? nil
            }
            guard current == countGeneration else { return }
            totalCount = count
            isCounting = false
        }
    }

    /// Replaces the loaded page without running a query. Used by tests.
    func replaceLoadedPage(columns: [String], rows: [[CellValue]], structure: TableStructure?, kind: TableKind = .table) {
        self.columns = columns
        self.rows = rows
        self.structure = structure
        tableKind = kind
        structureError = nil
        hasLoaded = true
        resetFilterColumnIfNeeded()
        clearPending()
    }

    private func resetFilterColumnIfNeeded() {
        guard !columns.contains(filterDraft.column) else { return }
        filterDraft.column = structure?.primaryKey.first.flatMap { columns.contains($0) ? $0 : nil } ?? columns.first ?? ""
    }

    // MARK: Filter building

    /// Builds a WHERE expression from the filter bar's simple mode, quoting the column and the value
    /// for the current dialect. Returns nil when the draft is incomplete, or the engine can't filter that way.
    /// For MongoDB it is a query document, for Redis a key pattern, for Meilisearch a filter expression.
    func filterExpression(for draft: FilterDraft) -> String? {
        guard !draft.column.isEmpty else { return nil }
        let type = structure?.columns.first { $0.name == draft.column }?.dataType
        switch dialect.kind {
        case .mongodb: return Self.mongoFilter(for: draft)
        case .redis: return Self.redisPattern(for: draft)
        case .scylla: return Self.cqlFilter(for: draft, type: type)
        case .meilisearch: return Self.meilisearchFilter(for: draft)
        case .postgres, .mysql, .sqlite, .clickhouse: break
        }
        let column = dialect.quoteIdentifier(draft.column)
        let value = draft.value
        switch draft.op {
        case .equal: return "\(column) = \(dialect.literal(value))"
        case .notEqual: return "\(column) <> \(dialect.literal(value))"
        case .less: return "\(column) < \(dialect.literal(value))"
        case .greater: return "\(column) > \(dialect.literal(value))"
        case .lessOrEqual: return "\(column) <= \(dialect.literal(value))"
        case .greaterOrEqual: return "\(column) >= \(dialect.literal(value))"
        case .like, .notLike:
            // Postgres and ClickHouse have no LIKE for non-text types, so compare the text form.
            let subject = switch dialect.kind {
            case .postgres: "CAST(\(column) AS TEXT)"
            case .clickhouse: "toString(\(column))"
            default: column
            }
            return "\(subject) \(draft.op.rawValue) \(dialect.literal(value))"
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        case .in:
            let items = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "\(column) IN (\(items.map { dialect.literal($0) }.joined(separator: ", ")))"
        }
    }

    /// A MongoDB query document for the simple filter. Values are read like the shell reads them (numbers,
    /// true, null, ObjectId("…")); anything else is a string. 24 hex digits match an ObjectId or that text.
    static func mongoFilter(for draft: FilterDraft) -> String? {
        let field = BSONFormatting.quote(draft.column)
        let text = draft.value.trimmingCharacters(in: .whitespaces)
        func literal(_ value: String) -> String {
            if let parsed = try? MongoShellParser.value(value) {
                switch parsed {
                case .document, .array: break
                default: return value
                }
            }
            return BSONFormatting.quote(value)
        }
        func comparable(_ value: String) -> String {
            if value.count == 24, MongoShellParser.hexBytes(value) != nil {
                return "ObjectId(\(BSONFormatting.quote(value))), \(BSONFormatting.quote(value))"
            }
            return literal(value)
        }
        func regex(_ pattern: String) -> String {
            var out = "^"
            for character in pattern {
                switch character {
                case "%": out += ".*"
                case "_": out += "."
                case "/": out += "\\/"
                case _ where "\\^$.|?*+()[]{}".contains(character): out += "\\" + String(character)
                default: out.append(character)
                }
            }
            return "/" + out + "$/"
        }
        let isHexId = text.count == 24 && MongoShellParser.hexBytes(text) != nil
        switch draft.op {
        case .equal: return isHexId ? "{ \(field): { $in: [\(comparable(text))] } }" : "{ \(field): \(literal(text)) }"
        case .notEqual: return isHexId ? "{ \(field): { $nin: [\(comparable(text))] } }" : "{ \(field): { $ne: \(literal(text)) } }"
        case .less: return "{ \(field): { $lt: \(literal(text)) } }"
        case .greater: return "{ \(field): { $gt: \(literal(text)) } }"
        case .lessOrEqual: return "{ \(field): { $lte: \(literal(text)) } }"
        case .greaterOrEqual: return "{ \(field): { $gte: \(literal(text)) } }"
        case .like: return "{ \(field): \(regex(draft.value)) }"
        case .notLike: return "{ \(field): { $not: \(regex(draft.value)) } }"
        case .isNull: return "{ \(field): null }"
        case .isNotNull: return "{ \(field): { $ne: null } }"
        case .in:
            let items = draft.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "{ \(field): { $in: [\(items.map(comparable).joined(separator: ", "))] } }"
        }
    }

    /// A CQL condition for the simple filter. Values for numeric, boolean and uuid columns are written bare,
    /// anything else as a string. CQL has no <>, NOT LIKE or IS [NOT] NULL in WHERE, so those give nil. LIKE
    /// works on ScyllaDB (and Cassandra with a SASI index).
    nonisolated static func cqlFilter(for draft: FilterDraft, type: String?) -> String? {
        let column = ScyllaDriver.quoteName(draft.column)
        let bareTypes: Set<String> = ["int", "bigint", "smallint", "tinyint", "varint", "float", "double", "decimal",
                                      "counter", "boolean", "uuid", "timeuuid"]
        let bare = type.map { bareTypes.contains($0.lowercased()) } ?? false
        func literal(_ value: String) -> String {
            let text = value.trimmingCharacters(in: .whitespaces)
            return bare && !text.isEmpty && !text.contains("'") ? text : ScyllaDriver.literal(value)
        }
        switch draft.op {
        case .equal: return "\(column) = \(literal(draft.value))"
        case .less: return "\(column) < \(literal(draft.value))"
        case .greater: return "\(column) > \(literal(draft.value))"
        case .lessOrEqual: return "\(column) <= \(literal(draft.value))"
        case .greaterOrEqual: return "\(column) >= \(literal(draft.value))"
        case .like: return "\(column) LIKE \(ScyllaDriver.literal(draft.value))"
        case .in:
            let items = draft.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "\(column) IN (\(items.map(literal).joined(separator: ", ")))"
        case .notEqual, .notLike, .isNull, .isNotNull: return nil
        }
    }

    /// A Meilisearch filter for the simple filter. Numbers are written bare, anything else in double quotes.
    /// The attribute must be filterable in the index's settings. Meilisearch has no LIKE.
    nonisolated static func meilisearchFilter(for draft: FilterDraft) -> String? {
        let attribute = draft.column
        func literal(_ value: String) -> String {
            let text = value.trimmingCharacters(in: .whitespaces)
            if text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil { return text }
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        switch draft.op {
        case .equal: return "\(attribute) = \(literal(draft.value))"
        case .notEqual: return "\(attribute) != \(literal(draft.value))"
        case .less: return "\(attribute) < \(literal(draft.value))"
        case .greater: return "\(attribute) > \(literal(draft.value))"
        case .lessOrEqual: return "\(attribute) <= \(literal(draft.value))"
        case .greaterOrEqual: return "\(attribute) >= \(literal(draft.value))"
        case .isNull: return "\(attribute) IS NULL"
        case .isNotNull: return "\(attribute) IS NOT NULL"
        case .in:
            let items = draft.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "\(attribute) IN [\(items.map(literal).joined(separator: ", "))]"
        case .like, .notLike: return nil
        }
    }

    /// A SCAN pattern for the simple filter: only the key column can be matched, exactly or with LIKE's
    /// % and _ wildcards.
    static func redisPattern(for draft: FilterDraft) -> String? {
        guard draft.column == "key", !draft.value.isEmpty else { return nil }
        func escaped(_ character: Character) -> String {
            "*?[]\\^".contains(character) ? "\\" + String(character) : String(character)
        }
        switch draft.op {
        case .equal: return draft.value.map(escaped).joined()
        case .like:
            return draft.value.map { $0 == "%" ? "*" : $0 == "_" ? "?" : escaped($0) }.joined()
        default: return nil
        }
    }

    // MARK: Editing

    /// Why the table can't be edited, or nil when it can.
    var readOnlyReason: String? {
        switch dialect.kind {
        case .redis: return "Keys are read-only here. Change them with commands in a query tab."
        case .mongodb: return "Documents are read-only here. Change them with commands in a query tab."
        case .meilisearch: return "Documents are read-only here. Change them with requests in a query tab."
        case .clickhouse, .scylla: return "Rows are read-only here. Change them with statements in a query tab."
        case .postgres, .mysql, .sqlite: break
        }
        if tableKind != .table { return "Views are read-only." }
        if needsReload { return "The table changed. Reload to edit." }
        if let structureError, structure == nil {
            return "The table structure couldn't be read, so rows can't be edited safely.\n\(structureError)"
        }
        guard let structure, hasLoaded else { return "Loading…" }
        if structure.primaryKey.isEmpty { return "This table has no primary key, so rows can't be edited safely." }
        if primaryKeyIndices == nil { return "The primary key columns aren't part of the result, so rows can't be edited safely." }
        return nil
    }

    /// False while a page load or commit is in flight, since either would invalidate pending row indices.
    var isEditable: Bool { readOnlyReason == nil && !isCommitting && !isLoading }

    /// Result-column indices of the primary key, or nil when any key column is missing.
    var primaryKeyIndices: [Int]? {
        guard let key = structure?.primaryKey, !key.isEmpty else { return nil }
        let indices = key.compactMap { columns.firstIndex(of: $0) }
        return indices.count == key.count ? indices : nil
    }

    var hasChanges: Bool { changeCount > 0 }

    /// Number of statements a commit will run: one per edited, deleted or inserted row.
    var changeCount: Int {
        let editedRows = Set(edits.keys.map(\.row)).subtracting(deletedRows)
        return editedRows.count + deletedRows.count + insertedRows.count
    }

    var deleteCount: Int { deletedRows.count }

    /// Column type from the structure, for display (e.g. the inspector).
    func dataType(ofColumn index: Int) -> String? {
        guard columns.indices.contains(index) else { return nil }
        return structure?.columns.first { $0.name == columns[index] }?.dataType
    }

    func isInsertedRow(_ row: Int) -> Bool { row >= rows.count && row < rows.count + insertedRows.count }
    func isDeletedRow(_ row: Int) -> Bool { deletedRows.contains(row) }

    /// Sets a cell in the grid. Setting a loaded cell back to its original value removes the edit.
    func setValue(_ value: CellValue, at cell: GridCell) {
        guard isEditable, columns.indices.contains(cell.column) else { return }
        let before = pendingState
        if cell.row < rows.count {
            guard !deletedRows.contains(cell.row) else { return }
            if rows[cell.row][cell.column] == value {
                edits[cell] = nil
            } else {
                edits[cell] = .some(value)
            }
        } else if isInsertedRow(cell.row) {
            let index = cell.row - rows.count
            insertedRows[index].values[cell.column] = value
            insertedRows[index].setColumns.insert(cell.column)
        } else {
            return
        }
        commitError = nil
        didChangePending(from: before, actionName: "Edit Cell")
    }

    /// Appends an empty row at the bottom of the grid and returns its grid index.
    @discardableResult
    func insertRow() -> Int? {
        guard isEditable, !columns.isEmpty else { return nil }
        let before = pendingState
        insertedRows.append(InsertedRow(values: Array(repeating: nil, count: columns.count)))
        commitError = nil
        didChangePending(from: before, actionName: "Add Row")
        return rows.count + insertedRows.count - 1
    }

    /// Marks loaded rows for deletion and drops inserted rows outright.
    func deleteRows(_ indexes: IndexSet) {
        guard isEditable, !indexes.isEmpty else { return }
        let before = pendingState
        for row in indexes where row < rows.count { deletedRows.insert(row) }
        for row in indexes.reversed() where isInsertedRow(row) { insertedRows.remove(at: row - rows.count) }
        selectedRows = selectedRows.filteredIndexSet { $0 < rows.count + insertedRows.count }
        if let focusedCell, focusedCell.row >= rows.count + insertedRows.count { self.focusedCell = nil }
        commitError = nil
        didChangePending(from: before, actionName: indexes.count == 1 ? "Delete Row" : "Delete Rows")
    }

    /// Whether `cell` has a pending value that `revert(cell:)` would undo.
    func canRevert(cell: GridCell) -> Bool { editedCells.contains(cell) }

    /// Drops the pending value of one cell (for inserted rows the column goes back to its default).
    func revert(cell: GridCell) {
        guard canRevert(cell: cell) else { return }
        let before = pendingState
        if cell.row < rows.count {
            edits[cell] = nil
        } else if isInsertedRow(cell.row) {
            let index = cell.row - rows.count
            insertedRows[index].values[cell.column] = nil
            insertedRows[index].setColumns.remove(cell.column)
        }
        didChangePending(from: before, actionName: "Revert Cell")
    }

    /// Whether any of `indexes` has pending changes.
    func canRevert(rows indexes: IndexSet) -> Bool {
        let editedRows = Set(edits.keys.map(\.row))
        return indexes.contains { rowStates[$0] != nil || editedRows.contains($0) }
    }

    /// Reverts edits and deletion marks on loaded rows and removes inserted rows.
    func revertRows(_ indexes: IndexSet) {
        guard canRevert(rows: indexes) else { return }
        let before = pendingState
        for row in indexes where row < rows.count {
            deletedRows.remove(row)
            edits = edits.filter { $0.key.row != row }
        }
        for row in indexes.reversed() where isInsertedRow(row) { insertedRows.remove(at: row - rows.count) }
        selectedRows = selectedRows.filteredIndexSet { $0 < rows.count + insertedRows.count }
        didChangePending(from: before, actionName: "Revert Rows")
    }

    func discard() {
        guard hasChanges else { return }
        let before = pendingState
        clearPending(keepUndo: true)
        didChangePending(from: before, actionName: "Discard Changes")
    }

    // MARK: SQL generation

    /// The statements a commit runs, in order: deletes, then updates, then inserts. Deleting first
    /// lets an update or insert reuse a key that a deleted row held.
    func pendingStatements() -> [String] {
        pendingChanges().map(\.sql)
    }

    /// A commit statement, with the condition identifying its row for an UPDATE.
    private struct PendingStatement {
        var sql: String
        var keyCondition: String?
    }

    private func pendingChanges() -> [PendingStatement] {
        guard let keyIndices = primaryKeyIndices else { return [] }
        let binary = binaryColumns
        var statements: [PendingStatement] = []

        for row in deletedRows.sorted() where row < rows.count {
            statements.append(PendingStatement(
                sql: dialect.delete(table, key: key(for: row, keyIndices: keyIndices), binaryColumns: binary)))
        }

        let editsByRow = Dictionary(grouping: edits, by: { $0.key.row })
        for row in editsByRow.keys.sorted() where row < rows.count && !deletedRows.contains(row) {
            let changes = editsByRow[row, default: []]
                .sorted { $0.key.column < $1.key.column }
                .map { (columns[$0.key.column], $0.value) }
            let key = key(for: row, keyIndices: keyIndices)
            statements.append(PendingStatement(
                sql: dialect.update(table, changes: changes, key: key, binaryColumns: binary),
                keyCondition: dialect.keyCondition(key, binaryColumns: binary)))
        }

        for inserted in insertedRows {
            let values = inserted.setColumns.sorted().map { (columns[$0], inserted.values[$0]) }
            statements.append(PendingStatement(sql: dialect.insert(table, values: values, binaryColumns: binary)))
        }
        return statements
    }

    /// Columns whose "\x…" cells hold bytes, so edits and keys are written back as bytes rather than text.
    private var binaryColumns: Set<String> {
        let kind = dialect.kind
        return Set(structure?.columns.filter { SQLDialect.isBinaryType($0.dataType, kind: kind) }.map(\.name) ?? [])
    }

    /// Key columns with the row's ORIGINAL values, so editing a key column still targets the right row.
    private func key(for row: Int, keyIndices: [Int]) -> [(String, CellValue)] {
        keyIndices.map { (columns[$0], rows[row][$0]) }
    }

    // MARK: Commit

    /// Runs the pending statements in one transaction and reloads. On failure the transaction is rolled
    /// back, pending changes are kept and `commitError` is set.
    ///
    /// Each UPDATE or DELETE must affect exactly one row, so a stale or imprecisely rendered key can't
    /// silently drop or multiply an edit.
    func commit() async {
        guard !isCommitting else { return }
        let changes = pendingChanges()
        guard !changes.isEmpty else { return }
        guard !needsReload else {
            commitError = "The table changed since it was loaded, so these edits can’t be saved safely. Reload the table and make them again."
            return
        }
        isCommitting = true
        commitError = nil
        defer { isCommitting = false }
        do {
            let session = try connectedSession()
            let dialect = self.dialect
            let table = self.table
            try await session.executeInTransaction(changes.map(\.sql)) { index, result, driver in
                let change = changes[index]
                try await Self.verify(result, of: change.sql, kind: dialect.kind) {
                    // MySQL counts changed rows, not matched ones; ask whether the row is still there.
                    guard let condition = change.keyCondition else { return nil }
                    let count = try await driver.execute(dialect.count(table, filter: condition), maxRows: 1)
                    return (count.rows.first?.first ?? nil).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                }
            }
            clearPending()
            await loadPage(refreshStructure: false, recount: true)
        } catch {
            commitError = DatabaseSession.describe(error)
        }
    }

    /// Throws unless an UPDATE or DELETE affected exactly one row. When MySQL reports 0 for an UPDATE
    /// without a matched-rows count (an UPDATE that left the row unchanged also reports 0), `matchingRows`
    /// counts the rows its key matches instead.
    private static func verify(_ result: QueryResult, of statement: String, kind: DatabaseKind,
                               matchingRows: () async throws -> Int?) async throws {
        let verb = statement.prefix(6).uppercased()
        guard verb == "UPDATE" || verb == "DELETE" else { return }
        var affected = (verb == "UPDATE" ? result.rowsMatched : nil) ?? result.rowsAffected
        if affected == 0, verb == "UPDATE", kind == .mysql, result.rowsMatched == nil {
            affected = try await matchingRows()
        }
        guard let affected else { return }
        if affected > 1 {
            throw DatabaseError(
                "A change matched \(affected) rows instead of one, so nothing was saved.",
                detail: "The primary key didn't identify a single row."
            )
        }
        if affected == 0 {
            throw DatabaseError(
                "A row you \(verb == "DELETE" ? "deleted" : "edited") no longer exists or its key changed, so nothing was saved.",
                detail: "Reload the table to see its current contents."
            )
        }
    }

    // MARK: Pending state bookkeeping

    private struct PendingState: Equatable {
        var edits: [GridCell: CellValue]
        var insertedRows: [InsertedRow]
        var deletedRows: Set<Int>
    }

    private var pendingState: PendingState {
        get { PendingState(edits: edits, insertedRows: insertedRows, deletedRows: deletedRows) }
        set {
            edits = newValue.edits
            insertedRows = newValue.insertedRows
            deletedRows = newValue.deletedRows
        }
    }

    /// Drops all pending changes and rebuilds the grid from the loaded rows.
    private func clearPending(keepUndo: Bool = false) {
        if !keepUndo { undoManager?.removeAllActions(withTarget: self) }
        edits = [:]
        insertedRows = []
        deletedRows = []
        commitError = nil
        rebuildGrid()
    }

    private func didChangePending(from before: PendingState, actionName: String) {
        guard before != pendingState else { return }
        rebuildGrid()
        registerUndo(restoring: before, actionName: actionName)
    }

    private func registerUndo(restoring state: PendingState, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            guard !model.isCommitting else { return }
            let current = model.pendingState
            model.pendingState = state
            model.selectedRows = model.selectedRows.filteredIndexSet { $0 < model.rows.count + model.insertedRows.count }
            model.rebuildGrid()
            model.registerUndo(restoring: current, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func rebuildGrid() {
        var display = rows
        var cells = Set<GridCell>()
        var states: [Int: GridRowState] = [:]
        for (cell, value) in edits where cell.row < display.count && cell.column < display[cell.row].count {
            display[cell.row][cell.column] = value
            cells.insert(cell)
        }
        for row in deletedRows where row < rows.count { states[row] = .deleted }
        for (offset, inserted) in insertedRows.enumerated() {
            let row = rows.count + offset
            display.append(inserted.values)
            states[row] = .inserted
            for column in inserted.setColumns { cells.insert(GridCell(row: row, column: column)) }
        }
        gridRows = display
        editedCells = cells
        rowStates = states
    }
}
