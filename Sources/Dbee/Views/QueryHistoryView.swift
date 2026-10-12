import AppKit
import SwiftUI

/// Popover listing the window's in-memory query history, newest first.
/// Double-click (or Return) opens an entry in a new query tab; the context menu can also replace or append
/// to the current editor, or copy the SQL.
struct QueryHistoryView: View {
    var session: DatabaseSession
    /// The editor tab that "Replace Editor Text" and "Append to Editor" act on. nil hides those actions.
    var tab: QueryTab?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selection: HistoryEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            HistorySearchField(text: $searchText, prompt: "Search History")
                .padding(10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 460, height: 440)
    }

    private var filteredEntries: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return session.history }
        return session.history.filter {
            $0.sql.localizedCaseInsensitiveContains(query) || $0.database.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var content: some View {
        let entries = filteredEntries
        if session.history.isEmpty {
            ContentUnavailableView {
                Label("No Queries Yet", systemImage: "clock")
            } description: {
                Text(session.settings.keepQueryHistory
                     ? "Statements you run in this window appear here."
                     : "Query history is turned off in Settings.")
            }
        } else if entries.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(entries, selection: $selection) { entry in
                HistoryRow(entry: entry)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                if let entry = entry(for: ids) {
                    Button("Open in New Tab") { openInNewTab(entry) }
                    if tab != nil {
                        Button("Replace Editor Text") { replaceEditorText(with: entry) }
                        Button("Append to Editor") { appendToEditor(entry) }
                    }
                    Divider()
                    Button("Copy SQL") { copy(entry) }
                }
            } primaryAction: { ids in
                if let entry = entry(for: ids) { openInNewTab(entry) }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("History is kept in memory and cleared when the window closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Clear History") {
                selection = nil
                session.clearHistory()
            }
            .controlSize(.small)
            .disabled(session.history.isEmpty)
        }
        .padding(10)
    }

    // MARK: Actions

    private func entry(for ids: Set<HistoryEntry.ID>) -> HistoryEntry? {
        guard let id = ids.first else { return nil }
        return session.history.first { $0.id == id }
    }

    private func openInNewTab(_ entry: HistoryEntry) {
        session.newQueryTab(sql: entry.sql)
        dismiss()
    }

    private func replaceEditorText(with entry: HistoryEntry) {
        tab?.sql = entry.sql
        dismiss()
    }

    private func appendToEditor(_ entry: HistoryEntry) {
        guard let tab else { return }
        tab.sql = Self.appending(entry.sql, to: tab.sql)
        dismiss()
    }

    private func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sql, forType: .string)
    }

    /// Appends a statement after the existing script, terminating the previous statement if needed.
    static func appending(_ statement: String, to script: String) -> String {
        var base = script
        while let last = base.last, last.isWhitespace { base.removeLast() }
        guard !base.isEmpty else { return statement }
        return base + (base.hasSuffix(";") ? "\n\n" : ";\n\n") + statement
    }
}

private struct HistoryRow: View {
    var entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.tail)
            HStack(spacing: 4) {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                    .accessibilityLabel(entry.succeeded ? "Succeeded" : "Failed")
                Text(entry.date, format: .relative(presentation: .named))
                if let duration = entry.duration {
                    Text("·")
                    Text(QueryResult.format(duration))
                }
                if !entry.database.isEmpty {
                    Text("·")
                    Text(entry.database).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .help("Double-click to open in a new tab")
    }

    /// The SQL without surrounding whitespace, capped so huge statements don't cost layout time.
    private var preview: String {
        let trimmed = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.prefix(600)
        return head.endIndex < trimmed.endIndex ? String(head) + "…" : trimmed
    }
}

/// Native NSSearchField. Recent searches are deliberately not saved.
private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}
