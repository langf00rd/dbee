import Foundation
import NIOCore
import Testing
@testable import Dbee

// MARK: - Pure formatting (no server needed)

@Suite("MySQLFormatting")
struct MySQLFormattingTests {
    @Test func renderingByTypeAndCharset() {
        let utf8mb4: UInt16 = 255
        #expect(MySQLFormatting.rendering(type: 0xFC, charset: 63) == .hex) // BLOB
        #expect(MySQLFormatting.rendering(type: 0xFC, charset: utf8mb4) == .text) // TEXT
        #expect(MySQLFormatting.rendering(type: 0xFD, charset: 63) == .hex) // VARBINARY
        #expect(MySQLFormatting.rendering(type: 0xFE, charset: 63) == .hex) // BINARY
        #expect(MySQLFormatting.rendering(type: 0xFE, charset: 2304) == .text) // CHAR with a uca1400 collation
        #expect(MySQLFormatting.rendering(type: 0xFF, charset: 63) == .hex) // GEOMETRY
        #expect(MySQLFormatting.rendering(type: 0x10, charset: 63) == .bitInteger) // BIT
        #expect(MySQLFormatting.rendering(type: 0x08, charset: 63) == .text) // BIGINT
        #expect(MySQLFormatting.rendering(type: 0xF6, charset: 63) == .text) // DECIMAL
        #expect(MySQLFormatting.rendering(type: 0xF5, charset: 63) == .text) // JSON
    }

    @Test func renderValues() {
        #expect(MySQLFormatting.render(ByteBuffer(bytes: [0x00, 0xFF, 0x10]), as: .hex) == "\\x00ff10")
        #expect(MySQLFormatting.render(ByteBuffer(), as: .hex) == "\\x")
        #expect(MySQLFormatting.render(ByteBuffer(bytes: [0x01, 0x05]), as: .bitInteger) == "261")
        #expect(MySQLFormatting.render(ByteBuffer(string: "héllo 😀"), as: .text) == "héllo 😀")
    }

    @Test func serverDescriptions() {
        #expect(MySQLFormatting.serverDescription(version: "8.4.2", comment: "MySQL Community Server - GPL").display == "MySQL 8.4.2")
        let maria = MySQLFormatting.serverDescription(version: "11.4.2-MariaDB-ubu2404", comment: "mariadb.org binary distribution")
        #expect(maria.display == "MariaDB 11.4.2")
        #expect(maria.isMariaDB)
        #expect(maria.numbers == [11, 4, 2])
        #expect(MySQLFormatting.serverDescription(version: "5.5.5-10.6.12-MariaDB", comment: "").display == "MariaDB 10.6.12")
        #expect(MySQLFormatting.serverDescription(version: "8.0.36-28", comment: "Percona Server (GPL), Release 28").display == "Percona Server 8.0.36")
        #expect(MySQLFormatting.serverDescription(version: "8.0.11-TiDB-v7.5.0", comment: "").display == "TiDB v7.5.0")
    }

    @Test func quoting() {
        #expect(MySQLFormatting.quoteIdentifier("a`b") == "`a``b`")
        #expect(MySQLFormatting.stringLiteral("it's\\") == "CONVERT(X'697427735c' USING utf8mb4)")
        #expect(MySQLFormatting.stringLiteral("") == "CONVERT(X'' USING utf8mb4)")
    }

    @Test func columnDefaults() {
        typealias F = MySQLFormatting
        #expect(F.columnDefault("abc", columnType: "varchar(10)", extra: "", generationExpression: nil, isMariaDB: false) == "'abc'")
        #expect(F.columnDefault("it's", columnType: "text", extra: "", generationExpression: nil, isMariaDB: false) == "'it''s'")
        #expect(F.columnDefault("0", columnType: "int unsigned", extra: "", generationExpression: nil, isMariaDB: false) == "0")
        #expect(F.columnDefault("CURRENT_TIMESTAMP", columnType: "timestamp", extra: "DEFAULT_GENERATED", generationExpression: "", isMariaDB: false) == "CURRENT_TIMESTAMP")
        #expect(F.columnDefault(nil, columnType: "int", extra: "auto_increment", generationExpression: nil, isMariaDB: false) == "AUTO_INCREMENT")
        #expect(F.columnDefault(nil, columnType: "int", extra: "STORED GENERATED", generationExpression: "`a` + 1", isMariaDB: false) == "AS (`a` + 1) STORED")
        #expect(F.columnDefault(nil, columnType: "int", extra: "", generationExpression: nil, isMariaDB: false) == nil)
        #expect(F.columnDefault("NULL", columnType: "int", extra: "", generationExpression: nil, isMariaDB: true) == nil)
        #expect(F.columnDefault("'abc'", columnType: "varchar(10)", extra: "", generationExpression: nil, isMariaDB: true) == "'abc'")
    }

