import AppKit
import SwiftUI

/// Inspector pane showing every column of one row, with the focused column's full value
/// (multi-line, monospaced, pretty-printed when it is JSON). Editable when `onEdit` is non-nil.
///
/// Clicking a column in the list shows that column's value until the grid's focused column changes.
struct RowInspectorView: View {
    var columns: [String]
    /// nil when no row is selected.
    var row: [CellValue]?
    /// Identity of `row` (e.g. page and row index). A change discards an unsaved draft, even when the
    /// new row holds the same value, so Save can never write a draft into a different row.
    var rowID: AnyHashable? = nil
    var focusedColumn: Int?
    var onEdit: ((Int, CellValue) -> Void)? = nil

    /// Column picked in the inspector's own list; reset whenever the grid moves its focus.
    @State private var pickedColumn: Int?

    private var activeColumn: Int? {
        let candidate = pickedColumn ?? focusedColumn ?? (columns.isEmpty ? nil : 0)
        guard let candidate, columns.indices.contains(candidate) else { return nil }
        return candidate
    }

    var body: some View {
        Group {
            if let row {
                content(row)
            } else {
                ContentUnavailableView(
                    "No Row Selected",
                    systemImage: "tablecells",
                    description: Text("Select a row to inspect its values.")
                )
            }
        }
        .onChange(of: focusedColumn) {
            pickedColumn = nil
        }
    }

    private func content(_ row: [CellValue]) -> some View {
        Form {
            if let column = activeColumn {
                InspectorValueSection(
                    name: columns[column],
                    value: value(at: column, in: row),
                    onSave: onEdit.map { onEdit in { onEdit(column, $0) } }
                )
                .id(ValueSectionID(row: rowID, column: column))
            }
            Section("Columns") {
                ForEach(columns.indices, id: \.self) { index in
                    Button {
                        pickedColumn = index
                    } label: {
                        InspectorColumnRow(name: columns[index], value: value(at: index, in: row), isActive: index == activeColumn)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func value(at index: Int, in row: [CellValue]) -> CellValue {
        row.indices.contains(index) ? row[index] : nil
    }

    private struct ValueSectionID: Hashable {
        var row: AnyHashable?
        var column: Int
    }
}

/// One line in the inspector's column list: name above a one-or-two-line preview of the value.
private struct InspectorColumnRow: View {
    var name: String
    var value: CellValue
    var isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
            if let value {
                Text(GridText.display(value, limit: 300).text)
                    .font(.body.monospacedDigit())
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else {
                Text("NULL")
                    .font(.body)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(value.map { GridText.display($0, limit: 300).text } ?? "NULL")")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The focused value in full, with optional JSON formatting and editing.
private struct InspectorValueSection: View {
    var name: String
    var value: CellValue
    var onSave: ((CellValue) -> Void)?

    @State private var formatJSON = true
    @State private var prettyJSON: String?
    @State private var draft = ""
    @State private var baseline = ""

    private var isDirty: Bool { draft != baseline }

    var body: some View {
        Section {
            if value == nil, onSave == nil {
                Text("NULL")
                    .italic()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Value of \(name): NULL")
            } else {
                InspectorTextView(text: $draft, isEditable: onSave != nil)
                    .frame(minHeight: 120, idealHeight: 200, maxHeight: 420)
                    .overlay(alignment: .topLeading) {
                        if value == nil, draft.isEmpty {
                            Text("NULL")
                                .italic()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Value of \(name)")
            }

            if let onSave {
                HStack {
                    Button("Set NULL") { onSave(nil) }
                        .disabled(value == nil && !isDirty)
                    Spacer()
                    Button("Revert") { draft = baseline }
                        .disabled(!isDirty)
                    Button("Save") {
                        onSave(formatJSON && prettyJSON != nil ? JSONPrettyPrinter.textToSave(draft, original: value) : draft)
                    }
                        .disabled(!isDirty)
                }
                .controlSize(.small)
            }
        } header: {
            HStack(spacing: 6) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let value {
                    Text(value.utf8.count.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if prettyJSON != nil {
                    Toggle(isOn: $formatJSON) {
                        Image(systemName: "curlybraces")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(formatJSON ? "Show Raw JSON" : "Format JSON")
                    .accessibilityLabel("Format JSON")
                }
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(value ?? "", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy Value")
                .accessibilityLabel("Copy Value")
                .disabled(value == nil)
            }
        }
        .onChange(of: value, initial: true) {
            prettyJSON = value.flatMap(JSONPrettyPrinter.format)
            resetDraft()
        }
        .onChange(of: formatJSON) {
            resetDraft()
        }
    }

    private func resetDraft() {
        let text = formatJSON ? (prettyJSON ?? value ?? "") : (value ?? "")
        baseline = text
        draft = text
    }
}

/// Monospaced NSTextView: selectable, scrollable, fast with large values, and free of smart quote / dash substitution.
private struct InspectorTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if textView.string != text {
            textView.string = text
            textView.undoManager?.removeAllActions(withTarget: textView)
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Re-indents JSON text without parsing values, so key order and number spelling are preserved exactly.
enum JSONPrettyPrinter {
    /// Above this size, formatting is skipped to keep the inspector responsive.
    static let maxBytes = 4_000_000

    /// The pretty-printed text when `text` is a JSON object or array, otherwise nil.
    static func format(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.utf8.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
              trimmed.utf8.count <= maxBytes,
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
        else { return nil }
        return reindent(trimmed)
    }

    /// What to store after editing the formatted view of `original`. When the original was on one line, the edit
    /// is compacted back to one line in the original's separator style (`{"a":1}` or `{"a": 1}`), so Save
    /// doesn't rewrite the stored layout. Multi-line originals, and drafts that aren't valid JSON, are kept as typed.
    static func textToSave(_ draft: String, original: CellValue) -> String {
        guard let original, !original.contains(where: \.isNewline) else { return draft }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxBytes,
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed)) != nil
        else { return draft }
        let source = original.trimmingCharacters(in: .whitespaces)
        let spaced = compact(source, spaced: false) != source && compact(source, spaced: true) == source
        return compact(trimmed, spaced: spaced)
    }

    /// One-line JSON: whitespace outside strings removed, optionally with a space after `:` and `,`.
    /// Assumes `json` is valid JSON.
    static func compact(_ json: String, spaced: Bool = false) -> String {
        let bytes = Array(json.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                out.append(byte)
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                break
            case UInt8(ascii: "\""):
                inString = true
                out.append(byte)
            case UInt8(ascii: ":"), UInt8(ascii: ","):
                out.append(byte)
                if spaced { out.append(0x20) }
            default:
                out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Two-space indentation; empty containers stay on one line. Assumes `json` is valid JSON.
    static func reindent(_ json: String) -> String {
        let bytes = Array(json.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 2)
        var depth = 0
        var inString = false
        var escaped = false

        func newline() {
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }
        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                out.append(byte)
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                index += 1
                continue
            }
            switch byte {
            case _ where isWhitespace(byte):
                break
            case UInt8(ascii: "\""):
                inString = true
                out.append(byte)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                out.append(byte)
                let closing = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                var next = index + 1
                while next < bytes.count, isWhitespace(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == closing {
                    out.append(closing)
                    index = next
                } else {
                    depth += 1
                    newline()
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth = max(depth - 1, 0)
                newline()
                out.append(byte)
            case UInt8(ascii: ","):
                out.append(byte)
                newline()
            case UInt8(ascii: ":"):
                out.append(byte)
                out.append(0x20)
            default:
                out.append(byte)
            }
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
