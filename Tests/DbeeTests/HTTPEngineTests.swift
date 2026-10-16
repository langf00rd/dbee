import Foundation
import NIOCore
import Testing
@testable import Dbee

@Suite struct HTTPWireTests {
    private func head(_ text: String) throws -> HTTPWire.Head? {
        var buffer = ByteBuffer(string: text)
        return try HTTPWire.parseHead(&buffer)
    }

    /// Feeds `bytes` one at a time, the way they may arrive, through the decoder with `WireConnection.read`'s
    /// rule that a parse returning nil leaves the buffer as it was.
    private func decode(_ head: HTTPWire.Head, _ bytes: String) throws -> String {
        var decoder = HTTPWire.BodyDecoder(head: head, method: "POST")
        var pending = ByteBuffer()
        var body: [UInt8] = []
        for byte in Array(bytes.utf8) {
            pending.writeInteger(byte)
            while true {
                var candidate = pending
                guard let piece = try decoder.next(&candidate) else { break }
                pending = candidate
                switch piece {
                case .end: return String(decoding: body, as: UTF8.self)
                case .data(let data): body += Array(data.readableBytesView)
                }
            }
        }
        if decoder.isFinished { return String(decoding: body, as: UTF8.self) }
        throw WireConnection.Failure.closed
    }

    @Test func parsesResponseHeads() throws {
        let parsed = try #require(try head("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nKeep-Alive: timeout=10, max=99\r\nX-A: b\r\n\r\nhello"))
        #expect(parsed.status == 200)
        #expect(parsed.header("content-length") == "5")
        #expect(parsed.keepsAlive)
        #expect(parsed.idleLimit == .seconds(9))
        #expect(try head("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n") == nil)
        #expect(try head("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")?.keepsAlive == false)
        #expect(try head("HTTP/1.0 200 OK\r\n\r\n")?.keepsAlive == false)
        #expect(throws: (any Error).self) { try head("SSH-2.0-OpenSSH\r\n\r\n") }
    }

    @Test func decodesBodiesByteByByte() throws {
        let length = try #require(try head("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n"))
        #expect(try decode(length, "hello world") == "hello world")
        let chunked = try #require(try head("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"))
        #expect(try decode(chunked, "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: x\r\n\r\n") == "hello world")
        let empty = try #require(try head("HTTP/1.1 204 No Content\r\n\r\n"))
        #expect(try decode(empty, "") == "")
        #expect(throws: (any Error).self) { try decode(chunked, "zz\r\n") }
    }

    @Test func encodesRequests() {
        let request = HTTPWire.Request(method: "POST", target: "/?a=1", headers: [("X-Key", "se\r\ncret")], body: Array("{}".utf8))
        let text = String(buffer: HTTPWire.encode(request, host: "db.example.com:8123"))
        #expect(text == "POST /?a=1 HTTP/1.1\r\nHost: db.example.com:8123\r\nUser-Agent: Dbee\r\nX-Key: secret\r\nContent-Length: 2\r\n\r\n{}")
        #expect(HTTPWire.query([("query", "SELECT 1"), ("db", "a&b")]) == "query=SELECT%201&db=a%26b")
    }
}

@Suite struct JSONValueTests {
    @Test func keepsKeyOrderAndNumbers() throws {
        let value = try JSONValue.parse(#"{"z": 1, "a": [true, null, 12345678901234567890], "s": "éé😀\n"}"#)
        #expect(value.object?.keys == ["z", "a", "s"])
        #expect(value["a"]?.array?[2] == .number("12345678901234567890"))
        #expect(value["s"]?.string == "éé😀\n")
        #expect(value.json == #"{"z": 1, "a": [true, null, 12345678901234567890], "s": "éé😀\n"}"#)
        #expect(try JSONValue.parse("[]").pretty == "[]")
        #expect(try JSONValue.parse(#"{"a":{"b":1}}"#).pretty == "{\n  \"a\": {\n    \"b\": 1\n  }\n}")
    }

    @Test func rejectsBrokenJSON() {
        for text in ["", "{", "{a: 1}", "[1,]", "tru", "\"open", "1 2", "-"] {
            #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse(text) }
        }
    }

    @Test func makesCells() {
        #expect(JSONValue.null.cell == nil)
        #expect(JSONValue.string("x").cell == "x")
        #expect(JSONValue.array([.number("1"), .string("a")]).cell == #"[1, "a"]"#)
    }
}

@Suite struct ClickHouseFormatTests {
    @Test func readsTabSeparatedOutput() throws {
        var reader = TSVReader(maxRows: 10)
        let body = "a\tb\nString\tNullable(String)\nx\\ty\t\\N\nback\\\\slash\t\\\\N\n"
        // Split mid-line to show partial lines wait for the rest.
        #expect(try reader.feed(Array(body.utf8.prefix(30))))
        #expect(try reader.feed(Array(body.utf8.dropFirst(30))))
        try reader.finish()
        #expect(reader.columns == ["a", "b"])
        #expect(reader.types == ["String", "Nullable(String)"])
        #expect(reader.rows == [["x\ty", nil], ["back\\slash", "\\N"]])
    }

