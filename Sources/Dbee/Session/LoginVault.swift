import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import Security

/// Opt-in "Remember with Touch ID" logins for favorites.
///
/// Each saved login is encrypted to its own P-256 key that lives in this Mac's Secure Enclave and can only be
/// used after a successful Touch ID check (`.biometryCurrentSet`, so enrolling a new finger invalidates it,
/// and there is no password fallback). On disk there is only ciphertext plus the Enclave's wrapped key blob,
/// which no other Mac can use. Sealing needs only the public key, so saving never prompts; opening always does.
///
/// The encryption key also mixes in a random 32-byte secret kept in the login Keychain, readable only by Dbee
/// (another app reading it triggers a macOS Keychain prompt that needs the Mac password). That ties the login
/// to this app rather than to any process that copies the file, and makes Forget a real revocation: once the
/// Keychain secret is deleted, old copies of the file can never be opened again.
///
/// The sealed payload also carries the favorite's server details (host, port, database, TLS and SSH settings).
/// Favorites themselves are plain JSON in UserDefaults; if anything rewrites one to point somewhere else, the
/// login refuses to open instead of sending the real credentials to the new address.
@MainActor @Observable
final class LoginVault {
    static let shared = LoginVault()

    /// Favorites that currently have a saved login.
    private(set) var savedIDs: Set<SavedConnection.ID> = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let keys: any LoginKeyProvider
    @ObservationIgnored private let secrets: any LoginSecretStore

    init(
        directory: URL = LoginVault.defaultDirectory,
        keys: any LoginKeyProvider = SecureEnclaveLoginKeys(),
        secrets: any LoginSecretStore = KeychainLoginSecrets()
    ) {
        self.directory = directory
        self.keys = keys
        self.secrets = secrets
        savedIDs = Self.scan(directory)
    }

    /// Whether this Mac can save logins right now (Secure Enclave present and Touch ID enrolled).
    var isSupported: Bool { keys.isSupported }

    func hasLogin(for id: SavedConnection.ID) -> Bool { savedIDs.contains(id) }

