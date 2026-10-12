import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing
@testable import Dbee

// Integration tests run against a real server and are skipped unless DBEE_PG_PORT is set:
//   docker run -d --name dbee-it-postgres -e POSTGRES_PASSWORD=dbee_test -p 127.0.0.1:55432:5432 postgres:16
//   DBEE_PG_PORT=55432 swift test --filter Postgres

private enum PG {
    static let port = ProcessInfo.processInfo.environment["DBEE_PG_PORT"].flatMap(Int.init)
    static let password = ProcessInfo.processInfo.environment["DBEE_PG_PASSWORD"] ?? "dbee_test"

    static func config(password: String = PG.password, database: String = "postgres", tls: TLSMode = .disabled) -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .postgres
        config.host = "127.0.0.1"
        config.port = port ?? 5432
        config.username = "postgres"
        config.password = password
        config.database = database
        config.tls = tls
        return config
    }

    static func connect(_ config: ConnectionConfig = config()) async throws -> PostgresDriver {
        try await PostgresDriver.connect(config: config, host: config.host, port: config.port)
    }

    static func withDriver<T>(_ config: ConnectionConfig = config(), _ body: (PostgresDriver) async throws -> T) async throws -> T {
        let driver = try await connect(config)
        do {
            let result = try await body(driver)
            await driver.close()
            return result
        } catch {
            await driver.close()
            throw error
        }
    }

    static func message(of error: any Error) -> String {
        if let error = error as? DatabaseError {
            return [error.message, error.detail].compactMap { $0 }.joined(separator: "\n")
        }
        return String(describing: error)
    }
}

extension PostgresDriver {
    @discardableResult
    fileprivate func run(_ sql: String, maxRows: Int = 1000) async throws -> QueryResult {
        try await execute(sql, maxRows: maxRows)
    }

    fileprivate func value(_ sql: String) async throws -> String? {
        try await execute(sql, maxRows: 1).rows.first?.first ?? nil
    }
}

@Suite("Postgres integration", .serialized, .enabled(if: PG.port != nil, "set DBEE_PG_PORT to run"), .timeLimit(.minutes(2)))
struct PostgresIntegrationTests {
    @Test func connectsAndDescribesServer() async throws {
        try await PG.withDriver { driver in
            let version = try await driver.serverVersion()
            #expect(version.hasPrefix("PostgreSQL 16."))
            #expect(!version.contains("Debian"))
            #expect(try await driver.currentDatabase() == "postgres")
            let databases = try await driver.listDatabases()
            #expect(databases.contains("postgres"))
            #expect(!databases.contains("template0"))
            #expect(!databases.contains("template1"))
        }
    }

    @Test func emptyDatabaseNameUsesUsername() async throws {
        try await PG.withDriver(PG.config(database: "")) { driver in
            let database = try await driver.currentDatabase()
            #expect(database == "postgres")
        }
    }

    @Test func wrongPasswordReadsLikePsql() async throws {
        do {
            let driver = try await PG.connect(PG.config(password: "definitely-wrong"))
            await driver.close()
            Issue.record("connected with a wrong password")
        } catch let error as DatabaseError {
            #expect(error.message == #"password authentication failed for user "postgres""#)
            #expect(error.detail?.contains("SQLSTATE 28P01") == true)
            #expect(!PG.message(of: error).contains("PSQLError"))
        }
    }

    @Test func refusedConnectionHasClearError() async throws {
        var config = PG.config()
        config.port = 1
        do {
            let driver = try await PG.connect(config)
            await driver.close()
            Issue.record("connected to port 1")
        } catch let error as DatabaseError {
            #expect(error.message == "Couldn't connect to 127.0.0.1:1.")
            #expect(error.detail == "Connection refused")
        }
    }

    @Test func preferredTLSFallsBackOnPlainServer() async throws {
        try await PG.withDriver(PG.config(tls: .preferred)) { driver in
            let value = try await driver.value("SELECT 1")
            #expect(value == "1")
        }
    }

    @Test func requiredTLSFailsOnPlainServer() async throws {
        do {
            let driver = try await PG.connect(PG.config(tls: .required))
            await driver.close()
            Issue.record("connected with TLS required to a server without TLS")
        } catch let error as DatabaseError {
            #expect(error.message == "The server doesn't support TLS.")
        }
    }

