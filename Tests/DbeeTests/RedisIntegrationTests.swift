import Foundation
import Testing
@testable import Dbee

// Integration tests run against a real server and are skipped unless DBEE_REDIS_PORT is set:
//   docker run -d --name dbee-it-redis -p 127.0.0.1:56379:6379 redis:7 redis-server --requirepass dbee_test
//   DBEE_REDIS_PORT=56379 swift test --filter Redis

private enum RedisIT {
    static let port = ProcessInfo.processInfo.environment["DBEE_REDIS_PORT"].flatMap(Int.init)
    static let password = ProcessInfo.processInfo.environment["DBEE_REDIS_PASSWORD"] ?? "dbee_test"

    static func config(password: String = RedisIT.password, database: String = "15") -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .redis
        config.host = "127.0.0.1"
        config.port = port ?? 6379
        config.password = password
        config.database = database
        config.tls = .disabled
        return config
    }

    static func withDriver<T>(_ config: ConnectionConfig = config(), _ body: (RedisDriver) async throws -> T) async throws -> T {
        let driver = try await RedisDriver.connect(config: config, host: config.host, port: config.port)
        do {
            _ = try await driver.execute("FLUSHDB", maxRows: 1)
            let result = try await body(driver)
            await driver.close()
            return result
        } catch {
            await driver.close()
            throw error
        }
    }
}

@Suite("Redis integration", .serialized, .enabled(if: RedisIT.port != nil, "set DBEE_REDIS_PORT to run"), .timeLimit(.minutes(2)))
struct RedisIntegrationTests {
    @Test func connectsAndDescribesServer() async throws {
        try await RedisIT.withDriver { driver in
            #expect(try await driver.serverVersion().hasPrefix("Redis 7."))
            #expect(try await driver.currentDatabase() == "db15")
            let databases = try await driver.listDatabases()
            #expect(databases.first == "db0")
            #expect(databases.contains("db15"))
            let schemas = try await driver.listSchemas()
            #expect(schemas.map(\.name) == ["db15"])
            #expect(schemas.first?.tables.map(\.kind) == [.keys])
        }
    }

    @Test func refusesAWrongPassword() async throws {
        let config = RedisIT.config(password: "wrong")
        await #expect {
            try await RedisDriver.connect(config: config, host: config.host, port: config.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "Redis refused the login."
        }
        let none = RedisIT.config(password: "")
        await #expect {
            try await RedisDriver.connect(config: none, host: none.host, port: none.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "Redis needs a password."
        }
    }

    /// A SELECT inside MULTI only takes effect when EXEC runs it.
    @Test func selectInsideTransactionFollowsExec() async throws {
        try await RedisIT.withDriver { driver in
            _ = try await driver.execute("MULTI", maxRows: 1)
            _ = try await driver.execute("SELECT 14", maxRows: 1)
            #expect(try await driver.currentDatabase() == "db15")
            _ = try await driver.execute("DISCARD", maxRows: 1)
            #expect(try await driver.currentDatabase() == "db15")
            _ = try await driver.execute("SET marker discarded", maxRows: 1)
            #expect(try await driver.execute("GET marker", maxRows: 1).rows == [["discarded"]])

            _ = try await driver.execute("MULTI", maxRows: 1)
            _ = try await driver.execute("SELECT 14", maxRows: 1)
            _ = try await driver.execute("EXEC", maxRows: 10)
            #expect(try await driver.currentDatabase() == "db14")
            #expect(try await driver.execute("GET marker", maxRows: 1).rows == [[nil]])
            try await driver.useDatabase("15")
        }
    }

