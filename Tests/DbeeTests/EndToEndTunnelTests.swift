import Foundation
import Testing
@testable import Dbee

// End-to-end: database drivers reaching servers that are only visible from the SSH server's network.
// Skipped unless DBEE_SSH_PORT is set; each engine also needs its DBEE_E2E_*_HOST.
//
//   docker network connect --alias pg      dbee-it-net dbee-it-postgres
//   docker network connect --alias mysql   dbee-it-net dbee-it-mysql
//   docker network connect --alias mariadb dbee-it-net dbee-it-mariadb
//   docker network connect --alias redis   dbee-it-net dbee-it-redis
//   docker network connect --alias mongo   dbee-it-net dbee-it-mongo
//   DBEE_SSH_PORT=52222 DBEE_E2E_PG_HOST=pg DBEE_E2E_MYSQL_HOST=mysql DBEE_E2E_MARIADB_HOST=mariadb \
//     DBEE_E2E_REDIS_HOST=redis DBEE_E2E_MONGO_HOST=mongo swift test --filter EndToEnd
//
// The aliases resolve only inside the docker network, so a successful query proves the traffic went
// through the tunnel. Passwords default to the ones the dbee-it-* containers were created with.

private enum E2E {
    static let env = ProcessInfo.processInfo.environment
    static let sshPort = env["DBEE_SSH_PORT"].flatMap(Int.init)
    static let sshHost = env["DBEE_SSH_HOST"] ?? "127.0.0.1"
    static let sshUser = env["DBEE_SSH_USER"] ?? "dbee"
    static let sshPassword = env["DBEE_SSH_PASSWORD"] ?? "dbee-ssh-password"
    static let dbPassword = env["DBEE_E2E_DB_PASSWORD"] ?? "dbee_test"

    struct Target: Sendable, CustomTestStringConvertible {
        var name: String
        var kind: DatabaseKind
        var host: String
        var port: Int
        var user: String
        var database: String
        /// Schema `listSchemas` reports for the probe table.
        var schema: String

        var testDescription: String { name }
    }

    static let postgres = env["DBEE_E2E_PG_HOST"].map {
        Target(name: "PostgreSQL", kind: .postgres, host: $0, port: 5432, user: "postgres", database: "postgres", schema: "public")
    }
    static let mysql = env["DBEE_E2E_MYSQL_HOST"].map {
        Target(name: "MySQL", kind: .mysql, host: $0, port: 3306, user: "root", database: "dbee", schema: "dbee")
    }
    static let mariadb = env["DBEE_E2E_MARIADB_HOST"].map {
        Target(name: "MariaDB", kind: .mysql, host: $0, port: 3306, user: "root", database: "dbee", schema: "dbee")
    }

    static let redis = env["DBEE_E2E_REDIS_HOST"].map {
        Target(name: "Redis", kind: .redis, host: $0, port: 6379, user: "", database: "13", schema: "db13")
    }
    static let mongo = env["DBEE_E2E_MONGO_HOST"].map {
        Target(name: "MongoDB", kind: .mongodb, host: $0, port: 27017, user: "dbee", database: "dbee_e2e", schema: "dbee_e2e")
    }

    static var isEnabled: Bool { sshPort != nil }

    static func sshConfig() -> SSHConfig {
        var ssh = SSHConfig()
        ssh.enabled = true
        ssh.host = sshHost
        ssh.port = sshPort ?? 22
        ssh.username = sshUser
        ssh.authMethod = .password
        ssh.password = sshPassword
        return ssh
    }

    static func config(for target: Target) -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = target.kind
        config.host = target.host
        config.port = target.port
        config.username = target.user
        config.password = dbPassword
        config.database = target.database
        config.tls = .disabled
        config.ssh = sshConfig()
        return config
    }
}

/// Accepts every host key and counts the prompts.
private final class AcceptingHostKeyVerifier: HostKeyVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [KnownHostsStatus] = []

    var statuses: [KnownHostsStatus] { lock.withLock { _statuses } }

    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool {
        lock.withLock { _statuses.append(knownHostsStatus) }
        return fingerprint.hasPrefix("SHA256:")
    }
}

private struct E2ETimeout: Error {}

@Suite("EndToEnd tunnel", .serialized, .sshdInUse, .enabled(if: E2E.isEnabled, "Set DBEE_SSH_PORT and DBEE_E2E_*_HOST to run"))
struct EndToEndTunnelTests {
    // MARK: Driver level

    @Test(.enabled(if: E2E.postgres != nil)) func postgresThroughTunnel() async throws {
        try await exerciseDriver(E2E.postgres!)
    }

    @Test(.enabled(if: E2E.mysql != nil)) func mysqlThroughTunnel() async throws {
        try await exerciseDriver(E2E.mysql!)
    }

    @Test(.enabled(if: E2E.mariadb != nil)) func mariadbThroughTunnel() async throws {
        try await exerciseDriver(E2E.mariadb!)
    }