    @Test func valuesComeBackAsPostgresText() async throws {
        try await PG.withDriver { driver in
            try await driver.run("DROP SCHEMA IF EXISTS dbee_types CASCADE")
            try await driver.run("CREATE SCHEMA dbee_types")
            try await driver.run("CREATE TYPE dbee_types.mood AS ENUM ('happy', 'sad')")
            try await driver.run("CREATE TYPE dbee_types.pair AS (a int, b text)")
            try await driver.run("SET TimeZone = 'UTC'")

            let cases: [(String, String?)] = [
                ("1::int2", "1"),
                ("2147483647::int4", "2147483647"),
                ("9223372036854775807::int8", "9223372036854775807"),
                ("123456789012345678901234567890.123456789::numeric", "123456789012345678901234567890.123456789"),
                ("1.50::numeric(10,2)", "1.50"),
                ("'NaN'::numeric", "NaN"),
                ("3.14::float8", "3.14"),
                ("0.1::float8 + 0.2::float8", "0.30000000000000004"),
                ("1.5::float4", "1.5"),
                ("true", "t"),
                ("false", "f"),
                ("'héllo ✓'::text", "héllo ✓"),
                ("'a'::char(3)", "a  "),
                ("'x'::varchar(5)", "x"),
                ("'2024-01-02 03:04:05.678+00'::timestamptz", "2024-01-02 03:04:05.678+00"),
                ("'2024-01-02 03:04:05'::timestamp", "2024-01-02 03:04:05"),
                ("'2024-02-29'::date", "2024-02-29"),
                ("'13:14:15'::time", "13:14:15"),
                ("'13:14:15+02'::timetz", "13:14:15+02"),
                ("'1 year 2 mons 3 days 04:05:06'::interval", "1 year 2 mons 3 days 04:05:06"),
                ("interval '90 minutes'", "01:30:00"),
                ("ARRAY[1, 2, 3]", "{1,2,3}"),
                ("ARRAY['a b', 'c', NULL]", #"{"a b",c,NULL}"#),
                ("'{{1,2},{3,4}}'::int[]", "{{1,2},{3,4}}"),
                (#"'{"b": 1, "a": [1, 2]}'::json"#, #"{"b": 1, "a": [1, 2]}"#),
                (#"'{"b":1,"a":2}'::jsonb"#, #"{"a": 2, "b": 1}"#),
                ("'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"),
                (#"'\xdeadbeef'::bytea"#, #"\xdeadbeef"#),
                ("'happy'::dbee_types.mood", "happy"),
                ("ROW(1, 'x y')::dbee_types.pair", #"(1,"x y")"#),
                ("ARRAY['sad'::dbee_types.mood]", "{sad}"),
                ("'192.168.0.1/24'::inet", "192.168.0.1/24"),
                ("'08:00:2b:01:02:03'::macaddr", "08:00:2b:01:02:03"),
                ("point(1.5, 2)", "(1.5,2)"),
                ("int4range(1, 5)", "[1,5)"),
                ("B'1010'::bit(4)", "1010"),
                ("'a fat cat'::tsvector", "'a' 'cat' 'fat'"),
                ("'<a>x</a>'::xml", "<a>x</a>"),
                ("'pg_class'::regclass", "pg_class"),
                ("NULL::int", nil),
                ("NULL::text", nil),
                ("''::text", ""),
            ]
            let sql = "SELECT " + cases.map(\.0).joined(separator: ", ")
            let result = try await driver.run(sql)
            #expect(result.columns.count == cases.count)
            #expect(result.rows.count == 1)
            let row = result.rows.first ?? []
            for (index, (expression, expected)) in cases.enumerated() where index < row.count {
                #expect(row[index] == expected, "\(expression)")
            }
            try await driver.run("DROP SCHEMA dbee_types CASCADE")
        }
    }

    @Test func statementsReportRowsAffected() async throws {
        try await PG.withDriver { driver in
            try await driver.run("DROP SCHEMA IF EXISTS dbee_dml CASCADE")
            let create = try await driver.run("CREATE SCHEMA dbee_dml")
            #expect(create.columns.isEmpty)
            #expect(create.rowsAffected == nil)
            try await driver.run("CREATE TABLE dbee_dml.t (id int PRIMARY KEY, v text)")
            #expect(try await driver.run("INSERT INTO dbee_dml.t SELECT g, 'v' || g FROM generate_series(1, 5) g").rowsAffected == 5)
            #expect(try await driver.run("UPDATE dbee_dml.t SET v = 'x' WHERE id <= 3").rowsAffected == 3)
            #expect(try await driver.run("DELETE FROM dbee_dml.t WHERE id > 3").rowsAffected == 2)

            let select = try await driver.run("SELECT * FROM dbee_dml.t ORDER BY id")
            #expect(select.columns == ["id", "v"])
            #expect(select.rows == [["1", "x"], ["2", "x"], ["3", "x"]])
            #expect(select.rowsAffected == 3)
            #expect(!select.truncated)
            #expect(select.duration > 0)

            let returning = try await driver.run("INSERT INTO dbee_dml.t VALUES (10, NULL), (11, 'b') RETURNING id, v")
            #expect(returning.columns == ["id", "v"])
            #expect(returning.rows == [["10", nil], ["11", "b"]])
            #expect(returning.rowsAffected == 2)

            #expect(try await driver.run("CREATE TABLE dbee_dml.c AS SELECT * FROM dbee_dml.t").rowsAffected == 5)
            #expect(try await driver.run("EXPLAIN SELECT * FROM dbee_dml.t").columns == ["QUERY PLAN"])
            #expect(try await driver.run("SHOW search_path").columns == ["search_path"])
            #expect(try await driver.run("SET search_path TO dbee_dml, public").rowsAffected == nil)
            #expect(try await driver.value("SELECT count(*) FROM c") == "5")
            try await driver.run("VACUUM dbee_dml.t")
            let empty = try await driver.run("-- nothing to run")
            #expect(empty.columns.isEmpty)
            try await driver.run("DROP SCHEMA dbee_dml CASCADE")
        }
    }

    @Test func repeatedColumnNamesAreKept() async throws {
        try await PG.withDriver { driver in
            let result = try await driver.run("SELECT 1 AS a, 2 AS a, 3, 'x' AS a")
            #expect(result.columns == ["a", "a", "?column?", "a"])
            #expect(result.rows == [["1", "2", "3", "x"]])
        }
    }

    @Test func maxRowsIsEnforcedByTheServer() async throws {
        try await PG.withDriver { driver in
            // Never terminates on its own; only works if the server stops after maxRows + 1 rows.
            let endless = try await driver.run("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT n FROM r", maxRows: 10)
            #expect(endless.rows.count == 10)
            #expect(endless.rows.last == ["10"])
            #expect(endless.truncated)

            let exact = try await driver.run("SELECT g FROM generate_series(1, 100) g", maxRows: 100)
            #expect(exact.rows.count == 100)
            #expect(!exact.truncated)
            #expect(exact.rowsAffected == 100)

            let oneOver = try await driver.run("SELECT g FROM generate_series(1, 101) g", maxRows: 100)
            #expect(oneOver.rows.count == 100)
            #expect(oneOver.truncated)

            let unlimited = try await driver.run("SELECT g FROM generate_series(1, 5000) g", maxRows: 0)
            #expect(unlimited.rows.count == 5000)

            // A suspended portal inside a transaction must not break the transaction.
            try await driver.run("BEGIN")
            #expect(try await driver.run("SELECT g FROM generate_series(1, 1000) g", maxRows: 5).truncated)
            #expect(try await driver.value("SELECT 42") == "42")
            try await driver.run("COMMIT")
            #expect(try await driver.value("SELECT 'still fine'") == "still fine")
        }
    }

    @Test func listsSchemasAndDescribesTables() async throws {
        try await PG.withDriver { driver in
            for statement in [
                "DROP SCHEMA IF EXISTS dbee_it CASCADE",
                "DROP SCHEMA IF EXISTS dbee_empty CASCADE",
                "CREATE SCHEMA dbee_it",
                "CREATE SCHEMA dbee_empty",
                "CREATE TABLE dbee_it.customers (id serial PRIMARY KEY, email text NOT NULL UNIQUE, name varchar(100))",
                "COMMENT ON TABLE dbee_it.customers IS 'People who buy things'",
                "COMMENT ON COLUMN dbee_it.customers.email IS 'Login e-mail, it''s unique'",
                """
                CREATE TABLE dbee_it.orders (
                    id bigint GENERATED ALWAYS AS IDENTITY,
                    customer_id int NOT NULL REFERENCES dbee_it.customers (id) ON DELETE CASCADE ON UPDATE RESTRICT,
                    total numeric(10,2) NOT NULL DEFAULT 0,
                    placed_at timestamptz DEFAULT now(),
                    note text,
                    PRIMARY KEY (id)
                )
                """,
                "CREATE INDEX orders_customer_total_idx ON dbee_it.orders (customer_id, total DESC)",
                """
                CREATE TABLE dbee_it.line_items (
                    order_id bigint REFERENCES dbee_it.orders (id),
                    line int,
                    qty int CHECK (qty > 0),
                    PRIMARY KEY (order_id, line)
                )
                """,
                "CREATE VIEW dbee_it.big_orders AS SELECT id, total FROM dbee_it.orders WHERE total > 100",
                "CREATE MATERIALIZED VIEW dbee_it.customer_totals AS SELECT customer_id, sum(total) AS total FROM dbee_it.orders GROUP BY customer_id",
                #"CREATE TABLE dbee_it."Mixed Case" (x int)"#,
                "CREATE TABLE dbee_it.events (id int, at date) PARTITION BY RANGE (at)",
                "CREATE TABLE dbee_it.events_2024 PARTITION OF dbee_it.events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')",
            ] {
                try await driver.run(statement)
            }

            let schemas = try await driver.listSchemas()
            let names = schemas.map(\.name)
            #expect(names.first == "public")
            #expect(names.contains("dbee_it"))
            #expect(names.contains("dbee_empty"))
            #expect(!names.contains { $0.hasPrefix("pg_") || $0 == "information_schema" })
            #expect(schemas.first { $0.name == "dbee_empty" }?.tables.isEmpty == true)

            let tables = schemas.first { $0.name == "dbee_it" }?.tables ?? []
            #expect(tables.map(\.ref.name) == ["big_orders", "customer_totals", "customers", "events", "events_2024", "line_items", "Mixed Case", "orders"])
            let kinds = Dictionary(uniqueKeysWithValues: tables.map { ($0.ref.name, $0.kind) })
            #expect(kinds["customers"] == .table)
            #expect(kinds["events"] == .table)
            #expect(kinds["big_orders"] == .view)
            #expect(kinds["customer_totals"] == .materializedView)
            #expect(tables.allSatisfy { $0.ref.schema == "dbee_it" })

            let orders = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "orders"))
            #expect(orders.columns.map(\.name) == ["id", "customer_id", "total", "placed_at", "note"])
            #expect(orders.primaryKey == ["id"])
            let columns = Dictionary(uniqueKeysWithValues: orders.columns.map { ($0.name, $0) })
            #expect(columns["id"]?.dataType == "bigint")
            #expect(columns["id"]?.defaultValue == "GENERATED ALWAYS AS IDENTITY")
            #expect(columns["id"]?.isNullable == false)
            #expect(columns["total"]?.dataType == "numeric(10,2)")
            #expect(columns["total"]?.defaultValue == "0")
            #expect(columns["placed_at"]?.dataType == "timestamp with time zone")
            #expect(columns["placed_at"]?.defaultValue == "now()")
            #expect(columns["note"]?.isNullable == true)

            let pkey = orders.indexes.first { $0.name == "orders_pkey" }
            #expect(pkey?.isPrimary == true)
            #expect(pkey?.columns == ["id"])
            let composite = orders.indexes.first { $0.name == "orders_customer_total_idx" }
            #expect(composite?.columns == ["customer_id", "total"])
            #expect(composite?.isUnique == false)
            #expect(composite?.definition?.contains("(customer_id, total DESC)") == true)

            #expect(orders.foreignKeys.count == 1)
            let fk = orders.foreignKeys.first
            #expect(fk?.name == "orders_customer_id_fkey")
            #expect(fk?.columns == ["customer_id"])
            #expect(fk?.referencedTable == TableRef(schema: "dbee_it", name: "customers"))
            #expect(fk?.referencedColumns == ["id"])
            #expect(fk?.onDelete == "CASCADE")
            #expect(fk?.onUpdate == "RESTRICT")

            let ordersDDL = orders.ddl ?? ""
            #expect(ordersDDL.hasPrefix("CREATE TABLE dbee_it.orders ("))
            #expect(ordersDDL.contains("id bigint GENERATED ALWAYS AS IDENTITY NOT NULL"))
            #expect(ordersDDL.contains("CONSTRAINT orders_pkey PRIMARY KEY (id)"))
            #expect(ordersDDL.contains("REFERENCES dbee_it.customers(id) ON UPDATE RESTRICT ON DELETE CASCADE"))
            #expect(ordersDDL.contains("CREATE INDEX orders_customer_total_idx ON dbee_it.orders USING btree (customer_id, total DESC);"))

            let customers = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "customers"))
            #expect(customers.columns.first { $0.name == "email" }?.comment == "Login e-mail, it's unique")
            #expect(customers.columns.first { $0.name == "id" }?.defaultValue == "nextval('dbee_it.customers_id_seq'::regclass)")
            #expect(customers.indexes.contains { $0.isUnique && $0.columns == ["email"] })
            let customersDDL = customers.ddl ?? ""
            #expect(customersDDL.contains("COMMENT ON TABLE dbee_it.customers IS 'People who buy things';"))
            #expect(customersDDL.contains("COMMENT ON COLUMN dbee_it.customers.email IS 'Login e-mail, it''s unique';"))
            #expect(customersDDL.contains("UNIQUE (email)"))

            let lineItems = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "line_items"))
            #expect(lineItems.primaryKey == ["order_id", "line"])
            #expect(lineItems.ddl?.contains("CHECK (qty > 0)") == true)

            let view = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "big_orders"))
            #expect(view.columns.map(\.name) == ["id", "total"])
            #expect(view.ddl?.hasPrefix("CREATE VIEW dbee_it.big_orders AS\nSELECT") == true)

            let matview = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "customer_totals"))
            #expect(matview.ddl?.hasPrefix("CREATE MATERIALIZED VIEW dbee_it.customer_totals AS") == true)

            let mixed = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "Mixed Case"))
            #expect(mixed.ddl?.hasPrefix(#"CREATE TABLE dbee_it."Mixed Case" ("#) == true)

            let events = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "events"))
            #expect(events.ddl?.contains("PARTITION BY RANGE (at)") == true)
            let partition = try await driver.tableStructure(TableRef(schema: "dbee_it", name: "events_2024"))
            #expect(partition.ddl?.hasPrefix("CREATE TABLE dbee_it.events_2024 PARTITION OF dbee_it.events\nFOR VALUES FROM ('2024-01-01') TO ('2025-01-01');") == true)

            await #expect(throws: DatabaseError.self) {
                try await driver.tableStructure(TableRef(schema: "dbee_it", name: "no_such_table"))
            }

            try await driver.run("DROP SCHEMA dbee_it CASCADE")
            try await driver.run("DROP SCHEMA dbee_empty CASCADE")
        }
    }

    @Test func transactionsSpanSeparateCalls() async throws {
        try await PG.withDriver { driver in
            try await driver.run("DROP TABLE IF EXISTS public.dbee_tx")
            try await driver.run("CREATE TABLE public.dbee_tx (id int)")

            try await driver.run("BEGIN")
            try await driver.run("INSERT INTO public.dbee_tx VALUES (1)")
            try await driver.run("INSERT INTO public.dbee_tx VALUES (2)")
            #expect(try await driver.value("SELECT count(*) FROM public.dbee_tx") == "2")
            try await driver.run("ROLLBACK")
            #expect(try await driver.value("SELECT count(*) FROM public.dbee_tx") == "0")

            try await PG.withDriver { other in
                try await driver.run("BEGIN")
                try await driver.run("INSERT INTO public.dbee_tx VALUES (3)")
                #expect(try await other.value("SELECT count(*) FROM public.dbee_tx") == "0")
                try await driver.run("COMMIT")
                #expect(try await other.value("SELECT count(*) FROM public.dbee_tx") == "1")
            }

            try await driver.run("BEGIN")
            await #expect(throws: DatabaseError.self) { try await driver.run("SELECT 1 / 0") }
            do {
                try await driver.run("SELECT 1")
                Issue.record("statement ran in an aborted transaction")
            } catch {
                #expect(PG.message(of: error).contains("current transaction is aborted"))
            }
            try await driver.run("ROLLBACK")
            #expect(try await driver.value("SELECT 1") == "1")
            try await driver.run("DROP TABLE public.dbee_tx")
        }
    }

    @Test func serverErrorsCarryDetails() async throws {
        try await PG.withDriver { driver in
            do {
                try await driver.run("SELECT * FROM dbee_no_such_table")
                Issue.record("expected an error")
            } catch let error as DatabaseError {
                #expect(error.message == #"relation "dbee_no_such_table" does not exist"#)
                #expect(error.detail?.contains("SQLSTATE 42P01") == true)
                #expect(error.detail?.contains("Position: 15") == true)
            }
            do {
                try await driver.run("SELEC 1")
                Issue.record("expected an error")
            } catch let error as DatabaseError {
                #expect(error.message.hasPrefix("syntax error at or near"))
            }
            // The connection stays usable after errors.
            #expect(try await driver.value("SELECT 'ok'") == "ok")
        }
    }

    @Test func cancelStopsALongQuery() async throws {
        try await PG.withDriver { driver in
            let running = Task { try await driver.run("SELECT pg_sleep(30)") }
            try await Task.sleep(for: .milliseconds(500))
            let clock = ContinuousClock()
            let start = clock.now
            await driver.cancelCurrentQuery()
            do {
                _ = try await running.value
                Issue.record("pg_sleep(30) wasn't cancelled")
            } catch {
                #expect(PG.message(of: error).contains("canceling statement due to user request"))
            }
            #expect(clock.now - start < .seconds(10))
            #expect(try await driver.value("SELECT 'after cancel'") == "after cancel")

            // Cancelling the Swift task cancels the statement too.
            let task = Task { try await driver.run("SELECT pg_sleep(30)") }
            try await Task.sleep(for: .milliseconds(500))
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(clock.now - start < .seconds(20))
            #expect(try await driver.value("SELECT 1") == "1")

            // Nothing running: a no-op.
            await driver.cancelCurrentQuery()
            #expect(try await driver.value("SELECT 2") == "2")
        }
    }

    @Test func cancellingAStreamingQueryStopsItOnTheServer() async throws {
        try await PG.withDriver { driver in
            // Rows arrive at once, then the last one takes 8 s: the iterator is cancelled mid-stream.
            let task = Task {
                try await driver.execute("""
                    SELECT g, repeat('x', 200), CASE WHEN g = 5000 THEN pg_sleep(8)::text END
                    FROM generate_series(1, 5000) g
                    """, maxRows: 0)
            }
            try await Task.sleep(for: .milliseconds(700))
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            let clock = ContinuousClock()
            let start = clock.now
            #expect(try await driver.value("SELECT 'next'") == "next")
            #expect(clock.now - start < .seconds(3))
        }
    }

    @Test func lockingAndTransactionStatementsRunToCompletion() async throws {
        try await PG.withDriver { driver in
            try await PG.withDriver { observer in
                try await driver.run("DROP TABLE IF EXISTS dbee_fu")
                try await driver.run("CREATE TABLE dbee_fu AS SELECT g AS id FROM generate_series(1, 10) g")
                try await driver.run("BEGIN")
                let locked = try await driver.run("SELECT id FROM dbee_fu FOR UPDATE", maxRows: 5)
                #expect(locked.rows.count == 5)
                #expect(locked.truncated)
                // Every row is locked, not just the five shown.
                try await observer.run("BEGIN")
                let free = try await observer.run("SELECT id FROM dbee_fu FOR UPDATE SKIP LOCKED")
                #expect(free.rows.isEmpty)
                try await observer.run("ROLLBACK")

                // Inside a transaction block, volatile functions run for every row.
                try await driver.run("CREATE TEMP SEQUENCE dbee_fu_seq")
                let numbers = try await driver.run("SELECT nextval('dbee_fu_seq') FROM generate_series(1, 10)", maxRows: 3)
                #expect(numbers.rows.count == 3)
                #expect(numbers.truncated)
                #expect(try await driver.value("SELECT currval('dbee_fu_seq')") == "10")
                try await driver.run("ROLLBACK")

                // Outside a transaction the server still stops at the limit.
                let limited = try await driver.run("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT n FROM r", maxRows: 3)
                #expect(limited.rows == [["1"], ["2"], ["3"]])
                try await driver.run("DROP TABLE dbee_fu")
            }
        }
    }

    @Test func binaryCopyIsRefused() async throws {
        try await PG.withDriver { driver in
            do {
                try await driver.run("COPY (SELECT 1) TO STDOUT (FORMAT binary)")
                Issue.record("binary COPY should fail")
            } catch let error as DatabaseError {
                #expect(error.message == "Binary COPY output isn't supported.")
            }
            #expect(try await driver.value("SELECT 'still usable'") == "still usable")
        }
    }

    @Test func concurrentCallsAreSerialized() async throws {
        try await PG.withDriver { driver in
            try await withThrowingTaskGroup(of: (Int, String?).self) { group in
                for i in 0..<30 {
                    group.addTask {
                        if i % 5 == 0 { _ = try await driver.listSchemas() }
                        let result = try await driver.execute("SELECT \(i), pg_sleep(0.005)", maxRows: i % 3 == 0 ? 1 : 100)
                        return (i, result.rows.first?.first ?? nil)
                    }
                }
                for try await (i, value) in group {
                    #expect(value == String(i))
                }
            }
        }
    }

    @Test func copyIsHandledWithoutDroppingTheConnection() async throws {
        try await PG.withDriver { driver in
            let out = try await driver.run("COPY (SELECT g, 'x' || g FROM generate_series(1, 3) g) TO STDOUT")
            #expect(out.columns == ["COPY"])
            #expect(out.rows == [["1\tx1"], ["2\tx2"], ["3\tx3"]])
            #expect(out.rowsAffected == 3)

            let limited = try await driver.run("COPY (SELECT g FROM generate_series(1, 50) g) TO STDOUT", maxRows: 5)
            #expect(limited.rows.count == 5)
            #expect(limited.truncated)

            try await driver.run("CREATE TEMP TABLE dbee_copy (id int)")
            do {
                try await driver.run("COPY dbee_copy FROM STDIN")
                Issue.record("COPY FROM STDIN should fail")
            } catch {
                #expect(PG.message(of: error).contains("COPY FROM STDIN isn't supported"))
            }
            #expect(try await driver.value("SELECT count(*) FROM dbee_copy") == "0")
        }
    }

    @Test func closeIsIdempotent() async throws {
        let driver = try await PG.connect()
        #expect(try await driver.value("SELECT 1") == "1")
        await driver.close()
        await driver.close()
        #expect(driver.isClosed)
        await #expect(throws: DatabaseError.self) { try await driver.run("SELECT 1") }
        await driver.cancelCurrentQuery()
    }

    /// A connection that dropped while idle (server restart, SSH tunnel gone) fails the next statement
    /// instead of waiting forever: PostgresNIO never answers a query written to a closed channel.
    @Test func statementOnADroppedConnectionFails() async throws {
        let driver = try await PG.connect()
        let pid = try #require(try await driver.value("SELECT pg_backend_pid()"))
        try await PG.withDriver { admin in
            _ = try await admin.run("SELECT pg_terminate_backend(\(pid))")
        }
        for _ in 0..<100 where !driver.isClosed { try await Task.sleep(for: .milliseconds(20)) }
        #expect(driver.isClosed)
        await #expect(throws: DatabaseError.self) { try await driver.run("SELECT 1") }
        await #expect(throws: DatabaseError.self) { try await driver.run("SELECT 2") }
        await driver.close()
    }
}

