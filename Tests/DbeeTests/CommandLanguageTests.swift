import Foundation
import NIOCore
import Testing
@testable import Dbee

@Suite struct RedisProtocolTests {
    private func parse(_ text: String) throws -> RESPValue? {
        var buffer = ByteBuffer(string: text)
        return try RESPParser.parse(&buffer)
    }

    @Test func parsesReplies() throws {
        #expect(try parse("+OK\r\n") == .simple("OK"))
        #expect(try parse("-ERR wrong\r\n") == .error("ERR wrong"))
        #expect(try parse(":42\r\n") == .integer(42))
        #expect(try parse("$5\r\nhello\r\n") == .bulk(Array("hello".utf8)))
        #expect(try parse("$-1\r\n") == .bulk(nil))
        #expect(try parse("*2\r\n$1\r\na\r\n:1\r\n") == .array([.bulk([0x61]), .integer(1)]))
        #expect(try parse("%1\r\n+k\r\n+v\r\n") == .array([.simple("k"), .simple("v")]))
        #expect(try parse("_\r\n") == .bulk(nil))
    }

    @Test func waitsForCompleteReplies() throws {
        #expect(try parse("$5\r\nhel") == nil)
        #expect(try parse("*2\r\n$1\r\na\r\n") == nil)
        #expect(try parse(":4") == nil)
        var buffer = ByteBuffer(string: "*2\r\n$1\r\na\r\n")
        #expect(try RESPParser.parse(&buffer) == nil)
        #expect(buffer.readableBytes == 11, "an incomplete reply leaves the buffer alone")
    }

    @Test func splitsCommandLinesLikeRedisCLI() throws {
        func words(_ line: String) throws -> [String] {
            try RedisCommandLine.arguments(line).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(try words("SET  key   value") == ["SET", "key", "value"])
        #expect(try words(#"SET k "a b\n\"c\"""#) == ["SET", "k", "a b\n\"c\""])
        #expect(try words("SET k 'it\\'s'") == ["SET", "k", "it's"])
        #expect(try RedisCommandLine.arguments(#"SET k "\x00\xff""#)[2] == [0x00, 0xFF])
        #expect(try words("GET \"\"") == ["GET", ""])
        #expect(throws: DatabaseError.self) { try words("GET \"open") }
        for value in ["plain", "with space", "quo\"te", "back\\slash", "new\nline", ""] {
            #expect(try words("GET " + RedisCommandLine.quoted(value)) == ["GET", value])
        }
    }

    @Test func shapesReplies() {
        let pairs = RedisDriver.result(for: ["HGETALL", "h"], reply: .array([.bulk(Array("f".utf8)), .bulk(Array("v".utf8))]), maxRows: 10)
        #expect(pairs.columns == ["field", "value"])
        #expect(pairs.rows == [["f", "v"]])

        let scan = RedisDriver.result(for: ["SCAN", "0"], reply: .array([.bulk(Array("17".utf8)), .array([.bulk([0x61]), .bulk([0x62])])]), maxRows: 10)
        #expect(scan.columns == ["next cursor", "key"])
        #expect(scan.rows == [["17", "a"], ["17", "b"]])

        let ok = RedisDriver.result(for: ["SET", "a", "b"], reply: .simple("OK"), maxRows: 10)
        #expect(!ok.isRowSet)

        let limited = RedisDriver.result(for: ["LRANGE", "l", "0", "-1"], reply: .array((0..<5).map { .integer($0) }), maxRows: 3)
        #expect(limited.rows.count == 3)
        #expect(limited.truncated)

        #expect(RedisFormatting.text([0x68, 0x69]) == "hi")
        #expect(RedisFormatting.text([0xFF, 0x00]) == "\\xff00")
    }
}

@Suite struct BSONTests {
    @Test func roundTripsEveryType() throws {
        let document: BSONDocument = [
            "double": .double(1.5),
            "string": .string("héllo"),
            "document": .document(["a": .int32(1)]),
            "array": .array([.int32(1), .string("two")]),
            "binary": .binary(subtype: 4, data: [1, 2, 3]),
            "objectId": .objectId(Array(0..<12)),
            "bool": .bool(true),
            "date": .date(1_700_000_000_123),
            "null": .null,
            "regex": .regex(pattern: "^a", options: "i"),
            "int32": .int32(-7),
            "timestamp": .timestamp(42 << 32 | 7),
            "int64": .int64(1 << 40),
            "decimal": .decimal128(Decimal128.bytes("12.50")!),
            "min": .minKey,
            "max": .maxKey,
        ]
        var buffer = ByteBuffer()
        document.encode(into: &buffer)
        let decoded = try BSONDocument.decode(from: &buffer)
        #expect(decoded == document)
        #expect(buffer.readableBytes == 0)
    }