    @Test func stopsAtTheRowLimit() throws {
        var reader = TSVReader(maxRows: 2)
        #expect(try !reader.feed(Array("n\nUInt8\n1\n2\n3\n4\n".utf8)))
        #expect(reader.rows == [["1"], ["2"]])
        #expect(reader.truncated)
    }

    @Test func recognisesExceptionsInTheBody() throws {
        var reader = TSVReader(maxRows: 10)
        let body = "n\nUInt8\n0\nCode: 395. DB::Exception: boom: while executing. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 24.8.1)\n"
        #expect {
            _ = try reader.feed(Array(body.utf8))
        } throws: { error in
            (error as? ClickHouseError)?.name == "FUNCTION_THROW_IF_VALUE_IS_NON_ZERO"
        }
    }

    @Test func parsesExceptions() {
        let error = ClickHouseError("Code: 60. DB::Exception: Unknown table expression identifier 'x' in scope SELECT * FROM x. (UNKNOWN_TABLE) (version 24.8.14.39 (official build))\n")
        #expect(error.code == 60)
        #expect(error.name == "UNKNOWN_TABLE")
        #expect(error.message == "Unknown table expression identifier 'x' in scope SELECT * FROM x.")
        #expect(error.databaseError.detail == "UNKNOWN_TABLE · code 60")
    }

    @Test func quotesForClickHouse() {
        let d = SQLDialect(kind: .clickhouse)
        #expect(d.quoteIdentifier("a`b\\c") == "`a\\`b\\\\c`")
        #expect(d.literal("it's \\ \0") == "'it''s \\\\ \\0'")
        #expect(d.truncate(TableRef(schema: nil, name: "t")) == "TRUNCATE TABLE `t`")
    }
}

@Suite struct MeilisearchLanguageTests {
    @Test func parsesRequests() throws {
        let search = try MeilisearchRequest.parse("post indexes/movies/search\n{ \"q\": \"x\" }")
        #expect(search == MeilisearchRequest(method: "POST", target: "/indexes/movies/search", body: "{ \"q\": \"x\" }"))
        #expect(try MeilisearchRequest.parse("GET /indexes/a|b?limit=2").target == "/indexes/a%7Cb?limit=2")
        #expect(try MeilisearchRequest.parse("GET /indexes/caf%C3%A9").target == "/indexes/caf%C3%A9")
        #expect(try MeilisearchRequest.parse("GET /indexes/café").target == "/indexes/caf%C3%A9")
        #expect(try MeilisearchRequest.parse("DELETE http://localhost:7700/indexes/a?x=1").target == "/indexes/a?x=1")
        #expect(throws: DatabaseError.self) { try MeilisearchRequest.parse("SEARCH /indexes") }
        #expect(throws: DatabaseError.self) { try MeilisearchRequest.parse("GET") }
        #expect(throws: DatabaseError.self) { try MeilisearchRequest.parse("POST /x { nope }") }
    }