// A TLS-enabled server with a self-signed certificate (skipped unless DBEE_PG_TLS_PORT is set):
//   docker run -d --name dbee-it-postgres-tls -e POSTGRES_PASSWORD=dbee_test -p 127.0.0.1:55433:5432 postgres:16 bash -c \
//     'openssl req -new -x509 -days 2 -nodes -subj "/CN=localhost" -keyout /tmp/k -out /tmp/c 2>/dev/null &&
//      chown postgres /tmp/k /tmp/c && chmod 600 /tmp/k &&
//      exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/c -c ssl_key_file=/tmp/k'
//   DBEE_PG_PORT=55432 DBEE_PG_TLS_PORT=55433 swift test --filter Postgres
private enum PGTLS {
    static let port = ProcessInfo.processInfo.environment["DBEE_PG_TLS_PORT"].flatMap(Int.init)

    static func config(_ tls: TLSMode, host: String = "127.0.0.1") -> ConnectionConfig {
        var config = PG.config(tls: tls)
        config.host = host
        config.port = port ?? 5432
        return config
    }
}

@Suite("Postgres over TLS", .serialized, .enabled(if: PGTLS.port != nil, "set DBEE_PG_TLS_PORT to run"), .timeLimit(.minutes(1)))
struct PostgresTLSIntegrationTests {
    private static let sslInUse = "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"

