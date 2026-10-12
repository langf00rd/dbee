import Foundation
import Testing
@testable import Dbee

// Integration tests run against a real server and are skipped unless DBEE_MONGO_PORT is set:
//   docker run -d --name dbee-it-mongo -e MONGO_INITDB_ROOT_USERNAME=dbee -e MONGO_INITDB_ROOT_PASSWORD=dbee_test \
//     -p 127.0.0.1:57017:27017 mongo:7
//   DBEE_MONGO_PORT=57017 swift test --filter Mongo

private enum MongoIT {
    static let port = ProcessInfo.processInfo.environment["DBEE_MONGO_PORT"].flatMap(Int.init)
    static let password = ProcessInfo.processInfo.environment["DBEE_MONGO_PASSWORD"] ?? "dbee_test"
    static let database = "dbee_it"

    static func config(username: String = "dbee", password: String = MongoIT.password,
                       database: String = MongoIT.database) -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .mongodb
        config.host = "127.0.0.1"
        config.port = port ?? 27017
        config.username = username
        config.password = password
        config.database = database
        config.tls = .disabled
        return config
    }

    static func withDriver<T>(_ config: ConnectionConfig = config(), _ body: (MongoDriver) async throws -> T) async throws -> T {
        let driver = try await MongoDriver.connect(config: config, host: config.host, port: config.port)
        do {
            _ = try await driver.execute("db.dropDatabase()", maxRows: 1)
            let result = try await body(driver)
            await driver.close()
            return result
        } catch {
            await driver.close()
            throw error
        }
    }
}

@Suite("Mongo integration", .serialized, .enabled(if: MongoIT.port != nil, "set DBEE_MONGO_PORT to run"), .timeLimit(.minutes(2)))
struct MongoIntegrationTests {
    @Test func connectsAndAuthenticates() async throws {
        try await MongoIT.withDriver { driver async throws in
            #expect(try await driver.serverVersion().hasPrefix("MongoDB 7."))
            #expect(try await driver.currentDatabase() == MongoIT.database)
            #expect(try await driver.listDatabases().contains("admin"))
        }
    }

    @Test func refusesAWrongPassword() async throws {
        let config = MongoIT.config(password: "wrong")
        await #expect {
            try await MongoDriver.connect(config: config, host: config.host, port: config.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "MongoDB refused the login."
        }
    }

