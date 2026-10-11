import Foundation
import Observation

/// Non-sensitive preferences. Stored in UserDefaults. Nothing in here may identify a server credential.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Rows per page in the table browser.
    var pageSize: Int { didSet { defaults.set(pageSize, forKey: Keys.pageSize) } }
    /// Maximum rows read for a single statement in the query editor.
    var maxQueryRows: Int { didSet { defaults.set(maxQueryRows, forKey: Keys.maxQueryRows) } }
    /// Whether the user may save connection favorites (host/port/database only, never credentials).
    var allowFavorites: Bool { didSet { defaults.set(allowFavorites, forKey: Keys.allowFavorites) } }
    var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: Keys.editorFontSize) } }
    /// Ask for confirmation before committing table edits / running destructive sidebar actions.
    var confirmDestructiveActions: Bool { didSet { defaults.set(confirmDestructiveActions, forKey: Keys.confirmDestructive) } }
    /// Keep the in-memory query history (cleared when the window closes either way).
    var keepQueryHistory: Bool { didSet { defaults.set(keepQueryHistory, forKey: Keys.keepHistory) } }

    private enum Keys {
        static let pageSize = "pageSize"
        static let maxQueryRows = "maxQueryRows"
        static let allowFavorites = "allowFavorites"
        static let editorFontSize = "editorFontSize"
        static let confirmDestructive = "confirmDestructiveActions"
        static let keepHistory = "keepQueryHistory"
    }

    private init() {
        defaults.register(defaults: [
            Keys.pageSize: 200,
            Keys.maxQueryRows: 10_000,
            Keys.allowFavorites: true,
            Keys.editorFontSize: 13.0,
            Keys.confirmDestructive: true,
            Keys.keepHistory: true,
        ])
        pageSize = defaults.integer(forKey: Keys.pageSize)
        maxQueryRows = defaults.integer(forKey: Keys.maxQueryRows)
        allowFavorites = defaults.bool(forKey: Keys.allowFavorites)
        editorFontSize = defaults.double(forKey: Keys.editorFontSize)
        confirmDestructiveActions = defaults.bool(forKey: Keys.confirmDestructive)
        keepQueryHistory = defaults.bool(forKey: Keys.keepHistory)
    }
}
