import Foundation
import Testing
@testable import Dbee

// Integration tests run against a real server and are skipped unless DBEE_CLICKHOUSE_PORT is set:
//   docker run -d --name dbee-it-clickhouse -e CLICKHOUSE_USER=dbee -e CLICKHOUSE_PASSWORD=dbee_test \
//     -e CLICKHOUSE_DB=dbee -p 127.0.0.1:58123:8123 clickhouse/clickhouse-server:24.8
//   DBEE_CLICKHOUSE_PORT=58123 swift test --filter ClickHouse

private enum ClickHouseIT {
    static let port = ProcessInfo.processInfo.environment["DBEE_CLICKHOUSE_PORT"].flatMap(Int.init)
    static let password = ProcessInfo.processInfo.environment["DBEE_CLICKHOUSE_PASSWORD"] ?? "dbee_test"

    static func config(password: String = ClickHouseIT.password, database: String = "dbee") -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .clickhouse
        config.host = "127.0.0.1"
        config.port = port ?? 8123
        config.username = "dbee"
        config.password = password
        config.database = database
        config.tls = .disabled
        return config
    }

    static func withDriver<T>(_ config: ConnectionConfig = config(), _ body: (ClickHouseDriver) async throws -> T) async throws -> T {
        let driver = try await ClickHouseDriver.connect(config: config, host: config.host, port: config.port)
        do {
            _ = try await driver.execute("DROP DATABASE IF EXISTS dbee_it", maxRows: 1)
            _ = try await driver.execute("CREATE DATABASE dbee_it", maxRows: 1)
            _ = try await driver.execute("USE dbee_it", maxRows: 1)
            let result = try await body(driver)
            _ = try? await driver.execute("DROP DATABASE IF EXISTS dbee_it", maxRows: 1)
            await driver.close()
            return result
        } catch {
            await driver.close()
            throw error
        }
    }
}

@Suite("ClickHouse integration", .serialized, .enabled(if: ClickHouseIT.port != nil, "set DBEE_CLICKHOUSE_PORT to run"),
       .timeLimit(.minutes(2)))
struct ClickHouseIntegrationTests {
    @Test func connectsAndDescribesServer() async throws {
        let config = ClickHouseIT.config()
        let driver = try await ClickHouseDriver.connect(config: config, host: config.host, port: config.port)
        defer { Task { await driver.close() } }
        #expect(try await driver.serverVersion().hasPrefix("ClickHouse 2"))
        #expect(try await driver.currentDatabase() == "dbee")
        let databases = try await driver.listDatabases()
        #expect(databases.contains("dbee"))
        #expect(databases.contains("default"))
        #expect(!databases.contains("system"))
    }

    @Test func refusesAWrongPasswordAndAMissingDatabase() async throws {
        let wrong = ClickHouseIT.config(password: "wrong")
        await #expect {
            try await ClickHouseDriver.connect(config: wrong, host: wrong.host, port: wrong.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "ClickHouse refused the login."
        }
        let missing = ClickHouseIT.config(database: "no_such_db")
        await #expect {
            try await ClickHouseDriver.connect(config: missing, host: missing.host, port: missing.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "Couldn't open database “no_such_db”."
        }
    }

    @Test func createsQueriesAndDescribesTables() async throws {
        try await ClickHouseIT.withDriver { driver in
            #expect(try await driver.currentDatabase() == "dbee_it")
            _ = try await driver.execute("""
                CREATE TABLE events (
                    id UInt64,
                    name String COMMENT 'who',
                    score Nullable(Float64),
                    tags Array(String),
                    at DateTime DEFAULT now(),
                    INDEX name_idx name TYPE bloom_filter GRANULARITY 1
                ) ENGINE = MergeTree ORDER BY (id, name)
                """, maxRows: 1)
            _ = try await driver.execute("CREATE VIEW recent AS SELECT id, name FROM events", maxRows: 1)
            let insert = try await driver.execute("""
                INSERT INTO events (id, name, score, tags) VALUES
                (1, 'Ada', 9.5, ['a', 'b']), (2, 'tab\\there\\nnewline', NULL, []), (3, 'it''s', 1, ['x'])
                """, maxRows: 1)
            #expect(!insert.isRowSet)
            #expect(insert.rowsAffected == 3)

            let select = try await driver.execute("SELECT id, name, score, tags FROM events ORDER BY id", maxRows: 100)
            #expect(select.columns == ["id", "name", "score", "tags"])
            #expect(select.rows == [
                ["1", "Ada", "9.5", "['a','b']"],
                ["2", "tab\there\nnewline", nil, "[]"],
                ["3", "it's", "1", "['x']"],
            ])
            let empty = try await driver.execute("SELECT id FROM events WHERE id > 10", maxRows: 10)
            #expect(empty.isRowSet)
            #expect(empty.rows.isEmpty)

            let schemas = try await driver.listSchemas()
            #expect(schemas.map(\.name) == ["dbee_it"])
            #expect(schemas[0].tables.map(\.ref.name) == ["events", "recent"])
            #expect(schemas[0].tables.map(\.kind) == [.table, .view])

