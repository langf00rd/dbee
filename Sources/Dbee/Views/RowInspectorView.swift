import SwiftUI

/// Inspector pane showing every column of one row, with the focused column's full value
/// (multi-line, monospaced, pretty-printed when it is JSON). Editable when `onEdit` is non-nil.
struct RowInspectorView: View {
    var columns: [String]
    /// nil when no row is selected.
    var row: [CellValue]?
    var focusedColumn: Int?
    var onEdit: ((Int, CellValue) -> Void)? = nil

    var body: some View { Text("Inspector") }
}
