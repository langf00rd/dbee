import SwiftUI

struct QueryEditorView: View {
    @Bindable var session: DatabaseSession
    @Bindable var tab: QueryTab
    var body: some View { Text("Query") }
}