    @Test func splitsRequests() {
        let script = """
            # list them
            GET /indexes

            POST /indexes/movies/search
            {
              "q": "GET this"
            }
            // done
            DELETE /indexes/old
            """
        let statements = SQLSplitter.split(script, kind: .meilisearch)
        #expect(statements.map(\.text) == [
            "GET /indexes",
            "POST /indexes/movies/search\n{\n  \"q\": \"GET this\"\n}",
            "DELETE /indexes/old",
        ])
        let ns = script as NSString
        #expect(statements.allSatisfy { ns.substring(with: $0.range) == $0.text })
    }

    @Test func highlightsMethodsAndJSON() {
        let tokens = SQLHighlighter.tokens(in: "GET /indexes\n# note\nPOST /x { \"a\": true }" as NSString, kind: .meilisearch)
        #expect(tokens.map(\.kind) == [.keyword, .comment, .keyword, .string, .keyword])
    }

    @Test func shapesResponses() throws {
        let hits = MeilisearchDriver.grid(try JSONValue.parse(#"{"hits": [{"id": 1, "t": "a"}, {"id": 2, "x": [1]}], "query": ""}"#), maxRows: 10)
        #expect(hits.columns == ["id", "t", "x"])
        #expect(hits.rows == [["1", "a", nil], ["2", nil, "[1]"]])
        let stats = MeilisearchDriver.grid(try JSONValue.parse(#"{"databaseSize": 10, "indexes": {}}"#), maxRows: 10)
        #expect(stats.columns == ["field", "value"])
        #expect(stats.rows == [["databaseSize", "10"], ["indexes", "{}"]])
        let empty = MeilisearchDriver.documentGrid([], maxRows: 10, primaryKey: "sku")
        #expect(empty.isRowSet)
        #expect(empty.columns == ["sku"])
        let keyed = MeilisearchDriver.documentGrid([try JSONValue.parse(#"{"a": 1, "sku": "x"}"#)], maxRows: 10, primaryKey: "sku")
        #expect(keyed.columns == ["sku", "a"])
        #expect(keyed.rows == [["x", "1"]])
    }

    @Test func buildsFilters() {
        typealias Draft = TableBrowserModel.FilterDraft
        #expect(TableBrowserModel.meilisearchFilter(for: Draft(column: "genre", op: .equal, value: "sci \"fi\"")) == #"genre = "sci \"fi\"""#)
        #expect(TableBrowserModel.meilisearchFilter(for: Draft(column: "year", op: .greater, value: "2000")) == "year > 2000")
        #expect(TableBrowserModel.meilisearchFilter(for: Draft(column: "id", op: .in, value: "1, a")) == #"id IN [1, "a"]"#)
        #expect(TableBrowserModel.meilisearchFilter(for: Draft(column: "x", op: .isNull)) == "x IS NULL")
        #expect(TableBrowserModel.meilisearchFilter(for: Draft(column: "x", op: .like, value: "%a%")) == nil)
        #expect(SQLDialect(kind: .meilisearch).drop(TableRef(schema: nil, name: "my index"), kind: .searchIndex) == "DELETE /indexes/my%20index")
    }
}

@Suite struct HTTPConnectionURLTests {
    @Test func readsClickHouseAndCassandraURLs() {
        var config = ConnectionConfig()
        #expect(ConnectionString.apply("clickhouse://default:pw@olap.example.com/logs?secure=true", to: &config))
        #expect(config.kind == .clickhouse)
        #expect(config.port == 8123)
        #expect(config.database == "logs")
        #expect(config.tls == .verifyFull)

        #expect(ConnectionString.apply("cassandra://cassandra:cassandra@10.0.0.5/app", to: &config))
        #expect(config.kind == .scylla)
        #expect(config.port == 9042)
        #expect(config.database == "app")
        #expect(config.tls == .disabled)
    }

    @Test func readsHTTPURLsForHTTPEngines() {
        var config = ConnectionConfig()
        config.kind = .postgres
        #expect(!ConnectionString.apply("https://search.example.com", to: &config))

        config.kind = .meilisearch
        #expect(ConnectionString.apply("https://search.example.com/indexes/movies?key=abc", to: &config))
        #expect(config.kind == .meilisearch)
        #expect(config.port == 443)
        #expect(config.tls == .verifyFull)
        #expect(config.database == "")
        #expect(config.password == "abc")

        config = ConnectionConfig()
        config.kind = .clickhouse
        #expect(ConnectionString.apply("http://user@127.0.0.1:8123", to: &config))
        #expect(config.port == 8123)
        #expect(config.username == "user")
        #expect(config.tls == .disabled)
    }
}
