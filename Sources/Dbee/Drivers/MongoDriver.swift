import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// MongoDB over one connection to one server (no replica set discovery: Dbee talks to the host you enter).
///
/// The query editor takes mongosh-style statements (`db.users.find({ age: { $gt: 30 } }).sort({ name: 1 })`,
/// `show collections`, `use app`) or raw command documents. The sidebar lists collections and views;
/// the browser pages through them with find, and filters with a JSON query document.
///
/// Privacy: the username and password stay in memory only, to log in again when the connection drops or a
/// stopped command had to close it. `close()` drops them.
final class MongoDriver: CommandDriver, @unchecked Sendable {
    let kind: DatabaseKind = .mongodb

    private static let systemDatabases: Set<String> = ["admin", "config", "local"]
    /// Documents read to infer a collection's fields for the structure view.
    static let sampleSize = 100

    private struct Credentials {
        var username: String
        var password: String
        /// The database the user was found in, once a login worked.
        var source: String?
    }

    private struct ServerInfo {
        var version = ""
        /// A replica set member that isn't the primary: reads need a read preference that allows it.
        var isSecondary = false
        var isMongos = false
    }

    private struct State {
        var connection: WireConnection?
        var credentials: Credentials?
        var database: String
        var server = ServerInfo()
        var nextRequestID: Int32 = 1
        var running = false
        var isClosed = false
    }

    private let endpoint: WireConnection.Endpoint
    private let gate = PostgresStatementGate()
    private let state: NIOLockedValueBox<State>

    private init(endpoint: WireConnection.Endpoint, connection: WireConnection, credentials: Credentials,
                 database: String, server: ServerInfo) {
        self.endpoint = endpoint
        state = NIOLockedValueBox(State(connection: connection, credentials: credentials, database: database, server: server))
    }

    // MARK: Connecting

    static func connect(config: ConnectionConfig, host: String, port: Int,
                        transport: DriverTransport = .direct) async throws -> MongoDriver {
        let endpoint = WireConnection.Endpoint(config: config, dialHost: host, dialPort: port, transport: transport)
        var credentials = Credentials(username: config.username, password: config.password)
        let requested = config.database.trimmingCharacters(in: .whitespaces)
        let (connection, server, source) = try await open(endpoint, credentials: credentials, database: requested)
        credentials.source = source
        let driver = MongoDriver(endpoint: endpoint, connection: connection, credentials: credentials,
                                 database: requested.isEmpty ? "test" : requested, server: server)
        if requested.isEmpty, let first = try? await driver.listDatabases().first(where: { !systemDatabases.contains($0) }) {
            // Like Compass, open the first user database rather than an empty "test".
            driver.state.withLockedValue { $0.database = first }
        }
        return driver
    }

    /// Dials, says hello and logs in. Returns the database the login succeeded against.
    private static func open(_ endpoint: WireConnection.Endpoint, credentials: Credentials,
                             database: String) async throws -> (WireConnection, ServerInfo, String?) {
        let (connection, (server, source)) = try await WireConnection.open(endpoint) { connection -> (ServerInfo, String?) in
            let deadline = NIODeadline.now() + WireConnection.connectTimeout
            var requestID: Int32 = 0
            func run(_ command: BSONDocument) async throws -> BSONDocument {
                requestID += 1
                try await connection.write(MongoWire.message(command, requestID: requestID))
                return try await connection.read(deadline: deadline) { try MongoWire.parseReply(&$0) }.body
            }

            // The authentication source follows the connection string rule: the database, else admin.
            var sources = [credentials.source ?? (database.isEmpty ? "admin" : database)]
            if credentials.source == nil, sources[0] != "admin" { sources.append("admin") }

            var hello: BSONDocument = [
                "hello": .int32(1),
                "client": .document([
                    "application": .document(["name": .string("Dbee")]),
                    "driver": .document(["name": .string("Dbee"), "version": .string("1.0")]),
                    "os": .document(["type": .string("Darwin")]),
                ]),
                "$db": .string("admin"),
            ]
            if !credentials.username.isEmpty {
                hello["saslSupportedMechs"] = .string("\(sources[0]).\(credentials.username)")
            }
            var reply = try await run(hello)
            if reply["ok"]?.bool != true {
                // Servers before 4.4.2 only know the older name.
                hello.fields[0] = (key: "isMaster", value: .int32(1))
                reply = try await run(hello)
            }
            try check(reply)
            let maxWire = reply["maxWireVersion"]?.int ?? 0
            guard maxWire >= 6 else {
                throw DatabaseError("This MongoDB server is too old.", detail: "Dbee needs MongoDB 3.6 or later.")
            }
            var server = ServerInfo()
            server.isMongos = reply["msg"]?.string == "isdbgrid"
            server.isSecondary = reply["setName"] != nil
                && reply["isWritablePrimary"]?.bool != true && reply["ismaster"]?.bool != true

            var source: String?
            if !credentials.username.isEmpty {
                let mechanisms = reply["saslSupportedMechs"]?.array?.compactMap(\.string) ?? []
                let mechanism: MongoSCRAM.Mechanism = mechanisms.contains("SCRAM-SHA-256") || (mechanisms.isEmpty && maxWire >= 7)
                    ? .sha256 : .sha1
                var lastError: Error?
                for candidate in sources {
                    do {
                        try await authenticate(credentials, mechanism: mechanism, source: candidate, run: run)
                        source = candidate
                        lastError = nil
                        break
                    } catch let error as DatabaseError where error.detail?.contains("AuthenticationFailed") == true {
                        lastError = error
                    }
                }
                if let lastError { throw lastError }
            }

            let build = try? await run(["buildInfo": .int32(1), "$db": .string("admin")])
            if let version = build?["version"]?.string {
                server.version = "MongoDB \(version)"
            }
            return (server, source)
        }
        return (connection, server, source)
    }

