import Foundation
import Testing
@testable import Dbee

// Integration tests run against a real server and are skipped unless DBEE_MEILI_PORT is set:
//   docker run -d --name dbee-it-meili -e MEILI_MASTER_KEY=dbee_test_master_key_0123456789 \
//     -p 127.0.0.1:57700:7700 getmeili/meilisearch:v1.12
//   DBEE_MEILI_PORT=57700 swift test --filter Meilisearch

private enum MeiliIT {
    static let port = ProcessInfo.processInfo.environment["DBEE_MEILI_PORT"].flatMap(Int.init)
    static let key = ProcessInfo.processInfo.environment["DBEE_MEILI_KEY"] ?? "dbee_test_master_key_0123456789"
    static let index = "dbee_it_movies"

    static func config(key: String = MeiliIT.key) -> ConnectionConfig {
        var config = ConnectionConfig()
        config.kind = .meilisearch
        config.host = "127.0.0.1"
        config.port = port ?? 7700
        config.password = key
        config.tls = .disabled
        return config
    }

    /// A driver with a fresh `movies` index holding five documents, filterable by genre and year.
    static func withDriver<T>(_ body: (MeilisearchDriver) async throws -> T) async throws -> T {
        let config = config()
        let driver = try await MeilisearchDriver.connect(config: config, host: config.host, port: config.port)
        do {
            _ = try? await driver.execute("DELETE /indexes/\(index)", maxRows: 10)
            _ = try await driver.execute(#"POST /indexes { "uid": "\#(index)", "primaryKey": "id" }"#, maxRows: 10)
            _ = try await driver.execute("""
                PATCH /indexes/\(index)/settings
                { "filterableAttributes": ["genre", "year"], "sortableAttributes": ["year"] }
                """, maxRows: 10)
            _ = try await driver.execute("""
                POST /indexes/\(index)/documents
                [
                  { "id": 1, "title": "Alien", "genre": "horror", "year": 1979 },
                  { "id": 2, "title": "Heat", "genre": "crime", "year": 1995, "rating": 8.3 },
                  { "id": 3, "title": "The Thing", "genre": "horror", "year": 1982 },
                  { "id": 4, "title": "Arrival", "genre": "sci-fi", "year": 2016, "tags": ["linguistics", "aliens"] },
                  { "id": 5, "title": "Brazil", "genre": "sci-fi", "year": 1985, "crew": { "director": "Gilliam" } }
                ]
                """, maxRows: 10)
            let result = try await body(driver)
            _ = try? await driver.execute("DELETE /indexes/\(index)", maxRows: 10)
            await driver.close()
            return result
        } catch {
            await driver.close()
            throw error
        }
    }
}

@Suite("Meilisearch integration", .serialized, .enabled(if: MeiliIT.port != nil, "set DBEE_MEILI_PORT to run"),
       .timeLimit(.minutes(2)))
struct MeilisearchIntegrationTests {
    @Test func connectsAndRefusesBadKeys() async throws {
        let config = MeiliIT.config()
        let driver = try await MeilisearchDriver.connect(config: config, host: config.host, port: config.port)
        #expect(try await driver.serverVersion().hasPrefix("Meilisearch 1."))
        #expect(try await driver.listDatabases().isEmpty)
        #expect(try await driver.currentDatabase() == "")
        await driver.close()

        let none = MeiliIT.config(key: "")
        await #expect {
            try await MeilisearchDriver.connect(config: none, host: none.host, port: none.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "Meilisearch needs an API key."
        }
        let wrong = MeiliIT.config(key: "nope")
        await #expect {
            try await MeilisearchDriver.connect(config: wrong, host: wrong.host, port: wrong.port)
        } throws: { error in
            (error as? DatabaseError)?.message == "Meilisearch refused the API key."
        }
    }

