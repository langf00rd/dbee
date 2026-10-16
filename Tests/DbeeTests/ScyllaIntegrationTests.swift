import Foundation
import Testing
@testable import Dbee

// Integration tests run against a real server and are skipped unless DBEE_SCYLLA_PORT is set:
//   docker run -d --name dbee-it-scylla -p 127.0.0.1:59042:9042 scylladb/scylla:6.2 \
//     --smp 1 --memory 750M --overprovisioned 1 --authenticator PasswordAuthenticator
//   DBEE_SCYLLA_PORT=59042 swift test --filter Scylla
// They log in as the default superuser (cassandra / cassandra) and drop the keyspace dbee_it.

private enum ScyllaIT {
    static let port = ProcessInfo.processInfo.environment["DBEE_SCYLLA_PORT"].flatMap(Int.init)
    static let username = ProcessInfo.processInfo.environment["DBEE_SCYLLA_USER"] ?? "cassandra"
    static let password = ProcessInfo.processInfo.environment["DBEE_SCYLLA_PASSWORD"] ?? "cassandra"

    static func config(username: String = ScyllaIT.username, password: String = ScyllaIT.password,
                       keyspace: String = "") -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .scylla
        config.host = "127.0.0.1"
        config.port = port ?? 9042
        config.username = username
        config.password = password
        config.database = keyspace
        config.tls = .disabled
        return config
    }

    static func withDriver<T>(_ body: (ScyllaDriver) async throws -> T) async throws -> T {
        let config = config()
        let driver = try await ScyllaDriver.connect(config: config, host: config.host, port: config.port)
        do {
            _ = try await driver.execute("DROP KEYSPACE IF EXISTS dbee_it", maxRows: 1)
            _ = try await driver.execute(
                "CREATE KEYSPACE dbee_it WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}", maxRows: 1)
            _ = try await driver.execute("USE dbee_it", maxRows: 1)
            let result = try await body(driver)
            await driver.close()
            return result
        } catch {
            await driver.close()
            throw error
        }
    }
}

@Suite("ScyllaDB integration", .serialized, .enabled(if: ScyllaIT.port != nil, "set DBEE_SCYLLA_PORT to run"),
       .timeLimit(.minutes(3)))
struct ScyllaIntegrationTests {
    @Test func connectsAndRefusesBadLogins() async throws {
        let config = ScyllaIT.config()
        let driver = try await ScyllaDriver.connect(config: config, host: config.host, port: config.port)
        #expect(try await driver.serverVersion().hasPrefix("ScyllaDB "))
        #expect(try await driver.listDatabases().allSatisfy { !$0.hasPrefix("system") })
        await driver.close()

        let wrong = ScyllaIT.config(password: "wrong")
        await #expect {
            try await ScyllaDriver.connect(config: wrong, host: wrong.host, port: wrong.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "The server refused the login."
        }
        let anonymous = ScyllaIT.config(username: "", password: "")
        await #expect {
            try await ScyllaDriver.connect(config: anonymous, host: anonymous.host, port: anonymous.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "The server needs a user name and password."
        }
        let missing = ScyllaIT.config(keyspace: "no_such_keyspace")
        await #expect {
            try await ScyllaDriver.connect(config: missing, host: missing.host, port: missing.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "Couldn't open keyspace “no_such_keyspace”."
        }
    }