    @Test(arguments: [TLSMode.preferred, .required])
    func encryptsAndStillReadsResults(_ mode: TLSMode) async throws {
        try await PG.withDriver(PGTLS.config(mode)) { driver in
            #expect(try await driver.value(Self.sslInUse) == "t")
            // Plenty of data through the TLS layer and the wire adapter.
            let big = try await driver.run("SELECT g, repeat('x', 200) FROM generate_series(1, 20000) g", maxRows: 0)
            #expect(big.rows.count == 20000)
            #expect(big.rows.last == ["20000", String(repeating: "x", count: 200)])
            let limited = try await driver.run("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT n FROM r", maxRows: 3)
            #expect(limited.rows == [["1"], ["2"], ["3"]])
            #expect(limited.truncated)
            #expect(try await driver.value("SELECT '{\"a\": 1}'::jsonb") == #"{"a": 1}"#)
        }
    }

    @Test func disabledStaysPlain() async throws {
        try await PG.withDriver(PGTLS.config(.disabled)) { driver in
            let ssl = try await driver.value(Self.sslInUse)
            #expect(ssl == "f")
        }
    }

    @Test(arguments: ["localhost", "127.0.0.1"])
    func verifyFullRejectsUntrustedCertificate(_ host: String) async throws {
        var config = PGTLS.config(.verifyFull, host: host)
        config.host = host
        do {
            let driver = try await PostgresDriver.connect(config: config, host: "127.0.0.1", port: config.port)
            await driver.close()
            Issue.record("a self-signed certificate passed verification")
        } catch let error as DatabaseError {
            #expect(error.message == "The server's certificate couldn't be verified.")
        }
    }

