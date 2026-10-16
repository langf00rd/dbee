import SwiftUI

/// NavigationSplitView: SidebarView | detail (TableBrowserView or QueryEditorView).
///
/// Also shows the connection state of the window: a banner when the connection drops, a small
/// progress overlay while reconnecting or switching databases, and the error when a reconnect fails.
struct WorkspaceView: View {
    @Bindable var session: DatabaseSession

    @Environment(SessionWindowState.self) private var windowState: SessionWindowState?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(session: session)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        } detail: {
            detailColumn
                .navigationTitle(session.title)
                .navigationSubtitle(session.subtitle)
                .toolbar { workspaceToolbar }
        }
    }

    // MARK: Detail

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if session.connectionLost, session.isConnected {
                ConnectionLostBanner(
                    onReconnect: { session.reconnect() },
                    onDisconnect: disconnect
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(isReconnecting)
                .overlay {
                    if case .connecting(let message) = session.phase {
                        ReconnectingIndicator(message: message)
                    }
                }
        }
        .animation(.default, value: session.connectionLost)
    }

    @ViewBuilder private var detailContent: some View {
        switch session.phase {
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Reconnect", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message)
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again") { session.reconnect() }
                    .keyboardShortcut(.defaultAction)
                Button("Disconnect", action: disconnect)
            }
        case .idle:
            ContentUnavailableView {
                Label("Not Connected", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("The connection to the server was closed.")
            } actions: {
                Button("Reconnect") { session.reconnect() }
                    .keyboardShortcut(.defaultAction)
                Button("Disconnect", action: disconnect)
            }
        case .connecting, .connected:
            selectionContent
        }
    }

    @ViewBuilder private var selectionContent: some View {
        switch session.selection {
        case .table(let ref):
            TableBrowserView(model: session.browserModel(for: ref))
                .id(ref)
        case .diagram(let schema):
            RelationshipDiagramView(model: session.diagramModel(for: schema), session: session)
                .id(schema)
        case .query(let id):
            if let tab = session.queryTab(id) {
                QueryEditorView(session: session, tab: tab)
                    .id(id)
            } else {
                noSelection
            }
        case nil:
            noSelection
        }
    }

    private var noSelection: some View {
        ContentUnavailableView(
            "No Selection",
            systemImage: "tablecells",
            description: Text("Select a table or open a query.")
        )
    }

    private var isReconnecting: Bool {
        if case .connecting = session.phase { return true }
        return false
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        if showsDatabasePicker {
            ToolbarItem(placement: .navigation) {
                databasePicker
            }
        }
        ToolbarItem(placement: .navigation) {
            Button(action: disconnect) {
                Label("Disconnect", systemImage: "eject")
            }
            .help(disconnectHelp)
        }
        if session.supportsDiagram {
            ToolbarItem {
                Button {
                    session.showDiagram()
                } label: {
                    Label("Relationship Diagram", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Show Relationship Diagram (⇧⌘E)")
                .disabled(!session.isConnected || session.schemas.isEmpty)
            }
        }
    }

    private var showsDatabasePicker: Bool {
        guard !databaseChoices.isEmpty else { return false }
        return session.databases.count > 1 || session.kind != .sqlite
    }

    /// The server's databases, plus the current one if the list couldn't be read.
    private var databaseChoices: [String] {
        var names = session.databases
        if !session.currentDatabase.isEmpty, !names.contains(session.currentDatabase) {
            names.insert(session.currentDatabase, at: 0)
        }
        return names
    }

    /// A pull-down rather than a selection-bound Picker: switching reconnects, so it must only ever
    /// happen on an explicit click, never because the bound value was rewritten while items changed.
    private var databasePicker: some View {
        Menu {
            ForEach(databaseChoices, id: \.self) { name in
                Toggle(isOn: Binding(
                    get: { name == session.currentDatabase },
                    set: { isOn in
                        guard isOn, name != session.currentDatabase else { return }
                        if let windowState {
                            windowState.requestSwitchDatabase(name, session: session)
                        } else {
                            Task { await session.switchDatabase(name) }
                        }
                    }
                )) {
                    Text(name)
                }
            }
        } label: {
            Label(session.currentDatabase.isEmpty ? "Database" : session.currentDatabase, systemImage: "cylinder")
                .labelStyle(.titleOnly)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!session.isConnected)
        .help("Switch Database")
        .accessibilityLabel("Database")
        .accessibilityValue(session.currentDatabase)
    }

    private var disconnectHelp: String {
        if session.connectionLost { return "Connection lost. Disconnect from \(session.title)" }
        if session.isConnected { return "Connected to \(session.title). Disconnect (⇧⌘D)" }
        return "Disconnect (⇧⌘D)"
    }

    private func disconnect() {
        if let windowState {
            windowState.requestDisconnect(session)
        } else {
            Task { await session.disconnect() }
        }
    }
}

/// Non-modal banner shown above the detail when the connection or SSH tunnel drops.
private struct ConnectionLostBanner: View {
    var onReconnect: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Connection lost")
                    .fontWeight(.semibold)
                Text("The server or SSH tunnel closed the connection.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Disconnect", action: onDisconnect)
                Button("Reconnect", action: onReconnect)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.12))
            Divider()
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection lost")
    }
}

/// Small centered progress panel shown while the session reconnects or switches databases.
private struct ReconnectingIndicator: View {
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(minWidth: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}
