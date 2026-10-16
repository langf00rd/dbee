import Foundation
import NIOCore
import Testing
@testable import Dbee

@Suite struct CQLLanguageTests {
    private func texts(_ script: String) -> [String] {
        SQLSplitter.split(script, kind: .scylla).map(\.text)
    }

    @Test func splitsStatements() {
        #expect(texts("SELECT 1; SELECT 'a;b' FROM \"t;\"; -- c;\nSELECT 2 // x;\n;") == ["SELECT 1", "SELECT 'a;b' FROM \"t;\"", "SELECT 2"])
        #expect(texts("SELECT 'it''s; ok'") == ["SELECT 'it''s; ok'"])
        #expect(texts("CREATE FUNCTION f() CALLED ON NULL INPUT RETURNS int LANGUAGE lua AS $$ return 1; $$; SELECT 1")
                == ["CREATE FUNCTION f() CALLED ON NULL INPUT RETURNS int LANGUAGE lua AS $$ return 1; $$", "SELECT 1"])
    }

    @Test func keepsBatchesWhole() {
        let script = """
            begin unlogged batch
              INSERT INTO t (k) VALUES (1);
              UPDATE t SET v = 2 WHERE k = 1;
            APPLY BATCH;
            BEGIN COUNTER BATCH UPDATE c SET n = n + 1 WHERE k = 1; APPLY BATCH;
            SELECT * FROM t
            """
        let statements = texts(script)
        #expect(statements.count == 3)
        #expect(statements[0].hasPrefix("begin unlogged batch") && statements[0].hasSuffix("APPLY BATCH"))
        #expect(statements[1] == "BEGIN COUNTER BATCH UPDATE c SET n = n + 1 WHERE k = 1; APPLY BATCH")
        #expect(statements[2] == "SELECT * FROM t")
    }

    @Test func quotesNamesAndLiterals() {
        #expect(ScyllaDriver.quoteName("users") == "users")
        #expect(ScyllaDriver.quoteName("Users") == "\"Users\"")
        #expect(ScyllaDriver.quoteName("my table") == "\"my table\"")
        #expect(ScyllaDriver.literal("it's") == "'it''s'")
        #expect(ScyllaDriver.literal("a\0") == "blobAsText(0x6100)")
        let d = SQLDialect(kind: .scylla)
        #expect(d.drop(TableRef(schema: nil, name: "v"), kind: .materializedView) == "DROP MATERIALIZED VIEW \"v\"")
        #expect(d.truncate(TableRef(schema: nil, name: "t")) == "TRUNCATE TABLE \"t\"")
    }

    @Test func buildsFilters() {
        typealias Draft = TableBrowserModel.FilterDraft
        #expect(TableBrowserModel.cqlFilter(for: Draft(column: "id", op: .equal, value: "42"), type: "int") == "id = 42")
        #expect(TableBrowserModel.cqlFilter(for: Draft(column: "id", op: .equal, value: "42"), type: "text") == "id = '42'")
        #expect(TableBrowserModel.cqlFilter(for: Draft(column: "Name", op: .like, value: "A%"), type: "text") == "\"Name\" LIKE 'A%'")
        #expect(TableBrowserModel.cqlFilter(for: Draft(column: "id", op: .in, value: "1, 2"), type: "bigint") == "id IN (1, 2)")
        #expect(TableBrowserModel.cqlFilter(for: Draft(column: "id", op: .notEqual, value: "1"), type: "int") == nil)
        #expect(TableBrowserModel.cqlFilter(for: Draft(column: "id", op: .isNull), type: "int") == nil)
    }
}

@Suite struct CQLProtocolTests {
    @Test func readsFramesOnlyWhenComplete() throws {
        var body = ByteBuffer()
        body.writeInteger(Int32(0x0001))
        let frame = CQLProtocol.frame(.query, stream: 3, body: body)
        var response = frame
        response.setInteger(UInt8(0x84), at: response.readerIndex)
        var partial = response.getSlice(at: response.readerIndex, length: 10)!
        #expect(try CQLProtocol.parseFrame(&partial) == nil)
        let parsed = try #require(try CQLProtocol.parseFrame(&response))
        #expect(parsed.stream == 3)
        var result = parsed.body
        guard case .void = try CQLProtocol.readResult(&result) else {
            Issue.record("expected a void result")
            return
        }
    }

    @Test func formatsNumbers() {
        #expect(CQLFormatting.varint([0x00]) == "0")
        #expect(CQLFormatting.varint([0xFF]) == "-1")
        #expect(CQLFormatting.varint([0x01, 0x00]) == "256")
        // 2^72 and -(2^72): longer than 8 bytes.
        #expect(CQLFormatting.varint([0x01] + Array(repeating: 0, count: 9)) == "4722366482869645213696")
        #expect(CQLFormatting.varint([0xFF, 0x00] + Array(repeating: 0, count: 8)) == "-4722366482869645213696")
        #expect(CQLFormatting.decimal(unscaled: "-12345", scale: 3) == "-12.345")
        #expect(CQLFormatting.decimal(unscaled: "5", scale: 3) == "0.005")
        #expect(CQLFormatting.decimal(unscaled: "5", scale: -2) == "500")
        #expect(CQLFormatting.signedInteger([0x80, 0, 0, 0]) == Int64(Int32.min))
    }

    @Test func formatsDatesAndTimes() {
        #expect(CQLFormatting.day(0) == "1970-01-01")
        #expect(CQLFormatting.day(-1) == "1969-12-31")
        #expect(CQLFormatting.day(19_783) == "2024-03-01")
        #expect(CQLFormatting.timestamp(milliseconds: 0) == "1970-01-01 00:00:00.000Z")
        #expect(CQLFormatting.timestamp(milliseconds: -1) == "1969-12-31 23:59:59.999Z")
        #expect(CQLFormatting.timestamp(milliseconds: 1_709_296_496_789) == "2024-03-01 12:34:56.789Z")
    }

    @Test func formatsCollections() {
        func bytes(_ items: [[UInt8]?], counted: Bool = true) -> [UInt8] {
            var buffer = ByteBuffer()
            if counted { buffer.writeInteger(Int32(items.count)) }
            for item in items { CQLProtocol.writeBytes(item, to: &buffer) }
            return Array(buffer.readableBytesView)
        }
        let text = CQLProtocol.DataType.native(0x000D)
        let int = CQLProtocol.DataType.native(0x0009)
        #expect(CQLFormatting.text(bytes([Array("a".utf8), Array("it's".utf8)]), type: .list(text)) == "['a', 'it''s']")
        #expect(CQLFormatting.text(bytes([[0, 0, 0, 1]]), type: .set(int)) == "{1}")
        // A map's count is the number of pairs.
        let map = [UInt8]([0, 0, 0, 1]) + bytes([Array("k".utf8), [0, 0, 0, 2]], counted: false)
        #expect(CQLFormatting.text(map, type: .map(text, int)) == "{'k': 2}")
        #expect(CQLFormatting.text(bytes([[0, 0, 0, 7], nil], counted: false), type: .tuple([int, text])) == "(7, null)")
    }
}