    @Test func runsCommands() async throws {
        try await RedisIT.withDriver { driver in
            let set = try await driver.execute(#"SET greeting "hello world""#, maxRows: 10)
            #expect(!set.isRowSet)
            #expect(try await driver.execute("GET greeting", maxRows: 10).rows == [["hello world"]])
            #expect(try await driver.execute("GET missing", maxRows: 10).rows == [[nil]])
            _ = try await driver.execute("HSET user:1 name Ada lang en", maxRows: 10)
            let hash = try await driver.execute("HGETALL user:1", maxRows: 10)
            #expect(hash.columns == ["field", "value"])
            #expect(hash.rows == [["name", "Ada"], ["lang", "en"]])
            #expect(try await driver.execute("INCR counter", maxRows: 10).rows == [["1"]])
            let info = try await driver.execute("INFO server", maxRows: 1000)
            #expect(info.columns == ["section", "field", "value"])
            #expect(info.rows.contains { $0[1] == "redis_version" })
            await #expect(throws: DatabaseError.self) { try await driver.execute("NOSUCHCOMMAND", maxRows: 10) }
            await #expect(throws: DatabaseError.self) { try await driver.execute("SUBSCRIBE news", maxRows: 10) }
        }
    }

    @Test func pagesThroughKeys() async throws {
        try await RedisIT.withDriver { driver in
            for index in 0..<25 { _ = try await driver.execute("SET key:\(String(format: "%02d", index)) v\(index)", maxRows: 1) }
            _ = try await driver.execute("RPUSH list:a x y z", maxRows: 1)
            _ = try await driver.execute("ZADD scores 1 alice 2 bob", maxRows: 1)
            _ = try await driver.execute("EXPIRE key:00 300", maxRows: 1)

            let table = RedisDriver.keysTable
            let first = try await driver.page(of: table, filter: nil, sort: nil, limit: 10, offset: 0)
            #expect(first.columns == ["key", "type", "ttl", "size", "value"])
            #expect(first.rows.count == 10)
            #expect(first.rows[0][0] == "key:00")
            #expect(first.rows[0][1] == "string")
            #expect(first.rows[0][2].flatMap { Int($0) }.map { $0 > 0 && $0 <= 300 } == true)
            #expect(first.rows[1][2] == nil)
            let third = try await driver.page(of: table, filter: nil, sort: nil, limit: 10, offset: 20)
            #expect(third.rows.map { $0[0] } == ["key:20", "key:21", "key:22", "key:23", "key:24", "list:a", "scores"])
            #expect(third.rows[5][4] == #"["x","y","z"]"#)
            #expect(third.rows[6][4] == #"{"alice": "1", "bob": "2"}"#)
            #expect(try await driver.count(of: table, filter: nil) == 27)

            let filtered = try await driver.page(of: table, filter: "key:1*", sort: GridSort(column: "key", ascending: false),
                                                 limit: 100, offset: 0)
            #expect(filtered.rows.map { $0[0] } == (10...19).reversed().map { "key:\($0)" })
            #expect(try await driver.count(of: table, filter: "key:1*") == 10)
        }
    }

    @Test func switchesDatabases() async throws {
        try await RedisIT.withDriver { driver in
            _ = try await driver.execute("SET only-in-15 yes", maxRows: 1)
            try await driver.useDatabase("db14")
            #expect(try await driver.currentDatabase() == "db14")
            #expect(try await driver.execute("EXISTS only-in-15", maxRows: 1).rows == [["0"]])
            _ = try await driver.execute("SELECT 15", maxRows: 1)
            #expect(try await driver.currentDatabase() == "db15")
            #expect(try await driver.execute("EXISTS only-in-15", maxRows: 1).rows == [["1"]])
        }
    }

    @Test func stopsABlockingCommandAndReconnects() async throws {
        try await RedisIT.withDriver { driver in
            let blocked = Task { try await driver.execute("BLPOP never-filled 30", maxRows: 1) }
            try await Task.sleep(for: .milliseconds(300))
            await driver.cancelCurrentQuery()
            await #expect(throws: (any Error).self) { try await blocked.value }
            // The next command reconnects, logs in and selects the same database.
            #expect(try await driver.currentDatabase() == "db15")
            _ = try await driver.execute("SET after-stop 1", maxRows: 1)
            #expect(try await driver.execute("GET after-stop", maxRows: 1).rows == [["1"]])
            #expect(try await driver.execute("CLIENT INFO", maxRows: 1).rows.first?.first??.contains("db=15") == true)
        }
    }

    @Test func preferredTLSFallsBackToPlainTCP() async throws {
        var config = RedisIT.config()
        config.tls = .preferred
        let started = Date()
        let driver = try await RedisDriver.connect(config: config, host: config.host, port: config.port)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!(try await driver.serverVersion()).isEmpty)
        await driver.close()

        config.tls = .required
        await #expect(throws: (any Error).self) {
            try await RedisDriver.connect(config: config, host: config.host, port: config.port)
        }
    }
}
