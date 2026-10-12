import SwiftUI

/// Columns, indexes, foreign keys and DDL of one table.
struct StructureView: View {
    let session: DatabaseSession
    let table: TableRef

    @State private var structure: TableStructure?
    @State private var loadedTable: TableRef?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var section: Section = .columns

    enum Section: String, CaseIterable, Identifiable {
        case columns, indexes, foreignKeys, ddl

        var id: String { rawValue }
        var title: String {
            switch self {
            case .columns: "Columns"
            case .indexes: "Indexes"
            case .foreignKeys: "Foreign Keys"
            case .ddl: "DDL"
            }
        }

        /// Sections the engine has: MongoDB has no foreign keys and shows createCollection instead of DDL;
        /// Redis keys only have their fixed columns.
        static func available(for kind: DatabaseKind) -> [Section] {
            switch kind {
            case .redis: [.columns]
            case .mongodb: [.columns, .indexes, .ddl]
            case .postgres, .mysql, .sqlite: allCases
            }
        }

        func title(for kind: DatabaseKind) -> String {
            self == .ddl && kind == .mongodb ? "Definition" : title
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: table) { await load(force: false) }
    }

    private var header: some View {
        HStack {
            Spacer()
            Picker("Section", selection: $section) {
                ForEach(Section.available(for: session.kind)) { section in
                    Text(section.title(for: session.kind)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 4) {
                if section == .ddl, let ddl = structure?.ddl {
                    Button {
                        TableBrowserPasteboard.copy(ddl)
                    } label: {
                        Label("Copy \(section.title(for: session.kind))", systemImage: "doc.on.doc")
                    }
                    .help("Copy \(section.title(for: session.kind))")
                }
                Button {
                    Task { await load(force: true) }
                } label: {
                    Label("Refresh Structure", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Reload the structure")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if let structure, loadedTable == table {
            switch section {
            case .columns:
                StructureColumnsTable(structure: structure)
            case .indexes:
                if structure.indexes.isEmpty {
                    ContentUnavailableView("No Indexes", systemImage: "list.bullet.rectangle", description: Text("\(table.name) has no indexes."))
                } else {
                    StructureIndexesTable(indexes: structure.indexes)
                }
            case .foreignKeys:
                if structure.foreignKeys.isEmpty {
                    ContentUnavailableView("No Foreign Keys", systemImage: "link", description: Text("\(table.name) doesn't reference other tables."))
                } else {
                    StructureForeignKeysTable(foreignKeys: structure.foreignKeys)
                }
            case .ddl:
                if let ddl = structure.ddl, !ddl.isEmpty {
                    TableBrowserCodeView(text: ddl)
                        .accessibilityLabel("DDL for \(table.name)")
                } else {
                    ContentUnavailableView("No DDL Available", systemImage: "doc.plaintext", description: Text("The server didn't provide a CREATE statement for \(table.name)."))
                }
            }
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Structure", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
                    .textSelection(.enabled)
            } actions: {
                Button("Retry") { Task { await load(force: true) } }
            }
        } else {
            ProgressView()
                .accessibilityLabel("Loading structure")
        }
    }

    /// Reuses the structure the table browser already loaded unless `force` is set.
    private func load(force: Bool) async {
        let target = table
        if loadedTable != target {
            structure = nil
            errorMessage = nil
        }
        if !force, let cached = session.browserModels[target]?.structure {
            structure = cached
            loadedTable = target
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await session.structure(of: target)
            guard target == table else { return }
            structure = loaded
            loadedTable = target
            errorMessage = nil
        } catch {
            guard target == table else { return }
            errorMessage = DatabaseSession.describe(error)
            if force { structure = nil }
        }
    }
}

// MARK: - Columns

private struct StructureColumnRow: Identifiable {
    var ordinal: Int
    var info: ColumnInfo

    var id: String { info.name }
    var name: String { info.name }
    var dataType: String { info.dataType }
    var nullableSortKey: Int { info.isNullable ? 1 : 0 }
    var defaultText: String { info.defaultValue ?? "" }
    var commentText: String { info.comment ?? "" }
}

private struct StructureColumnsTable: View {
    let structure: TableStructure
    /// Empty means the table's own column order, shown without a sort indicator.
    @State private var sortOrder: [KeyPathComparator<StructureColumnRow>] = []
    @State private var selection = Set<StructureColumnRow.ID>()

    private var rows: [StructureColumnRow] {
        let rows = structure.columns.enumerated()
            .map { StructureColumnRow(ordinal: $0.offset + 1, info: $0.element) }
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.ordinal) { row in
                Text(row.ordinal, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 28, ideal: 36, max: 48)

            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 4) {
                    Text(row.name)
                    if row.info.isPrimaryKey {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                            .help("Primary key")
                            .accessibilityLabel("Primary key")
                    }
                }
            }
            .width(min: 100, ideal: 180)

            TableColumn("Type", value: \.dataType) { row in
                Text(row.dataType)
                    .monospaced()
            }
            .width(min: 80, ideal: 140)

            TableColumn("Nullable", value: \.nullableSortKey) { row in
                StructureCheckmark(isOn: row.info.isNullable, label: "Nullable")
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Default", value: \.defaultText) { row in
                if let value = row.info.defaultValue {
                    Text(value)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .help(value)
                }
            }
            .width(min: 60, ideal: 140)

            TableColumn("Comment", value: \.commentText) { row in
                Text(row.commentText)
                    .foregroundStyle(.secondary)
                    .help(row.commentText)
            }
        }
        // Full-width rows with column lines, matching the Data tab's grid.
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: StructureColumnRow.ID.self) { names in
            if !names.isEmpty {
                Button(names.count == 1 ? "Copy Name" : "Copy Names") {
                    TableBrowserPasteboard.copy(ordered(names).joined(separator: ", "))
                }
            }
        }
    }