    @Test func runsShellStatements() async throws {
        try await MongoIT.withDriver { driver in
            let inserted = try await driver.execute("""
                db.people.insertMany([
                  { name: "Ada", age: 36, tags: ["math"], born: ISODate("1815-12-10T00:00:00Z") },
                  { name: "Alan", age: 41, address: { city: "London" } },
                  { _id: 7, name: "Grace", age: 85, salary: NumberDecimal("12.50") },
                ])
                """, maxRows: 100)
            #expect(inserted.rowsAffected == 3)
            #expect(inserted.rows.count == 3)

            let found = try await driver.execute("db.people.find({ age: { $gt: 40 } }).sort({ age: -1 })", maxRows: 100)
            #expect(found.columns == ["_id", "name", "age", "salary", "address"])
            #expect(found.rows.map { $0[1] } == ["Grace", "Alan"])
            #expect(found.rows[0][0] == "7")
            #expect(found.rows[0][3] == "12.50")
            #expect(found.rows[1][4] == #"{"city": "London"}"#)

            let limited = try await driver.execute("db.people.find().limit(2)", maxRows: 100)
            #expect(limited.rows.count == 2)
            let capped = try await driver.execute("db.people.find()", maxRows: 2)
            #expect(capped.rows.count == 2)
            #expect(capped.truncated)

            #expect(try await driver.execute("db.people.countDocuments({ age: { $lt: 50 } })", maxRows: 1).rows == [["2"]])
            #expect(try await driver.execute("db.people.find({}).count()", maxRows: 1).rows == [["3"]])
            let updated = try await driver.execute(#"db.people.updateOne({ name: "Ada" }, { $set: { age: 37 } })"#, maxRows: 1)
            #expect(updated.rowsAffected == 1)
            #expect(try await driver.execute(#"db.people.findOne({ name: "Ada" }, { age: 1, _id: 0 })"#, maxRows: 1).rows == [["37"]])
            let grouped = try await driver.execute("""
                db.people.aggregate([{ $group: { _id: null, total: { $sum: "$age" } } }])
                """, maxRows: 10)
            #expect(grouped.rows == [[nil, "163"]])
            #expect(try await driver.execute("db.people.distinct('name')", maxRows: 10).rows.count == 3)
            let deleted = try await driver.execute("db.people.deleteMany({ age: { $gt: 80 } })", maxRows: 1)
            #expect(deleted.rowsAffected == 1)

            let ping = try await driver.execute("{ ping: 1 }", maxRows: 1)
            #expect(!ping.isRowSet)
            let collections = try await driver.execute("show collections", maxRows: 10)
            #expect(collections.rows.map { $0[0] } == ["people"])
            await #expect(throws: DatabaseError.self) { try await driver.execute("db.people.insertOne({ _id: 7 }); db.people.insertOne({ _id: 7 })", maxRows: 1) }
            await #expect(throws: DatabaseError.self) { try await driver.execute("db.people.updateOne({}, { name: 'x' })", maxRows: 1) }
        }
    }

    @Test func browsesCollections() async throws {
        try await MongoIT.withDriver { driver in
            let documents = (0..<30).map { "{ n: \($0), even: \($0 % 2 == 0) }" }.joined(separator: ", ")
            _ = try await driver.execute("db.numbers.insertMany([\(documents)])", maxRows: 100)
            _ = try await driver.execute("db.numbers.createIndex({ n: 1 }, { unique: true })", maxRows: 1)
            _ = try await driver.execute("db.createView('evens', 'numbers', [{ $match: { even: true } }])", maxRows: 1)

            let schemas = try await driver.listSchemas()
            #expect(schemas.first?.name == MongoIT.database)
            #expect(schemas.first?.tables.map(\.ref.name) == ["evens", "numbers"])
            #expect(schemas.first?.tables.map(\.kind) == [.view, .collection])

            let table = TableRef(schema: nil, name: "numbers")
            let page = try await driver.page(of: table, filter: "{ n: { $gte: 10 } }", sort: GridSort(column: "n", ascending: false),
                                             limit: 5, offset: 5)
            #expect(page.columns == ["_id", "n", "even"])
            #expect(page.rows.map { $0[1] } == ["24", "23", "22", "21", "20"])
            #expect(try await driver.count(of: table, filter: "{ even: true }") == 15)
            #expect(try await driver.count(of: TableRef(schema: nil, name: "evens"), filter: nil) == 15)
            await #expect(throws: DatabaseError.self) { try await driver.page(of: table, filter: "[1]", sort: nil, limit: 5, offset: 0) }

            let structure = try await driver.tableStructure(table)
            #expect(structure.columns.map(\.name) == ["_id", "n", "even"])
            #expect(structure.columns.map(\.dataType) == ["objectId", "int", "bool"])
            #expect(structure.primaryKey == ["_id"])
            #expect(structure.indexes.map(\.name) == ["_id_", "n_1"])
            #expect(structure.indexes.last?.isUnique == true)
            #expect(structure.ddl == #"db.createCollection("numbers")"#)
            let view = try await driver.tableStructure(TableRef(schema: nil, name: "evens"))
            #expect(view.ddl?.contains("\"viewOn\": \"numbers\"") == true)
        }
    }

    @Test func switchesDatabasesWithUse() async throws {
        try await MongoIT.withDriver { driver in
            _ = try await driver.execute("use dbee_it_other", maxRows: 1)
            #expect(try await driver.currentDatabase() == "dbee_it_other")
            _ = try await driver.execute("db.things.insertOne({ a: 1 })", maxRows: 1)
            #expect(try await driver.execute("db.getName()", maxRows: 1).rows == [["dbee_it_other"]])
            _ = try await driver.execute("db.dropDatabase()", maxRows: 1)
            try await driver.useDatabase(MongoIT.database)
            #expect(try await driver.currentDatabase() == MongoIT.database)
        }
    }

    @Test func stopsASlowCommandAndReconnects() async throws {
        try await MongoIT.withDriver { driver in
            _ = try await driver.execute("db.slow.insertOne({ a: 1 })", maxRows: 1)
            let slow = Task {
                try await driver.execute("db.slow.find({ $where: 'sleep(5000) || true' })", maxRows: 1)
            }
            try await Task.sleep(for: .milliseconds(500))
            let started = Date()
            await driver.cancelCurrentQuery()
            await #expect(throws: (any Error).self) { try await slow.value }
            #expect(Date().timeIntervalSince(started) < 2)
            #expect(try await driver.execute("db.slow.countDocuments()", maxRows: 1).rows == [["1"]])
        }
    }

    @Test func preferredTLSFallsBackToPlainTCP() async throws {
        var config = MongoIT.config()
        config.tls = .preferred
        let started = Date()
        let driver = try await MongoDriver.connect(config: config, host: config.host, port: config.port)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!(try await driver.serverVersion()).isEmpty)
        await driver.close()

        config.tls = .required
        await #expect(throws: (any Error).self) {
            try await MongoDriver.connect(config: config, host: config.host, port: config.port)
        }
    }
}
