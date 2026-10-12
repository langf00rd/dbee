import Foundation
import Testing
@testable import Dbee

@MainActor
@Suite("FavoritesStore", .serialized)
struct FavoritesStoreTests {
    /// One fixed defaults suite shared by the (serialized) tests and wiped by `cleanUp`. A fresh name per
    /// test would leave a stray plist in ~/Library/Preferences for every run, because cfprefsd can
    /// rewrite the file after the test deletes it.
    private let suiteName = "app.dbee.Dbee.tests.favorites"

    init() {
        UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
    }
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    private func makeStore(allowed: Bool = true) -> FavoritesStore {
        FavoritesStore(defaults: defaults, isSavingAllowed: { allowed })
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: file)
    }

    private static func sampleConfig() -> ConnectionConfig {
        var config = ConnectionConfig()
        config.name = "Production"
        config.kind = .postgres
        config.host = "db.example.com"
        config.port = 6543
        config.username = "alice_admin"
        config.password = "correct-horse-battery"
        config.database = "app"
        config.tls = .verifyFull
        config.ssh.enabled = true
        config.ssh.host = "bastion.example.com"
        config.ssh.port = 2222
        config.ssh.username = "deploy_user"
        config.ssh.authMethod = .privateKey
        config.ssh.privateKeyPath = "/Users/alice/.ssh/id_ed25519_prod"
        config.ssh.passphrase = "key-passphrase-123"
        config.ssh.password = "ssh-password-456"
        return config
    }

    @Test func roundTripsThroughDefaults() throws {
        defer { cleanUp() }
        let store = makeStore()
        let first = SavedConnection(from: Self.sampleConfig())
        var second = SavedConnection(from: ConnectionConfig())
        second.name = "Local"
        second.kind = .sqlite
        second.filePath = "/tmp/local.sqlite"
        store.save(first)
        store.save(second)

        let reloaded = makeStore()
        #expect(reloaded.favorites == [first, second])
        let config = try #require(reloaded.favorite(first.id)).makeConfig()
        #expect(config.host == "db.example.com")
        #expect(config.port == 6543)
        #expect(config.ssh.host == "bastion.example.com")
        #expect(config.username.isEmpty && config.password.isEmpty)
        #expect(config.ssh.username.isEmpty && config.ssh.privateKeyPath.isEmpty && config.ssh.passphrase.isEmpty)
    }

    @Test func savingSameIDReplaces() {
        defer { cleanUp() }
        let store = makeStore()
        var favorite = SavedConnection(from: Self.sampleConfig())
        store.save(favorite)
        favorite.database = "analytics"
        store.save(favorite)
        #expect(store.favorites.count == 1)
        #expect(makeStore().favorites.first?.database == "analytics")
    }

    @Test func removesOneAndAll() {
        defer { cleanUp() }
        let store = makeStore()
        let a = SavedConnection(from: Self.sampleConfig())
        var b = a
        b.id = UUID()
        b.name = "Staging"
        store.save(a)
        store.save(b)

        store.remove(a.id)
        #expect(store.favorites == [b])
        #expect(makeStore().favorites == [b])

        store.remove(b.id)
        #expect(store.favorites.isEmpty)
        #expect(defaults.object(forKey: FavoritesStore.defaultsKey) == nil)

        store.save(a)
        store.removeAll()
        #expect(store.favorites.isEmpty)
        #expect(defaults.object(forKey: FavoritesStore.defaultsKey) == nil)
        #expect(makeStore().favorites.isEmpty)
    }

    @Test func saveDoesNothingWhenFavoritesAreDisabled() {
        defer { cleanUp() }
        let store = makeStore(allowed: false)
        store.save(SavedConnection(from: Self.sampleConfig()))
        #expect(store.favorites.isEmpty)
        #expect(defaults.object(forKey: FavoritesStore.defaultsKey) == nil)
    }

    @Test func removingStillWorksWhenFavoritesAreDisabled() {
        defer { cleanUp() }
        let favorite = SavedConnection(from: Self.sampleConfig())
        makeStore().save(favorite)
        let store = makeStore(allowed: false)
        #expect(store.favorites.count == 1)
        store.remove(favorite.id)
        #expect(store.favorites.isEmpty)
        #expect(defaults.object(forKey: FavoritesStore.defaultsKey) == nil)
    }

    @Test func persistedDataContainsNoSecrets() throws {
        defer { cleanUp() }
        let config = Self.sampleConfig()
        let store = makeStore()
        store.save(SavedConnection(from: config))

        let data = try #require(defaults.data(forKey: FavoritesStore.defaultsKey))
        let json = String(decoding: data, as: UTF8.self)
        let secrets = [
            config.username, config.password,
            config.ssh.username, config.ssh.password, config.ssh.passphrase,
            config.ssh.privateKeyPath, "id_ed25519_prod",
        ]
        for secret in secrets {
            #expect(!json.contains(secret), "favorites JSON leaked \(secret)")
        }
        // Nothing else in the suite either.
        let everything = String(describing: defaults.dictionaryRepresentation())
        for secret in secrets {
            #expect(!everything.contains(secret))
        }
    }

    @Test func stripsUserInfoFromHosts() {
        defer { cleanUp() }
        var config = Self.sampleConfig()
        config.host = "postgres://bob:hunter2@db.example.com:5432/app"
        config.ssh.host = "root@bastion.example.com"
        let store = makeStore()
        store.save(SavedConnection(from: config))

        let saved = store.favorites.first
        #expect(saved?.sshHost == "bastion.example.com")
        #expect(saved?.host.contains("hunter2") == false)
        #expect(saved?.host.contains("bob") == false)
        let json = String(decoding: defaults.data(forKey: FavoritesStore.defaultsKey) ?? Data(), as: UTF8.self)
        #expect(!json.contains("hunter2") && !json.contains("root@"))
    }

    @Test func renameTrimsAndIgnoresEmptyNames() {
        defer { cleanUp() }
        let store = makeStore()
        let favorite = SavedConnection(from: Self.sampleConfig())
        store.save(favorite)
        store.rename(favorite.id, to: "  Primary  ")
        #expect(store.favorite(favorite.id)?.name == "Primary")
        store.rename(favorite.id, to: "   ")
        #expect(makeStore().favorite(favorite.id)?.name == "Primary")
    }

    @Test func scrubsCredentialsFromNameAndDatabase() {
        defer { cleanUp() }
        var config = Self.sampleConfig()
        config.name = "postgres://bob:hunter2@db.example.com/app"
        config.database = "app?password=hunter2"
        let store = makeStore()
        store.save(SavedConnection(from: config))
        let saved = store.favorites.first
        #expect(saved?.name == "db.example.com/app")
        #expect(saved?.database == "app")
        let json = String(decoding: defaults.data(forKey: FavoritesStore.defaultsKey) ?? Data(), as: UTF8.self)
        #expect(!json.contains("hunter2"))
    }

    @Test func rewritesFavoritesStoredByOlderBuilds() throws {
        defer { cleanUp() }
        var leaky = SavedConnection(from: Self.sampleConfig())
        leaky.name = "mysql://root:s3cret@vps.example.com:3306/shop"
        defaults.set(try JSONEncoder().encode([leaky]), forKey: FavoritesStore.defaultsKey)

        let store = makeStore()
        #expect(store.favorites.first?.name.contains("s3cret") == false)
        let json = String(decoding: defaults.data(forKey: FavoritesStore.defaultsKey) ?? Data(), as: UTF8.self)
        #expect(!json.contains("s3cret"))
        #expect(json.contains(leaky.id.uuidString))
    }

    @Test func ignoresCorruptData() {
        defer { cleanUp() }
        defaults.set(Data("not json".utf8), forKey: FavoritesStore.defaultsKey)
        #expect(makeStore().favorites.isEmpty)
    }
}