    private static func authenticate(_ credentials: Credentials, mechanism: MongoSCRAM.Mechanism, source: String,
                                     run: (BSONDocument) async throws -> BSONDocument) async throws {
        let scram = MongoSCRAM(mechanism: mechanism, username: credentials.username, password: credentials.password)
        let failed = { (reply: BSONDocument) in
            DatabaseError("MongoDB refused the login.",
                          detail: [reply["errmsg"]?.string, reply["codeName"]?.string].compactMap { $0 }.joined(separator: " · "))
        }
        var reply = try await run([
            "saslStart": .int32(1),
            "mechanism": .string(mechanism.rawValue),
            "payload": .binary(subtype: 0, data: scram.clientFirst),
            "autoAuthorize": .int32(1),
            "options": .document(["skipEmptyExchange": .bool(true)]),
            "$db": .string(source),
        ])
        guard reply["ok"]?.bool == true, case .binary(_, let first)? = reply["payload"],
              let conversation = reply["conversationId"] else { throw failed(reply) }
        let (final, expected) = try scram.clientFinal(serverFirst: String(decoding: first, as: UTF8.self))
        reply = try await run([
            "saslContinue": .int32(1),
            "conversationId": conversation,
            "payload": .binary(subtype: 0, data: final),
            "$db": .string(source),
        ])
        guard reply["ok"]?.bool == true, case .binary(_, let last)? = reply["payload"] else { throw failed(reply) }
        let verifier = MongoSCRAM.fields(String(decoding: last, as: UTF8.self))["v"].flatMap { Data(base64Encoded: $0) }
        guard verifier == expected else {
            throw DatabaseError("The server couldn't prove it knows the password.",
                                detail: "Dbee stopped the login. Someone could be intercepting this connection.")
        }
        while reply["done"]?.bool != true {
            reply = try await run([
                "saslContinue": .int32(1),
                "conversationId": conversation,
                "payload": .binary(subtype: 0, data: []),
                "$db": .string(source),
            ])
            guard reply["ok"]?.bool == true else { throw failed(reply) }
        }
    }

    /// Throws for a reply with ok: 0, a write error or a write concern error.
    @discardableResult
    static func check(_ reply: BSONDocument) throws -> BSONDocument {
        if reply["ok"]?.bool != true {
            let message = reply["errmsg"]?.string ?? "The command failed."
            let code = [reply["codeName"]?.string, reply["code"]?.int.map { "code \($0)" }].compactMap { $0 }
            throw DatabaseError(message, detail: code.isEmpty ? nil : code.joined(separator: " · "))
        }
        if let error = reply["writeErrors"]?.array?.first?.document {
            throw DatabaseError(error["errmsg"]?.string ?? "The write failed.",
                                detail: error["code"]?.int.map { "code \($0)" })
        }
        if let error = reply["writeConcernError"]?.document {
            throw DatabaseError(error["errmsg"]?.string ?? "The write concern failed.")
        }
        return reply
    }

    // MARK: Running commands

    /// Runs one command on `database` (the current one by default), reconnecting first when needed.
    private func run(_ command: BSONDocument, database: String? = nil) async throws -> BSONDocument {
        await gate.acquire()
        defer { gate.release() }
        let connection = try await liveConnection()
        let (requestID, current, server) = state.withLockedValue { state -> (Int32, String, ServerInfo) in
            state.nextRequestID &+= 1
            state.running = true
            return (state.nextRequestID, state.database, state.server)
        }
        defer { state.withLockedValue { $0.running = false } }
        var command = command
        command["$db"] = .string(database ?? current)
        if server.isSecondary, !server.isMongos {
            command["$readPreference"] = .document(["mode": .string("primaryPreferred")])
        }
        do {
            try await connection.write(MongoWire.message(command, requestID: requestID))
            while true {
                let reply = try await connection.read { try MongoWire.parseReply(&$0) }
                if reply.responseTo == requestID { return reply.body }
            }
        } catch {
            connection.close()
            state.withLockedValue { state in
                if state.connection === connection { state.connection = nil }
            }
            throw error
        }
    }

