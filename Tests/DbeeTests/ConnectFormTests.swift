import Foundation
import Testing
@testable import Dbee

@MainActor
@Suite("ConnectForm")
struct ConnectFormTests {
    // MARK: Connection URLs

    @Test func parsesPostgresURL() {
        var config = ConnectionConfig()
        config.name = "Kept"
        config.ssh.enabled = true
        config.ssh.host = "bastion"
        let ok = ConnectionString.apply("postgresql://alice:p%40ss%2Fword@db.example.com:6543/app?sslmode=verify-full", to: &config)
        #expect(ok)
        #expect(config.kind == .postgres)
        #expect(config.host == "db.example.com")
        #expect(config.port == 6543)
        #expect(config.username == "alice")
        #expect(config.password == "p@ss/word")
        #expect(config.database == "app")
        #expect(config.tls == .verifyFull)
        #expect(config.name == "Kept")
        #expect(config.ssh.enabled && config.ssh.host == "bastion")
    }

    @Test func parsesMySQLURLWithDefaults() {
        var config = ConnectionConfig()
        config.password = "old"
        #expect(ConnectionString.apply("mysql://root@127.0.0.1/shop", to: &config))
        #expect(config.kind == .mysql)
        #expect(config.port == 3306)
        #expect(config.username == "root")
        #expect(config.password.isEmpty)
        #expect(config.database == "shop")
        #expect(config.tls == .preferred)
    }

    @Test func parsesJDBCAndQueryCredentials() {
        var config = ConnectionConfig()
        #expect(ConnectionString.apply("jdbc:postgresql://db:5432/?dbname=main&user=bob&password=x&sslmode=disable", to: &config))
        #expect(config.host == "db")
        #expect(config.database == "main")
        #expect(config.username == "bob")
        #expect(config.password == "x")
        #expect(config.tls == .disabled)
    }

    @Test func parsesSQLiteURL() {
        var config = ConnectionConfig()
        #expect(ConnectionString.apply("sqlite:///Users/me/My%20App.db", to: &config))
        #expect(config.kind == .sqlite)
        #expect(config.filePath == "/Users/me/My App.db")
        #expect(config.host.isEmpty)
    }

    @Test func rejectsOtherStrings() {
        var config = ConnectionConfig()
        config.host = "before"
        for input in ["db.example.com", "https://example.com", "postgres://", "redis://h:6379"] {
            #expect(!ConnectionString.apply(input, to: &config))
        }
        #expect(config.host == "before")
    }

    @Test func splitsHostShortcuts() {
        let userHost = ConnectionString.splitHost("deploy@vps.example.com")
        #expect(userHost?.user == "deploy")
        #expect(userHost?.host == "vps.example.com")
        #expect(userHost?.port == nil)

        let full = ConnectionString.splitHost(" root@10.0.0.5:2222 ")
        #expect(full?.user == "root" && full?.host == "10.0.0.5" && full?.port == 2222)

        let v6 = ConnectionString.splitHost("me@[::1]:22")
        #expect(v6?.host == "::1" && v6?.port == 22)

        #expect(ConnectionString.splitHost("db.example.com") == nil)
        #expect(ConnectionString.splitHost("::1") == nil)
        #expect(ConnectionString.splitHost("@host") == nil)
        #expect(ConnectionString.splitHost("host:99999") == nil)
    }

    // MARK: Preparing and validating

    @Test func preparedTrimsAndAppliesDefaults() {
        var config = ConnectionConfig()
        config.host = "  admin@db.example.com:5433 "
        config.port = 0
        config.username = "ignored"
        config.ssh.host = "kept-but-unused"
        config.ssh.username = "someone"
        config.ssh.password = "secret"
        config.ssh.privateKeyPath = "~/.ssh/id"
        let prepared = ConnectView.prepared(config)
        #expect(prepared.host == "db.example.com")
        #expect(prepared.username == "admin")
        #expect(prepared.port == 5433)
        // SSH is off, so none of its credentials travel along.
        #expect(prepared.ssh.username.isEmpty && prepared.ssh.password.isEmpty && prepared.ssh.privateKeyPath.isEmpty)
    }