    @Test func formatsValues() {
        #expect(BSONFormatting.cell(.objectId(Array(repeating: 0xAB, count: 12))) == String(repeating: "ab", count: 12))
        #expect(BSONFormatting.cell(.date(0)) == "1970-01-01T00:00:00.000Z")
        #expect(BSONFormatting.cell(.null) == nil)
        #expect(BSONFormatting.cell(.double(2)) == "2.0")
        #expect(BSONFormatting.json(.document(["a": .array([.int32(1), .bool(false)])])) == #"{"a": [1, false]}"#)
        #expect(BSONFormatting.json(.objectId(Array(repeating: 0, count: 12))) == #"{"$oid": "000000000000000000000000"}"#)
        let nested = BSONFormatting.cell(.document(["when": .date(0), "n": .int64(5)]))!
        #expect((try? JSONSerialization.jsonObject(with: Data(nested.utf8))) != nil, "nested values are valid JSON")
    }

    @Test(arguments: ["0", "12.50", "-3", "1E+3", "0.001", "123456789012345678901234567890"])
    func roundTripsDecimal128(_ text: String) throws {
        let bytes = try #require(Decimal128.bytes(text))
        #expect(Decimal128.string(bytes) == text)
    }
}

@Suite struct MongoShellParserTests {
    @Test func parsesRelaxedValues() throws {
        let value = try MongoShellParser.value("""
            { name: 'Ada', "age": 36, score: 1.5, big: 5000000000, tags: ['a', "b",], ok: true, none: null,
              id: ObjectId("0123456789abcdef01234567"), at: ISODate("2024-01-02T03:04:05Z"), re: /^a[/]b/i,
              n: NumberLong("9"), d: NumberDecimal("1.10"), $or: [], // comment
              neg: -2 }
            """)
        let document = try #require(value.document)
        #expect(document.keys == ["name", "age", "score", "big", "tags", "ok", "none", "id", "at", "re", "n", "d", "$or", "neg"])
        #expect(document["name"] == .string("Ada"))
        #expect(document["age"] == .int32(36))
        #expect(document["score"] == .double(1.5))
        #expect(document["big"] == .int64(5_000_000_000))
        #expect(document["tags"] == .array([.string("a"), .string("b")]))
        #expect(document["none"] == .null)
        #expect(document["id"] == .objectId(MongoShellParser.hexBytes("0123456789abcdef01234567")!))
        #expect(document["at"] == .date(1_704_164_645_000))
        #expect(document["re"] == .regex(pattern: "^a[/]b", options: "i"))
        #expect(document["n"] == .int64(9))
        #expect(document["neg"] == .int32(-2))
    }

    @Test func parsesStatements() throws {
        #expect(try MongoShellParser.statement("show dbs") == .showDatabases)
        #expect(try MongoShellParser.statement("show collections;") == .showCollections)
        #expect(try MongoShellParser.statement("use app") == .use("app"))
        #expect(try MongoShellParser.statement("{ ping: 1 }") == .command(["ping": .int32(1)]))
        #expect(try MongoShellParser.statement("db.stats()") == .database(method: "stats", arguments: []))
        #expect(try MongoShellParser.statement("db.users.find({ a: 1 }).sort({ b: -1 }).limit(5)") == .collection(
            name: "users", method: "find", arguments: [.document(["a": .int32(1)])],
            chain: [MongoCall(method: "sort", arguments: [.document(["b": .int32(-1)])]),
                    MongoCall(method: "limit", arguments: [.int32(5)])]))
        #expect(try MongoShellParser.statement(#"db.getCollection("my coll").drop()"#)
            == .collection(name: "my coll", method: "drop", arguments: [], chain: []))
        #expect(try MongoShellParser.statement(#"db["x"].countDocuments()"#)
            == .collection(name: "x", method: "countDocuments", arguments: [], chain: []))
        #expect(try MongoShellParser.statement("db.system.users.find()")
            == .collection(name: "system.users", method: "find", arguments: [], chain: []))
        #expect(throws: DatabaseError.self) { try MongoShellParser.statement("SELECT 1") }
        #expect(throws: DatabaseError.self) { try MongoShellParser.statement("db.users.find({ a: 1 ") }
    }
}