    private func liveConnection() async throws -> WireConnection {
        let (connection, credentials, database, closed) = state.withLockedValue {
            ($0.connection, $0.credentials, $0.database, $0.isClosed)
        }
        guard !closed, let credentials else { throw DatabaseError("Not connected") }
        if let connection, connection.isOpen { return connection }
        let (fresh, server, _) = try await Self.open(endpoint, credentials: credentials, database: database)
        let replaced = state.withLockedValue { state -> Bool in
            guard !state.isClosed else { return false }
            state.connection = fresh
            state.server = server
            return true
        }
        guard replaced else {
            fresh.close()
            throw DatabaseError("Not connected")
        }
        return fresh
    }

    /// Runs a command that returns a cursor and reads up to `limit` documents, closing the cursor when
    /// documents are left. Returns whether there were more.
    private func documents(_ command: BSONDocument, database: String? = nil, limit: Int) async throws -> ([BSONDocument], Bool) {
        let reply = try Self.check(try await run(command, database: database))
        guard let cursor = reply["cursor"]?.document else {
            throw DatabaseError("MongoDB didn't return a cursor.")
        }
        var documents = (cursor["firstBatch"]?.array ?? []).compactMap(\.document)
        var cursorID = cursor["id"] ?? .int64(0)
        let namespace = cursor["ns"]?.string ?? ""
        let collection = namespace.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        let cursorDatabase = namespace.split(separator: ".", maxSplits: 1).first.map(String.init) ?? database
        while cursorID.int != 0, documents.count < limit {
            let more = try Self.check(try await run([
                "getMore": cursorID,
                "collection": .string(collection),
                "batchSize": .int32(Int32(clamping: min(limit - documents.count, 10_000))),
            ], database: cursorDatabase))
            guard let next = more["cursor"]?.document else { break }
            documents += (next["nextBatch"]?.array ?? []).compactMap(\.document)
            cursorID = next["id"] ?? .int64(0)
        }
        let hasMore = cursorID.int != 0 || documents.count > limit
        if cursorID.int != 0 {
            _ = try? await run(["killCursors": .string(collection), "cursors": .array([cursorID])], database: cursorDatabase)
        }
        return (Array(documents.prefix(limit)), hasMore)
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        state.withLockedValue { $0.server.version }
    }

    func listDatabases() async throws -> [String] {
        let reply = try await run(["listDatabases": .int32(1), "nameOnly": .bool(true), "authorizedDatabases": .bool(true)],
                                  database: "admin")
        let current = state.withLockedValue { $0.database }
        guard reply["ok"]?.bool == true else { return [current] }
        var names = (reply["databases"]?.array ?? []).compactMap { $0.document?["name"]?.string }
        if !names.contains(current) { names.append(current) }
        return names.sorted()
    }

    func currentDatabase() async throws -> String {
        state.withLockedValue { $0.database }
    }

    func listSchemas() async throws -> [SchemaInfo] {
        let database = try await currentDatabase()
        let (collections, _) = try await documents([
            "listCollections": .int32(1),
            "nameOnly": .bool(true),
            "authorizedCollections": .bool(true),
        ], limit: .max)
        let tables = collections.compactMap { info -> TableInfo? in
            guard let name = info["name"]?.string, !name.hasPrefix("system.") else { return nil }
            let kind: TableKind = info["type"]?.string == "view" ? .view : .collection
            return TableInfo(ref: TableRef(schema: nil, name: name), kind: kind)
        }
        .sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
        return [SchemaInfo(name: database, tables: tables)]
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        let (sample, _) = try await documents([
            "find": .string(table.name), "limit": .int32(Int32(Self.sampleSize)), "batchSize": .int32(Int32(Self.sampleSize)),
        ], limit: Self.sampleSize)
        let columns = Self.inferColumns(sample)

        var indexes: [IndexInfo] = []
        if let (specs, _) = try? await documents(["listIndexes": .string(table.name)], limit: 1000) {
            indexes = specs.compactMap { spec in
                guard let name = spec["name"]?.string, let key = spec["key"]?.document else { return nil }
                var options = spec
                for field in ["v", "key", "name", "ns"] { options[field] = nil }
                let definition = "{ key: \(BSONFormatting.json(key))\(options.isEmpty ? "" : ", options: \(BSONFormatting.json(options))") }"
                return IndexInfo(name: name, columns: key.keys, isUnique: spec["unique"]?.bool == true || name == "_id_",
                                 isPrimary: name == "_id_", definition: definition)
            }
        }

        var ddl: String?
        if let (infos, _) = try? await documents(["listCollections": .int32(1), "filter": .document(["name": .string(table.name)])], limit: 1),
           let info = infos.first {
            let options = info["options"]?.document ?? BSONDocument()
            let name = BSONFormatting.quote(table.name)
            ddl = options.isEmpty
                ? "db.createCollection(\(name))"
                : "db.createCollection(\(name), \(MongoFormatting.pretty(.document(options))))"
        }
        return TableStructure(columns: columns, indexes: indexes, foreignKeys: [], ddl: ddl)
    }

