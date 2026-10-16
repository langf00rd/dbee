import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// ScyllaDB (and Cassandra) over one connection with the CQL native protocol, version 4. Dbee talks to the node
/// you enter; it doesn't discover the rest of the cluster.
///
/// Keyspaces are the databases. The query editor runs CQL, plus cqlsh's `CONSISTENCY` command; results are read
/// page by page up to the row limit. CQL has no OFFSET, so the table browser pages through a table with the
/// server's paging state and remembers where each page it has seen starts.
///
/// Privacy: the user name and password stay in memory only, to log in again when the connection drops or a
/// stopped query had to close it. `close()` drops them.
final class ScyllaDriver: CommandDriver, @unchecked Sendable {
    let kind: DatabaseKind = .scylla

    /// Rows per protocol page when reading a result.
    static let fetchSize = 5000

    private struct Credentials {
        var username: String
        var password: String
    }

    /// Where the browser's pages of one table and filter start.
    private struct BrowseCursor {
        var key: String
        var limit: Int
        /// Paging state at each page offset; offset 0 starts from the beginning.
        var states: [Int: [UInt8]] = [:]
        /// The offset at which the table ended, once a page reached it.
        var end: Int?
    }

    private struct State {
        var connection: WireConnection?
        var credentials: Credentials?
        var keyspace: String
        var version = ""
        var consistency: UInt16 = 0x0001
        var nextStream: Int16 = 1
        var running = false
        var cursor: BrowseCursor?
        var isClosed = false
    }

    private let endpoint: WireConnection.Endpoint
    private let gate = PostgresStatementGate()
    private let state: NIOLockedValueBox<State>

    private init(endpoint: WireConnection.Endpoint, connection: WireConnection, credentials: Credentials,
                 keyspace: String, version: String) {
        self.endpoint = endpoint
        state = NIOLockedValueBox(State(connection: connection, credentials: credentials, keyspace: keyspace, version: version))
    }

    // MARK: Connecting

    static func connect(config: ConnectionConfig, host: String, port: Int,
                        transport: DriverTransport = .direct) async throws -> ScyllaDriver {
        var endpoint = WireConnection.Endpoint(config: config, dialHost: host, dialPort: port, transport: transport)
        endpoint.engine = "ScyllaDB or Cassandra"
        let credentials = Credentials(username: config.username.trimmingCharacters(in: .whitespaces), password: config.password)
        let requested = config.database.trimmingCharacters(in: .whitespaces)
        let (connection, version) = try await open(endpoint, credentials: credentials, keyspace: requested, readVersion: true)
        let driver = ScyllaDriver(endpoint: endpoint, connection: connection, credentials: credentials,
                                  keyspace: requested, version: version)
        if requested.isEmpty, let first = try? await driver.listDatabases().first {
            // Like MongoDB, open the first user keyspace rather than none.
            try? await driver.useDatabase(first)
        }
        return driver
    }