    @Test func statementTraits() {
        #expect(StatementTraits.leadingKeyword("  /* x */ -- y\n select 1", kind: .mysql) == "SELECT")
        #expect(StatementTraits.leadingKeyword("# note\nSET @a = 1", kind: .mysql) == "SET")
        #expect(StatementTraits.hasLockingClause("SELECT * FROM t FOR UPDATE", kind: .mysql))
        #expect(StatementTraits.hasLockingClause("select * from t for  no key\nupdate", kind: .postgres))
        #expect(StatementTraits.hasLockingClause("SELECT * FROM t FOR KEY SHARE", kind: .postgres))
        #expect(StatementTraits.hasLockingClause("SELECT * FROM t LOCK IN SHARE MODE", kind: .mysql))
        #expect(!StatementTraits.hasLockingClause("SELECT 'for update' FROM t -- for update", kind: .mysql))
        #expect(!StatementTraits.hasLockingClause("SELECT $x$ for update $x$, \"for\" FROM t", kind: .postgres))
        #expect(!StatementTraits.hasLockingClause("SELECT `for`, `update` FROM t", kind: .mysql))
        #expect(!StatementTraits.hasLockingClause("SELECT format FROM forms", kind: .postgres))
    }

    @Test func stopEarlyAndSessionState() {
        typealias F = MySQLFormatting
        #expect(F.canStopEarly("SELECT * FROM t"))
        #expect(F.canStopEarly("(SELECT 1) UNION (SELECT 2)"))
        #expect(F.canStopEarly("WITH x AS (SELECT 1) SELECT * FROM x"))
        #expect(!F.canStopEarly("SELECT * FROM t FOR UPDATE"))
        #expect(!F.canStopEarly("SELECT a INTO @a FROM t"))
        #expect(!F.canStopEarly("CALL p()"))
        #expect(!F.canStopEarly("UPDATE t SET a = 1"))
        #expect(F.changesSessionState("SET autocommit = 0"))
        #expect(F.changesSessionState("set @guard = 'x'"))
        #expect(F.changesSessionState("LOCK TABLES t WRITE"))
        #expect(F.changesSessionState("CREATE TEMPORARY TABLE t (id INT)"))
        #expect(!F.changesSessionState("CREATE TABLE t (id INT)"))
        #expect(!F.changesSessionState("UPDATE t SET a = 1"))
        #expect(!F.changesSessionState("SELECT 'SET'"))
    }

    @Test func tlsGreetingCheck() {
        // HandshakeV10: protocol 10, version, connection id, 8 bytes of auth data, filler, capabilities (low).
        func greeting(capabilities: UInt16) -> ByteBuffer {
            var payload: [UInt8] = [10] + Array("8.4.2".utf8) + [0] + [1, 0, 0, 0] + Array(repeating: 0x41, count: 8) + [0]
            payload += [UInt8(capabilities & 0xFF), UInt8(capabilities >> 8), 0xFF, 2, 0]
            return ByteBuffer(bytes: [UInt8(payload.count), 0, 0, 0] + payload)
        }
        #expect(MySQLTLSRelay.allowsGreeting(greeting(capabilities: 0xFFFF)))
        #expect(!MySQLTLSRelay.allowsGreeting(greeting(capabilities: 0xF7FF)))
        #expect(MySQLTLSRelay.allowsGreeting(ByteBuffer(bytes: [3, 0, 0, 0, 0xFF, 0x10, 0x04])))
        #expect(!MySQLTLSRelay.allowsGreeting(ByteBuffer(bytes: [1, 0, 0, 0, 9])))
    }

    @Test func useDetection() {
        #expect(MySQLFormatting.isUseStatement("USE dbee"))
        #expect(MySQLFormatting.isUseStatement("  use `x y`"))
        #expect(!MySQLFormatting.isUseStatement("USER()"))
        #expect(!MySQLFormatting.isUseStatement("SELECT 1"))
    }
}

// MARK: - Connection failures (no server needed)