@Suite struct MongoSCRAMTests {
    /// RFC 7677, section 3.
    @Test func matchesRFC7677() throws {
        let scram = MongoSCRAM(mechanism: .sha256, username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(String(decoding: scram.clientFirst, as: UTF8.self) == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let (final, signature) = try scram.clientFinal(
            serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(String(decoding: final, as: UTF8.self)
            == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        #expect(signature.base64EncodedString() == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    @Test func rejectsAForeignNonce() {
        let scram = MongoSCRAM(mechanism: .sha256, username: "user", password: "pencil", clientNonce: "abc")
        #expect(throws: DatabaseError.self) { try scram.clientFinal(serverFirst: "r=xyz,s=AAAA,i=4096") }
    }
}

@Suite struct CommandScriptTests {
    private func texts(_ script: String, _ kind: DatabaseKind) -> [String] {
        let statements = SQLSplitter.split(script, kind: kind)
        let ns = script as NSString
        for statement in statements { #expect(ns.substring(with: statement.range) == statement.text) }
        return statements.map(\.text)
    }

    @Test func splitsRedisByLine() {
        #expect(texts("SET a 1\n\n  GET a  \n# comment\nDEL a", .redis) == ["SET a 1", "GET a", "DEL a"])
        #expect(texts("SET a \"two\nlines\"\nGET a", .redis) == ["SET a \"two\nlines\"", "GET a"])
    }

    @Test func splitsMongoStatements() {
        let script = """
            db.users.find({
              age: { $gt: 30 }
            })
              .sort({ name: 1 })
            // comment
            show collections
            db.a.insertOne({ s: "x;y" }); db.a.drop()
            db.b.find({ r: /a;b/ })
            """
        #expect(texts(script, .mongodb) == [
            "db.users.find({\n  age: { $gt: 30 }\n})\n  .sort({ name: 1 })",
            "show collections",
            #"db.a.insertOne({ s: "x;y" })"#,
            "db.a.drop()",
            "db.b.find({ r: /a;b/ })",
        ])
    }

    @Test func highlightsCommands() {
        let redis = SQLHighlighter.tokens(in: "GET user:1\nSET \"k\" 10", kind: .redis)
        #expect(redis.map(\.kind) == [.keyword, .keyword, .string, .number])
        let mongo = SQLHighlighter.tokens(in: #"db.users.find({ $gt: 1, n: "x" })"#, kind: .mongodb)
        #expect(mongo.contains { $0.kind == .keyword && $0.range == NSRange(location: 9, length: 4) })
        #expect(mongo.contains { $0.kind == .parameter })
        #expect(mongo.contains { $0.kind == .string })
    }
}

@Suite struct CommandConnectionStringTests {
    @Test func readsRedisURLs() {
        var config = ConnectionConfig()
        #expect(ConnectionString.apply("rediss://alice:s3cret@cache.example.com:6380/2", to: &config))
        #expect(config.kind == .redis)
        #expect(config.host == "cache.example.com")
        #expect(config.port == 6380)
        #expect(config.username == "alice")
        #expect(config.password == "s3cret")
        #expect(config.database == "2")
        #expect(config.tls == .verifyFull)

        #expect(ConnectionString.apply("redis://localhost", to: &config))
        #expect(config.port == 6379)
        #expect(config.tls == .disabled)
    }

    @Test func readsMongoURLs() {
        var config = ConnectionConfig()
        #expect(ConnectionString.apply("mongodb://u:p@db1.example.com:27018,db2.example.com/app?tls=true&replicaSet=rs0", to: &config))
        #expect(config.kind == .mongodb)
        #expect(config.host == "db1.example.com")
        #expect(config.port == 27018)
        #expect(config.username == "u")
        #expect(config.database == "app")
        #expect(config.tls == .verifyFull)

        #expect(ConnectionString.apply("mongodb://localhost/?tls=true&tlsAllowInvalidCertificates=true", to: &config))
        #expect(config.tls == .required)
        #expect(!ConnectionString.apply("mongodb+srv://cluster0.example.net/app", to: &config))
    }
}

@Suite @MainActor struct CommandFilterTests {
    @Test func buildsMongoFilters() throws {
        typealias Draft = TableBrowserModel.FilterDraft
        func filter(_ column: String, _ op: TableBrowserModel.FilterOperator, _ value: String) throws -> BSONDocument? {
            guard let text = TableBrowserModel.mongoFilter(for: Draft(column: column, op: op, value: value)) else { return nil }
            return try MongoDriver.filterDocument(text)
        }
        #expect(try filter("age", .greater, "30") == ["age": .document(["$gt": .int32(30)])])
        #expect(try filter("name", .equal, "Ada") == ["name": .string("Ada")])
        #expect(try filter("name", .like, "A%") == ["name": .regex(pattern: "^A.*$", options: "")])
        #expect(try filter("x", .isNull, "") == ["x": .null])
        let id = "0123456789abcdef01234567"
        #expect(try filter("_id", .equal, id) == ["_id": .document(["$in": .array([
            .objectId(MongoShellParser.hexBytes(id)!), .string(id)])])])
        #expect(try filter("n", .in, "1, two") == ["n": .document(["$in": .array([.int32(1), .string("two")])])])
    }

    @Test func buildsRedisPatterns() {
        typealias Draft = TableBrowserModel.FilterDraft
        #expect(TableBrowserModel.redisPattern(for: Draft(column: "key", op: .like, value: "user:%")) == "user:*")
        #expect(TableBrowserModel.redisPattern(for: Draft(column: "key", op: .equal, value: "a*b")) == "a\\*b")
        #expect(TableBrowserModel.redisPattern(for: Draft(column: "type", op: .equal, value: "hash")) == nil)
    }
}

