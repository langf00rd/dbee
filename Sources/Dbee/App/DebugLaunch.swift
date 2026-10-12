#if DEBUG
import AppKit
import Foundation

/// Debug builds only: opens a SQLite file named by DBEE_DEBUG_OPEN_SQLITE in the first window so the
/// UI can be inspected without clicking through the connect screen. Never compiled into release builds,
/// and only SQLite is supported because it needs no credentials.
///
/// DBEE_DEBUG_SELECT: "table:<name>" opens a table, "structure:<name>" its structure tab,
/// "query:<sql>" runs SQL in the first query tab. DBEE_DEBUG_APPEARANCE: "light" or "dark".
@MainActor
enum DebugLaunch {
    private static var consumed = false

    static func apply(to session: DatabaseSession) {
        let env = ProcessInfo.processInfo.environment
        guard !consumed, let path = env["DBEE_DEBUG_OPEN_SQLITE"] else { return }
        consumed = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        switch env["DBEE_DEBUG_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        var config = ConnectionConfig()
        config.kind = .sqlite
        config.filePath = path
        session.connect(config)
        guard let select = env["DBEE_DEBUG_SELECT"] else { return }
        Task {
            while !session.isConnected || session.isLoadingSchema { try? await Task.sleep(for: .milliseconds(50)) }
            if select.hasPrefix("table:") || select.hasPrefix("structure:") {
                let name = String(select.drop(while: { $0 != ":" }).dropFirst())
                guard let info = session.allTables.first(where: { $0.ref.name == name }) else { return }
                if select.hasPrefix("structure:") { session.browserModel(for: info.ref).displayMode = .structure }
                session.selection = .table(info.ref)
            } else if select.hasPrefix("query:"), let tab = session.queryTabs.first {
                tab.sql = String(select.dropFirst("query:".count))
                session.selection = .query(tab.id)
                await session.run(tab.sql, in: tab)
            }
        }
    }
}
#endif
