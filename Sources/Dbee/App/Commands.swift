import SwiftUI

/// Menu bar commands. They act on the key window's session through focused scene values,
/// so every window (or window tab) keeps its own connection.
struct DbeeCommands: Commands {
    @FocusedValue(\.session) private var session
    @FocusedValue(\.sessionWindowState) private var windowState

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()
        // Edit > Find, Spelling and Substitutions; the SQL editor and DDL views respond through the responder chain.
        TextEditingCommands()

        CommandGroup(after: .newItem) {
            Button("New Query") { session?.newQueryTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session?.isConnected != true)
        }

        CommandMenu("Database") {
            Button("Refresh") { refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session?.isConnected != true)
            Button("Show Relationship Diagram") { session?.showDiagram() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session?.isConnected != true || session?.supportsDiagram != true || session?.schemas.isEmpty != false)

            Divider()

            Button("Reconnect") { session?.reconnect() }
                .disabled(!canReconnect)
            Button("Disconnect") {
                guard let session else { return }
                if let windowState {
                    windowState.requestDisconnect(session)
                } else {
                    Task { await session.disconnect() }
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(session?.config == nil)
        }
    }

    private var canReconnect: Bool {
        guard let session, session.config != nil else { return false }
        switch session.phase {
        case .connected: return session.connectionLost
        case .failed, .idle: return true
        case .connecting: return false
        }
    }

    /// Reloads the table list, plus the visible table's rows when that wouldn't discard edits.
    private func refresh() {
        guard let session else { return }
        Task {
            await session.refreshSchema()
            if case .table(let ref) = session.selection,
               let model = session.browserModels[ref],
               !model.hasChanges, !model.isLoading {
                await model.reload()
            }
        }
    }
}
