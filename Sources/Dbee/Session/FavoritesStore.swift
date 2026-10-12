import Foundation
import Observation

/// Opt-in list of connection favorites. Stores `SavedConnection` only (no credentials). A favorite's optional
/// Touch ID login lives encrypted in `LoginVault` and is deleted together with the favorite.
///
/// Favorites are kept as JSON under the "favorites" UserDefaults key. Nothing is written while the user
/// has turned favorites off in Settings, and the key is removed entirely once the list is empty.
@MainActor @Observable
final class FavoritesStore {
    static let shared = FavoritesStore(
        didRemove: { LoginVault.shared.forget($0) },
        didRemoveAll: { LoginVault.shared.forgetAll() }
    )
    static let defaultsKey = "favorites"

    private(set) var favorites: [SavedConnection] = []
    /// True when favorites were stored but couldn't be decoded (damaged, or written by a newer version).
    private(set) var storedDataIsUnreadable = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isSavingAllowed: @MainActor () -> Bool
    @ObservationIgnored private let didRemove: @MainActor (SavedConnection.ID) -> Void
    @ObservationIgnored private let didRemoveAll: @MainActor () -> Void

    /// - Parameters:
    ///   - defaults: where favorites are persisted. Tests pass a private suite.
    ///   - isSavingAllowed: consulted on every write; defaults to the user's "Allow saving favorites" setting.
    ///   - didRemove, didRemoveAll: called after favorites are removed, so their saved logins go too.
    init(
        defaults: UserDefaults = .standard,
        isSavingAllowed: @escaping @MainActor () -> Bool = { AppSettings.shared.allowFavorites },
        didRemove: @escaping @MainActor (SavedConnection.ID) -> Void = { _ in },
        didRemoveAll: @escaping @MainActor () -> Void = {}
    ) {
        self.defaults = defaults
        self.isSavingAllowed = isSavingAllowed
        self.didRemove = didRemove
        self.didRemoveAll = didRemoveAll
        let (stored, needsRewrite) = Self.load(from: defaults)
        favorites = stored
        storedDataIsUnreadable = stored.isEmpty && defaults.data(forKey: Self.defaultsKey) != nil
        // Older builds could have saved credential-like text (for example a URL pasted into the name).
        // Write the cleaned list back once so it doesn't stay on disk.
        if needsRewrite { persist() }
    }

    func favorite(_ id: SavedConnection.ID) -> SavedConnection? {
        favorites.first { $0.id == id }
    }

    /// Adds `connection`, or replaces the favorite with the same id. Does nothing when favorites are disabled.
    func save(_ connection: SavedConnection) {
        guard isSavingAllowed() else { return }
        let clean = Self.sanitized(connection)
        if let index = favorites.firstIndex(where: { $0.id == clean.id }) {
            favorites[index] = clean
        } else {
            favorites.append(clean)
        }
        persist()
    }

    func rename(_ id: SavedConnection.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var connection = favorite(id) else { return }
        connection.name = trimmed
        save(connection)
    }

    /// Removing is always allowed, even when saving favorites is turned off.
    func remove(_ id: SavedConnection.ID) {
        favorites.removeAll { $0.id == id }
        persist()
        didRemove(id)
    }

    func removeAll() {
        favorites = []
        defaults.removeObject(forKey: Self.defaultsKey)
        didRemoveAll()
    }

    // MARK: Persistence

    private func persist() {
        guard !favorites.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> ([SavedConnection], needsRewrite: Bool) {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data)
        else { return ([], false) }
        let cleaned = decoded.map(sanitized)
        return (cleaned, cleaned != decoded)
    }

    /// Defense in depth: drops anything that looks like "user@", "user:password@" or a `password=` parameter
    /// from every free-text field, in case a connection string slipped through the connect form.
    static func sanitized(_ connection: SavedConnection) -> SavedConnection {
        var c = connection
        c.name = ConnectionString.scrubbed(c.name)
        c.host = ConnectionString.scrubbed(strippingUserInfo(c.host))
        c.sshHost = ConnectionString.scrubbed(strippingUserInfo(c.sshHost))
        c.database = ConnectionString.scrubbed(c.database)
        if c.name.isEmpty { c.name = c.host.isEmpty ? c.kind.displayName : c.host }
        return c
    }

    static func strippingUserInfo(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = h.range(of: "://") { h = String(h[scheme.upperBound...]) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        return h
    }
}
