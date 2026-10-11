import SwiftUI

/// NavigationSplitView: SidebarView | detail (TableBrowserView or QueryEditorView).
struct WorkspaceView: View {
    @Bindable var session: DatabaseSession
    var body: some View { Text("Workspace") }
}