    /// Fields seen in `documents`, _id first, then in order of first appearance, with every type seen.
    static func inferColumns(_ documents: [BSONDocument]) -> [ColumnInfo] {
        var order: [String] = []
        var types: [String: [String]] = [:]
        var present: [String: Int] = [:]
        for document in documents {
            for (key, value) in document.fields {
                if types[key] == nil { order.append(key) }
                if !(types[key] ?? []).contains(value.typeName) { types[key, default: []].append(value.typeName) }
                present[key, default: 0] += 1
            }
        }
        if let id = order.firstIndex(of: "_id"), id != 0 { order.insert(order.remove(at: id), at: 0) }
        if order.isEmpty { order = ["_id"] }
        return order.map { key in
            let seen = types[key] ?? ["objectId"]
            return ColumnInfo(name: key, dataType: seen.joined(separator: " | "),
                              isNullable: key != "_id" && (seen.contains("null") || present[key, default: 0] < documents.count),
                              defaultValue: nil, isPrimaryKey: key == "_id",
                              comment: documents.isEmpty ? nil : "In \(present[key, default: 0]) of \(documents.count) sampled documents")
        }
    }

    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        let start = Date()
        var result = try await run(statement: MongoShellParser.statement(sql), maxRows: max(0, maxRows))
        result.statement = sql
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    func cancelCurrentQuery() async {
        // Stopping an operation needs killOp from a second, logged-in connection; closing this one ends the
        // wait right away and the next statement reconnects.
        let connection = state.withLockedValue { state -> WireConnection? in
            guard state.running else { return nil }
            defer { state.connection = nil }
            return state.connection
        }
        connection?.abort()
    }

    func close() async {
        let connection = state.withLockedValue { state -> WireConnection? in
            state.isClosed = true
            state.credentials = nil
            defer { state.connection = nil }
            return state.connection
        }
        await connection?.closeAndWait()
    }

    // MARK: CommandDriver