    /// Encrypts the credentials in `config` for `favorite`. Never prompts.
    func save(_ config: ConnectionConfig, for favorite: SavedConnection) throws {
        var plaintext = try JSONEncoder().encode(SavedLogin(config: config, target: LoginTarget(favorite)))
        defer { plaintext.wipe() }
        let key = try keys.makeKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var appSecret = try secrets.replace(for: favorite.id)
        defer { appSecret.wipe() }
        let symmetric = try Self.symmetricKey(
            secret: ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey),
            appSecret: appSecret,
            ephemeralPublicKey: ephemeral.publicKey
        )
        let box = try AES.GCM.seal(plaintext, using: symmetric, authenticating: Self.associatedData(favorite.id))
        let file = SealedLoginFile(
            version: 1,
            key: key.blob,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            box: box.combined!
        )
        try write(JSONEncoder().encode(file), for: favorite.id)
        savedIDs.insert(favorite.id)
    }

    /// Asks for Touch ID, then returns `favorite`'s config with the saved credentials filled in.
    ///
    /// A login that can never open again (fingerprints changed, file damaged, server details changed) is
    /// deleted before the error is thrown. Cancelling or Touch ID being unavailable leaves it in place.
    func open(_ favorite: SavedConnection) async throws -> ConnectionConfig {
        let fileURL = url(for: favorite.id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            forget(favorite.id)
            throw LoginVaultError.damaged
        }
        // An unreadable file (permissions, disk trouble) may be temporary, so it isn't deleted.
        guard let data = try? Data(contentsOf: fileURL) else { throw LoginVaultError.unavailable }
        guard let file = try? JSONDecoder().decode(SealedLoginFile.self, from: data),
              file.version == 1,
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: file.ephemeralPublicKey)
        else {
            forget(favorite.id)
            throw LoginVaultError.damaged
        }

        let secret: SharedSecret
        do {
            secret = try await keys.sharedSecret(
                keyBlob: file.key,
                with: ephemeral,
                reason: "use the saved login for “\(favorite.name)”"
            )
        } catch let error as LoginVaultError {
            if error == .invalidated { forget(favorite.id) }
            throw error
        }

        var appSecret: Data
        switch secrets.read(for: favorite.id) {
        case .found(let value): appSecret = value
        case .missing:
            // Forgotten (possibly from another window) or restored from elsewhere: it can never open again.
            forget(favorite.id)
            throw LoginVaultError.damaged
        case .denied: throw LoginVaultError.cancelled
        case .failed: throw LoginVaultError.unavailable
        }
        defer { appSecret.wipe() }

        var plaintext: Data
        do {
            let symmetric = try Self.symmetricKey(secret: secret, appSecret: appSecret, ephemeralPublicKey: ephemeral)
            plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: file.box),
                using: symmetric,
                authenticating: Self.associatedData(favorite.id)
            )
        } catch {
            forget(favorite.id)
            throw LoginVaultError.damaged
        }
        defer { plaintext.wipe() }

        guard let login = try? JSONDecoder().decode(SavedLogin.self, from: plaintext) else {
            forget(favorite.id)
            throw LoginVaultError.damaged
        }
        guard login.target == LoginTarget(favorite) else {
            forget(favorite.id)
            throw LoginVaultError.serverChanged
        }
        var config = favorite.makeConfig()
        login.apply(to: &config)
        return config
    }

    func forget(_ id: SavedConnection.ID) {
        secrets.delete(for: id)
        try? FileManager.default.removeItem(at: url(for: id))
        savedIDs.remove(id)
    }

    func forgetAll() {
        secrets.deleteAll()
        for id in savedIDs.union(Self.scan(directory)) {
            try? FileManager.default.removeItem(at: url(for: id))
        }
        savedIDs = []
    }

    /// Deletes logins whose favorite no longer exists.
    func prune(keeping ids: some Sequence<SavedConnection.ID>) {
        let keep = Set(ids)
        for id in savedIDs where !keep.contains(id) { forget(id) }
    }

    // MARK: Storage

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.dbee.Dbee", isDirectory: true)
            .appendingPathComponent("Logins", isDirectory: true)
    }

    private static let fileExtension = "dbeelogin"

    private func url(for id: SavedConnection.ID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }

    private func write(_ data: Data, for id: SavedConnection.ID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let target = url(for: id)
        try data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func scan(_ directory: URL) -> Set<SavedConnection.ID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { name in
            guard name.hasSuffix(".\(fileExtension)") else { return nil }
            return UUID(uuidString: String(name.dropLast(fileExtension.count + 1)))
        })
    }

    // MARK: Crypto

    /// HKDF-SHA256 over the Enclave ECDH secret followed by the Keychain secret; both are needed.
    private static func symmetricKey(
        secret: SharedSecret,
        appSecret: Data,
        ephemeralPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        var material = secret.withUnsafeBytes { Data($0) }
        defer { material.wipe() }
        guard appSecret.count == 32 else { throw LoginVaultError.damaged }
        material.append(appSecret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: ephemeralPublicKey.x963Representation,
            info: Data("Dbee saved login v1".utf8),
            outputByteCount: 32
        )
    }

    /// Ties the ciphertext to its favorite, so files can't be swapped between favorites.
    private static func associatedData(_ id: SavedConnection.ID) -> Data {
        Data("dbee-login-v1:\(id.uuidString)".utf8)
    }
}

enum LoginVaultError: Error, Equatable, LocalizedError {
    /// The user dismissed the Touch ID prompt.
    case cancelled
    /// Touch ID can't be used right now (lid closed, locked out after failed attempts, not enrolled).
    case unavailable
    /// Fingerprints changed since the login was saved; the Secure Enclave key is permanently unusable.
    case invalidated
    /// The favorite's server details no longer match the ones the login was saved for.
    case serverChanged
    /// The saved file is unreadable or was tampered with.
    case damaged