@Suite struct RedisSelectionTests {
    private func track(_ selection: inout RedisSelection, _ line: String, _ reply: RESPValue) {
        _ = selection.track(line.uppercased().split(separator: " ").map(String.init), reply: reply)
    }

    @Test func queuedSelectWaitsForExec() {
        var selection = RedisSelection(database: 0)
        track(&selection, "MULTI", .simple("OK"))
        track(&selection, "SELECT 1", .simple("QUEUED"))
        #expect(selection.database == 0)
        track(&selection, "EXEC", .array([.simple("OK")]))
        #expect(selection.database == 1)
        #expect(!selection.isInTransaction)
    }

    @Test func discardedSelectKeepsDatabase() {
        var selection = RedisSelection(database: 0)
        track(&selection, "MULTI", .simple("OK"))
        track(&selection, "SELECT 1", .simple("QUEUED"))
        track(&selection, "DISCARD", .simple("OK"))
        #expect(selection.database == 0)
        #expect(!selection.isInTransaction)
    }

    @Test func abortedOrFailedExecKeepsDatabase() {
        var selection = RedisSelection(database: 2)
        track(&selection, "MULTI", .simple("OK"))
        track(&selection, "SELECT 1", .simple("QUEUED"))
        // WATCH conflict: null array.
        track(&selection, "EXEC", .array(nil))
        #expect(selection.database == 2)

        track(&selection, "MULTI", .simple("OK"))
        track(&selection, "SELECT 1", .simple("QUEUED"))
        track(&selection, "EXEC", .error("EXECABORT Transaction discarded because of previous errors."))
        #expect(selection.database == 2)
        #expect(!selection.isInTransaction)
    }

    @Test func execAppliesOnlyCommandsThatRan() {
        var selection = RedisSelection(database: 0)
        track(&selection, "MULTI", .simple("OK"))
        track(&selection, "SELECT 3", .simple("QUEUED"))
        track(&selection, "SELECT 99", .simple("QUEUED"))
        track(&selection, "EXEC", .array([.simple("OK"), .error("ERR DB index is out of range")]))
        #expect(selection.database == 3)
    }

    @Test func selectOutsideTransactionAppliesNow() {
        var selection = RedisSelection(database: 0)
        track(&selection, "SELECT 4", .simple("OK"))
        #expect(selection.database == 4)
        track(&selection, "SELECT 5", .error("ERR DB index is out of range"))
        #expect(selection.database == 4)
    }
}

@Suite struct MongoNumericInputTests {
    private func decimal(_ text: String) throws -> String? {
        guard case .decimal128(let bytes) = try MongoShellParser.value(text) else { return nil }
        return Decimal128.string(bytes)
    }

    @Test func numberDecimalKeepsFractions() throws {
        #expect(try decimal("NumberDecimal(12.5)") == "12.5")
        #expect(try decimal("NumberDecimal(0.1)") == "0.1")
        #expect(try decimal("NumberDecimal(-1.9)") == "-1.9")
        #expect(try decimal("NumberDecimal(-0.25)") == "-0.25")
        #expect(try decimal("NumberDecimal(7)") == "7")
        #expect(try decimal("NumberDecimal(5000000000)") == "5000000000")
        #expect(try decimal("NumberDecimal(1e20)") == "1E+20")
        #expect(try decimal("NumberDecimal(\"12.50\")") == "12.50")
    }