    /// Tunnel → DriverFactory → SELECT, DDL, listSchemas, tableStructure → close.
    private func exerciseDriver(_ target: E2E.Target) async throws {
        let verifier = AcceptingHostKeyVerifier()
        // Empty known_hosts: the verifier must be asked, and the tunnel reconnects pinned to the accepted key.
        let tunnel = try await SSHTunnel.open(ssh: E2E.sshConfig(), targetHost: target.host, targetPort: target.port,
                                              verifier: verifier, knownHosts: KnownHosts(contents: ""))
        #expect(verifier.statuses == [.unknown])
        #expect(tunnel.isConnected)

        let config = E2E.config(for: target)
        let driver = try await DriverFactory.connect(config: config, host: "127.0.0.1", port: tunnel.localPort)
        do {
            #expect(driver.kind == target.kind)
            let sum = try await driver.execute("SELECT 1 + 1 AS two", maxRows: 10)
            #expect(sum.columns == ["two"])
            #expect(sum.rows == [["2"]])
            #expect(try await driver.currentDatabase() == target.database)
            #expect(!(try await driver.serverVersion()).isEmpty)

            // Bigger than one SSH window, so flow control over the channel is exercised too.
            let series = target.kind == .postgres
                ? "SELECT g AS n, repeat('x', 200) AS pad FROM generate_series(1, 5000) AS g"
                : """
                  WITH d(v) AS (SELECT 0 UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)
                  SELECT a.v + 10 * b.v + 100 * c.v + 1000 * e.v + 1 AS n, REPEAT('x', 200) AS pad
                  FROM d a, d b, d c, d e WHERE e.v < 5 ORDER BY n
                  """
            let many = try await driver.execute(series, maxRows: 10_000)
            #expect(many.rows.count == 5000)
            #expect(many.rows.last?.first == "5000")

            _ = try await driver.execute("DROP TABLE IF EXISTS e2e_tunnel_probe", maxRows: 0)
            _ = try await driver.execute("CREATE TABLE e2e_tunnel_probe (id int PRIMARY KEY, label varchar(20))", maxRows: 0)
            let inserted = try await driver.execute("INSERT INTO e2e_tunnel_probe VALUES (1, 'through ssh')", maxRows: 0)
            #expect(inserted.rowsAffected == 1)

            let schemas = try await driver.listSchemas()
            let schema = try #require(schemas.first { $0.name == target.schema }, "schemas: \(schemas.map(\.name))")
            let probe = try #require(schema.tables.first { $0.ref.name == "e2e_tunnel_probe" })
            #expect(probe.kind == .table)
            let structure = try await driver.tableStructure(probe.ref)
            #expect(structure.columns.map(\.name) == ["id", "label"])
            #expect(structure.primaryKey == ["id"])

            _ = try await driver.execute("DROP TABLE e2e_tunnel_probe", maxRows: 0)
        } catch {
            await driver.close()
            await tunnel.close()
            throw error
        }
        await driver.close()
        await tunnel.close()
        #expect(!tunnel.isConnected)
    }

    // MARK: Session level

    /// Redis and MongoDB through the whole app path: the session opens the tunnel, the driver runs over the
    /// tunnel's own SSH channel, the sidebar lists the keys or collections, a query tab runs commands and
    /// the table browser pages and filters.
    @MainActor
    @Test(arguments: [E2E.redis, E2E.mongo].compactMap { $0 })
    fileprivate func commandEngineSessionThroughTunnel(_ target: E2E.Target) async throws {
        let session = DatabaseSession()
        session.hostKeyVerifier = AcceptingHostKeyVerifier()
        session.connect(E2E.config(for: target))
        try await waitUntilConnected(session)
        #expect(session.kind == target.kind)
        #expect(session.subtitle.contains("via SSH"))
        #expect(session.currentDatabase == target.schema)

        let tab = try #require(session.queryTabs.first)
        let table: TableRef
        if target.kind == .redis {
            await session.run("FLUSHDB\nSET e2e:a 1\nSET e2e:b 2\nSET other 3\nGET e2e:b", in: tab)
            #expect(tab.errorMessage == nil)
            #expect(tab.results.last?.rows == [["2"]])
            table = RedisDriver.keysTable
        } else {
            await session.run("""
                db.dropDatabase()
                db.probe.insertMany([{ n: 1, label: "through ssh" }, { n: 2 }, { n: 3 }])
                db.probe.find({ n: { $gte: 2 } }).sort({ n: 1 })
                """, in: tab)
            #expect(tab.errorMessage == nil)
            #expect(tab.results.last?.rows.map { $0[1] } == ["2", "3"])
            table = TableRef(schema: nil, name: "probe")
        }
        #expect(session.allTables.contains { $0.ref == table })

        let model = session.browserModel(for: table)
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.rows.count == 3)
        #expect(model.readOnlyReason != nil)
        await model.setFilter(target.kind == .redis ? "e2e:*" : "{ n: { $lt: 3 } }")
        #expect(model.rows.count == 2)
        try await waitUntil { model.totalCount == 2 }