    /// Dials, starts the protocol, logs in and opens `keyspace`. Returns the server version when asked.
    private static func open(_ endpoint: WireConnection.Endpoint, credentials: Credentials, keyspace: String,
                             readVersion: Bool) async throws -> (WireConnection, String) {
        try await WireConnection.open(endpoint) { connection -> String in
            let deadline = NIODeadline.now() + WireConnection.connectTimeout
            var stream: Int16 = 0
            func send(_ opcode: CQLProtocol.Opcode, _ body: ByteBuffer) async throws -> CQLProtocol.Frame {
                stream += 1
                try await connection.write(CQLProtocol.frame(opcode, stream: stream, body: body))
                return try await connection.read(deadline: deadline) { try CQLProtocol.parseFrame(&$0) }
            }
            func check(_ frame: CQLProtocol.Frame) throws -> CQLProtocol.Frame {
                guard frame.opcode == CQLProtocol.Opcode.error.rawValue else { return frame }
                var body = frame.body
                throw try CQLProtocol.readError(&body).databaseError
            }

            var supported = try check(try await send(.options, ByteBuffer()))
            guard supported.opcode == CQLProtocol.Opcode.supported.rawValue else {
                throw WireConnection.Failure.malformed("unexpected reply to OPTIONS")
            }
            let options = try CQLProtocol.readStringMultimap(&supported.body)
            let isScylla = options.keys.contains { $0.hasPrefix("SCYLLA") }

            var reply = try check(try await send(.startup, CQLProtocol.startupBody()))
            if reply.opcode == CQLProtocol.Opcode.authenticate.rawValue {
                guard !credentials.username.isEmpty else {
                    let authenticator = (try? CQLProtocol.readString(&reply.body))?.split(separator: ".").last.map(String.init)
                    throw DatabaseError("The server needs a user name and password.",
                                        detail: authenticator.map { "It authenticates with \($0)." })
                }
                reply = try await send(.authResponse, CQLProtocol.authResponseBody(username: credentials.username,
                                                                                   password: credentials.password))
                if reply.opcode == CQLProtocol.Opcode.error.rawValue {
                    var body = reply.body
                    let error = try CQLProtocol.readError(&body)
                    throw DatabaseError("The server refused the login.", detail: error.message)
                }
                guard reply.opcode == CQLProtocol.Opcode.authSuccess.rawValue else {
                    throw DatabaseError("The server asked for a login Dbee doesn't support.",
                                        detail: "Dbee logs in with PasswordAuthenticator.")
                }
            } else if reply.opcode != CQLProtocol.Opcode.ready.rawValue {
                throw WireConnection.Failure.malformed("unexpected reply to STARTUP")
            }

            func query(_ cql: String) async throws -> CQLProtocol.Result {
                var frame = try check(try await send(.query, CQLProtocol.queryBody(cql, consistency: 0x0001, pageSize: 100, pagingState: nil)))
                return try CQLProtocol.readResult(&frame.body)
            }
            if !keyspace.isEmpty {
                do {
                    _ = try await query("USE " + quoteName(keyspace))
                } catch let error as DatabaseError {
                    throw DatabaseError("Couldn't open keyspace “\(keyspace)”.", detail: error.message)
                }
            }
            guard readVersion else { return "" }
            let cql = isScylla ? "SELECT version FROM system.versions WHERE key = 'local'"
                               : "SELECT release_version FROM system.local WHERE key = 'local'"
            if case .rows(let rows)? = try? await query(cql), let version = rows.rows.first?.first ?? nil {
                return (isScylla ? "ScyllaDB " : "Cassandra ") + version
            }
            return isScylla ? "ScyllaDB" : "Cassandra"
        }
    }

