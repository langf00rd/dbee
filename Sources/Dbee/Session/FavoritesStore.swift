import Foundation
import Observation

/// Opt-in list of connection favorites. Stores `SavedConnection` only (no credentials).
@MainActor @Observable
final class FavoritesStore {
    static let shared = FavoritesStore()
    private(set) var favorites: [SavedConnection] = []

    func save(_ connection: SavedConnection) {}
    func remove(_ id: SavedConnection.ID) {}
    func removeAll() {}
}