        // Switching databases goes through the driver and refreshes the sidebar.
        let other = target.kind == .redis ? "db12" : "dbee_e2e_other"
        await session.switchDatabase(other)
        #expect(session.currentDatabase == other)
        #expect(session.config?.database == other)
        #expect(session.browserModels[table] == nil, "the old database's browser state is dropped")
        if target.kind == .mongodb { #expect(!session.allTables.contains { $0.ref == table }) }

        await session.disconnect()
        #expect(session.phase == .idle)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for a condition")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The whole app path: DatabaseSession opens the tunnel, connects, loads the schema and runs a script.
    @MainActor
    @Test(.enabled(if: E2E.postgres != nil)) func sessionConnectsThroughTunnel() async throws {
        let target = try #require(E2E.postgres)
        let verifier = AcceptingHostKeyVerifier()
        let session = DatabaseSession()
        session.hostKeyVerifier = verifier
        session.connect(E2E.config(for: target))
        try await waitUntilConnected(session)
        #expect(session.kind == .postgres)
        #expect(session.currentDatabase == "postgres")
        #expect(session.subtitle.contains("via SSH"))
        #expect(session.schemas.contains { $0.name == "public" })
        #expect(session.databases.contains("postgres"))

        let tab = try #require(session.queryTabs.first)
        await session.run("SELECT 40 + 2 AS answer; SELECT current_database() AS db", in: tab)
        #expect(tab.errorMessage == nil)
        #expect(tab.results.map(\.rows) == [[["42"]], [["postgres"]]])

        // Switching databases on Postgres reconnects through a new tunnel with the in-memory config.
        await session.switchDatabase("template1")
        try await waitUntilConnected(session) { $0.currentDatabase == "template1" }
        #expect(session.config?.database == "template1")
        #expect(session.subtitle.contains("via SSH"))

        await session.disconnect()
        #expect(session.phase == .idle)
        #expect(session.config == nil)
        await #expect(throws: DatabaseError.self) {
            _ = try await session.execute("SELECT 1", recordHistory: false)
        }
    }

    /// Stop reaches the server through the tunnel: Postgres sends its CancelRequest over a new SSH channel,
    /// MySQL its KILL QUERY from a second session that the restricted local listener lets through.
    @MainActor
    @Test(arguments: [E2E.postgres, E2E.mysql].compactMap { $0 })
    private func stopWorksThroughTheTunnel(_ target: E2E.Target) async throws {
        let session = DatabaseSession()
        session.hostKeyVerifier = AcceptingHostKeyVerifier()
        session.connect(E2E.config(for: target))
        try await waitUntilConnected(session)
        let tab = try #require(session.queryTabs.first)
        let sleep = target.kind == .postgres ? "SELECT pg_sleep(30)" : "SELECT SLEEP(30)"
        let started = ContinuousClock.now
        let run = Task { await session.run(sleep, in: tab) }
        try await Task.sleep(for: .milliseconds(700))
        await session.cancelRunningQuery(in: tab)
        await run.value
        #expect(ContinuousClock.now - started < .seconds(15))
        if target.kind == .postgres { #expect(tab.errorMessage != nil) }
        // The connection is still usable afterwards.
        await session.run("SELECT 1", in: tab)
        #expect(tab.errorMessage == nil)
        #expect(tab.results.first?.rows == [["1"]])
        await session.disconnect()
    }

    /// A superseded connection attempt must not tear down or overwrite the connection that replaced it.
    @MainActor
    @Test(.enabled(if: E2E.postgres != nil)) func supersededAttemptDoesNotClobberNewerConnection() async throws {
        let target = try #require(E2E.postgres)
        let session = DatabaseSession()
        session.hostKeyVerifier = AcceptingHostKeyVerifier()
        session.connect(E2E.config(for: target))
        // Let the first attempt get into the SSH handshake before replacing it.
        try await Task.sleep(for: .milliseconds(30))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbee-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("replacement.sqlite")
        let seed = try SQLiteDriver.open(path: file.path, create: true)
        _ = try await seed.execute("CREATE TABLE marker (id integer PRIMARY KEY)", maxRows: 0)
        await seed.close()

        var sqlite = ConnectionConfig()
        sqlite.kind = .sqlite
        sqlite.filePath = file.path
        session.connect(sqlite)
        try await waitUntilConnected(session)
        #expect(session.kind == .sqlite)

        // Give the abandoned tunnel attempt time to finish or fail; the SQLite session must be untouched.
        try await Task.sleep(for: .seconds(2))
        #expect(session.phase == .connected)
        #expect(session.kind == .sqlite)
        let check = try await session.execute("SELECT count(*) FROM marker", recordHistory: false)
        #expect(check.rows == [["0"]])
        await session.disconnect()
    }

    @MainActor
    private func waitUntilConnected(_ session: DatabaseSession, timeout: Duration = .seconds(30),
                                    until condition: (DatabaseSession) -> Bool = { _ in true }) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if case .failed(let message) = session.phase { throw DatabaseError(message) }
            if session.isConnected, !session.isLoadingSchema, condition(session) { return }
            if ContinuousClock.now > deadline { throw E2ETimeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
