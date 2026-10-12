import CryptoKit
import Foundation
import Testing
@testable import Dbee

/// A software stand-in for the Secure Enclave: same sealing code path, no Touch ID prompt.
private final class SoftwareLoginKeys: LoginKeyProvider, @unchecked Sendable {
    var supported = true
    /// What the next unlock does instead of agreeing a secret.
    var unlockError: LoginVaultError?
    private(set) var unlockReasons: [String] = []

    var isSupported: Bool { supported }

    func makeKey() throws -> LoginKey {
        let key = P256.KeyAgreement.PrivateKey()
        return LoginKey(blob: key.rawRepresentation, publicKey: key.publicKey)
    }

    func sharedSecret(keyBlob: Data, with publicKey: P256.KeyAgreement.PublicKey, reason: String) async throws -> SharedSecret {
        unlockReasons.append(reason)
        if let unlockError { throw unlockError }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: keyBlob).sharedSecretFromKeyAgreement(with: publicKey)
    }
}

/// Stands in for the login Keychain.
private final class MemoryLoginSecrets: LoginSecretStore, @unchecked Sendable {
    var items: [UUID: Data] = [:]
    var readOverride: LoginSecretRead?

    func replace(for id: UUID) throws -> Data {
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        items[id] = secret
        return secret
    }

    func read(for id: UUID) -> LoginSecretRead {
        if let readOverride { return readOverride }
        return items[id].map(LoginSecretRead.found) ?? .missing
    }

    func delete(for id: UUID) { items[id] = nil }
    func deleteAll() { items = [:] }
}