    /// Selected names in the table's column order.
    private func ordered(_ names: Set<String>) -> [String] {
        structure.columns.map(\.name).filter(names.contains)
    }
}

// MARK: - Indexes

private struct StructureIndexRow: Identifiable {
    var info: IndexInfo

    var id: String { info.name }
    var name: String { info.name }
    var columnsText: String { info.columns.joined(separator: ", ") }
    var uniqueSortKey: Int { info.isUnique ? 1 : 0 }
    var primarySortKey: Int { info.isPrimary ? 1 : 0 }
    var definitionText: String { info.definition ?? "" }
}

private struct StructureIndexesTable: View {
    let indexes: [IndexInfo]
    @State private var sortOrder: [KeyPathComparator<StructureIndexRow>] = []
    @State private var selection = Set<StructureIndexRow.ID>()

    private var rows: [StructureIndexRow] {
        let rows = indexes.map(StructureIndexRow.init(info:))
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Text(row.name)
            }
            .width(min: 100, ideal: 200)

            TableColumn("Columns", value: \.columnsText) { row in
                Text(row.columnsText)
                    .monospaced()
            }
            .width(min: 80, ideal: 180)

            TableColumn("Unique", value: \.uniqueSortKey) { row in
                StructureCheckmark(isOn: row.info.isUnique, label: "Unique")
            }
            .width(min: 44, ideal: 56, max: 72)

            TableColumn("Primary", value: \.primarySortKey) { row in
                StructureCheckmark(isOn: row.info.isPrimary, label: "Primary")
            }
            .width(min: 44, ideal: 56, max: 72)

            TableColumn("Definition", value: \.definitionText) { row in
                Text(row.definitionText)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .help(row.definitionText)
            }
        }
        // Full-width rows with column lines, matching the Data tab's grid.
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: StructureIndexRow.ID.self) { names in
            if !names.isEmpty {
                Button(names.count == 1 ? "Copy Name" : "Copy Names") {
                    TableBrowserPasteboard.copy(indexes.map(\.name).filter(names.contains).joined(separator: ", "))
                }
                if names.count == 1, let definition = indexes.first(where: { names.contains($0.name) })?.definition {
                    Button("Copy Definition") { TableBrowserPasteboard.copy(definition) }
                }
            }
        }
    }
}

// MARK: - Foreign keys

private struct StructureForeignKeyRow: Identifiable {
    var info: ForeignKeyInfo

    var id: String { info.name }
    var name: String { info.name }
    var columnsText: String { info.columns.joined(separator: ", ") }
    var referenceText: String {
        "\(info.referencedTable.id) (\(info.referencedColumns.joined(separator: ", ")))"
    }
    var onUpdateText: String { info.onUpdate ?? "" }
    var onDeleteText: String { info.onDelete ?? "" }
}

private struct StructureForeignKeysTable: View {
    let foreignKeys: [ForeignKeyInfo]
    @State private var sortOrder: [KeyPathComparator<StructureForeignKeyRow>] = []
    @State private var selection = Set<StructureForeignKeyRow.ID>()

    private var rows: [StructureForeignKeyRow] {
        let rows = foreignKeys.map(StructureForeignKeyRow.init(info:))
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Text(row.name)
            }
            .width(min: 100, ideal: 200)

            TableColumn("Columns", value: \.columnsText) { row in
                Text(row.columnsText)
                    .monospaced()
            }
            .width(min: 80, ideal: 140)

            TableColumn("References", value: \.referenceText) { row in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(row.referenceText)
                        .monospaced()
                }
                .help(row.referenceText)
            }
            .width(min: 120, ideal: 240)

            TableColumn("On Update", value: \.onUpdateText) { row in
                Text(row.onUpdateText)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)

            TableColumn("On Delete", value: \.onDeleteText) { row in
                Text(row.onDeleteText)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        }
        // Full-width rows with column lines, matching the Data tab's grid.
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: StructureForeignKeyRow.ID.self) { names in
            if !names.isEmpty {
                Button(names.count == 1 ? "Copy Name" : "Copy Names") {
                    TableBrowserPasteboard.copy(foreignKeys.map(\.name).filter(names.contains).joined(separator: ", "))
                }
            }
        }
    }
}

// MARK: - Shared

/// A checkmark for true and nothing for false, with a spoken value either way.
private struct StructureCheckmark: View {
    var isOn: Bool
    var label: String

    var body: some View {
        Image(systemName: "checkmark")
            .opacity(isOn ? 1 : 0)
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "Yes" : "No")
    }
}
