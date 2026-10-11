import SwiftUI

/// Root of every window: shows the connect screen until a session is connected, then the workspace.
struct SessionWindow: View {
    @State private var session = DatabaseSession()

    var body: some View {
        Group {
            if session.isConnected {
                WorkspaceView(session: session)
            } else {
                ConnectView(session: session)
            }
        }
    }
}
