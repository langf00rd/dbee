import AppKit
import Foundation
import Observation

/// A foreign key drawn in the relationship diagram, between two tables that are both on it.
struct DiagramRelation: Identifiable, Hashable {
    /// The referencing table's id and the constraint name.
    var id: String
    var name: String
    /// The referencing table (the "many" side).
    var child: String
    /// The referenced table (the "one" side).
    var parent: String
    var columns: [String]
    var referencedColumns: [String]
    /// A referencing column allows NULL, so a row may have no parent.
    var isOptional: Bool
    /// The foreign key columns are the referencing table's whole primary key, so each parent has at most one child.
    var isOneToOne: Bool
}

/// State for the relationship diagram of one schema: its tables, the foreign keys between them, and
/// where each table sits. Kept by the session so a rearranged layout survives switching away and back.
@MainActor @Observable
final class RelationshipDiagramModel {
    /// Weak, like `TableBrowserModel.owner`: a load can outlive the window's session.
    @ObservationIgnored private weak var owner: DatabaseSession?
    let schema: String

    private(set) var tables: [DiagramTable] = []
    private(set) var relations: [DiagramRelation] = []
    /// Foreign keys pointing at tables in other schemas, which aren't drawn.
    private(set) var externalReferenceCount = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var needsReload = false
    /// Per table: the columns shown and the size of its box. Rebuilt when the tables or `keysOnly` change.
    @ObservationIgnored private var shownColumns: [String: [ColumnInfo]] = [:]
    @ObservationIgnored private var sizes: [String: CGSize] = [:]

    /// Top-left corner of each table, by `DiagramTable.id`.
    var positions: [String: CGPoint] = [:]
    /// Shows only primary key and foreign key columns.
    var keysOnly = false {
        didSet {
            guard keysOnly != oldValue else { return }
            rebuildGeometry()
            arrange()
        }
    }
    var zoom: CGFloat = 1
    /// The table whose relations are highlighted.
    var selectedTable: String?

    init(session: DatabaseSession, schema: String) {
        owner = session
        self.schema = schema
    }

    func markStale() {
        needsReload = true
    }

    /// Loads the schema the first time, or again after `markStale`.
    func loadIfNeeded() async {
        guard !hasLoaded || needsReload else { return }
        await load()
    }

    func load() async {
        guard !isLoading, let session = owner else { return }
        guard let info = session.schemas.first(where: { $0.name == schema }) else {
            errorMessage = "The schema “\(schema)” no longer exists."
            return
        }
        isLoading = true
        needsReload = false
        defer { isLoading = false }
        do {
            let loaded = try await session.diagramTables(in: info)
            apply(loaded)
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
            needsReload = true
        } catch {
            errorMessage = DatabaseSession.describe(error)
        }
    }

    /// Replaces the tables. Positions are kept when the same tables come back, so a refresh doesn't undo
    /// the user's arrangement; otherwise everything is laid out again.
    func apply(_ loaded: [DiagramTable]) {
        let sameTables = Set(loaded.map(\.id)) == Set(tables.map(\.id))
        tables = loaded.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
        (relations, externalReferenceCount) = Self.relations(of: tables)
        rebuildGeometry()
        if let selectedTable, !tables.contains(where: { $0.id == selectedTable }) {
            self.selectedTable = nil
        }
        if !sameTables || positions.isEmpty {
            arrange()
        }
    }

    // MARK: Relations

    static func relations(of tables: [DiagramTable]) -> (relations: [DiagramRelation], external: Int) {
        var byID: [String: DiagramTable] = [:]
        var byFoldedName: [String: DiagramTable] = [:]
        for table in tables {
            byID[table.id] = table
            byFoldedName[folded(table.ref)] = byFoldedName[folded(table.ref)] ?? table
        }
        var relations: [DiagramRelation] = []
        var external = 0
        for table in tables {
            let nullable = Set(table.columns.filter(\.isNullable).map(\.name))
            let primaryKey = Set(table.columns.filter(\.isPrimaryKey).map(\.name))
            for key in table.foreignKeys {
                // SQLite matches table names without regard to case, so `REFERENCES Users` names `users`.
                guard let parent = byID[key.referencedTable.id] ?? byFoldedName[folded(key.referencedTable)] else {
                    external += 1
                    continue
                }
                relations.append(DiagramRelation(
                    id: table.id + "\u{1F}" + key.name,
                    name: key.name,
                    child: table.id,
                    parent: parent.id,
                    columns: key.columns,
                    referencedColumns: key.referencedColumns,
                    isOptional: key.columns.contains(where: nullable.contains),
                    isOneToOne: !primaryKey.isEmpty && Set(key.columns) == primaryKey
                ))
            }
        }
        return (relations, external)
    }

