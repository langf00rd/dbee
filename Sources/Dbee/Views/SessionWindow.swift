import AppKit
import SwiftUI

/// Root of every window: shows the connect screen until a session is connected, then the workspace.
///
/// The workspace stays up for as long as the session holds a configuration, so reconnecting or
/// switching a Postgres database (which reconnects) doesn't flash back to the connect screen, and a
/// failed reconnect is reported in the workspace.
struct SessionWindow: View {
    @State private var session = DatabaseSession()
    @State private var windowState = SessionWindowState()

    var body: some View {
        // Captured by value: closures that outlive the view must not read @State.
        let session = session
        let state = windowState
        Group {
            if session.config != nil {
                WorkspaceView(session: session)
                    .frame(minWidth: 760, minHeight: 460)
            } else {
                ConnectView(session: session)
                    .frame(minWidth: 520, minHeight: 440)
            }
        }
        .environment(windowState)
        .focusedSceneValue(\.session, session)
        .focusedSceneValue(\.sessionWindowState, windowState)
        .background(SessionWindowBridge(session: session, showsWorkspace: session.config != nil))
        .background {
            WindowLifecycleObserver {
                // Closing a window drops its connection and wipes its secrets right away.
                Task { await session.disconnect() }
            }
        }
        .onAppear {
            SessionRegistry.shared.register(session)
            #if DEBUG
            DebugLaunch.apply(to: session)
            #endif
        }
        .confirmationDialog(
            "Disconnect and discard uncommitted changes?",
            isPresented: $windowState.isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Discard Changes and Disconnect", role: .destructive) {
                Task { await session.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some tables have edits that haven’t been saved to the database.")
        }
        .confirmationDialog(
            "Switch to \(state.pendingDatabaseSwitch ?? "") and discard unsaved table edits?",
            isPresented: Binding(
                get: { state.pendingDatabaseSwitch != nil },
                set: { if !$0 { state.pendingDatabaseSwitch = nil } }
            ),
            titleVisibility: .visible,
            presenting: state.pendingDatabaseSwitch
        ) { name in
            Button("Discard Edits and Switch", role: .destructive) {
                state.pendingDatabaseSwitch = nil
                Task { await session.switchDatabase(name) }
            }
            Button("Cancel", role: .cancel) { state.pendingDatabaseSwitch = nil }
        } message: { _ in
            Text("Some tables have edits that haven’t been saved to the database.")
        }
    }
}

/// Per-window UI state shared by the window root, the workspace toolbar and the menu commands.
@MainActor @Observable
final class SessionWindowState {
    var isConfirmingDisconnect = false

    /// The database the user picked while tables had uncommitted edits, waiting for confirmation.
    var pendingDatabaseSwitch: String?

    /// Switches right away, or asks first when tables have uncommitted edits (switching drops them).
    func requestSwitchDatabase(_ name: String, session: DatabaseSession) {
        if session.hasUncommittedTableChanges {
            pendingDatabaseSwitch = name
        } else {
            Task { await session.switchDatabase(name) }
        }
    }

    /// Disconnects right away, or asks first when tables have uncommitted edits.
    func requestDisconnect(_ session: DatabaseSession) {
        if session.hasUncommittedTableChanges {
            isConfirmingDisconnect = true
        } else {
            Task { await session.disconnect() }
        }
    }
}

/// Hooks the hosting `NSWindow`: makes it non-restorable and reports when it closes.
///
/// Window close is observed directly rather than through `onDisappear`, which is not a reliable
/// signal for a window that is merely hidden behind another tab or minimized.
private struct WindowLifecycleObserver: NSViewRepresentable {
    var onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onClose: (@MainActor () -> Void)?
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            guard let window else { return }
            window.isRestorable = false
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
        }
    }
}