@Suite("MySQLConnectFailures")
struct MySQLConnectFailureTests {
    private func config(port: Int, host: String = "127.0.0.1", tls: TLSMode = .disabled) -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .mysql
        config.host = host
        config.port = port
        config.username = "root"
        config.password = "secret"
        config.tls = tls
        return config
    }

    @Test func refusedPortIsReadable() async throws {
        // "localhost" resolves to ::1 and 127.0.0.1; both must be tried before giving up.
        do {
            _ = try await MySQLDriver.connect(config: config(port: 1, host: "localhost"), host: "localhost", port: 1)
            Issue.record("connected to port 1")
        } catch let error as DatabaseError {
            #expect(error.message == "Couldn't connect to localhost:1.")
            #expect(error.detail?.contains("refused") == true)
        }
    }

    @Test func unknownHostIsReadable() async throws {
        let host = "dbee-no-such-host.invalid"
        do {
            _ = try await MySQLDriver.connect(config: config(port: 3306, host: host), host: host, port: 3306)
            Issue.record("resolved an invalid host")
        } catch let error as DatabaseError {
            #expect(error.message == "Couldn't find the server “\(host)”.")
        }
    }

    @Test func silentServerTimesOut() async throws {
        // A listening socket that never accepts: TCP connects, but no MySQL greeting ever arrives.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && listen(listener, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await MySQLDriver.connect(config: config(port: port), host: "127.0.0.1", port: port, timeout: 1)
            Issue.record("connected to a silent socket")
        } catch let error as DatabaseError {
            #expect(error.message == "Timed out connecting to 127.0.0.1:\(port).")
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellingConnectStopsWaiting() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && listen(listener, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let config = config(port: port)

        let task = Task { try await MySQLDriver.connect(config: config, host: "127.0.0.1", port: port) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}

// MARK: - Integration (Docker: DBEE_MYSQL_PORT / DBEE_MARIADB_PORT)

struct MySQLTestServer: Sendable, CustomTestStringConvertible {
    var name: String
    var port: Int
    var isMariaDB: Bool

    var testDescription: String { name }

    static let all: [MySQLTestServer] = {
        let environment = ProcessInfo.processInfo.environment
        var servers: [MySQLTestServer] = []
        if let port = environment["DBEE_MYSQL_PORT"].flatMap({ Int($0) }) {
            servers.append(MySQLTestServer(name: "MySQL", port: port, isMariaDB: false))
        }
        if let port = environment["DBEE_MARIADB_PORT"].flatMap({ Int($0) }) {
            servers.append(MySQLTestServer(name: "MariaDB", port: port, isMariaDB: true))
        }
        return servers
    }()

    static var mysql: MySQLTestServer? { all.first { !$0.isMariaDB } }

    func config(user: String = "root", password: String = "dbee_test", database: String = "dbee",
                tls: TLSMode = .disabled) -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .mysql
        config.host = "127.0.0.1"
        config.port = port
        config.username = user
        config.password = password
        config.database = database
        config.tls = tls
        return config
    }

    /// Docker Desktop's port forwarder occasionally drops a MySQL server's greeting when many connections open
    /// at once (seen in full parallel runs: no greeting arrives, then the server's own connect_timeout error,
    /// ERROR 1159, or MariaDB simply closes). That is an artifact of the test setup, so connect once more.
    func connect(user: String = "root", password: String = "dbee_test", database: String = "dbee",
                 tls: TLSMode = .disabled) async throws -> MySQLDriver {
        let config = config(user: user, password: password, database: database, tls: tls)
        do {
            return try await MySQLDriver.connect(config: config, host: "127.0.0.1", port: port)
        } catch let error as DatabaseError where Self.isLostGreeting(error) {
            return try await MySQLDriver.connect(config: config, host: "127.0.0.1", port: port)
        }
    }

    static func isLostGreeting(_ error: DatabaseError) -> Bool {
        (error.message + (error.detail ?? "")).contains("ERROR 1159") || error.message.hasPrefix("Timed out connecting")
    }

    /// Opens a driver, runs `body`, and always closes the driver.
    @discardableResult
    func withDriver<T>(user: String = "root", password: String = "dbee_test", database: String = "dbee",
                       tls: TLSMode = .disabled, _ body: (MySQLDriver) async throws -> T) async throws -> T {
        let driver = try await connect(user: user, password: password, database: database, tls: tls)
        do {
            let value = try await body(driver)
            await driver.close()
            return value
        } catch {
            await driver.close()
            throw error
        }
    }
}

private extension MySQLDriver {
    func value(_ sql: String) async throws -> String? {
        try await execute(sql, maxRows: 10).rows.first?.first ?? nil
    }

    @discardableResult
    func run(_ sql: String) async throws -> QueryResult {
        try await execute(sql, maxRows: 1000)
    }
}

@Suite("MySQLIntegration", .serialized, .enabled(if: !MySQLTestServer.all.isEmpty))
struct MySQLIntegrationTests {
    @Test(arguments: MySQLTestServer.all)
    func connectsAndDescribesServer(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            let version = try await driver.serverVersion()
            #expect(version.hasPrefix(server.isMariaDB ? "MariaDB 1" : "MySQL 8."))
            #expect(try await driver.currentDatabase() == "dbee")
            let databases = try await driver.listDatabases()
            #expect(databases.contains("dbee"))
            for system in ["mysql", "sys", "information_schema", "performance_schema"] {
                #expect(!databases.contains(system))
            }
            // The session must be utf8mb4 whatever the server defaults are.
            #expect(try await driver.value("SELECT @@character_set_results") == "utf8mb4")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func wrongPasswordIsReadable(_ server: MySQLTestServer) async throws {
        do {
            _ = try await server.connect(password: "nope")
            Issue.record("connected with a wrong password")
        } catch let error as DatabaseError {
            #expect(error.message.hasPrefix("Access denied for user 'root'"))
            #expect(error.detail?.contains("1045") == true)
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func rendersEveryTypeAsText(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await driver.run("DROP TABLE IF EXISTS it_types")
            try await driver.run("""
                CREATE TABLE it_types (
                  id INT PRIMARY KEY, dec_col DECIMAL(10,4), dt DATETIME(3), ts TIMESTAMP NULL, d DATE, tm TIME, yr YEAR,
                  js JSON, bl BLOB, bin BINARY(4), vb VARBINARY(10), bt BIT(5), en ENUM('a','b'), st SET('x','y'),
                  geo POINT, ub BIGINT UNSIGNED, f FLOAT, db DOUBLE, txt TEXT, nul VARCHAR(5), ch CHAR(3), tiny TINYINT(1)
                )
                """)
            let insert = try await driver.run("""
                INSERT INTO it_types VALUES (1, 12.5, '2024-01-02 03:04:05.678', '2024-05-06 07:08:09', '2024-12-31',
                  '-12:34:56', 2024, '{"a": [1, 2]}', X'00FF10', X'01020304', X'ABCD', b'10101', 'b', 'x,y',
                  ST_GeomFromText('POINT(1 2)'), 18446744073709551615, 1.5, 2.25, 'héllo ✓ 😀', NULL, 'ab', 1)
                """)
            #expect(insert.rowsAffected == 1)
            let result = try await driver.execute("SELECT * FROM it_types", maxRows: 10)
            #expect(result.columns.count == 22)
            #expect(result.rowsAffected == nil)
            let row = try #require(result.rows.first)
            let expected: [CellValue] = ["1", "12.5000", "2024-01-02 03:04:05.678", "2024-05-06 07:08:09", "2024-12-31",
                                         "-12:34:56", "2024", "{\"a\": [1, 2]}", "\\x00ff10", "\\x01020304", "\\xabcd",
                                         "21", "b", "x,y"]
            #expect(Array(row.prefix(expected.count)) == expected)
            // SRID 0, then little-endian WKB for POINT(1 2).
            #expect(row[14] == "\\x000000000101000000000000000000f03f0000000000000040")
            #expect(Array(row.suffix(7)) == ["18446744073709551615", "1.5", "2.25", "héllo ✓ 😀", nil, "ab", "1"])

            let literals = try await driver.execute("SELECT NULL, 1 + 1, X'4142', CAST('2024-01-01' AS DATE), 0.1 + 0.2", maxRows: 1)
            #expect(literals.rows == [[nil, "2", "\\x4142", "2024-01-01", "0.3"]])
            try await driver.run("DROP TABLE it_types")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func reportsRowsAffectedForDDLAndDML(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await driver.run("DROP TABLE IF EXISTS it_dml")
            let create = try await driver.run("CREATE TABLE it_dml (id INT PRIMARY KEY, v VARCHAR(10))")
            #expect(create.columns.isEmpty)
            #expect(create.rowsAffected == 0)
            #expect(try await driver.run("INSERT INTO it_dml VALUES (1, 'a'), (2, 'b'), (3, 'c')").rowsAffected == 3)
            #expect(try await driver.run("UPDATE it_dml SET v = 'z' WHERE id >= 2").rowsAffected == 2)
            #expect(try await driver.run("UPDATE it_dml SET v = 'z' WHERE id >= 2").rowsAffected == 0)
            #expect(try await driver.run("DELETE FROM it_dml WHERE id = 1").rowsAffected == 1)
            let select = try await driver.run("SELECT * FROM it_dml ORDER BY id")
            #expect(select.rows == [["2", "z"], ["3", "z"]])
            #expect(select.rowsAffected == nil)
            #expect(select.duration > 0)

            try await driver.run("SET @x = 5")
            #expect(try await driver.value("SELECT @x") == "5")
            #expect(try await driver.run("SHOW TABLES").isRowSet)
            #expect(try await driver.run("EXPLAIN SELECT * FROM it_dml WHERE id = 2").isRowSet)
            #expect(try await driver.run("SHOW CREATE TABLE it_dml").rows.first?[1]?.hasPrefix("CREATE TABLE") == true)

            // Statements that can't go through prepared statements.
            try await driver.run("DROP PROCEDURE IF EXISTS it_proc")
            try await driver.run("CREATE PROCEDURE it_proc() BEGIN UPDATE it_dml SET v = 'p'; END")
            try await driver.run("CALL it_proc()")
            #expect(try await driver.value("SELECT DISTINCT v FROM it_dml") == "p")
            try await driver.run("DROP PROCEDURE it_proc")
            try await driver.run("LOCK TABLES it_dml WRITE")
            try await driver.run("UNLOCK TABLES")

            // Errors are short and leave the connection usable.
            do {
                try await driver.run("SELEC 1")
                Issue.record("syntax error not reported")
            } catch let error as DatabaseError {
                #expect(error.message.contains("SQL syntax"))
                #expect(error.detail == "ERROR 1064 (42000)")
            }
            do {
                try await driver.run("INSERT INTO it_dml VALUES (2, 'dup')")
                Issue.record("duplicate not reported")
            } catch let error as DatabaseError {
                #expect(error.message.hasPrefix("Duplicate entry '2'"))
            }
            #expect(try await driver.value("SELECT 7") == "7")
            #expect(try await driver.run("DROP TABLE it_dml").rowsAffected == 0)
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func useChangesCurrentDatabase(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await driver.run("CREATE DATABASE IF NOT EXISTS dbee_other")
            try await driver.run("CREATE TABLE IF NOT EXISTS dbee_other.only_here (id INT)")
            try await driver.run("USE `dbee_other`")
            #expect(try await driver.currentDatabase() == "dbee_other")
            let schemas = try await driver.listSchemas()
            #expect(schemas.map(\.name) == ["dbee_other"])
            #expect(schemas.first?.tables.map(\.ref) == [TableRef(schema: nil, name: "only_here")])
            try await driver.run("USE dbee")
            #expect(try await driver.currentDatabase() == "dbee")
            try await driver.run("DROP DATABASE dbee_other")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func connectsWithoutDefaultDatabase(_ server: MySQLTestServer) async throws {
        try await server.withDriver(database: "") { driver in
            #expect(try await driver.currentDatabase() == "")
            #expect(try await driver.listSchemas().isEmpty)
            #expect(try await driver.listDatabases().contains("dbee"))
            try await driver.run("USE dbee")
            #expect(try await driver.currentDatabase() == "dbee")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func keepsDuplicateColumnNames(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            let result = try await driver.run("SELECT 1 AS a, 2 AS a, 'x' AS b")
            #expect(result.columns == ["a", "a", "b"])
            #expect(result.rows == [["1", "2", "x"]])
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func limitsRowsAndStaysInSync(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            let sql = "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 500) SELECT n FROM seq"
            let limited = try await driver.execute(sql, maxRows: 10)
            #expect(limited.rows.count == 10)
            #expect(limited.truncated)
            #expect(limited.rows.last == ["10"])
            #expect(try await driver.value("SELECT 42") == "42")
            let exact = try await driver.execute(sql, maxRows: 500)
            #expect(exact.rows.count == 500)
            #expect(!exact.truncated)
            let unlimited = try await driver.execute(sql, maxRows: 0)
            #expect(unlimited.rows.count == 500)
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func describesTableStructure(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await driver.run("DROP VIEW IF EXISTS it_view")
            try await driver.run("DROP TABLE IF EXISTS it_child")
            try await driver.run("DROP TABLE IF EXISTS it_parent")
            try await driver.run("DROP TABLE IF EXISTS `we``ird 'name`")
            try await driver.run("""
                CREATE TABLE it_parent (
                  a INT NOT NULL, b VARCHAR(20) NOT NULL,
                  label VARCHAR(50) DEFAULT 'it''s' COMMENT 'Display label',
                  created TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
                  PRIMARY KEY (a, b)
                ) COMMENT 'parents'
                """)
            try await driver.run("""
                CREATE TABLE it_child (
                  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, pa INT, pb VARCHAR(20), qty INT DEFAULT 0, note TEXT,
                  KEY idx_pab (pa, pb), UNIQUE KEY uq_note (note(10)),
                  CONSTRAINT fk_parent FOREIGN KEY (pa, pb) REFERENCES it_parent (a, b) ON DELETE CASCADE ON UPDATE RESTRICT
                )
                """)
            try await driver.run("CREATE VIEW it_view AS SELECT a, b FROM it_parent")
            try await driver.run("CREATE TABLE `we``ird 'name` (`x\\y` INT PRIMARY KEY)")

            let parent = try await driver.tableStructure(TableRef(schema: nil, name: "it_parent"))
            #expect(parent.columns.map(\.name) == ["a", "b", "label", "created"])
            #expect(parent.primaryKey == ["a", "b"])
            #expect(parent.columns[0].dataType == (server.isMariaDB ? "int(11)" : "int"))
            #expect(parent.columns[1].dataType == "varchar(20)")
            #expect(!parent.columns[0].isNullable)
            #expect(parent.columns[2].isNullable)
            #expect(parent.columns[2].defaultValue == "'it''s'")
            #expect(parent.columns[2].comment == "Display label")
            #expect(parent.columns[0].comment == nil)
            #expect(parent.columns[3].defaultValue?.lowercased().hasPrefix("current_timestamp") == true)
            #expect(parent.indexes.first?.isPrimary == true)
            #expect(parent.indexes.first?.columns == ["a", "b"])
            #expect(parent.indexes.first?.definition == "PRIMARY KEY (`a`, `b`)")
            #expect(parent.ddl?.hasPrefix("CREATE TABLE `it_parent`") == true)

            let child = try await driver.tableStructure(TableRef(schema: nil, name: "it_child"))
            #expect(child.columns.first?.defaultValue == "AUTO_INCREMENT")
            #expect(child.columns.first?.dataType == "int unsigned" || child.columns.first?.dataType == "int(10) unsigned")
            #expect(child.columns.first { $0.name == "qty" }?.defaultValue == "0")
            #expect(child.columns.first { $0.name == "note" }?.defaultValue == nil)
            #expect(child.primaryKey == ["id"])
            let composite = try #require(child.indexes.first { $0.name == "idx_pab" })
            #expect(composite.columns == ["pa", "pb"])
            #expect(!composite.isUnique)
            let unique = try #require(child.indexes.first { $0.name == "uq_note" })
            #expect(unique.isUnique)
            #expect(unique.definition == "UNIQUE KEY `uq_note` (`note`(10))")
            #expect(child.foreignKeys.count == 1)
            let foreignKey = try #require(child.foreignKeys.first)
            #expect(foreignKey.name == "fk_parent")
            #expect(foreignKey.columns == ["pa", "pb"])
            #expect(foreignKey.referencedTable == TableRef(schema: nil, name: "it_parent"))
            #expect(foreignKey.referencedColumns == ["a", "b"])
            #expect(foreignKey.onDelete == "CASCADE")
            #expect(foreignKey.onUpdate == "RESTRICT")

            let view = try await driver.tableStructure(TableRef(schema: nil, name: "it_view"))
            #expect(view.columns.map(\.name) == ["a", "b"])
            #expect(view.indexes.isEmpty)
            #expect(view.ddl?.contains("VIEW") == true)

            let weird = try await driver.tableStructure(TableRef(schema: nil, name: "we`ird 'name"))
            #expect(weird.primaryKey == ["x\\y"])
            let qualified = try await driver.tableStructure(TableRef(schema: "dbee", name: "it_child"))
            #expect(qualified.foreignKeys.first?.referencedTable == TableRef(schema: "dbee", name: "it_parent"))

            await #expect(throws: DatabaseError.self) {
                try await driver.tableStructure(TableRef(schema: nil, name: "it_missing"))
            }

            let tables = try #require(try await driver.listSchemas().first).tables
            #expect(tables.first { $0.ref.name == "it_view" }?.kind == .view)
            #expect(tables.first { $0.ref.name == "it_parent" }?.kind == .table)
            #expect(tables.map(\.ref.name) == tables.map(\.ref.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })

            try await driver.run("DROP VIEW it_view")
            try await driver.run("DROP TABLE it_child")
            try await driver.run("DROP TABLE it_parent")
            try await driver.run("DROP TABLE `we``ird 'name`")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func keepsTransactionsAcrossCalls(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await server.withDriver { observer in
                try await driver.run("DROP TABLE IF EXISTS it_tx")
                try await driver.run("CREATE TABLE it_tx (id INT PRIMARY KEY) ENGINE=InnoDB")
                try await driver.run("START TRANSACTION")
                try await driver.run("INSERT INTO it_tx VALUES (1)")
                #expect(try await driver.value("SELECT COUNT(*) FROM it_tx") == "1")
                #expect(try await observer.value("SELECT COUNT(*) FROM it_tx") == "0")
                try await driver.run("ROLLBACK")
                #expect(try await driver.value("SELECT COUNT(*) FROM it_tx") == "0")
                try await driver.run("START TRANSACTION")
                try await driver.run("INSERT INTO it_tx VALUES (2)")
                try await driver.run("COMMIT")
                #expect(try await observer.value("SELECT COUNT(*) FROM it_tx") == "1")
                try await driver.run("DROP TABLE it_tx")
            }
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func cancelsRunningQuery(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            let clock = ContinuousClock()
            let start = clock.now
            let task = Task { try await driver.execute("SELECT SLEEP(30)", maxRows: 10) }
            try await Task.sleep(for: .seconds(1))
            await driver.cancelCurrentQuery()
            let outcome = await task.result
            #expect(clock.now - start < .seconds(10))
            switch outcome {
            case .success(let result):
                // SLEEP() returns 1 when interrupted instead of failing the statement.
                #expect(result.rows == [["1"]])
            case .failure(let error):
                #expect((error as? DatabaseError)?.detail?.contains("1317") == true)
            }
            #expect(try await driver.value("SELECT 1") == "1")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func cancellingTheTaskStopsTheStatement(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            let clock = ContinuousClock()
            let start = clock.now
            let task = Task { try await driver.execute("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE SLEEP(30)", maxRows: 10) }
            try await Task.sleep(for: .seconds(1))
            // Queued behind the first: never reaches the server once cancelled.
            let queued = Task { try await driver.execute("SELECT SLEEP(30)", maxRows: 10) }
            try await Task.sleep(for: .milliseconds(100))
            queued.cancel()
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            await #expect(throws: CancellationError.self) { try await queued.value }
            #expect(clock.now - start < .seconds(10))
            #expect(try await driver.value("SELECT 'next'") == "next")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func rowLimitStopsTheServer(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await driver.run("DROP TABLE IF EXISTS it_numbers")
            try await driver.run("CREATE TABLE it_numbers (n INT)")
            try await driver.run("INSERT INTO it_numbers WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 1000) SELECT n FROM r")
            let clock = ContinuousClock()
            let start = clock.now
            // A billion rows: only finishes quickly if the server is stopped after the first 100.
            let result = try await driver.execute("SELECT a.n, b.n, c.n FROM it_numbers a, it_numbers b, it_numbers c", maxRows: 100)
            #expect(result.rows.count == 100)
            #expect(result.truncated)
            #expect(clock.now - start < .seconds(15))
            #expect(try await driver.value("SELECT 'next'") == "next")
            try await driver.run("DROP TABLE it_numbers")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func valuesOf16MBOrMore(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            let limit = try #require(try await driver.value("SELECT @@max_allowed_packet").flatMap { Int($0) })
            if limit > 40_000_000 {
                try await driver.run("CREATE TEMPORARY TABLE it_big (id INT, b LONGBLOB)")
                try await driver.run("INSERT INTO it_big VALUES (1, REPEAT('z', 9000000))")
                let result = try await driver.execute("SELECT id, b, b FROM it_big", maxRows: 10)
                #expect(result.rows.count == 1)
                #expect(result.rows.first?[1]?.count == 2 + 18_000_000)
                let text = try await driver.execute("SELECT REPEAT('a', 17000000)", maxRows: 10)
                #expect(text.rows.first?.first??.count == 17_000_000)
                #expect(try await driver.value("SELECT 'after big'") == "after big")
                #expect(try await driver.value("SELECT 1") == "1")

                // A statement of 16 MB or more is split into several packets.
                let literal = String(repeating: "a", count: 16_777_300)
                #expect(try await driver.value("SELECT LENGTH('\(literal)')") == "16777300")
                #expect(try await driver.value("SELECT 2") == "2")
            } else {
                let literal = String(repeating: "a", count: limit + 10)
                do {
                    try await driver.run("SELECT LENGTH('\(literal)')")
                    Issue.record("sent a statement over max_allowed_packet")
                } catch let error as DatabaseError {
                    #expect(error.message == "The statement is too large for the server.")
                }
                #expect(try await driver.value("SELECT 2") == "2")
            }
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func reconnectReportsLostSessionSettings(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await server.withDriver { admin in
                try await admin.run("DROP TABLE IF EXISTS it_ac")
                try await admin.run("CREATE TABLE it_ac (v INT) ENGINE=InnoDB")
                try await admin.run("INSERT INTO it_ac VALUES (1)")
                try await driver.run("SET autocommit = 0")
                let id = try #require(try await driver.value("SELECT CONNECTION_ID()"))
                try await admin.run("KILL \(id)")
                try await Task.sleep(for: .milliseconds(500))
                do {
                    try await driver.run("UPDATE it_ac SET v = 2")
                    Issue.record("reconnected silently with autocommit back on")
                } catch let error as DatabaseError {
                    #expect(error.detail?.contains("Session settings") == true)
                }
                #expect(try await admin.value("SELECT v FROM it_ac") == "1")
                #expect(try await driver.value("SELECT @@autocommit") == "1")

                // A user variable is session state too.
                try await driver.run("SET @guard = 'x'")
                let second = try #require(try await driver.value("SELECT CONNECTION_ID()"))
                try await admin.run("KILL \(second)")
                try await Task.sleep(for: .milliseconds(500))
                await #expect(throws: DatabaseError.self) { try await driver.run("SELECT @guard") }
                #expect(try await driver.value("SELECT 3") == "3")
                try await admin.run("DROP TABLE it_ac")
            }
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func requiredTLSRefusesAStrippedGreeting(_ server: MySQLTestServer) async throws {
        let proxy = try GreetingStripper(upstreamPort: server.port)
        var config = server.config(tls: .required)
        config.port = proxy.port
        do {
            let driver = try await MySQLDriver.connect(config: config, host: "127.0.0.1", port: proxy.port)
            await driver.close()
            Issue.record("signed in although the greeting didn't offer TLS")
        } catch let error as DatabaseError {
            #expect(error.message == "The server doesn't support TLS.")
        }
        // Nothing at all, in particular no HandshakeResponse with the login, reached the "server".
        #expect(proxy.bytesFromClient() == 0)
    }

    @Test(arguments: MySQLTestServer.all)
    func serializesConcurrentCalls(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            let values = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
                for index in 0..<25 {
                    group.addTask { (index, try await driver.value("SELECT \(index), SLEEP(0.01)")) }
                }
                return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            #expect(values.count == 25)
            #expect(values.allSatisfy { String($0.key) == $0.value })
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func reconnectsAfterServerDropsConnection(_ server: MySQLTestServer) async throws {
        try await server.withDriver { driver in
            try await server.withDriver { admin in
                let first = try #require(try await driver.value("SELECT CONNECTION_ID()"))
                try await driver.run("USE mysql")
                try await admin.run("KILL \(first)")
                try await Task.sleep(for: .milliseconds(500))
                let second = try #require(try await driver.value("SELECT CONNECTION_ID()"))
                #expect(second != first)
                #expect(try await driver.currentDatabase() == "mysql")

                // A transaction that dies with the connection is reported, not silently dropped.
                try await driver.run("START TRANSACTION")
                try await admin.run("KILL \(second)")
                try await Task.sleep(for: .milliseconds(500))
                do {
                    try await driver.run("SELECT 1")
                    Issue.record("lost transaction not reported")
                } catch let error as DatabaseError {
                    #expect(error.detail?.contains("rolled back") == true)
                }
                #expect(try await driver.value("SELECT 2") == "2")
            }
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func closeIsIdempotent(_ server: MySQLTestServer) async throws {
        let driver = try await server.connect()
        await driver.close()
        await driver.close()
        await #expect(throws: DatabaseError.self) { try await driver.execute("SELECT 1", maxRows: 1) }
        await driver.cancelCurrentQuery()
    }

    @Test(arguments: MySQLTestServer.all, [TLSMode.preferred, .required])
    func encryptsWithTLS(_ server: MySQLTestServer, mode: TLSMode) async throws {
        try await server.withDriver(tls: mode) { driver in
            let cipher = try await driver.execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'", maxRows: 1).rows.first?[1]
            #expect(cipher?.isEmpty == false)
        }
        try await server.withDriver(tls: .disabled) { driver in
            let cipher = try await driver.execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'", maxRows: 1).rows.first?[1]
            #expect(cipher == "")
        }
    }

    /// Needs a server started without TLS (e.g. `mariadb:11 --skip-ssl`) on DBEE_MYSQL_NOTLS_PORT.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBEE_MYSQL_NOTLS_PORT"] != nil))
    func serverWithoutTLS() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["DBEE_MYSQL_NOTLS_PORT"].flatMap { Int($0) })
        let server = MySQLTestServer(name: "No TLS", port: port, isMariaDB: true)
        for mode in [TLSMode.required, .verifyFull] {
            do {
                _ = try await server.connect(tls: mode)
                Issue.record("\(mode) connected without TLS")
            } catch let error as DatabaseError {
                #expect(error.message == "The server doesn't support TLS.")
            }
        }
        try await server.withDriver(tls: .preferred) { driver in
            let cipher = try await driver.execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'", maxRows: 1).rows.first?[1]
            #expect(cipher == "")
        }
    }

    @Test(arguments: MySQLTestServer.all)
    func passwordlessAccount(_ server: MySQLTestServer) async throws {
        try await server.withDriver { root in
            try await root.run("DROP USER IF EXISTS 'dbee_nopw'@'%'")
            try await root.run("CREATE USER 'dbee_nopw'@'%' IDENTIFIED BY ''")
            try await root.run("GRANT SELECT ON dbee.* TO 'dbee_nopw'@'%'")
        }
        try await server.withDriver(user: "dbee_nopw", password: "", tls: .preferred) { driver in
            let user = try await driver.value("SELECT CURRENT_USER()")
            #expect(user == "dbee_nopw@%")
        }
        if server.isMariaDB {
            // mysql_native_password: works without TLS too.
            try await server.withDriver(user: "dbee_nopw", password: "", tls: .disabled) { driver in
                let user = try await driver.value("SELECT CURRENT_USER()")
                #expect(user == "dbee_nopw@%")
            }
        } else {
            do {
                // Fails with MySQLNIO today; if a future version signs in, that's fine too.
                try await server.connect(user: "dbee_nopw", password: "", tls: .disabled).close()
            } catch let error as DatabaseError {
                #expect(error.detail?.contains("Set TLS to Preferred") == true)
            }
        }
        try await server.withDriver { root in try await root.run("DROP USER 'dbee_nopw'@'%'") }
    }

    @Test(.enabled(if: MySQLTestServer.mysql != nil))
    func verifyFullRejectsSelfSignedCertificate() async throws {
        let server = try #require(MySQLTestServer.mysql)
        var config = server.config(tls: .verifyFull)
        config.host = "localhost"
        do {
            _ = try await MySQLDriver.connect(config: config, host: "localhost", port: server.port)
            Issue.record("accepted a self-signed certificate")
        } catch let error as DatabaseError {
            #expect(error.message.contains("TLS"))
            #expect(error.detail?.contains("Required") == true)
        }
        // An IP address can't be checked against the certificate through the TLS relay.
        do {
            _ = try await server.connect(tls: .verifyFull)
            Issue.record("verified a certificate against an IP address")
        } catch let error as DatabaseError {
            #expect(error.message == "Verify Certificate needs the server's host name.")
        }
    }

    @Test(.enabled(if: MySQLTestServer.mysql != nil))
    func cachingSha2UserWithAndWithoutTLS() async throws {
        let server = try #require(MySQLTestServer.mysql)
        try await server.withDriver { root in
            try await root.run("CREATE USER IF NOT EXISTS 'dbee_sha2'@'%' IDENTIFIED WITH caching_sha2_password BY 'sha2 pw'")
            try await root.run("GRANT ALL ON dbee.* TO 'dbee_sha2'@'%'")
            #expect(try await root.value("SELECT plugin FROM mysql.user WHERE user = 'dbee_sha2'") == "caching_sha2_password")
            try await root.run("FLUSH PRIVILEGES") // empties the auth cache: next login does full authentication
        }
        // Full authentication without TLS: RSA key exchange.
        try await server.withDriver(user: "dbee_sha2", password: "sha2 pw") { driver in
            let user = try await driver.value("SELECT CURRENT_USER()")
            #expect(user == "dbee_sha2@%")
        }
        // Fast (cached) authentication.
        try await server.withDriver(user: "dbee_sha2", password: "sha2 pw") { driver in
            let one = try await driver.value("SELECT 1")
            #expect(one == "1")
        }
        try await server.withDriver { root in try await root.run("FLUSH PRIVILEGES") }
        // Full authentication over TLS.
        try await server.withDriver(user: "dbee_sha2", password: "sha2 pw", tls: .required) { driver in
            let user = try await driver.value("SELECT CURRENT_USER()")
            #expect(user == "dbee_sha2@%")
        }
        do {
            _ = try await server.connect(user: "dbee_sha2", password: "wrong", tls: .required)
            Issue.record("connected with a wrong password")
        } catch let error as DatabaseError {
            #expect(error.message.hasPrefix("Access denied for user 'dbee_sha2'"))
        }
    }
}

/// A one-connection TCP proxy that clears CLIENT_SSL in the server's greeting, as an attacker on the path would,
/// and counts what the client sends afterwards.
private final class GreetingStripper: @unchecked Sendable {
    let port: Int
    private let received = NSLock()
    private var count = 0
    private let finished = DispatchSemaphore(value: 0)

    init(upstreamPort: Int, strip: Bool = true) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw DatabaseError("proxy setup failed") }
        var length = size
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            defer { close(listener); finished.signal() }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let server = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(server) }
            var upstream = sockaddr_in()
            upstream.sin_family = sa_family_t(AF_INET)
            upstream.sin_addr.s_addr = inet_addr("127.0.0.1")
            upstream.sin_port = UInt16(upstreamPort).bigEndian
            let connected = withUnsafePointer(to: &upstream) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(server, $0, size) }
            }
            guard connected == 0 else { return }
            func readExactly(_ count: Int) -> [UInt8]? {
                var bytes = [UInt8](repeating: 0, count: count)
                var offset = 0
                while offset < count {
                    let n = bytes.withUnsafeMutableBytes { read(server, $0.baseAddress! + offset, count - offset) }
                    guard n > 0 else { return nil }
                    offset += n
                }
                return bytes
            }
            guard let header = readExactly(4),
                  var payload = readExactly(Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16),
                  let versionEnd = payload[1...].firstIndex(of: 0) else { return }
            // After the version: connection id (4), auth data (8), filler (1), then the lower capability flags,
            // little-endian. CLIENT_SSL is 0x0800, so 0x08 in the second byte.
            if strip { payload[versionEnd + 15] &= ~0x08 }
            let packet = header + payload
            _ = packet.withUnsafeBytes { write(client, $0.baseAddress!, packet.count) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress!, 4096) }
                guard n > 0 else { break }
                self.received.withLock { self.count += n }
            }
        }
    }

    /// Waits for the client's side to finish, then returns how many bytes it sent after the greeting.
    func bytesFromClient() -> Int {
        _ = finished.wait(timeout: .now() + 10)
        return received.withLock { count }
    }
}