    @Test func runsRequestsAndWaitsForTasks() async throws {
        try await MeiliIT.withDriver { driver in
            // The documents were added by a task; waiting for it means they are searchable now.
            let search = try await driver.execute(#"POST /indexes/\#(MeiliIT.index)/search { "q": "alien", "filter": "genre = horror" }"#,
                                                  maxRows: 100)
            #expect(search.columns.first == "id")
            #expect(search.columns.contains("title"))
            #expect(search.rows.count == 1)
            #expect(search.rows.first?[search.columns.firstIndex(of: "title")!] == "Alien")

            let documents = try await driver.execute("GET /indexes/\(MeiliIT.index)/documents?limit=10", maxRows: 3)
            #expect(documents.rows.count == 3)
            #expect(documents.truncated)

            let one = try await driver.execute("GET /indexes/\(MeiliIT.index)/documents/5", maxRows: 100)
            #expect(one.columns == ["field", "value"])
            #expect(one.rows.contains(["crew", #"{"director": "Gilliam"}"#]))

            let task = try await driver.execute(#"PUT /indexes/\#(MeiliIT.index)/documents [{ "id": 2, "rating": 8.4 }]"#, maxRows: 100)
            #expect(task.rows.contains(["status", "succeeded"]))

            let indexes = try await driver.execute("GET /indexes", maxRows: 100)
            #expect(indexes.columns.contains("uid"))
            #expect(indexes.rows.contains { $0.contains(MeiliIT.index) })
        }
    }

    @Test func outlivesTheServersKeepAliveTimeout() async throws {
        let config = MeiliIT.config()
        let driver = try await MeilisearchDriver.connect(config: config, host: config.host, port: config.port)
        _ = try await driver.execute("GET /version", maxRows: 10)
        // Meilisearch closes connections idle for five seconds.
        try await Task.sleep(for: .seconds(6))
        let version = try await driver.execute("GET /version", maxRows: 10)
        #expect(version.rows.contains { $0.first == "pkgVersion" })
        await driver.close()
    }

    @Test func reportsErrors() async throws {
        try await MeiliIT.withDriver { driver in
            await #expect {
                try await driver.execute("GET /indexes/no_such_index", maxRows: 1)
            } throws: { error in
                (error as? DatabaseError)?.detail == "index_not_found"
            }
            // A task that fails: the documents have no id.
            await #expect {
                try await driver.execute(#"POST /indexes/\#(MeiliIT.index)/documents [{ "title": "No id" }]"#, maxRows: 1)
            } throws: { error in
                (error as? DatabaseError)?.detail?.hasPrefix("missing_document_id") == true
            }
            await #expect {
                try await driver.execute("POST /indexes/x/search { q: 1 }", maxRows: 1)
            } throws: { error in
                (error as? DatabaseError)?.message == "The request body isn't valid JSON."
            }
        }
    }

    @Test func listsAndBrowsesIndexes() async throws {
        try await MeiliIT.withDriver { driver in
            let schemas = try await driver.listSchemas()
            #expect(schemas.map(\.name) == [MeilisearchDriver.schemaName])
            let table = try #require(schemas.first?.tables.first { $0.ref.name == MeiliIT.index })
            #expect(table.kind == .searchIndex)

            let page = try await driver.page(of: table.ref, filter: nil, sort: nil, limit: 2, offset: 2)
            #expect(page.columns.first == "id")
            #expect(page.rows.map { $0[0] } == ["3", "4"])
            #expect(try await driver.count(of: table.ref, filter: nil) == 5)

            let horror = try await driver.page(of: table.ref, filter: "genre = horror", sort: GridSort(column: "year", ascending: false),
                                               limit: 10, offset: 0)
            let year = try #require(horror.columns.firstIndex(of: "year"))
            #expect(horror.rows.map { $0[year] } == ["1982", "1979"])
            #expect(try await driver.count(of: table.ref, filter: "genre = horror") == 2)
            #expect(try await driver.count(of: table.ref, filter: "year > 1990") == 2)

            let simple = TableBrowserModel.meilisearchFilter(for: .init(column: "genre", op: .equal, value: "sci-fi"))
            #expect(try await driver.count(of: table.ref, filter: simple) == 2)
            let range = TableBrowserModel.meilisearchFilter(for: .init(column: "year", op: .in, value: "1979, 2016"))
            #expect(try await driver.count(of: table.ref, filter: range) == 2)

            let structure = try await driver.tableStructure(table.ref)
            #expect(structure.primaryKey == ["id"])
            #expect(Array(structure.columns.map(\.name).prefix(4)) == ["id", "title", "genre", "year"])
            #expect(Set(structure.columns.map(\.name)) == ["id", "title", "genre", "year", "rating", "tags", "crew"])
            #expect(structure.columns.first { $0.name == "year" }?.comment?.hasPrefix("Searchable, filterable, sortable") == true)
            #expect(structure.columns.first { $0.name == "rating" }?.comment?.contains("in 1 of 5 documents") == true)
            #expect(structure.columns.first { $0.name == "tags" }?.dataType == "array")
            #expect(structure.ddl?.contains("\"filterableAttributes\"") == true)

            let dialect = SQLDialect(kind: .meilisearch)
            _ = try await driver.execute(dialect.truncate(table.ref), maxRows: 10)
            #expect(try await driver.count(of: table.ref, filter: nil) == 0)
            _ = try await driver.execute(dialect.drop(table.ref, kind: .searchIndex), maxRows: 10)
            #expect(try await driver.listSchemas().first?.tables.contains { $0.ref.name == MeiliIT.index } == false)
        }
    }
}