    /// A keyspace or table name as CQL reads it: bare when it is lower-case letters, digits and _, else quoted.
    static func quoteName(_ name: String) -> String {
        let bare = name.first.map { $0.isLetter && $0.isLowercase && $0.isASCII } == true
            && name.allSatisfy { ($0.isLetter && $0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "_" }
        return bare ? name : SQLDialect(kind: .scylla).quoteIdentifier(name)
    }

    static func literal(_ text: String) -> String {
        SQLDialect(kind: .scylla).literal(text)
    }

    // MARK: Running queries

    /// One QUERY exchange, reconnecting first when the last connection was closed (by the server or by Stop).
    private func request(_ cql: String, pageSize: Int, pagingState: [UInt8]?) async throws -> CQLProtocol.Result {
        let connection = try await liveConnection()
        let (stream, consistency) = state.withLockedValue { state -> (Int16, UInt16) in
            let stream = state.nextStream
            state.nextStream = stream == Int16.max ? 1 : stream + 1
            state.running = true
            return (stream, state.consistency)
        }
        defer { state.withLockedValue { $0.running = false } }
        do {
            let body = CQLProtocol.queryBody(cql, consistency: consistency, pageSize: pageSize, pagingState: pagingState)
            try await connection.write(CQLProtocol.frame(.query, stream: stream, body: body))
            var frame: CQLProtocol.Frame
            repeat {
                // Server events (stream -1) aren't registered for, but skip anything that isn't the answer.
                frame = try await connection.read { try CQLProtocol.parseFrame(&$0) }
            } while frame.stream != stream
            if frame.opcode == CQLProtocol.Opcode.error.rawValue {
                throw try CQLProtocol.readError(&frame.body).databaseError
            }
            guard frame.opcode == CQLProtocol.Opcode.result.rawValue else {
                throw WireConnection.Failure.malformed("unexpected reply to QUERY")
            }
            return try CQLProtocol.readResult(&frame.body)
        } catch let error as DatabaseError {
            throw error
        } catch {
            connection.close()
            state.withLockedValue { state in
                if state.connection === connection { state.connection = nil }
            }
            throw error
        }
    }

    private func liveConnection() async throws -> WireConnection {
        let (connection, credentials, keyspace, closed) = state.withLockedValue {
            ($0.connection, $0.credentials, $0.keyspace, $0.isClosed)
        }
        guard !closed, let credentials else { throw DatabaseError("Not connected") }
        if let connection, connection.isOpen { return connection }
        let (fresh, _) = try await Self.open(endpoint, credentials: credentials, keyspace: keyspace, readVersion: false)
        let replaced = state.withLockedValue { state -> Bool in
            guard !state.isClosed else { return false }
            state.connection = fresh
            return true
        }
        guard replaced else {
            fresh.close()
            throw DatabaseError("Not connected")
        }
        return fresh
    }

    /// Reads up to `limit` rows from `pagingState` on, asking for exactly the rows still missing so a page never
    /// overshoots (the server may still return fewer, or none, before the end). Returns where the rest starts.
    private func fetch(_ cql: String, limit: Int, from pagingState: [UInt8]?) async throws -> (CQLProtocol.Rows?, CQLProtocol.Result) {
        var collected: CQLProtocol.Rows?
        var paging = pagingState
        var last: CQLProtocol.Result = .void
        repeat {
            try Task.checkCancellation()
            let missing = limit - (collected?.rows.count ?? 0)
            last = try await request(cql, pageSize: min(missing, Self.fetchSize), pagingState: paging)
            guard case .rows(let page) = last else { return (nil, last) }
            if collected == nil {
                collected = page
            } else {
                collected!.rows += page.rows
                collected!.pagingState = page.pagingState
            }
            paging = page.pagingState
        } while paging != nil && (collected?.rows.count ?? 0) < limit
        return (collected, last)
    }

    private func rows(_ cql: String) async throws -> [[CellValue]] {
        await gate.acquire()
        defer { gate.release() }
        return try await fetch(cql, limit: 100_000, from: nil).0?.rows ?? []
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        state.withLockedValue { $0.version }
    }

    func listDatabases() async throws -> [String] {
        try await rows("SELECT keyspace_name FROM system_schema.keyspaces")
            .compactMap { $0.first ?? nil }
            .filter { !$0.hasPrefix("system") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func currentDatabase() async throws -> String {
        state.withLockedValue { $0.keyspace }
    }

    func listSchemas() async throws -> [SchemaInfo] {
        let keyspace = state.withLockedValue { $0.keyspace }
        guard !keyspace.isEmpty else { return [] }
        let literal = Self.literal(keyspace)
        let tables = try await rows("SELECT table_name FROM system_schema.tables WHERE keyspace_name = \(literal)")
            .compactMap { $0.first ?? nil }
        // ScyllaDB backs secondary indexes with views named after them; those aren't the user's views.
        let indexViews = Set((try? await rows("SELECT index_name FROM system_schema.indexes WHERE keyspace_name = \(literal)"))?
            .compactMap { $0.first ?? nil }.map { $0 + "_index" } ?? [])
        let views = (try? await rows("SELECT view_name FROM system_schema.views WHERE keyspace_name = \(literal)"))?
            .compactMap { $0.first ?? nil }
            .filter { !indexViews.contains($0) } ?? []
        let infos = tables.map { TableInfo(ref: TableRef(schema: nil, name: $0), kind: .table) }
            + views.map { TableInfo(ref: TableRef(schema: nil, name: $0), kind: .materializedView) }
        return [SchemaInfo(name: keyspace, tables: infos.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending })]
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        let keyspace = table.schema ?? state.withLockedValue { $0.keyspace }
        let filter = "keyspace_name = \(Self.literal(keyspace)) AND table_name = \(Self.literal(table.name))"
        let rows = try await rows("SELECT column_name, type, kind, position, clustering_order FROM system_schema.columns WHERE \(filter)")
        // SELECT * lists the partition key, the clustering columns, then the others by name.
        let rank = ["partition_key": 0, "clustering": 1, "static": 2, "regular": 3]
        func order(_ row: [CellValue]) -> (Int, Int, String) {
            let kind = row[2] ?? ""
            let position = kind == "partition_key" || kind == "clustering" ? Int(row[3] ?? "") ?? 0 : 0
            return (rank[kind] ?? 4, position, row[0] ?? "")
        }
        let ordered = rows.sorted { order($0) < order($1) }
        var partition: [String] = []
        var clustering: [String] = []
        let columns = ordered.map { row -> ColumnInfo in
            let name = row[0] ?? ""
            let kind = row[2] ?? ""
            let comment: String?
            switch kind {
            case "partition_key":
                partition.append(name)
                comment = "Partition key"
            case "clustering":
                clustering.append(name)
                comment = "Clustering column (\((row[4] ?? "asc").uppercased()))"
            case "static":
                comment = "Static"
            default:
                comment = nil
            }
            return ColumnInfo(name: name, dataType: row[1] ?? "", isNullable: kind == "regular" || kind == "static",
                              defaultValue: nil, isPrimaryKey: kind == "partition_key" || kind == "clustering", comment: comment)
        }

        var indexes: [IndexInfo] = []
        if !partition.isEmpty {
            let key = "(" + partition.map(Self.quoteName).joined(separator: ", ") + ")"
                + clustering.map { ", " + Self.quoteName($0) }.joined()
            indexes.append(IndexInfo(name: "PRIMARY KEY", columns: partition + clustering, isUnique: true, isPrimary: true,
                                     definition: "PRIMARY KEY (\(key))"))
        }
        if let secondary = try? await self.rows("SELECT index_name, kind, options FROM system_schema.indexes WHERE \(filter)") {
            for row in secondary {
                let name = row[0] ?? ""
                // options is a map<text, text> literal: {'target': 'email'}.
                let options = row[2] ?? ""
                let target = options.range(of: "'target': '").map { range in
                    String(options[range.upperBound...].prefix { $0 != "'" })
                } ?? ""
                indexes.append(IndexInfo(name: name, columns: target.isEmpty ? [] : [target], isUnique: false, isPrimary: false,
                                         definition: "CREATE INDEX \(Self.quoteName(name)) ON \(Self.quoteName(table.name)) (\(target))"))
            }
        }

        let qualified = Self.quoteName(keyspace) + "." + Self.quoteName(table.name)
        // Servers since ScyllaDB 5.2 and Cassandra 4.0 describe tables themselves, with all their options.
        await gate.acquire()
        let described = try? await fetch("DESCRIBE TABLE \(qualified)", limit: 100, from: nil).0
        gate.release()
        var ddl: String
        if let described, let index = described.columns.firstIndex(of: "create_statement") {
            ddl = described.rows.compactMap { $0[index] }.joined(separator: "\n\n")
        } else {
            let lines = columns.map { "    \(Self.quoteName($0.name)) \($0.dataType)\($0.comment == "Static" ? " static" : "")" }
                + (indexes.first(where: \.isPrimary)?.definition.map { ["    " + $0] } ?? [])
            ddl = "CREATE TABLE \(qualified) (\n" + lines.joined(separator: ",\n") + "\n)"
        }
        return TableStructure(columns: columns, indexes: indexes, foreignKeys: [], ddl: ddl)
    }

    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        let start = Date()
        var cql = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while cql.hasSuffix(";") { cql = String(cql.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        let words = cql.split(whereSeparator: \.isWhitespace).map { $0.uppercased() }
        if words.first == "CONSISTENCY" {
            return try consistency(words.dropFirst().first, statement: sql)
        }

        await gate.acquire()
        defer { gate.release() }
        let limit = max(0, maxRows)
        let (rows, last) = try await fetch(cql, limit: limit + 1, from: nil)
        var result = QueryResult(statement: sql, columns: [], rows: [], rowsAffected: nil, duration: 0)
        switch last {
        case .setKeyspace(let keyspace):
            state.withLockedValue { state in
                state.keyspace = keyspace
                state.cursor = nil
            }
        case .schemaChange:
            state.withLockedValue { $0.cursor = nil }
            if words.starts(with: ["DROP", "KEYSPACE"]) {
                let current = state.withLockedValue { $0.keyspace }
                let left = try? await fetch("SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = \(Self.literal(current))",
                                            limit: 1, from: nil).0
                if left?.rows.isEmpty == true { state.withLockedValue { $0.keyspace = "" } }
            }
        default:
            break
        }
        if let rows {
            result.columns = rows.columns
            result.rows = Array(rows.rows.prefix(limit))
            result.truncated = rows.rows.count > limit
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// cqlsh's CONSISTENCY: shows the level without an argument, sets it with one.
    private func consistency(_ level: String?, statement: String) throws -> QueryResult {
        if let level {
            guard let code = CQLProtocol.consistencyLevels.first(where: { $0.name == level })?.code else {
                throw DatabaseError("“\(level)” isn't a consistency level.",
                                    detail: CQLProtocol.consistencyLevels.map(\.name).joined(separator: ", "))
            }
            state.withLockedValue { $0.consistency = code }
        }
        let current = CQLProtocol.consistencyName(state.withLockedValue { $0.consistency })
        return QueryResult(statement: statement, columns: ["consistency"], rows: [[current]], rowsAffected: nil, duration: 0)
    }

    func cancelCurrentQuery() async {
        // The protocol can't stop a running query, so close the connection; the next query reconnects.
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
            state.cursor = nil
            defer { state.connection = nil }
            return state.connection
        }
        await connection?.closeAndWait()
    }

    // MARK: CommandDriver

    func useDatabase(_ name: String) async throws {
        await gate.acquire()
        defer { gate.release() }
        if case .setKeyspace(let keyspace) = try await request("USE " + Self.quoteName(name), pageSize: 1, pagingState: nil) {
            state.withLockedValue { state in
                state.keyspace = keyspace
                state.cursor = nil
            }
        }
    }

    /// The SELECT that browses `table` with `filter` (a WHERE condition).
    private func browseQuery(_ table: TableRef, filter: String?) -> String {
        let keyspace = table.schema ?? state.withLockedValue { $0.keyspace }
        var cql = "SELECT * FROM " + Self.quoteName(keyspace) + "." + Self.quoteName(table.name)
        var condition = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while condition.hasSuffix(";") { condition = String(condition.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        if !condition.isEmpty {
            cql += " WHERE " + condition
            if !condition.uppercased().hasSuffix("ALLOW FILTERING") { cql += " ALLOW FILTERING" }
        }
        return cql
    }

    func page(of table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) async throws -> QueryResult {
        let start = Date()
        let cql = browseQuery(table, filter: filter)
        let limit = max(1, limit)
        let offset = max(0, offset)

        await gate.acquire()
        defer { gate.release() }
        let key = cql
        var cursor = state.withLockedValue { $0.cursor }
        // The first page always starts over, so Reload and a new filter see current rows.
        if offset == 0 || cursor?.key != key || cursor?.limit != limit {
            cursor = BrowseCursor(key: key, limit: limit)
        }
        // Walk forward from the nearest page whose start is known.
        var position = cursor!.states.keys.filter { $0 <= offset }.max() ?? 0
        var paging = cursor!.states[position]
        var rows: CQLProtocol.Rows?
        while true {
            if let end = cursor!.end, position >= end {
                rows = nil
                break
            }
            let (page, _) = try await fetch(cql, limit: limit, from: paging)
            guard let page else { break }
            position += limit
            if let next = page.pagingState { cursor!.states[position] = next } else { cursor!.end = position - limit + page.rows.count }
            if position - limit >= offset || page.pagingState == nil {
                rows = position - limit == offset ? page : nil
                break
            }
            paging = page.pagingState
        }
        state.withLockedValue { $0.cursor = cursor }

        var result = QueryResult(statement: cql, columns: rows?.columns ?? [], rows: rows?.rows ?? [], rowsAffected: nil,
                                 duration: 0)
        if let sort, let index = sort.index(in: result.columns) {
            // CQL can only order by clustering columns within a partition; sorting applies to the page that was read.
            result.rows.sort { lhs, rhs in
                sort.ascending ? Self.precedes(lhs[index], rhs[index]) : Self.precedes(rhs[index], lhs[index])
            }
        }
        if result.rows.isEmpty { result.columns = [] }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// Counting rows in CQL scans the whole table across the cluster, so the browser only knows the count once
    /// it has paged to the end.
    func count(of table: TableRef, filter: String?) async throws -> Int? {
        let cursor = state.withLockedValue { $0.cursor }
        return cursor?.key == browseQuery(table, filter: filter) ? cursor?.end : nil
    }

    private static func precedes(_ lhs: CellValue, _ rhs: CellValue) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (l?, r?):
            if let a = Double(l), let b = Double(r) { return a < b }
            return l.localizedStandardCompare(r) == .orderedAscending
        }
    }
}