    @Test func preparedKeepsOnlyTheChosenSSHCredential() {
        var config = ConnectionConfig()
        config.ssh.enabled = true
        config.ssh.password = "pw"
        config.ssh.privateKeyPath = "/k"
        config.ssh.passphrase = "pp"

        config.ssh.authMethod = .password
        var prepared = ConnectView.prepared(config)
        #expect(prepared.ssh.password == "pw" && prepared.ssh.privateKeyPath.isEmpty && prepared.ssh.passphrase.isEmpty)

        config.ssh.authMethod = .privateKey
        prepared = ConnectView.prepared(config)
        #expect(prepared.ssh.password.isEmpty && prepared.ssh.privateKeyPath == "/k" && prepared.ssh.passphrase == "pp")
    }

    @Test func preparedSQLiteDropsNetworkFields() {
        var config = ConnectionConfig()
        config.kind = .sqlite
        config.filePath = " /tmp/a.db "
        config.username = "u"
        config.password = "p"
        config.ssh.enabled = true
        config.ssh.passphrase = "pp"
        let prepared = ConnectView.prepared(config)
        #expect(prepared.filePath == "/tmp/a.db")
        #expect(prepared.username.isEmpty && prepared.password.isEmpty)
        #expect(!prepared.ssh.enabled && prepared.ssh.passphrase.isEmpty)
    }

    @Test func requiredFields() {
        var config = ConnectionConfig()
        #expect(ConnectView.firstMissingField(in: ConnectView.prepared(config)) == .host)
        config.host = "db"
        #expect(ConnectView.firstMissingField(in: ConnectView.prepared(config)) == .user)
        config.username = "app"
        #expect(ConnectView.isComplete(ConnectView.prepared(config)))

        config.ssh.enabled = true
        config.host = ""
        #expect(ConnectView.firstMissingField(in: ConnectView.prepared(config)) == .sshHost)
        config.ssh.host = "deploy@vps"
        // "user@host" fills in the SSH user.
        #expect(ConnectView.firstMissingField(in: ConnectView.prepared(config)) == .sshKey)
        config.ssh.authMethod = .password
        #expect(ConnectView.firstMissingField(in: ConnectView.prepared(config)) == .sshPassword)
        config.ssh.password = "pw"
        #expect(ConnectView.isComplete(ConnectView.prepared(config)))

        var file = ConnectionConfig()
        file.kind = .sqlite
        #expect(ConnectView.firstMissingField(in: ConnectView.prepared(file)) == .filePath)
        file.filePath = "/tmp/x.db"
        #expect(ConnectView.isComplete(ConnectView.prepared(file)))
    }

    @Test func favoriteNamesAndCredentials() {
        var config = ConnectionConfig()
        config.ssh.enabled = true
        config.ssh.host = "vps.example.com"
        config.database = "app"
        config.username = "alice"
        config.password = "pw"
        let favorite = ConnectView.favorite(from: ConnectView.prepared(config))
        #expect(favorite.name == "app @ vps.example.com")
        let json = String(decoding: (try? JSONEncoder().encode(favorite)) ?? Data(), as: UTF8.self)
        #expect(!json.contains("alice") && !json.contains("\"pw\""))

        config.name = "Mine"
        #expect(ConnectView.favorite(from: ConnectView.prepared(config)).name == "Mine")

        // A name typed in "user@host" form doesn't carry the user name into the saved favorite.
        config.name = "alice@vps.example.com"
        #expect(ConnectView.favorite(from: ConnectView.prepared(config)).name == "vps.example.com")
        config.ssh.username = "deploy"
        config.name = "deploy@alice@"
        #expect(ConnectView.favorite(from: ConnectView.prepared(config)).name == "app @ vps.example.com")
    }

    // MARK: Credentials in URLs never reach a favorite

    private func json(_ favorite: SavedConnection) -> String {
        String(decoding: (try? JSONEncoder().encode(favorite)) ?? Data(), as: UTF8.self)
    }