    var errorDescription: String? {
        switch self {
        case .cancelled: "Touch ID was cancelled."
        case .unavailable: "Touch ID isn’t available right now.\nEnter the login to connect. If this keeps happening, right-click the favorite and choose Forget Saved Login."
        case .invalidated: "The saved login was removed because your Touch ID fingerprints changed.\nEnter the login to connect, then turn on Remember with Touch ID again."
        case .serverChanged: "The saved login was removed because this favorite’s server details changed since it was saved.\nCheck the host and port, then enter the login."
        case .damaged: "The saved login couldn’t be opened and was removed.\nEnter the login to connect."
        }
    }
}

// MARK: - Payload

/// The server details a login is sealed together with.
struct LoginTarget: Codable, Equatable {
    var kind: DatabaseKind
    var host: String
    var port: Int
    var database: String
    var tls: TLSMode
    var sshEnabled: Bool
    var sshHost: String
    var sshPort: Int
    var sshAuthMethod: SSHAuthMethod

    init(_ favorite: SavedConnection) {
        kind = favorite.kind
        host = favorite.host
        port = favorite.port
        database = favorite.database
        tls = favorite.tls
        sshEnabled = favorite.sshEnabled
        sshHost = favorite.sshEnabled ? favorite.sshHost : ""
        sshPort = favorite.sshEnabled ? favorite.sshPort : 0
        sshAuthMethod = favorite.sshAuthMethod
    }
}

/// Only ever exists encrypted on disk, or briefly in memory while sealing or opening.
private struct SavedLogin: Codable {
    var target: LoginTarget
    var username: String
    var password: String
    var sshUsername: String
    var sshPassword: String
    var sshPrivateKeyPath: String
    var sshPassphrase: String

    init(config: ConnectionConfig, target: LoginTarget) {
        self.target = target
        username = config.username
        password = config.password
        let ssh = config.ssh.enabled
        sshUsername = ssh ? config.ssh.username : ""
        sshPassword = ssh && config.ssh.authMethod == .password ? config.ssh.password : ""
        sshPrivateKeyPath = ssh && config.ssh.authMethod == .privateKey ? config.ssh.privateKeyPath : ""
        sshPassphrase = ssh && config.ssh.authMethod == .privateKey ? config.ssh.passphrase : ""
    }

    func apply(to config: inout ConnectionConfig) {
        config.username = username
        config.password = password
        config.ssh.username = sshUsername
        config.ssh.password = sshPassword
        config.ssh.privateKeyPath = sshPrivateKeyPath
        config.ssh.passphrase = sshPassphrase
    }
}

private struct SealedLoginFile: Codable {
    var version: Int
    /// The Secure Enclave's wrapped private key. Only this Mac's Enclave can use it, and only after Touch ID.
    var key: Data
    var ephemeralPublicKey: Data
    var box: Data
}

extension Data {
    /// Best-effort zeroing of a buffer that held plaintext.
    mutating func wipe() {
        withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset_s(base, raw.count, 0, raw.count)
        }
        removeAll()
    }
}

// MARK: - Keys

struct LoginKey {
    var blob: Data
    var publicKey: P256.KeyAgreement.PublicKey
}

protocol LoginKeyProvider: Sendable {
    var isSupported: Bool { get }
    func makeKey() throws -> LoginKey
    /// Unlocks the key in `keyBlob` (prompting as needed) and agrees a secret with `publicKey`.
    func sharedSecret(keyBlob: Data, with publicKey: P256.KeyAgreement.PublicKey, reason: String) async throws -> SharedSecret
}