    private static func folded(_ ref: TableRef) -> String {
        ((ref.schema.map { $0 + "." } ?? "") + ref.name).lowercased()
    }

    /// Columns shown for `table`: all of them, or with `keysOnly` the primary key and the columns of
    /// foreign keys on either end.
    func visibleColumns(of table: DiagramTable) -> [ColumnInfo] {
        shownColumns[table.id] ?? table.columns
    }

    /// Names of `table`'s columns that are part of a foreign key it holds.
    func foreignKeyColumns(of table: DiagramTable) -> Set<String> {
        Set(table.foreignKeys.flatMap(\.columns))
    }

    /// Tables linked to the selected one, including itself.
    var highlightedTables: Set<String> {
        guard let selectedTable else { return [] }
        var linked: Set<String> = [selectedTable]
        for relation in relations where relation.child == selectedTable || relation.parent == selectedTable {
            linked.insert(relation.child)
            linked.insert(relation.parent)
        }
        return linked
    }

    // MARK: Geometry

    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 20
    static let bottomPadding: CGFloat = 4
    static let minWidth: CGFloat = 170
    static let maxWidth: CGFloat = 340

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let columnFont = NSFont.systemFont(ofSize: 11)

    func size(of table: DiagramTable) -> CGSize {
        sizes[table.id] ?? Self.boxSize(table, columns: visibleColumns(of: table))
    }

    private func rebuildGeometry() {
        var keys: [String: Set<String>] = [:]
        if keysOnly {
            for relation in relations {
                keys[relation.child, default: []].formUnion(relation.columns)
                keys[relation.parent, default: []].formUnion(relation.referencedColumns)
            }
        }
        shownColumns = [:]
        sizes = [:]
        for table in tables {
            let shown = keysOnly
                ? table.columns.filter { $0.isPrimaryKey || keys[table.id, default: []].contains($0.name) }
                : table.columns
            shownColumns[table.id] = shown
            sizes[table.id] = Self.boxSize(table, columns: shown)
        }
    }

    /// Size of a table's box, wide enough for its name and its widest column (within limits).
    private static func boxSize(_ table: DiagramTable, columns: [ColumnInfo]) -> CGSize {
        let title = Self.textWidth(table.ref.name, font: Self.titleFont) + 40
        let widestColumn = columns.map {
            Self.textWidth($0.name, font: Self.columnFont) + Self.textWidth($0.dataType, font: Self.columnFont) + 52
        }.max() ?? 0
        let width = min(max(title, widestColumn, Self.minWidth), Self.maxWidth).rounded(.up)
        let rows = max(columns.count, 1)
        return CGSize(width: width, height: Self.headerHeight + CGFloat(rows) * Self.rowHeight + Self.bottomPadding)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    func frame(of table: DiagramTable) -> CGRect {
        CGRect(origin: positions[table.id] ?? .zero, size: size(of: table))
    }

    /// The vertical centre of `column`'s row in `table`'s box, or of its header when the column isn't shown.
    func rowMidY(of column: String?, in table: DiagramTable, frame: CGRect) -> CGFloat {
        if let column, let index = visibleColumns(of: table).firstIndex(where: { $0.name == column }) {
            return frame.minY + Self.headerHeight + (CGFloat(index) + 0.5) * Self.rowHeight
        }
        return frame.minY + Self.headerHeight / 2
    }

    /// Size of the whole drawing, with room around the outermost tables.
    var canvasSize: CGSize {
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for table in tables {
            let frame = frame(of: table)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }
        return CGSize(width: maxX + DiagramLayout.margin, height: maxY + DiagramLayout.margin)
    }

    /// Lays every table out again, discarding the user's arrangement.
    func arrange() {
        let nodes = tables.map { DiagramLayout.Node(id: $0.id, size: size(of: $0)) }
        let edges = relations.map { DiagramLayout.Edge(from: $0.child, to: $0.parent) }
        positions = DiagramLayout.positions(nodes: nodes, edges: edges)
    }

    /// Moves `table` so its top-left corner is at `origin`, never past the top or left margin.
    func move(_ table: String, to origin: CGPoint) {
        positions[table] = CGPoint(x: max(origin.x, 8).rounded(), y: max(origin.y, 8).rounded())
    }
}