    @Test func scrubsCredentialLikeText() {
        #expect(ConnectionString.scrubbed("mysql2://u:pw@h/db") == "h/db")
        #expect(ConnectionString.scrubbed("postgres://db.example.com/app?user=bob&password=s3cret") == "db.example.com/app")
        #expect(ConnectionString.scrubbed("postgres://h/db?password=se@cret") == "h/db")
        #expect(ConnectionString.scrubbed("pg://bob:p/a?ss@h:5432/") == "h:5432")
        #expect(ConnectionString.scrubbed("bob:s3cret@db.example.com") == "db.example.com")
        #expect(ConnectionString.scrubbed("app ; Password=x") == "app")
        // Ordinary names, hosts and the suggested "db @ host" form are left alone.
        for plain in ["app @ db.example.com", "fe80::1", "db.example.com", "Prod (EU)"] {
            #expect(ConnectionString.scrubbed(plain) == plain)
            #expect(ConnectionString.scrubbed(ConnectionString.scrubbed(plain)) == plain)
        }
    }

    @Test func unsupportedURLSchemeBlocksConnectAndIsNeverSaved() {
        var config = ConnectionConfig()
        config.host = "mysql2://u:pw@h/db"
        config.username = "u"
        let prepared = ConnectView.prepared(config)
        #expect(ConnectView.invalidURLField(in: prepared) == .host)
        #expect(ConnectView.firstMissingField(in: prepared) == .host)
        #expect(!ConnectView.isComplete(prepared))
        let favorite = ConnectView.favorite(from: prepared)
        #expect(!json(favorite).contains("pw"))
        #expect(!favorite.name.contains("://"))
    }

    @Test func typedSupportedURLIsParsedWhenPrepared() {
        var config = ConnectionConfig()
        config.host = "postgres://db.example.com/app?user=bob&password=s3cret"
        let prepared = ConnectView.prepared(config)
        #expect(prepared.host == "db.example.com")
        #expect(prepared.username == "bob")
        #expect(prepared.database == "app")
        #expect(ConnectView.invalidURLField(in: prepared) == nil)
        let favorite = ConnectView.favorite(from: prepared)
        #expect(favorite.name == "app @ db.example.com")
        #expect(!json(favorite).contains("s3cret") && !json(favorite).contains("bob"))

        // Typed credentials survive when the URL carries none.
        config.host = "mysql://db.example.com/shop"
        config.username = "alice"
        config.password = "pw"
        let typed = ConnectView.prepared(config)
        #expect(typed.kind == .mysql && typed.username == "alice" && typed.password == "pw")
    }

    @Test func urlsInNameOrDatabaseFieldsAreScrubbed() {
        var config = ConnectionConfig()
        config.host = "db.example.com"
        config.username = "bob"
        config.database = "postgres://bob:s3cret@other/app"
        let prepared = ConnectView.prepared(config)
        #expect(ConnectView.invalidURLField(in: prepared) == .database)
        #expect(!json(ConnectView.favorite(from: prepared)).contains("s3cret"))

        config.database = "app"
        config.name = "postgres://bob:s3cret@db.example.com/app?password=s3cret"
        let named = ConnectView.prepared(config)
        #expect(!named.name.contains("s3cret"))
        let favorite = ConnectView.favorite(from: named)
        #expect(favorite.name == "db.example.com/app")
        #expect(!json(favorite).contains("s3cret"))
    }

    @Test func createsEmptyDatabaseThatSQLiteOpens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbee-connect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("New.sqlite")
        try Data("stale".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data("old".utf8).write(to: url)

        try ConnectView.createEmptyDatabase(at: url)
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))

        let driver = try SQLiteDriver.open(path: url.path)
        _ = try await driver.execute("CREATE TABLE t (id INTEGER)", maxRows: 10)
        let result = try await driver.execute("SELECT count(*) FROM t", maxRows: 10)
        #expect(result.rows.first?.first == "0")
        await driver.close()
    }
}