    @Test func formatsValuesLikeCqlsh() async throws {
        try await ScyllaIT.withDriver { driver in
            #expect(try await driver.currentDatabase() == "dbee_it")
            _ = try await driver.execute("CREATE TYPE address (street text, zip int)", maxRows: 1)
            _ = try await driver.execute("""
                CREATE TABLE everything (
                    id int PRIMARY KEY, b bigint, s smallint, t tinyint, v varint, d decimal, f float, db double,
                    ok boolean, name text, raw blob, u uuid, tu timeuuid, at timestamp, day date, clock time,
                    ip inet, ip6 inet, span duration, tags list<text>, scores map<text, int>, nums set<int>,
                    pair tuple<int, text>, home frozen<address>
                )
                """, maxRows: 1)
            _ = try await driver.execute("""
                INSERT INTO everything (id, b, s, t, v, d, f, db, ok, name, raw, u, tu, at, day, clock, ip, ip6, span,
                    tags, scores, nums, pair, home)
                VALUES (1, -9000000000, -5, 7, 123456789012345678901234567890, -12.345, 1.5, 2.25, true, 'it''s',
                    0xcafe, 2c1f6f4a-6f7e-4d6e-9a1c-2b7c1e7c4f00, 50554d6e-29bb-11e5-b345-feff819cdc9f,
                    '2024-03-01 12:34:56.789+0000', '1969-07-20', '13:45:00.000000123', '10.0.0.1', '::1', 1y2mo3d4h5m6s,
                    ['a', 'b''c'], {'x': 1, 'y': 2}, {3, 1, 2}, (7, 'seven'), {street: 'Main', zip: 12345})
                """, maxRows: 1)
            _ = try await driver.execute("INSERT INTO everything (id) VALUES (2)", maxRows: 1)
            let result = try await driver.execute("SELECT * FROM everything WHERE id = 1", maxRows: 10)
            func value(_ column: String) -> CellValue {
                result.rows.first?[result.columns.firstIndex(of: column)!] ?? nil
            }
            #expect(result.columns.first == "id")
            #expect(value("b") == "-9000000000")
            #expect(value("s") == "-5")
            #expect(value("t") == "7")
            #expect(value("v") == "123456789012345678901234567890")
            #expect(value("d") == "-12.345")
            #expect(value("f") == "1.5")
            #expect(value("db") == "2.25")
            #expect(value("ok") == "true")
            #expect(value("name") == "it's")
            #expect(value("raw") == "0xcafe")
            #expect(value("u") == "2c1f6f4a-6f7e-4d6e-9a1c-2b7c1e7c4f00")
            #expect(value("tu") == "50554d6e-29bb-11e5-b345-feff819cdc9f")
            #expect(value("at") == "2024-03-01 12:34:56.789Z")
            #expect(value("day") == "1969-07-20")
            #expect(value("clock") == "13:45:00.000000123")
            #expect(value("ip") == "10.0.0.1")
            #expect(value("ip6") == "::1")
            #expect(value("span") == "1y2mo3d4h5m6s")
            #expect(value("tags") == "['a', 'b''c']")
            #expect(value("scores") == "{'x': 1, 'y': 2}")
            #expect(value("nums") == "{1, 2, 3}")
            #expect(value("pair") == "(7, 'seven')")
            #expect(value("home") == "{street: 'Main', zip: 12345}")

            let empty = try await driver.execute("SELECT name, tags FROM everything WHERE id = 2", maxRows: 10)
            #expect(empty.rows == [[nil, nil]])
        }
    }

    @Test func describesKeyspacesAndTables() async throws {
        try await ScyllaIT.withDriver { driver in
            _ = try await driver.execute("""
                CREATE TABLE readings (sensor text, day date, at timestamp, value double, unit text static,
                    PRIMARY KEY ((sensor, day), at)) WITH CLUSTERING ORDER BY (at DESC)
                """, maxRows: 1)
            _ = try await driver.execute("CREATE INDEX readings_value ON readings (value)", maxRows: 1)
            _ = try await driver.execute("""
                CREATE MATERIALIZED VIEW by_value AS SELECT sensor, day, at, value FROM readings
                WHERE value IS NOT NULL AND sensor IS NOT NULL AND day IS NOT NULL AND at IS NOT NULL
                PRIMARY KEY (value, sensor, day, at)
                """, maxRows: 1)
            #expect(try await driver.listDatabases().contains("dbee_it"))
            let schemas = try await driver.listSchemas()
            #expect(schemas.map(\.name) == ["dbee_it"])
            #expect(schemas[0].tables.map(\.ref.name) == ["by_value", "readings"])
            #expect(schemas[0].tables.map(\.kind) == [.materializedView, .table])

            let structure = try await driver.tableStructure(TableRef(schema: nil, name: "readings"))
            #expect(structure.columns.map(\.name) == ["sensor", "day", "at", "unit", "value"])
            #expect(structure.primaryKey == ["sensor", "day", "at"])
            #expect(structure.columns[2].comment == "Clustering column (DESC)")
            #expect(structure.columns[3].comment == "Static")
            #expect(structure.indexes.first?.definition == "PRIMARY KEY ((sensor, day), at)")
            #expect(structure.indexes.contains { $0.name == "readings_value" && $0.columns == ["value"] })
            #expect(structure.ddl?.contains("CREATE TABLE dbee_it.readings") == true)
        }
    }