@MainActor
@Suite("LoginVault")
struct LoginVaultTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbee-login-vault-tests-\(UUID().uuidString)", isDirectory: true)
    private let keys = SoftwareLoginKeys()
    private let secrets = MemoryLoginSecrets()

    private func makeVault() -> LoginVault { LoginVault(directory: directory, keys: keys, secrets: secrets) }
    private func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    nonisolated private static func config() -> ConnectionConfig {
        var c = ConnectionConfig()
        c.name = "Production"
        c.kind = .postgres
        c.host = "db.example.com"
        c.port = 6543
        c.username = "alice_admin"
        c.password = "correct-horse-battery"
        c.database = "app"
        c.tls = .verifyFull
        c.ssh.enabled = true
        c.ssh.host = "bastion.example.com"
        c.ssh.port = 2222
        c.ssh.username = "deploy"
        c.ssh.authMethod = .privateKey
        c.ssh.privateKeyPath = "/Users/alice/.ssh/id_ed25519"
        c.ssh.passphrase = "key-passphrase-123"
        return c
    }

    nonisolated private static func favorite(_ config: ConnectionConfig = config()) -> SavedConnection {
        SavedConnection(from: config)
    }

    @Test func roundTripRestoresEveryCredential() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)
        #expect(vault.hasLogin(for: favorite.id))

        let opened = try await vault.open(favorite)
        #expect(opened == Self.config())
        #expect(keys.unlockReasons == ["use the saved login for “Production”"])
    }

    @Test func fileHoldsNoPlaintextAndIsPrivate() throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let bytes = try Data(contentsOf: files[0])
        for secret in ["alice_admin", "correct-horse-battery", "deploy", "key-passphrase-123", "id_ed25519", "db.example.com"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is readable in the saved file")
        }
        let filePermissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
        let dirPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(filePermissions == 0o600)
        #expect(dirPermissions == 0o700)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// The favorites list is plain JSON. A rewritten host must not receive the saved login.
    @Test(arguments: [
        { (f: inout SavedConnection) in f.host = "attacker.example.net" },
        { (f: inout SavedConnection) in f.port = 5432 },
        { (f: inout SavedConnection) in f.tls = .disabled },
        { (f: inout SavedConnection) in f.sshHost = "attacker.example.net" },
        { (f: inout SavedConnection) in f.sshEnabled = false },
        { (f: inout SavedConnection) in f.database = "other" },
        { (f: inout SavedConnection) in f.kind = .mysql },
    ] as [@Sendable (inout SavedConnection) -> Void])
    func changedServerDetailsRefuseAndForget(change: @Sendable (inout SavedConnection) -> Void) async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)

        var tampered = favorite
        change(&tampered)
        await #expect(throws: LoginVaultError.serverChanged) { try await vault.open(tampered) }
        #expect(!vault.hasLogin(for: favorite.id))
    }

    @Test func renamingKeepsTheLogin() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        var favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)
        favorite.name = "Renamed"
        let opened = try await vault.open(favorite)
        #expect(opened.password == "correct-horse-battery")
        #expect(opened.name == "Renamed")
    }

    @Test func filesCannotBeSwappedBetweenFavorites() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let first = Self.favorite()
        var second = first
        second.id = UUID()
        try vault.save(Self.config(), for: first)
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent("\(first.id.uuidString).dbeelogin"),
            to: directory.appendingPathComponent("\(second.id.uuidString).dbeelogin")
        )
        let reloaded = makeVault()
        await #expect(throws: LoginVaultError.damaged) { try await reloaded.open(second) }
        #expect(!reloaded.hasLogin(for: second.id))
        #expect(reloaded.hasLogin(for: first.id))
    }

    @Test func tamperedFileIsRejectedAndRemoved() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)
        let url = directory.appendingPathComponent("\(favorite.id.uuidString).dbeelogin")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var box = Data(base64Encoded: json["box"] as! String)!
        box[box.count / 2] ^= 0xFF
        json["box"] = box.base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        await #expect(throws: LoginVaultError.damaged) { try await vault.open(favorite) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancelKeepsTheLoginButInvalidatedRemovesIt() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)

        keys.unlockError = .cancelled
        await #expect(throws: LoginVaultError.cancelled) { try await vault.open(favorite) }
        #expect(vault.hasLogin(for: favorite.id))

        keys.unlockError = .unavailable
        await #expect(throws: LoginVaultError.unavailable) { try await vault.open(favorite) }
        #expect(vault.hasLogin(for: favorite.id))

        keys.unlockError = .invalidated
        await #expect(throws: LoginVaultError.invalidated) { try await vault.open(favorite) }
        #expect(!vault.hasLogin(for: favorite.id))
    }

    /// Forgetting deletes the Keychain secret, so a copy of the file taken earlier can never open again.
    @Test func forgottenLoginsCannotBeRestoredFromACopy() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)
        let url = directory.appendingPathComponent("\(favorite.id.uuidString).dbeelogin")
        let copy = try Data(contentsOf: url)

        vault.forget(favorite.id)
        #expect(secrets.items.isEmpty)
        try copy.write(to: url)
        let restored = makeVault()
        #expect(restored.hasLogin(for: favorite.id))
        await #expect(throws: LoginVaultError.damaged) { try await restored.open(favorite) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Re-saving rotates the Keychain secret, so the previous file stops working too.
    @Test func resavingRevokesThePreviousFile() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)
        let url = directory.appendingPathComponent("\(favorite.id.uuidString).dbeelogin")
        let old = try Data(contentsOf: url)
        try vault.save(Self.config(), for: favorite)
        try old.write(to: url)
        await #expect(throws: LoginVaultError.damaged) { try await vault.open(favorite) }
    }

    @Test func declinedOrFailingKeychainKeepsTheLogin() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        let favorite = Self.favorite()
        try vault.save(Self.config(), for: favorite)
        secrets.readOverride = .denied
        await #expect(throws: LoginVaultError.cancelled) { try await vault.open(favorite) }
        secrets.readOverride = .failed
        await #expect(throws: LoginVaultError.unavailable) { try await vault.open(favorite) }
        #expect(vault.hasLogin(for: favorite.id))
        secrets.readOverride = nil
        #expect(try await vault.open(favorite).password == "correct-horse-battery")
    }

    @Test func onlyTheChosenSSHMethodsSecretIsSaved() async throws {
        defer { cleanUp() }
        let vault = makeVault()
        var config = Self.config()
        config.ssh.authMethod = .password
        config.ssh.password = "ssh-pass"
        let favorite = Self.favorite(config)
        try vault.save(config, for: favorite)
        let opened = try await vault.open(favorite)
        #expect(opened.ssh.password == "ssh-pass")
        #expect(opened.ssh.passphrase.isEmpty)
        #expect(opened.ssh.privateKeyPath.isEmpty)
    }

    @Test func forgetPruneAndReload() throws {
        defer { cleanUp() }
        let vault = makeVault()
        let a = Self.favorite()
        var b = a; b.id = UUID()
        var c = a; c.id = UUID()
        for f in [a, b, c] { try vault.save(Self.config(), for: f) }

        #expect(makeVault().savedIDs == [a.id, b.id, c.id])
        vault.forget(a.id)
        vault.prune(keeping: [b.id])
        #expect(vault.savedIDs == [b.id])
        #expect(makeVault().savedIDs == [b.id])
        vault.forgetAll()
        #expect(makeVault().savedIDs.isEmpty)
        #expect(secrets.items.isEmpty)
    }

    @Test func removingFavoritesForgetsTheirLogins() throws {
        defer { cleanUp() }
        let suite = "app.dbee.Dbee.tests.loginvault"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Preferences/\(suite).plist"))
        }
        let vault = makeVault()
        let store = FavoritesStore(
            defaults: defaults,
            isSavingAllowed: { true },
            didRemove: { vault.forget($0) },
            didRemoveAll: { vault.forgetAll() }
        )
        let a = Self.favorite()
        var b = a; b.id = UUID()
        store.save(a); store.save(b)
        try vault.save(Self.config(), for: a)
        try vault.save(Self.config(), for: b)

        store.remove(a.id)
        #expect(vault.savedIDs == [b.id])
        store.removeAll()
        #expect(vault.savedIDs.isEmpty)
        // The favorites JSON itself never carries the login.
        #expect(defaults.data(forKey: FavoritesStore.defaultsKey) == nil)
    }

    @Test func connectFormOnlyOffersTheLoginForTheSameServer() {
        let favorite = Self.favorite()
        var form = favorite.makeConfig()
        #expect(ConnectView.sameServer(ConnectView.prepared(form), as: favorite))
        form.name = "Anything"
        #expect(ConnectView.sameServer(ConnectView.prepared(form), as: favorite))
        form.host = "elsewhere.example.com"
        #expect(!ConnectView.sameServer(ConnectView.prepared(form), as: favorite))
    }
}