    func useDatabase(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: { "/\\. \"$".contains($0) }) else {
            throw DatabaseError("“\(name)” isn't a valid database name.")
        }
        state.withLockedValue { $0.database = trimmed }
    }

    func page(of table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) async throws -> QueryResult {
        let start = Date()
        var command: BSONDocument = ["find": .string(table.name), "filter": .document(try Self.filterDocument(filter))]
        if let sort { command["sort"] = .document([sort.column: .int32(sort.ascending ? 1 : -1)]) }
        if offset > 0 { command["skip"] = .int64(Int64(offset)) }
        command["limit"] = .int64(Int64(max(1, limit)))
        command["batchSize"] = .int32(Int32(clamping: max(1, limit)))
        let (documents, _) = try await documents(command, limit: max(1, limit))
        var result = Self.grid(documents, maxRows: limit)
        // No documents: the browser takes the columns from the structure instead.
        if documents.isEmpty { result.columns = [] }
        result.statement = "db.getCollection(\(BSONFormatting.quote(table.name))).find(\(filter?.isEmpty == false ? filter! : "{}"))"
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    func count(of table: TableRef, filter: String?) async throws -> Int? {
        let reply = try Self.check(try await run(["count": .string(table.name), "query": .document(try Self.filterDocument(filter))]))
        return reply["n"]?.int
    }

    static func filterDocument(_ filter: String?) throws -> BSONDocument {
        let text = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return BSONDocument() }
        guard case .document(let document) = try MongoShellParser.value(text) else {
            throw DatabaseError("The filter must be a query document, such as { status: \"active\" }.")
        }
        return document
    }

    // MARK: Statements

    private func run(statement: MongoStatement, maxRows: Int) async throws -> QueryResult {
        switch statement {
        case .command(let document):
            return try await commandResult(document, database: nil, maxRows: maxRows)
        case .showDatabases:
            let reply = try Self.check(try await run(["listDatabases": .int32(1), "authorizedDatabases": .bool(true)], database: "admin"))
            let rows = (reply["databases"]?.array ?? []).compactMap(\.document).map { info -> [CellValue] in
                [info["name"].flatMap(BSONFormatting.cell), info["sizeOnDisk"].flatMap(BSONFormatting.cell),
                 info["empty"].flatMap(BSONFormatting.cell)]
            }
            return Self.table(["name", "sizeOnDisk", "empty"], rows, maxRows: maxRows)
        case .showCollections:
            let (collections, _) = try await documents(["listCollections": .int32(1), "nameOnly": .bool(true),
                                                        "authorizedCollections": .bool(true)], limit: .max)
            let rows = collections.map { [$0["name"].flatMap(BSONFormatting.cell), $0["type"].flatMap(BSONFormatting.cell)] }
                .sorted { ($0[0] ?? "") < ($1[0] ?? "") }
            return Self.table(["name", "type"], rows, maxRows: maxRows)
        case .use(let name):
            try await useDatabase(name)
            return Self.message()
        case .database(let method, let arguments):
            return try await runDatabaseMethod(method, arguments, maxRows: maxRows)
        case .collection(let name, let method, let arguments, let chain):
            return try await runCollectionMethod(name, method, arguments, chain: chain, maxRows: maxRows)
        }
    }

    private func runDatabaseMethod(_ method: String, _ arguments: [BSONValue], maxRows: Int) async throws -> QueryResult {
        func document(_ index: Int) -> BSONDocument? { arguments.indices.contains(index) ? arguments[index].document : nil }
        func string(_ index: Int) -> String? { arguments.indices.contains(index) ? arguments[index].string : nil }
        switch method {
        case "runCommand", "adminCommand":
            var command: BSONDocument
            if let given = document(0) {
                command = given
            } else if let name = string(0) {
                command = [name: .int32(1)]
            } else {
                throw DatabaseError("db.\(method)() needs a command document.")
            }
            command["$db"] = nil
            return try await commandResult(command, database: method == "adminCommand" ? "admin" : nil, maxRows: maxRows)
        case "getCollectionNames":
            let (collections, _) = try await documents(["listCollections": .int32(1), "nameOnly": .bool(true),
                                                        "authorizedCollections": .bool(true)], limit: .max)
            let names = collections.compactMap { $0["name"]?.string }.sorted()
            return Self.table(["name"], names.map { [$0] }, maxRows: maxRows)
        case "getCollectionInfos":
            var command: BSONDocument = ["listCollections": .int32(1)]
            if let filter = document(0) { command["filter"] = .document(filter) }
            let (infos, more) = try await documents(command, limit: maxRows)
            return Self.grid(infos, maxRows: maxRows, more: more)
        case "createCollection":
            guard let name = string(0) else { throw DatabaseError("db.createCollection() needs a name.") }
            var command: BSONDocument = ["create": .string(name)]
            command.fields += document(1)?.fields ?? []
            try Self.check(try await run(command))
            return Self.message()
        case "createView":
            guard let name = string(0), let source = string(1) else {
                throw DatabaseError("db.createView() needs a name, a source collection and a pipeline.")
            }
            let pipeline = arguments.count > 2 ? arguments[2] : .array([])
            try Self.check(try await run(["create": .string(name), "viewOn": .string(source), "pipeline": pipeline]))
            return Self.message()
        case "dropDatabase":
            try Self.check(try await run(["dropDatabase": .int32(1)]))
            return Self.message()
        case "stats":
            return try await commandResult(["dbStats": .int32(1)], database: nil, maxRows: maxRows)
        case "serverStatus":
            return try await commandResult(["serverStatus": .int32(1)], database: "admin", maxRows: maxRows)
        case "hostInfo":
            return try await commandResult(["hostInfo": .int32(1)], database: "admin", maxRows: maxRows)
        case "version":
            let reply = try Self.check(try await run(["buildInfo": .int32(1)], database: "admin"))
            return Self.table(["version"], [[reply["version"]?.string]], maxRows: maxRows)
        case "getName":
            return Self.table(["name"], [[try await currentDatabase()]], maxRows: maxRows)
        case "currentOp":
            let reply = try Self.check(try await run(["currentOp": .int32(1)], database: "admin"))
            return Self.grid((reply["inprog"]?.array ?? []).compactMap(\.document), maxRows: maxRows)
        case "killOp":
            guard let op = arguments.first else { throw DatabaseError("db.killOp() needs an operation id.") }
            return try await commandResult(["killOp": .int32(1), "op": op], database: "admin", maxRows: maxRows)
        default:
            throw DatabaseError("Dbee doesn't support db.\(method)().",
                                detail: "Use db.runCommand({ … }) to run any server command.")
        }
    }

    private func runCollectionMethod(_ collection: String, _ method: String, _ arguments: [BSONValue],
                                     chain: [MongoCall], maxRows: Int) async throws -> QueryResult {
        func document(_ index: Int) -> BSONDocument? { arguments.indices.contains(index) ? arguments[index].document : nil }
        func required(_ index: Int, _ what: String) throws -> BSONDocument {
            guard let value = document(index) else { throw DatabaseError("\(method)() needs \(what).") }
            return value
        }
        let name = BSONValue.string(collection)
        var chained: [String: [BSONValue]] = [:]
        for call in chain {
            if ["pretty", "toArray"].contains(call.method) { continue }
            guard Self.cursorMethods.contains(call.method) else {
                throw DatabaseError("Dbee doesn't support .\(call.method)() here.")
            }
            chained[call.method] = call.arguments
        }

        switch method {
        case "find", "findOne":
            var command: BSONDocument = ["find": name, "filter": .document(document(0) ?? BSONDocument())]
            if let projection = document(1) ?? chained["projection"]?.first?.document { command["projection"] = .document(projection) }
            if let sort = chained["sort"]?.first { command["sort"] = sort }
            if let skip = chained["skip"]?.first?.int { command["skip"] = .int64(Int64(skip)) }
            if let hint = chained["hint"]?.first { command["hint"] = hint }
            if let maxTime = chained["maxTimeMS"]?.first { command["maxTimeMS"] = maxTime }
            if let collation = chained["collation"]?.first { command["collation"] = collation }
            if let comment = chained["comment"]?.first { command["comment"] = comment }
            var limit = method == "findOne" ? 1 : chained["limit"]?.first?.int.map(abs) ?? 0
            if limit > 0 { command["limit"] = .int64(Int64(limit)) }
            if chained["count"] != nil {
                return try await count(collection, filter: document(0) ?? BSONDocument(), skip: command["skip"], limit: command["limit"])
            }
            if let verbosity = chained["explain"] {
                return try await explain(command, verbosity: verbosity.first, maxRows: maxRows)
            }
            limit = limit == 0 ? maxRows : min(limit, maxRows)
            command["batchSize"] = .int32(Int32(clamping: max(1, min(limit, 1000))))
            let (found, more) = try await documents(command, limit: limit)
            return Self.grid(found, maxRows: maxRows, more: more && limit == maxRows)
        case "aggregate":
            let pipeline = arguments.first ?? .array([])
            guard case .array = pipeline else { throw DatabaseError("aggregate() needs a pipeline: an array of stages.") }
            var command: BSONDocument = ["aggregate": name, "pipeline": pipeline]
            command.fields += document(1)?.fields.filter { $0.key != "cursor" } ?? []
            if let verbosity = chained["explain"] {
                return try await explain(command, verbosity: verbosity.first, maxRows: maxRows)
            }
            command["cursor"] = .document(["batchSize": .int32(Int32(clamping: max(1, min(maxRows, 1000))))])
            let (found, more) = try await documents(command, limit: maxRows)
            return Self.grid(found, maxRows: maxRows, more: more)
        case "countDocuments":
            let options = document(1)
            return try await count(collection, filter: document(0) ?? BSONDocument(), skip: options?["skip"], limit: options?["limit"])
        case "estimatedDocumentCount", "count":
            var command: BSONDocument = ["count": name]
            if method == "count", let filter = document(0) { command["query"] = .document(filter) }
            let reply = try Self.check(try await run(command))
            return Self.table(["count"], [[reply["n"].flatMap(BSONFormatting.cell)]], maxRows: maxRows)
        case "distinct":
            guard let key = arguments.first?.string else { throw DatabaseError("distinct() needs a field name.") }
            var command: BSONDocument = ["distinct": name, "key": .string(key)]
            if let filter = document(1) { command["query"] = .document(filter) }
            let reply = try Self.check(try await run(command))
            return Self.table([key], (reply["values"]?.array ?? []).map { [BSONFormatting.cell($0)] }, maxRows: maxRows)
        case "insertOne", "insert", "insertMany":
            var documents: [BSONDocument]
            if method == "insertMany" || (method == "insert" && arguments.first?.array != nil) {
                guard let items = arguments.first?.array else { throw DatabaseError("insertMany() needs an array of documents.") }
                documents = try items.map {
                    guard let document = $0.document else { throw DatabaseError("insertMany() needs an array of documents.") }
                    return document
                }
            } else {
                documents = [try required(0, "a document")]
            }
            // Like the shell, give every document an _id first so the result can report it.
            for index in documents.indices where documents[index]["_id"] == nil {
                documents[index].fields.insert((key: "_id", value: .objectId(ObjectIdGenerator.next())), at: 0)
            }
            var command: BSONDocument = ["insert": name, "documents": .array(documents.map { .document($0) })]
            if let ordered = document(1)?["ordered"] { command["ordered"] = ordered }
            let reply = try Self.check(try await run(command))
            var result = Self.table(["insertedId"], documents.map { [$0["_id"].flatMap(BSONFormatting.cell)] }, maxRows: maxRows)
            result.rowsAffected = reply["n"]?.int
            return result
        case "updateOne", "updateMany", "replaceOne", "update":
            let filter = try required(0, "a filter")
            guard arguments.count > 1 else { throw DatabaseError("\(method)() needs an update.") }
            let update = arguments[1]
            let options = document(2) ?? BSONDocument()
            if method == "replaceOne", let replacement = update.document, replacement.keys.contains(where: { $0.hasPrefix("$") }) {
                throw DatabaseError("replaceOne() takes a whole document, without update operators.")
            }
            if method != "replaceOne", let operators = update.document, !operators.isEmpty,
               !operators.keys.allSatisfy({ $0.hasPrefix("$") }) {
                throw DatabaseError("\(method)() needs update operators such as { $set: { … } }.",
                                    detail: "Use replaceOne() to replace a whole document.")
            }
            var statement: BSONDocument = ["q": .document(filter), "u": update,
                                            "multi": .bool(method == "updateMany" || (method == "update" && options["multi"]?.bool == true))]
            for option in ["upsert", "arrayFilters", "collation", "hint"] where options[option] != nil {
                statement[option] = options[option]
            }
            let reply = try Self.check(try await run(["update": name, "updates": .array([.document(statement)])]))
            let upserted = (reply["upserted"]?.array ?? []).compactMap { $0.document?["_id"] }
            var result = upserted.isEmpty
                ? Self.message()
                : Self.table(["upsertedId"], upserted.map { [BSONFormatting.cell($0)] }, maxRows: maxRows)
            result.rowsAffected = reply["nModified"]?.int ?? reply["n"]?.int
            result.rowsMatched = reply["n"]?.int
            return result
        case "deleteOne", "deleteMany", "remove":
            let filter = try required(0, "a filter")
            let justOne = method == "deleteOne" || (method == "remove" && (arguments.count > 1 && arguments[1].bool == true))
            var statement: BSONDocument = ["q": .document(filter), "limit": .int32(justOne ? 1 : 0)]
            if let collation = document(1)?["collation"] { statement["collation"] = collation }
            let reply = try Self.check(try await run(["delete": name, "deletes": .array([.document(statement)])]))
            var result = Self.message()
            result.rowsAffected = reply["n"]?.int
            return result
        case "findOneAndUpdate", "findOneAndReplace", "findOneAndDelete":
            let filter = try required(0, "a filter")
            let options = document(method == "findOneAndDelete" ? 1 : 2) ?? BSONDocument()
            var command: BSONDocument = ["findAndModify": name, "query": .document(filter)]
            if method == "findOneAndDelete" {
                command["remove"] = .bool(true)
            } else {
                guard arguments.count > 1 else { throw DatabaseError("\(method)() needs an update.") }
                command["update"] = arguments[1]
                command["new"] = .bool(options["returnDocument"]?.string == "after" || options["returnNewDocument"]?.bool == true)
                if let upsert = options["upsert"] { command["upsert"] = upsert }
            }
            if let sort = options["sort"] { command["sort"] = sort }
            if let projection = options["projection"] { command["fields"] = projection }
            let reply = try Self.check(try await run(command))
            let value = reply["value"]?.document
            return Self.grid(value.map { [$0] } ?? [], maxRows: maxRows)
        case "drop":
            try Self.check(try await run(["drop": name]))
            return Self.message()
        case "renameCollection":
            guard let target = arguments.first?.string else { throw DatabaseError("renameCollection() needs a new name.") }
            let database = try await currentDatabase()
            var command: BSONDocument = ["renameCollection": .string("\(database).\(collection)"), "to": .string("\(database).\(target)")]
            if let dropTarget = arguments.dropFirst().first { command["dropTarget"] = dropTarget }
            try Self.check(try await run(command, database: "admin"))
            return Self.message()
        case "getIndexes":
            let (specs, _) = try await documents(["listIndexes": name], limit: maxRows)
            return Self.grid(specs, maxRows: maxRows)
        case "createIndex":
            let keys = try required(0, "the index keys")
            var index: BSONDocument = ["key": .document(keys)]
            index.fields += document(1)?.fields ?? []
            if index["name"] == nil {
                index["name"] = .string(keys.fields.map { "\($0.key)_\(BSONFormatting.cell($0.value) ?? "")" }.joined(separator: "_"))
            }
            try Self.check(try await run(["createIndexes": name, "indexes": .array([.document(index)])]))
            return Self.table(["name"], [[index["name"]?.string]], maxRows: maxRows)
        case "dropIndex":
            guard let index = arguments.first else { throw DatabaseError("dropIndex() needs an index name or key.") }
            try Self.check(try await run(["dropIndexes": name, "index": index]))
            return Self.message()
        case "stats":
            return try await commandResult(["collStats": name], database: nil, maxRows: maxRows)
        default:
            throw DatabaseError("Dbee doesn't support \(method)() on collections.",
                                detail: "Use db.runCommand({ … }) to run any server command.")
        }
    }

    private static let cursorMethods: Set<String> = [
        "sort", "limit", "skip", "projection", "hint", "maxTimeMS", "collation", "comment", "count", "explain", "batchSize",
    ]

    private func count(_ collection: String, filter: BSONDocument, skip: BSONValue?, limit: BSONValue?) async throws -> QueryResult {
        var pipeline: [BSONValue] = [.document(["$match": .document(filter)])]
        if let skip, (skip.int ?? 0) > 0 { pipeline.append(.document(["$skip": skip])) }
        if let limit, (limit.int ?? 0) > 0 { pipeline.append(.document(["$limit": limit])) }
        pipeline.append(.document(["$group": .document(["_id": .int32(1), "n": .document(["$sum": .int32(1)])])]))
        let (groups, _) = try await documents(["aggregate": .string(collection), "pipeline": .array(pipeline),
                                               "cursor": .document([:])], limit: 1)
        let n = groups.first?["n"].flatMap(BSONFormatting.cell) ?? "0"
        return Self.table(["count"], [[n]], maxRows: 1)
    }

    private func explain(_ command: BSONDocument, verbosity: BSONValue?, maxRows: Int) async throws -> QueryResult {
        var level = "queryPlanner"
        if let text = verbosity?.string { level = text } else if verbosity?.bool == true { level = "allPlansExecution" }
        return try await commandResult(["explain": .document(command), "verbosity": .string(level)], database: nil, maxRows: maxRows)
    }

    /// Runs a command document. A reply with a cursor is read like find; anything else becomes a row of
    /// its fields.
    private func commandResult(_ command: BSONDocument, database: String?, maxRows: Int) async throws -> QueryResult {
        guard let name = command.fields.first?.key else { throw DatabaseError("The command document is empty.") }
        if name == "use" { throw DatabaseError("Write use <database> without braces.") }
        let reply = try Self.check(try await run(command, database: database))
        if let cursor = reply["cursor"]?.document, cursor["firstBatch"] != nil {
            var documents = (cursor["firstBatch"]?.array ?? []).compactMap(\.document)
            var cursorID = cursor["id"] ?? .int64(0)
            let namespace = cursor["ns"]?.string ?? ""
            let parts = namespace.split(separator: ".", maxSplits: 1).map(String.init)
            while cursorID.int != 0, documents.count < maxRows, parts.count == 2 {
                let more = try Self.check(try await run(["getMore": cursorID, "collection": .string(parts[1])], database: parts[0]))
                documents += (more["cursor"]?.document?["nextBatch"]?.array ?? []).compactMap(\.document)
                cursorID = more["cursor"]?.document?["id"] ?? .int64(0)
            }
            if cursorID.int != 0, parts.count == 2 {
                _ = try? await run(["killCursors": .string(parts[1]), "cursors": .array([cursorID])], database: parts[0])
            }
            return Self.grid(documents, maxRows: maxRows, more: cursorID.int != 0)
        }
        var shown = reply
        for field in ["ok", "$clusterTime", "operationTime", "$gleStats", "lastCommittedOpTime", "electionId", "$configServerState"] {
            shown[field] = nil
        }
        if shown.isEmpty { return Self.message() }
        var result = Self.grid([shown], maxRows: maxRows)
        if ["insert", "update", "delete"].contains(name) {
            result.rowsAffected = reply["nModified"]?.int ?? reply["n"]?.int
        }
        return result
    }

    // MARK: Results

    private static func message() -> QueryResult {
        QueryResult(statement: "", columns: [], rows: [], rowsAffected: nil, duration: 0)
    }

    private static func table(_ columns: [String], _ rows: [[CellValue]], maxRows: Int) -> QueryResult {
        QueryResult(statement: "", columns: columns, rows: Array(rows.prefix(maxRows)), rowsAffected: nil, duration: 0,
                    truncated: rows.count > maxRows)
    }

    /// Documents as a grid: one column per top-level field (_id first, then in order of first appearance).
    static func grid(_ documents: [BSONDocument], maxRows: Int, more: Bool = false) -> QueryResult {
        var columns: [String] = []
        var index: [String: Int] = [:]
        for document in documents {
            for key in document.keys where index[key] == nil {
                index[key] = columns.count
                columns.append(key)
            }
        }
        if let id = columns.firstIndex(of: "_id"), id != 0 {
            columns.insert(columns.remove(at: id), at: 0)
            index = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })
        }
        if documents.isEmpty { columns = [] }
        let shown = documents.prefix(maxRows)
        let rows = shown.map { document -> [CellValue] in
            var row = [CellValue](repeating: nil, count: columns.count)
            for (key, value) in document.fields {
                if let position = index[key] { row[position] = BSONFormatting.cell(value) }
            }
            return row
        }
        // An empty find still reads as a row set, so the grid says "No rows" rather than "Executed".
        return QueryResult(statement: "", columns: documents.isEmpty ? ["_id"] : columns, rows: rows, rowsAffected: nil,
                           duration: 0, truncated: more || documents.count > maxRows)
    }
}

enum MongoFormatting {
    /// Indented relaxed Extended JSON, for collection options in the structure view.
    static func pretty(_ value: BSONValue, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case .document(let document) where !document.isEmpty:
            let fields = document.fields.map { inner + BSONFormatting.quote($0.key) + ": " + pretty($0.value, indent: inner) }
            return "{\n" + fields.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let items) where !items.isEmpty:
            return "[\n" + items.map { inner + pretty($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        default:
            return BSONFormatting.json(value)
        }
    }
}