/// Keys created inside the Secure Enclave, usable only after Touch ID with the fingers enrolled at creation.
struct SecureEnclaveLoginKeys: LoginKeyProvider {
    var isSupported: Bool {
        guard SecureEnclave.isAvailable else { return false }
        let context = LAContext()
        var error: NSError?
        let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        // A closed lid reports "not available" even though Touch ID is set up; saving still works then.
        return ok || (error?.code == LAError.biometryNotAvailable.rawValue && context.biometryType == .touchID)
    }

    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &error
        ) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? LoginVaultError.unavailable
        }
        return control
    }

    func makeKey() throws -> LoginKey {
        guard isSupported else { throw LoginVaultError.unavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: Self.accessControl())
        return LoginKey(blob: key.dataRepresentation, publicKey: key.publicKey)
    }

    func sharedSecret(keyBlob: Data, with publicKey: P256.KeyAgreement.PublicKey, reason: String) async throws -> SharedSecret {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        do {
            let ok = try await context.evaluateAccessControl(
                Self.accessControl(),
                operation: .useKeyKeyExchange,
                localizedReason: reason
            )
            guard ok else { throw LoginVaultError.cancelled }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback:
                throw LoginVaultError.cancelled
            default:
                throw LoginVaultError.unavailable
            }
        }
        // The context is already authenticated, so the Enclave uses it as is; it may never prompt a second time.
        context.interactionNotAllowed = true
        let box = ContextBox(context: context)
        let blob = keyBlob
        return try await Task.detached(priority: .userInitiated) {
            do {
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: blob,
                    authenticationContext: box.context
                )
                return try key.sharedSecretFromKeyAgreement(with: publicKey)
            } catch {
                throw Self.classify(error)
            }
        }.value
    }

    /// Only an error that can't be temporary counts as "invalidated" (and leads to the login being deleted).
    private static func classify(_ error: Error) -> LoginVaultError {
        let ns = error as NSError
        if ns.domain == LAErrorDomain {
            switch LAError.Code(rawValue: ns.code) {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
            default: return .unavailable
            }
        }
        if ns.domain == NSOSStatusErrorDomain {
            switch OSStatus(ns.code) {
            case errSecUserCanceled: return .cancelled
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable: return .unavailable
            default: break
            }
        }
        return .invalidated
    }
}

/// Hands the authenticated context to the Enclave call off the main actor; it isn't touched anywhere else.
private struct ContextBox: @unchecked Sendable {
    let context: LAContext
}

// MARK: - Keychain secret

enum LoginSecretRead {
    case found(Data)
    case missing
    /// The user declined a Keychain access prompt.
    case denied
    case failed
}

protocol LoginSecretStore: Sendable {
    /// Creates (replacing any old one) and returns a fresh random 32-byte secret for `id`.
    func replace(for id: UUID) throws -> Data
    func read(for id: UUID) -> LoginSecretRead
    func delete(for id: UUID)
    func deleteAll()
}

/// Generic-password items in the login Keychain, never synced. The creating app is the only one trusted to
/// read them without a prompt.
struct KeychainLoginSecrets: LoginSecretStore {
    var service = "app.dbee.Dbee.saved-login"

    private func query(_ id: UUID?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let id { q[kSecAttrAccount as String] = id.uuidString }
        return q
    }

    func replace(for id: UUID) throws -> Data {
        delete(for: id)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LoginVaultError.unavailable
        }
        let secret = Data(bytes)
        bytes.withUnsafeMutableBytes { raw in _ = memset_s(raw.baseAddress!, raw.count, 0, raw.count) }
        var attributes = query(id)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrLabel as String] = "Dbee saved login key"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)",
            ])
        }
        return secret
    }

    func read(for id: UUID) -> LoginSecretRead {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed }
            return .found(data)
        case errSecItemNotFound: return .missing
        case errSecUserCanceled, errSecAuthFailed: return .denied
        default: return .failed
        }
    }

    func delete(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }

    func deleteAll() {
        // Some keychains delete one matching item per call, so repeat until none is left.
        var attempts = 0
        while attempts < 10_000, SecItemDelete(query(nil) as CFDictionary) == errSecSuccess { attempts += 1 }
    }
}