    @Test func cancelWorksOverTLS() async throws {
        try await PG.withDriver(PGTLS.config(.required)) { driver in
            let running = Task { try await driver.run("SELECT pg_sleep(30)") }
            try await Task.sleep(for: .milliseconds(400))
            await driver.cancelCurrentQuery()
            await #expect(throws: DatabaseError.self) { try await running.value }
            #expect(try await driver.value("SELECT 1") == "1")
        }
    }
}

// MARK: - Wire rewriting (no server needed)

@Suite("Postgres wire rewriting")
struct PostgresWireRewriterTests {
    private static func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count + 4)
        return [type.asciiValue!] + withUnsafeBytes(of: length.bigEndian, Array.init) + body
    }

    private static func cString(_ string: String) -> [UInt8] { Array(string.utf8) + [0] }

    /// Feeds `bytes` in the given chunk sizes and returns (bytes forwarded to PostgresNIO, bytes replied to the server).
    private static func feed(_ bytes: [UInt8], chunks: [Int], probe: PostgresWireProbe) -> ([UInt8], [UInt8]) {
        var rewriter = PostgresBackendRewriter()
        var forwarded: [UInt8] = []
        var replied: [UInt8] = []
        var offset = 0
        var chunkIndex = 0
        while offset < bytes.count {
            let size = max(1, min(chunks[chunkIndex % chunks.count], bytes.count - offset))
            chunkIndex += 1
            let chunk = ByteBuffer(bytes: bytes[offset..<offset + size])
            offset += size
            for output in rewriter.process(chunk, probe: probe) {
                switch output {
                case .forward(var buffer): forwarded += buffer.readBytes(length: buffer.readableBytes) ?? []
                case .reply(var buffer): replied += buffer.readBytes(length: buffer.readableBytes) ?? []
                }
            }
        }
        return (forwarded, replied)
    }

    @Test func backendStreamSurvivesAnyChunking() {
        let dataRow = Self.message("D", [0, 1, 0, 0, 0, 2, 0x34, 0x32])
        let input = Self.message("1", []) + Self.message("2", []) + dataRow + dataRow
            + Self.message("C", Self.cString("SELECT 2")) + Self.message("Z", [UInt8(ascii: "I")])
        for chunks in [[1], [2], [3], [5], [7], [4096], [1, 9, 2], [6, 1, 13]] {
            let probe = PostgresWireProbe()
            probe.begin(rowLimit: 0)
            let (forwarded, replied) = Self.feed(input, chunks: chunks, probe: probe)
            #expect(forwarded == input, "chunks \(chunks)")
            #expect(replied.isEmpty)
            #expect(probe.finish().commandTag == "SELECT 2")
        }
    }

    @Test func portalSuspendedBecomesCommandComplete() {
        let dataRow = Self.message("D", [0, 1, 0, 0, 0, 1, 0x31])
        let input = dataRow + Self.message("s", []) + Self.message("Z", [UInt8(ascii: "T")])
        let expected = dataRow + Self.message("C", Self.cString("SELECT")) + Self.message("Z", [UInt8(ascii: "T")])
        for chunks in [[1], [3], [100]] {
            let probe = PostgresWireProbe()
            probe.begin(rowLimit: 2)
            let (forwarded, _) = Self.feed(input, chunks: chunks, probe: probe)
            #expect(forwarded == expected)
            #expect(probe.finish().portalSuspended)
        }
    }

    @Test func copyOutIsCapturedAndCopyInIsRefused() {
        let copyOut = Self.message("n", []) + Self.message("2", [])
            + Self.message("H", [0, 0, 1, 0, 0])
            + Self.message("d", Array("a\tb\n".utf8)) + Self.message("d", Array("c\td\n".utf8))
            + Self.message("c", []) + Self.message("C", Self.cString("COPY 2"))
        let probe = PostgresWireProbe()
        probe.begin(rowLimit: 0)
        let (forwarded, _) = Self.feed(copyOut, chunks: [3, 1, 4], probe: probe)
        #expect(forwarded == Self.message("n", []) + Self.message("2", []) + Self.message("C", Self.cString("COPY 2")))
        let outcome = probe.finish()
        #expect(outcome.copyLines == ["a\tb", "c\td"])
        #expect(outcome.commandTag == "COPY 2")

        let copyIn = Self.message("2", []) + Self.message("G", [0, 0, 1, 0, 0])
        let (forwardedIn, replied) = Self.feed(copyIn, chunks: [2], probe: probe)
        #expect(forwardedIn == Self.message("2", []))
        #expect(replied.first == UInt8(ascii: "f"))
        #expect(Array(replied.suffix(5)) == Self.message("S", []))
    }

    @Test func frontendRequestsTextAndAppliesRowLimit() {
        // Bind: portal "", statement "", 0 param formats, 0 params, 1 result format: binary.
        let bind = Self.message("B", [0, 0, 0, 0, 0, 0, 0, 1, 0, 1])
        let execute = Self.message("E", [0, 0, 0, 0, 0])
        let sync = Self.message("S", [])
        let probe = PostgresWireProbe()
        probe.begin(rowLimit: 11)
        var rewriter = PostgresFrontendRewriter()
        var buffer = ByteBuffer(bytes: bind + execute + sync)
        rewriter.process(&buffer, probe: probe)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        #expect(bytes == Self.message("B", [0, 0, 0, 0, 0, 0, 0, 1, 0, 0]) + Self.message("E", [0, 0, 0, 0, 11]) + sync)
        #expect(!probe.finish().framingProblem)
    }

    @Test func readyForQueryTracksTransactionStatus() {
        let probe = PostgresWireProbe()
        #expect(!probe.isInTransactionBlock)
        let input = Self.message("C", Self.cString("BEGIN")) + Self.message("Z", [UInt8(ascii: "T")])
        let (forwarded, _) = Self.feed(input, chunks: [2], probe: probe)
        #expect(forwarded == input)
        #expect(probe.isInTransactionBlock)
        _ = Self.feed(Self.message("Z", [UInt8(ascii: "I")]), chunks: [1], probe: probe)
        #expect(!probe.isInTransactionBlock)
    }

    @Test func binaryCopyIsNotDecoded() {
        let input = Self.message("H", [1, 0, 1, 0, 1]) + Self.message("d", Array("PGCOPY\n".utf8) + [0xFF, 0x0D, 0x0A, 0])
            + Self.message("c", []) + Self.message("C", Self.cString("COPY 1"))
        let probe = PostgresWireProbe()
        probe.begin(rowLimit: 0)
        let (forwarded, _) = Self.feed(input, chunks: [4], probe: probe)
        #expect(forwarded == Self.message("C", Self.cString("COPY 1")))
        let outcome = probe.finish()
        #expect(outcome.copyBinary)
        #expect(outcome.copyLines == [])
    }

    @Test func backendKeyIsCapturedDuringStartup() throws {
        let startup = Self.message("R", [0, 0, 0, 0]) + Self.message("S", Self.cString("a") + Self.cString("b"))
            + Self.message("K", [0, 0, 0x30, 0x39, 0xDE, 0xAD, 0xBE, 0xEF]) + Self.message("Z", [UInt8(ascii: "I")])
        for (prefix, awaitingSSLAnswer) in [([UInt8](), false), ([UInt8(ascii: "N")], true)] {
            let key = NIOLockedValueBox<PostgresBackendKey?>(nil)
            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHandler(PostgresBackendKeyCapture(key: key, awaitingSSLAnswer: awaitingSSLAnswer))
            let bytes = prefix + startup
            for chunk in stride(from: 0, to: bytes.count, by: 3) {
                try channel.writeInbound(ByteBuffer(bytes: bytes[chunk..<min(chunk + 3, bytes.count)]))
            }
            var forwarded: [UInt8] = []
            while var buffer = try channel.readInbound(as: ByteBuffer.self) {
                forwarded += buffer.readBytes(length: buffer.readableBytes) ?? []
            }
            #expect(forwarded == bytes)
            #expect(key.withLockedValue { $0 } == PostgresBackendKey(processID: 12345, secret: Int32(bitPattern: 0xDEADBEEF)))
            #expect((try? channel.pipeline.syncOperations.handler(type: PostgresBackendKeyCapture.self)) == nil)
            _ = try channel.finish()
        }
    }

    @Test func verifyFullThroughTunnelNeedsAHostName() async throws {
        var config = PG.config(tls: .verifyFull)
        config.host = "203.0.113.5"
        do {
            let driver = try await PostgresDriver.connect(config: config, host: "127.0.0.1", port: 1)
            await driver.close()
            Issue.record("connected without being able to check the certificate's name")
        } catch let error as DatabaseError {
            #expect(error.message == PostgresDriver.verifyNeedsHostName.message)
        }
    }

    @Test func commandTagsMapToRowCounts() {
        #expect(PostgresDriver.rowCount(fromCommandTag: "INSERT 0 5") == 5)
        #expect(PostgresDriver.rowCount(fromCommandTag: "UPDATE 3") == 3)
        #expect(PostgresDriver.rowCount(fromCommandTag: "DELETE 0") == 0)
        #expect(PostgresDriver.rowCount(fromCommandTag: "SELECT 12") == 12)
        #expect(PostgresDriver.rowCount(fromCommandTag: "MERGE 2") == 2)
        #expect(PostgresDriver.rowCount(fromCommandTag: "CREATE TABLE") == nil)
        #expect(PostgresDriver.rowCount(fromCommandTag: "SELECT") == nil)
        #expect(PostgresDriver.rowCount(fromCommandTag: "BEGIN") == nil)
    }
}