            let structure = try await driver.tableStructure(TableRef(schema: nil, name: "events"))
            #expect(structure.columns.map(\.name) == ["id", "name", "score", "tags", "at"])
            #expect(structure.columns.map(\.dataType) == ["UInt64", "String", "Nullable(Float64)", "Array(String)", "DateTime"])
            #expect(structure.primaryKey == ["id", "name"])
            #expect(structure.columns[1].comment == "who")
            #expect(structure.columns[2].isNullable)
            #expect(structure.columns[4].defaultValue == "now()")
            #expect(structure.indexes.contains { $0.isPrimary && $0.columns == ["id", "name"] })
            #expect(structure.indexes.contains { $0.name == "name_idx" })
            #expect(structure.ddl?.hasPrefix("CREATE TABLE dbee_it.events") == true)
        }
    }

    @Test func browsesWithGeneratedSQL() async throws {
        try await ClickHouseIT.withDriver { driver in
            _ = try await driver.execute("CREATE TABLE t (id UInt32, label String) ENGINE = MergeTree ORDER BY id", maxRows: 1)
            _ = try await driver.execute("INSERT INTO t SELECT number, toString(number * 2) FROM numbers(25)", maxRows: 1)
            let dialect = SQLDialect(kind: .clickhouse)
            let table = TableRef(schema: nil, name: "t")
            let sql = dialect.selectPage(table, filter: "id >= 10", sort: GridSort(column: "id", ascending: false), limit: 5, offset: 5)
            let page = try await driver.execute(sql, maxRows: 5)
            #expect(page.rows.map { $0[0] } == ["19", "18", "17", "16", "15"])
            let count = try await driver.execute(dialect.count(table, filter: "id >= 10"), maxRows: 1)
            #expect(count.rows == [["15"]])
            // String comparisons against a number column, and LIKE on its text, as the filter bar writes them.
            let equal = try await driver.execute("SELECT id FROM t WHERE id = \(dialect.literal("7"))", maxRows: 5)
            #expect(equal.rows == [["7"]])
            let like = try await driver.execute("SELECT id FROM t WHERE toString(id) LIKE '2%' ORDER BY id", maxRows: 5)
            #expect(like.rows == [["2"], ["20"], ["21"], ["22"], ["23"]])
        }
    }

    @Test func quotesAwkwardNames() async throws {
        try await ClickHouseIT.withDriver { driver in
            let dialect = SQLDialect(kind: .clickhouse)
            let name = "we`ird\\name"
            _ = try await driver.execute("CREATE TABLE \(dialect.quoteIdentifier(name)) (v String) ENGINE = Memory", maxRows: 1)
            _ = try await driver.execute("INSERT INTO \(dialect.quoteIdentifier(name)) VALUES (\(dialect.literal("a'b\\c\0d")))", maxRows: 1)
            let rows = try await driver.execute("SELECT v FROM \(dialect.quoteIdentifier(name))", maxRows: 1).rows
            #expect(rows == [["a'b\\c\0d"]])
            #expect(try await driver.listSchemas()[0].tables.map(\.ref.name) == [name])
            #expect(try await driver.tableStructure(TableRef(schema: nil, name: name)).columns.map(\.name) == ["v"])
        }
    }

    @Test func stopsAtTheRowLimitAndKeepsTheSession() async throws {
        try await ClickHouseIT.withDriver { driver in
            _ = try await driver.execute("SET max_threads = 1", maxRows: 1)
            _ = try await driver.execute("CREATE TEMPORARY TABLE scratch (n UInt8)", maxRows: 1)
            let big = try await driver.execute("SELECT number FROM numbers(10000000)", maxRows: 10)
            #expect(big.rows.count == 10)
            #expect(big.truncated)
            // The rest of that result was abandoned; the session (settings, temporary tables) carries on.
            let setting = try await driver.execute("SELECT getSetting('max_threads')", maxRows: 1)
            #expect(setting.rows == [["1"]])
            _ = try await driver.execute("INSERT INTO scratch VALUES (7)", maxRows: 1)
            #expect(try await driver.execute("SELECT n FROM scratch", maxRows: 1).rows == [["7"]])
            let exact = try await driver.execute("SELECT number FROM numbers(10)", maxRows: 10)
            #expect(exact.rows.count == 10)
            #expect(!exact.truncated)
        }
    }

    @Test func reportsErrors() async throws {
        try await ClickHouseIT.withDriver { driver in
            await #expect {
                try await driver.execute("SELECT * FROM no_such_table", maxRows: 1)
            } throws: { error in
                let error = error as? DatabaseError
                return error?.message.contains("no_such_table") == true && error?.detail?.contains("UNKNOWN_TABLE") == true
            }
            // An error after rows were already sent.
            await #expect {
                try await driver.execute("SELECT throwIf(number = 100000, 'boom') FROM numbers(200000)", maxRows: 1_000_000)
            } throws: { error in
                (error as? DatabaseError)?.message.hasPrefix("boom") == true
            }
            let after = try await driver.execute("SELECT 1", maxRows: 1)
            #expect(after.rows == [["1"]])
        }
    }

    @Test func switchesDatabases() async throws {
        try await ClickHouseIT.withDriver { driver in
            _ = try await driver.execute("USE `default`", maxRows: 1)
            #expect(try await driver.currentDatabase() == "default")
            #expect(try await driver.execute("SELECT currentDatabase()", maxRows: 1).rows == [["default"]])
            _ = try await driver.execute("USE dbee_it", maxRows: 1)
            _ = try await driver.execute("DROP DATABASE dbee_it", maxRows: 1)
            #expect(try await driver.currentDatabase() == "default")
        }
    }

    @Test func stopsARunningQuery() async throws {
        try await ClickHouseIT.withDriver { driver in
            let running = Task { try await driver.execute("SELECT count() FROM numbers(100000000000)", maxRows: 1) }
            try await Task.sleep(for: .milliseconds(500))
            await driver.cancelCurrentQuery()
            await #expect(throws: (any Error).self) { try await running.value }
            let after = try await driver.execute("SELECT 2", maxRows: 1)
            #expect(after.rows == [["2"]])
        }
    }
}
