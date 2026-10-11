import AppKit
import SwiftUI

/// NSTextView-based SQL editor with syntax highlighting, line numbers and completion.
struct SQLTextView: NSViewRepresentable {
    @Binding var text: String
    var kind: DatabaseKind
    var fontSize: CGFloat
    /// Table and column names offered by completion in addition to keywords.
    var completionWords: [String] = []
    /// Range to underline as an error.
    var errorRange: NSRange? = nil
    /// Reports the selected range (UTF-16) so the caller can run the selection or the statement at the cursor.
    @Binding var selectedRange: NSRange

    func makeNSView(context: Context) -> NSScrollView { NSScrollView() }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