/// Saves through the real Secure Enclave and login Keychain (saving never prompts), then forgets.
/// Opt-in because it touches the user's Keychain: DBEE_REAL_VAULT=1 swift test --filter RealLoginVault
@MainActor
@Suite("RealLoginVault", .enabled(if: ProcessInfo.processInfo.environment["DBEE_REAL_VAULT"] != nil))
struct RealLoginVaultTests {
    @Test func saveAndForgetWithTheSecureEnclaveAndKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbee-real-vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = KeychainLoginSecrets(service: "app.dbee.Dbee.tests.saved-login")
        defer { secrets.deleteAll() }
        let vault = LoginVault(directory: directory, keys: SecureEnclaveLoginKeys(), secrets: secrets)
        try #require(vault.isSupported)

        var config = ConnectionConfig()
        config.host = "db.example.com"
        config.username = "alice"
        config.password = "secret"
        let favorite = SavedConnection(from: config)
        try vault.save(config, for: favorite)
        #expect(vault.hasLogin(for: favorite.id))
        guard case .found(let value) = secrets.read(for: favorite.id) else {
            Issue.record("Keychain secret missing")
            return
        }
        #expect(value.count == 32)

        vault.forget(favorite.id)
        #expect(!vault.hasLogin(for: favorite.id))
        guard case .missing = secrets.read(for: favorite.id) else {
            Issue.record("Keychain secret not deleted")
            return
        }
    }
}