    @Test func pagesThroughATable() async throws {
        try await ScyllaIT.withDriver { driver in
            _ = try await driver.execute("CREATE TABLE items (id int PRIMARY KEY, even boolean)", maxRows: 1)
            for id in 0..<25 {
                _ = try await driver.execute("INSERT INTO items (id, even) VALUES (\(id), \(id % 2 == 0))", maxRows: 1)
            }
            let table = TableRef(schema: nil, name: "items")
            var seen: [CellValue] = []
            for page in 0..<3 {
                let result = try await driver.page(of: table, filter: nil, sort: nil, limit: 10, offset: page * 10)
                #expect(result.rows.count == (page < 2 ? 10 : 5))
                seen += result.rows.map { $0[0] }
            }
            #expect(Set(seen).count == 25)
            #expect(try await driver.count(of: table, filter: nil) == 25)
            // Jumping straight to the last page walks there from the first.
            _ = try await driver.page(of: table, filter: "even = true", sort: nil, limit: 5, offset: 0)
            let last = try await driver.page(of: table, filter: "even = true", sort: GridSort(column: "id", ascending: true),
                                             limit: 5, offset: 10)
            #expect(last.rows.count == 3)
            let ids: [Int] = last.rows.compactMap { $0[0].flatMap { Int($0) } }
            #expect(ids == ids.sorted())
            #expect(try await driver.count(of: table, filter: "even = true") == 13)
            let past = try await driver.page(of: table, filter: nil, sort: nil, limit: 10, offset: 30)
            #expect(past.rows.isEmpty)

            let filter = TableBrowserModel.cqlFilter(for: .init(column: "id", op: .in, value: "3, 4"), type: "int")
            let picked = try await driver.page(of: table, filter: filter, sort: nil, limit: 10, offset: 0)
            #expect(Set(picked.rows.map { $0[0] }) == ["3", "4"])
        }
    }

    @Test func runsStatements() async throws {
        try await ScyllaIT.withDriver { driver in
            _ = try await driver.execute("CREATE TABLE kv (k text PRIMARY KEY, v int)", maxRows: 1)
            let script = """
                BEGIN BATCH
                  INSERT INTO kv (k, v) VALUES ('a', 1);
                  INSERT INTO kv (k, v) VALUES ('b', 2);
                APPLY BATCH;
                SELECT k, v FROM kv
                """
            let statements = SQLSplitter.split(script, kind: .scylla)
            #expect(statements.count == 2)
            for statement in statements.dropLast() { _ = try await driver.execute(statement.text, maxRows: 10) }
            let rows = try await driver.execute(statements.last!.text, maxRows: 10).rows
            #expect(Set(rows) == [["a", "1"], ["b", "2"]])

            let limited = try await driver.execute("SELECT * FROM kv", maxRows: 1)
            #expect(limited.rows.count == 1)
            #expect(limited.truncated)

            let lwt = try await driver.execute("INSERT INTO kv (k, v) VALUES ('a', 9) IF NOT EXISTS", maxRows: 10)
            #expect(lwt.columns.first == "[applied]")
            #expect(lwt.rows.first?.first == "false")

            #expect(try await driver.execute("CONSISTENCY", maxRows: 1).rows == [["ONE"]])
            #expect(try await driver.execute("CONSISTENCY quorum", maxRows: 1).rows == [["QUORUM"]])
            await #expect {
                try await driver.execute("CONSISTENCY sometimes", maxRows: 1)
            } throws: { error in
                (error as? DatabaseError)?.message == "“SOMETIMES” isn't a consistency level."
            }
            await #expect {
                try await driver.execute("SELEC * FROM kv", maxRows: 1)
            } throws: { error in
                (error as? DatabaseError)?.detail == "Syntax error"
            }
            let after = try await driver.execute("SELECT v FROM kv WHERE k = 'b'", maxRows: 1)
            #expect(after.rows == [["2"]])
        }
    }

    @Test func switchesKeyspaces() async throws {
        try await ScyllaIT.withDriver { driver in
            try await driver.useDatabase("system_schema")
            #expect(try await driver.currentDatabase() == "system_schema")
            _ = try await driver.execute("USE dbee_it", maxRows: 1)
            #expect(try await driver.currentDatabase() == "dbee_it")
            _ = try await driver.execute("DROP KEYSPACE dbee_it", maxRows: 1)
            #expect(try await driver.currentDatabase() == "")
            #expect(try await driver.listSchemas().isEmpty)
        }
    }

    @Test func stopsARunningQuery() async throws {
        try await ScyllaIT.withDriver { driver in
            _ = try await driver.execute("CREATE TABLE n (id int PRIMARY KEY)", maxRows: 1)
            let running = Task { try await driver.execute("SELECT * FROM n", maxRows: 1) }
            await driver.cancelCurrentQuery()
            _ = try? await running.value
            // Whether or not Stop caught the query, the next one reconnects into the same keyspace.
            let after = try await driver.execute("SELECT * FROM n", maxRows: 1)
            #expect(after.columns == ["id"])
        }
    }
}
