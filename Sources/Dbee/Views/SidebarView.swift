import AppKit
import SwiftUI

/// Source-list sidebar: the window's query tabs, then the tables and views of each schema,
/// with a filter field and a compact connection footer.
struct SidebarView: View {
    @Bindable var session: DatabaseSession

    @State private var filter = ""
    /// All sections, sorted. Rebuilt only when the schema changes, so large databases stay smooth.
    @State private var sortedSections: [SidebarSchemaSection] = []
    /// `sortedSections` after applying the filter.
    @State private var visibleSections: [SidebarSchemaSection] = []
    @State private var collapsedSections: Set<String> = []
    @State private var renamingTabID: UUID?
    @State private var isHoveringQueriesHeader = false
    @State private var pendingAction: SidebarTableAction?
    @State private var actionError: SidebarActionError?

    var body: some View {
        List(selection: $session.selection) {
            queriesSection
            schemaStatus
            ForEach(visibleSections) { section in
                Section(isExpanded: expansion(for: section.id)) {
                    if section.tables.isEmpty {
                        SidebarPlaceholderRow(text: "No Tables")
                    }
                    ForEach(section.tables) { table in
                        SidebarTableRow(table: table)
                            .tag(SidebarSelection.table(table.ref))
                            .contextMenu { tableMenu(table) }
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarConnectionFooter(session: session)
        }
        .toolbar {
            ToolbarItem {
                Button(action: newQuery) {
                    Label("New Query", systemImage: "square.and.pencil")
                }
                .help("New Query (⌘T)")
            }
        }
        .onChange(of: session.schemas, initial: true) { rebuildSections() }
        .onChange(of: filter) { applyFilter() }
        .confirmationDialog(
            pendingAction?.confirmationTitle ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.confirmButtonTitle, role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.confirmationMessage)
        }
        .alert(
            actionError?.title ?? "",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: Queries

    private var queriesSection: some View {
        Section {
            ForEach(session.queryTabs) { tab in
                SidebarQueryRow(tab: tab, renamingTabID: $renamingTabID)
                    .tag(SidebarSelection.query(tab.id))
                    .contextMenu { queryMenu(tab) }
            }
        } header: {
            // The toolbar's compose button is the visible New Query control; this one appears on hover,
            // like section accessories in Finder, and stays reachable for VoiceOver.
            HStack {
                Text("Queries")
                Spacer()
                Button(action: newQuery) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Query (⌘T)")
                .accessibilityLabel("New Query")
                .opacity(isHoveringQueriesHeader ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { isHoveringQueriesHeader = $0 }
        }
    }

    @ViewBuilder private func queryMenu(_ tab: QueryTab) -> some View {
        Button("Rename") {
            session.selection = .query(tab.id)
            renamingTabID = tab.id
        }
        Button("Duplicate") {
            let copy = session.newQueryTab(sql: tab.sql)
            copy.title = tab.title + " copy"
        }
        Divider()
        Button("Close Query") { session.closeQueryTab(tab.id) }
    }

    private func newQuery() {
        session.newQueryTab()
    }

    // MARK: Schema

    @ViewBuilder private var schemaStatus: some View {
        if let error = session.schemaError {
            SidebarSchemaErrorRow(message: error) {
                Task { await session.refreshSchema() }
            }
        } else if session.schemas.isEmpty {
            if session.isLoadingSchema {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Tables…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if session.isConnected {
                SidebarPlaceholderRow(text: "No Tables")
            }
        } else if !trimmedFilter.isEmpty, visibleSections.isEmpty {
            SidebarPlaceholderRow(text: "No Matching Tables")
        }
    }

    private var trimmedFilter: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { !trimmedFilter.isEmpty || !collapsedSections.contains(id) },
            set: { expanded in
                if expanded {
                    collapsedSections.remove(id)
                } else {
                    collapsedSections.insert(id)
                }
            }
        )
    }

    private func rebuildSections() {
        let fileName = session.kind == .sqlite
            ? session.config.map { URL(fileURLWithPath: $0.filePath).lastPathComponent }
            : nil
        sortedSections = SidebarSchemaSection.sorted(session.schemas, singleSectionTitle: fileName)
        applyFilter()
    }

    private func applyFilter() {
        visibleSections = SidebarSchemaSection.filtered(sortedSections, by: trimmedFilter)
    }

    // MARK: Table actions

    @ViewBuilder private func tableMenu(_ table: TableInfo) -> some View {
        Button("Open") { session.selection = .table(table.ref) }
        Button("Open in New Query") {
            session.newQueryTab(sql: "SELECT * FROM \(session.dialect.qualifiedName(table.ref)) LIMIT 100;")
        }
        Divider()
        Button("Copy Name") { copyToPasteboard(table.ref.name) }
        Button("Copy Qualified Name") { copyToPasteboard(session.dialect.qualifiedName(table.ref)) }
        Divider()
        if table.kind == .table {
            Button(session.settings.confirmDestructiveActions ? "Truncate Table…" : "Truncate Table", role: .destructive) {
                request(.truncate(table))
            }
            .disabled(!session.isConnected)
        }
        Button(SidebarTableAction.drop(table).menuTitle, role: .destructive) {
            request(.drop(table))
        }
        .disabled(!session.isConnected)
    }

    /// Truncate honours the "confirm destructive actions" setting; dropping is always confirmed.
    private func request(_ action: SidebarTableAction) {
        if case .truncate = action, !session.settings.confirmDestructiveActions {
            perform(action)
        } else {
            pendingAction = action
        }
    }

    private func perform(_ action: SidebarTableAction) {
        let session = session
        Task {
            do {
                _ = try await session.execute(action.sql(session.dialect))
                let ref = action.table.ref
                switch action {
                case .truncate:
                    if let model = session.browserModels[ref], !model.isLoading {
                        await model.reload()
                    }
                case .drop:
                    if session.selection == .table(ref) { session.selection = nil }
                    session.browserModels[ref] = nil
                }
                await session.refreshSchema()
            } catch {
                actionError = SidebarActionError(title: action.failureTitle, message: DatabaseSession.describe(error))
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

// MARK: - Sections

/// One schema's worth of sidebar rows, sorted and optionally filtered.
struct SidebarSchemaSection: Identifiable, Equatable {
    var id: String
    var title: String
    var tables: [TableInfo]

    /// Sorts schemas and their tables in Finder order (case-insensitive, numbers compared numerically).
    /// `singleSectionTitle` replaces the title when there is exactly one section (SQLite's "main").
    static func sorted(_ schemas: [SchemaInfo], singleSectionTitle: String? = nil) -> [SidebarSchemaSection] {
        let sections = schemas
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { schema in
                SidebarSchemaSection(
                    id: schema.name,
                    title: schema.name,
                    tables: schema.tables.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
                )
            }
        if sections.count == 1, var only = sections.first, let singleSectionTitle, !singleSectionTitle.isEmpty {
            only.title = singleSectionTitle
            return [only]
        }
        return sections
    }

    /// Keeps tables whose name contains `filter` (case- and diacritic-insensitive) and drops
    /// sections left empty. An empty filter returns `sections` unchanged.
    static func filtered(_ sections: [SidebarSchemaSection], by filter: String) -> [SidebarSchemaSection] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let tables = section.tables.filter {
                $0.ref.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard !tables.isEmpty else { return nil }
            var copy = section
            copy.tables = tables
            return copy
        }
    }
}

// MARK: - Destructive actions

/// A destructive sidebar action waiting for confirmation.
enum SidebarTableAction: Identifiable {
    case truncate(TableInfo)
    case drop(TableInfo)

    var id: String {
        switch self {
        case .truncate(let table): "truncate:" + table.id
        case .drop(let table): "drop:" + table.id
        }
    }

    var table: TableInfo {
        switch self {
        case .truncate(let table), .drop(let table): table
        }
    }

    func sql(_ dialect: SQLDialect) -> String {
        switch self {
        case .truncate(let table): dialect.truncate(table.ref)
        case .drop(let table): dialect.drop(table.ref, kind: table.kind)
        }
    }

    private var noun: String {
        switch table.kind {
        case .table: "table"
        case .view: "view"
        case .materializedView: "materialized view"
        }
    }

    var menuTitle: String {
        table.kind == .table ? "Drop Table…" : "Drop View…"
    }

    var confirmationTitle: String {
        switch self {
        case .truncate(let table): "Truncate table “\(table.ref.name)”?"
        case .drop(let table): "Drop \(noun) “\(table.ref.name)”?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .truncate(let table):
            return "Every row in “\(table.ref.id)” will be permanently deleted. This can’t be undone."
        case .drop(let table):
            switch table.kind {
            case .table:
                return "“\(table.ref.id)” and all of its data will be permanently deleted. This can’t be undone."
            case .view:
                return "The view “\(table.ref.id)” will be deleted. The data it reads from isn’t affected."
            case .materializedView:
                return "The materialized view “\(table.ref.id)” and its stored rows will be deleted. This can’t be undone."
            }
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .truncate: "Truncate"
        case .drop: table.kind == .table ? "Drop Table" : "Drop View"
        }
    }

    var failureTitle: String {
        switch self {
        case .truncate(let table): "Couldn’t Truncate “\(table.ref.name)”"
        case .drop(let table): "Couldn’t Drop “\(table.ref.name)”"
        }
    }
}

struct SidebarActionError: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

// MARK: - Rows

private struct SidebarQueryRow: View {
    let tab: QueryTab
    @Binding var renamingTabID: UUID?

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Label {
            HStack(spacing: 4) {
                if renamingTabID == tab.id {
                    TextField("Query Name", text: $draft)
                        .focused($isFieldFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { renamingTabID = nil }
                        .onChange(of: isFieldFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                        .task {
                            draft = tab.title
                            isFieldFocused = true
                        }
                } else {
                    Text(tab.title)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if tab.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Running")
                }
            }
        } icon: {
            Image(systemName: "doc.text")
        }
    }

    private func commitRename() {
        guard renamingTabID == tab.id else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { tab.title = name }
        renamingTabID = nil
    }
}

private struct SidebarTableRow: View {
    let table: TableInfo

    var body: some View {
        Label {
            Text(table.ref.name)
                .lineLimit(1)
        } icon: {
            // Every kind takes the sidebar's accent tint; the glyph alone tells views from tables.
            Image(systemName: table.kind.symbolName)
        }
        .accessibilityValue(kindDescription)
    }

    private var kindDescription: String {
        switch table.kind {
        case .table: "Table"
        case .view: "View"
        case .materializedView: "Materialized view"
        }
    }
}

private struct SidebarPlaceholderRow: View {
    var text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .selectionDisabled()
    }
}

private struct SidebarSchemaErrorRow: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn’t Load Tables", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.primary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            Button("Retry", action: retry)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }
}

// MARK: - Footer

/// Where the window is connected, without any credential: kind, host or file name, and transport security.
struct ConnectionSummary: Equatable {
    enum Security: Equatable {
        case sshTunnel
        case tlsVerified
        case tlsUnverified

        var symbolName: String {
            self == .tlsUnverified ? "lock" : "lock.fill"
        }

        var description: String {
            switch self {
            case .sshTunnel: "Encrypted through an SSH tunnel"
            case .tlsVerified: "Encrypted with TLS, certificate verified"
            case .tlsUnverified: "Encrypted with TLS, certificate not verified"
            }
        }
    }

    var symbolName: String
    /// Short label: server host (the SSH host when the database listens on the tunnel's loopback) or file name.
    var location: String
    /// Longer description for the tooltip.
    var detail: String
    var security: Security?

    init(config: ConnectionConfig) {
        let kind = config.kind
        symbolName = kind.symbolName
        guard kind.isNetworked else {
            location = URL(fileURLWithPath: config.filePath).lastPathComponent
            detail = "SQLite database at \(config.filePath)"
            security = nil
            return
        }
        let host = config.host.trimmingCharacters(in: .whitespaces)
        let server = Self.endpoint(host.isEmpty ? "127.0.0.1" : host, port: config.port, defaultPort: kind.defaultPort)
        if config.ssh.enabled {
            let sshHost = config.ssh.host.trimmingCharacters(in: .whitespaces)
            location = Self.isLoopback(host) ? sshHost : server
            detail = "\(kind.displayName) at \(server) through an SSH tunnel to \(Self.endpoint(sshHost, port: config.ssh.port, defaultPort: 22))"
            security = .sshTunnel
        } else {
            location = server
            detail = "\(kind.displayName) at \(server)"
            switch config.tls {
            case .verifyFull: security = .tlsVerified
            case .required: security = .tlsUnverified
            case .preferred, .disabled: security = nil
            }
        }
    }

    var accessibilityLabel: String {
        [detail, security?.description].compactMap { $0 }.joined(separator: ", ")
    }

    private static func endpoint(_ host: String, port: Int, defaultPort: Int) -> String {
        let displayHost = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? host : "\(displayHost):\(port)"
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["", "localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }
}

private struct SidebarConnectionFooter: View {
    let session: DatabaseSession

    var body: some View {
        if let summary = session.config.map(ConnectionSummary.init(config:)) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: summary.symbolName)
                        .accessibilityHidden(true)
                    Text(summary.location)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if session.isLoadingSchema, !session.schemas.isEmpty {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Refreshing tables")
                    }
                    if let security = summary.security {
                        Image(systemName: security.symbolName)
                            .help(security.description)
                            .accessibilityHidden(true)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .help(summary.detail)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summary.accessibilityLabel)
        }
    }
}