    @Test func outOfRangeNumbersAreRejectedNotTrapped() {
        for input in ["NumberLong(1e20)", "NumberLong(1.5)", "NumberInt(1e20)", "Timestamp(-1, 0)", "Timestamp(1, -1)",
                      "Timestamp(4294967296, 0)", "Timestamp(1, 4294967296)", "Timestamp({ t: -1, i: 0 })",
                      "NumberDecimal(\"1e9223372036854775807\")", "NumberDecimal(\"1.5e-9223372036854775808\")",
                      "NumberDecimal(Infinity)", "ISODate(1e300)", "BinData(1e300, \"AA==\")"] {
            #expect(throws: DatabaseError.self, "\(input)") { try MongoShellParser.value(input) }
        }
    }

    @Test func timestampInRange() throws {
        #expect(try MongoShellParser.value("Timestamp(4294967295, 4294967295)") == .timestamp(UInt64.max))
        #expect(try MongoShellParser.value("Timestamp({ t: 1, i: 2 })") == .timestamp(1 << 32 | 2))
    }

    @Test func intAccessorRejectsUnrepresentableDoubles() {
        #expect(BSONValue.double(3).int == 3)
        #expect(BSONValue.double(3.5).int == nil)
        #expect(BSONValue.double(1e20).int == nil)
        #expect(BSONValue.double(.nan).int == nil)
        #expect(BSONValue.double(0.5).bool == true)
    }
}

@Suite struct MongoWriteCommandTests {
    private let concern: BSONValue = .document(["w": .int32(2), "wtimeout": .int32(100)])

    private func command(_ statement: String) throws -> BSONDocument {
        guard case .collection(let collection, let method, let arguments, _) = try MongoShellParser.statement(statement) else {
            Issue.record("not a collection call")
            return BSONDocument()
        }
        return try MongoDriver.writeCommand(collection, method, arguments)
    }

    @Test func writeConcernReachesEveryHelper() throws {
        let statements = [
            "db.items.insertOne({x: 1}, {writeConcern: {w: 2, wtimeout: 100}})",
            "db.items.insertMany([{x: 1}], {ordered: false, writeConcern: {w: 2, wtimeout: 100}})",
            "db.items.updateOne({x: 1}, {$set: {y: 2}}, {writeConcern: {w: 2, wtimeout: 100}})",
            "db.items.replaceOne({x: 1}, {y: 2}, {writeConcern: {w: 2, wtimeout: 100}})",
            "db.items.deleteMany({x: 1}, {writeConcern: {w: 2, wtimeout: 100}})",
            "db.items.remove({x: 1}, {justOne: true, writeConcern: {w: 2, wtimeout: 100}})",
            "db.items.findOneAndUpdate({x: 1}, {$set: {y: 2}}, {writeConcern: {w: 2, wtimeout: 100}})",
            "db.items.findOneAndDelete({x: 1}, {writeConcern: {w: 2, wtimeout: 100}})",
        ]
        for statement in statements {
            #expect(try command(statement)["writeConcern"] == concern, "\(statement)")
        }
    }

    @Test func statementOptionsStayOnTheStatement() throws {
        let update = try command("db.items.updateMany({x: 1}, {$set: {y: 2}}, {upsert: true, hint: 'x_1'})")
        let statement = try #require(update["updates"]?.array?.first?.document)
        #expect(statement["upsert"] == .bool(true))
        #expect(statement["hint"] == .string("x_1"))
        #expect(statement["multi"] == .bool(true))
        #expect(update["upsert"] == nil)

        let remove = try command("db.items.remove({x: 1}, {justOne: true})")
        #expect(remove["deletes"]?.array?.first?.document?["limit"] == .int32(1))
        let insert = try command("db.items.insertMany([{x: 1}], {ordered: false})")
        #expect(insert["ordered"] == .bool(false))
    }

    @Test func unsupportedOptionsAreRefused() {
        for statement in ["db.items.insertOne({x: 1}, {w: 2})",
                          "db.items.insertOne({x: 1}, {ordered: false})",
                          "db.items.updateOne({x: 1}, {$set: {y: 2}}, {unknownOption: 1})",
                          "db.items.deleteOne({x: 1}, {justOne: true})",
                          "db.items.insertOne({x: 1}, {writeConcern: 2})"] {
            #expect(throws: DatabaseError.self, "\(statement)") { try command(statement) }
        }
    }
}
