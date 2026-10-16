import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// ClickHouse over its HTTP interface (port 8123, or 8443 with TLS), on one keep-alive connection.
///
/// Every statement carries a session id, so `SET`, temporary tables and `USE` last between statements as in
/// clickhouse-client. Results come back as TabSeparatedWithNamesAndTypes and are read as they stream in, so a
/// large result stops at the row limit instead of being downloaded whole. Stop closes the connection and asks
/// the server to kill the query from a second connection.
///
/// Privacy: the user name and password travel in the X-ClickHouse-User and X-ClickHouse-Key headers, never
/// in the URL. They stay in memory only, to reconnect and to stop a query; `close()` drops them.
final class ClickHouseDriver: DatabaseDriver, @unchecked Sendable {
    let kind: DatabaseKind = .clickhouse

    static let format = "TabSeparatedWithNamesAndTypes"
    static let systemDatabases: Set<String> = ["system", "INFORMATION_SCHEMA", "information_schema"]
    private static let dialect = SQLDialect(kind: .clickhouse)

    private struct Credentials {
        var username: String
        var password: String
    }

    private struct State {
        var connection: WireConnection?
        var credentials: Credentials?
        var database: String
        var version = ""
        /// The session_timeout Dbee asks for, or nil when the server allows less and the default (60 s) applies.
        var sessionTimeout: String? = "3600"
        /// The query on the wire, so Stop knows what to kill.
        var runningQueryID: String?
        var isClosed = false
    }

    private let endpoint: WireConnection.Endpoint
    /// The server session every statement runs in.
    private let sessionID: String
    private let gate = PostgresStatementGate()
    private let state: NIOLockedValueBox<State>

    private init(endpoint: WireConnection.Endpoint, sessionID: String, connection: WireConnection,
                 credentials: Credentials, state initial: State) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        var initial = initial
        initial.connection = connection
        initial.credentials = credentials
        state = NIOLockedValueBox(initial)
    }

    // MARK: Connecting

    static func connect(config: ConnectionConfig, host: String, port: Int,
                        transport: DriverTransport = .direct) async throws -> ClickHouseDriver {
        let endpoint = WireConnection.Endpoint(config: config, dialHost: host, dialPort: port, transport: transport)
        let credentials = Credentials(username: config.username.trimmingCharacters(in: .whitespaces), password: config.password)
        let requested = config.database.trimmingCharacters(in: .whitespaces)
        let sessionID = "dbee-" + UUID().uuidString

        var probe = State(database: requested)
        let (connection, (version, database)) = try await WireConnection.open(endpoint) { connection -> (String, String) in
            let deadline = NIODeadline.now() + WireConnection.connectTimeout
            func attempt(_ timeout: String?) async throws -> Outcome {
                let request = Self.request("SELECT version(), currentDatabase()", credentials: credentials, database: requested,
                                           sessionID: sessionID, sessionTimeout: timeout, queryID: UUID().uuidString)
                return try await perform(request, on: connection, maxRows: 1, deadline: deadline, expectsClickHouse: true)
            }
            var outcome: Outcome
            do {
                outcome = try await attempt(probe.sessionTimeout)
            } catch let error as ClickHouseError where error.message.contains("session_timeout") {
                // The server caps sessions below an hour; use its default instead.
                probe.sessionTimeout = nil
                outcome = try await attempt(nil)
            } catch let error as ClickHouseError {
                switch error.name {
                case "AUTHENTICATION_FAILED", "REQUIRED_PASSWORD", "UNKNOWN_USER", "WRONG_PASSWORD":
                    throw DatabaseError("ClickHouse refused the login.", detail: error.message)
                case "UNKNOWN_DATABASE":
                    throw DatabaseError("Couldn't open database “\(requested)”.", detail: error.message)
                default:
                    throw error.databaseError
                }
            }
            guard let row = outcome.rows.first, row.count == 2 else {
                throw WireConnection.Failure.malformed("unexpected reply to SELECT version()")
            }
            return ("ClickHouse " + (row[0] ?? ""), row[1] ?? requested)
        }
        probe.version = version
        probe.database = database
        // The probe opened the server session; the driver keeps using it.
        return ClickHouseDriver(endpoint: endpoint, sessionID: sessionID, connection: connection,
                                credentials: credentials, state: probe)
    }

    // MARK: Requests

    private static func request(_ sql: String, credentials: Credentials, database: String?, sessionID: String?,
                                sessionTimeout: String?, queryID: String) -> HTTPWire.Request {
        var items = [("default_format", format), ("query_id", queryID)]
        if let database, !database.isEmpty { items.append(("database", database)) }
        if let sessionID {
            items.append(("session_id", sessionID))
            if let sessionTimeout { items.append(("session_timeout", sessionTimeout)) }
        }
        var headers: [(name: String, value: String)] = [
            ("X-ClickHouse-User", credentials.username.isEmpty ? "default" : credentials.username),
            ("Content-Type", "text/plain; charset=utf-8"),
        ]
        if !credentials.password.isEmpty { headers.append(("X-ClickHouse-Key", credentials.password)) }
        return HTTPWire.Request(method: "POST", target: "/?" + HTTPWire.query(items), headers: headers, body: Array(sql.utf8))
    }

    /// What one statement returned.
    private struct Outcome {
        var columns: [String] = []
        var types: [String] = []
        var rows: [[CellValue]] = []
        var isRowSet = false
        var truncated = false
        var writtenRows: Int?
        /// Whether the connection can carry the next request (the whole response was read and kept alive).
        var reusable = true
    }

    /// Sends one statement and reads its result, stopping after `maxRows` rows.
    private static func perform(_ request: HTTPWire.Request, on connection: WireConnection, maxRows: Int,
                                deadline: NIODeadline? = nil, expectsClickHouse: Bool = false) async throws -> Outcome {
        let head = try await connection.send(request, deadline: deadline)
        let isClickHouse = head.headers.contains { $0.name.lowercased().hasPrefix("x-clickhouse-") }
        guard head.status == 200 else {
            let body = try await connection.readBody(head, method: request.method, deadline: deadline, limit: 1 << 20)
            let text = String(decoding: body, as: UTF8.self)
            if isClickHouse || text.hasPrefix("Code: ") { throw ClickHouseError(text) }
            throw DatabaseError("\(connection.endpoint.displayName) didn't answer like a ClickHouse server.",
                                detail: "HTTP \(head.status) \(head.reason). " + text.prefix(300)
                                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if expectsClickHouse, !isClickHouse {
            throw DatabaseError("\(connection.endpoint.displayName) didn't answer like a ClickHouse server.",
                                detail: "Check the port number: ClickHouse's HTTP interface usually listens on 8123, or 8443 with TLS.")
        }

        var reader = TSVReader(maxRows: maxRows, tabular: (head.header("X-ClickHouse-Format") ?? format) == format,
                               format: head.header("X-ClickHouse-Format") ?? format)
        let complete: Bool
        do {
            complete = try await connection.streamBody(head, method: request.method, deadline: deadline) { piece in
                try reader.feed(piece.readableBytesView)
            }
        } catch {
            // Stopped in the middle of the response: the connection can't carry another request.
            connection.close()
            throw error
        }
        if complete { try reader.finish() }

        var outcome = Outcome()
        outcome.columns = reader.columns
        outcome.types = reader.types
        outcome.rows = reader.rows
        outcome.isRowSet = reader.sawHeader
        outcome.truncated = reader.truncated
        outcome.reusable = complete && head.keepsAlive
        if let summary = head.header("X-ClickHouse-Summary").flatMap({ try? JSONValue.parse($0) }) {
            outcome.writtenRows = summary["written_rows"]?.string.flatMap(Int.init) ?? summary["written_rows"]?.int
        }
        return outcome
    }

    // MARK: Running statements

    private func run(_ sql: String, maxRows: Int, useDatabase: Bool = true) async throws -> Outcome {
        await gate.acquire()
        defer { gate.release() }
        var attempts = 0
        while true {
            do {
                return try await runOnce(sql, maxRows: maxRows, useDatabase: useDatabase)
            } catch let error as ClickHouseError where error.name == "SESSION_IS_LOCKED" && attempts < 25 {
                // A stopped query still holds the session until the server notices; give it a moment.
                attempts += 1
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func runOnce(_ sql: String, maxRows: Int, useDatabase: Bool) async throws -> Outcome {
        let connection = try await liveConnection()
        let queryID = UUID().uuidString
        let request = state.withLockedValue { state -> HTTPWire.Request? in
            guard let credentials = state.credentials else { return nil }
            state.runningQueryID = queryID
            return Self.request(sql, credentials: credentials, database: useDatabase ? state.database : nil,
                                sessionID: sessionID, sessionTimeout: state.sessionTimeout, queryID: queryID)
        }
        guard let request else { throw DatabaseError("Not connected") }
        defer { state.withLockedValue { $0.runningQueryID = nil } }
        do {
            let outcome = try await Self.perform(request, on: connection, maxRows: maxRows)
            if !outcome.reusable {
                drop(connection)
                // The rest of the result is still being produced; don't let it hold the session.
                if outcome.truncated { await kill(queryID) }
            }
            return outcome
        } catch let error as ClickHouseError {
            // The server answered; `perform` closed the connection if the reply wasn't read whole.
            throw error
        } catch {
            drop(connection)
            throw error
        }
    }

    private func drop(_ connection: WireConnection) {
        connection.close()
        state.withLockedValue { state in
            if state.connection === connection { state.connection = nil }
        }
    }

    private func liveConnection() async throws -> WireConnection {
        let (connection, closed) = state.withLockedValue { ($0.connection, $0.isClosed) }
        guard !closed else { throw DatabaseError("Not connected") }
        if let connection, connection.isOpen { return connection }
        let (fresh, _) = try await WireConnection.open(endpoint) { _ in () }
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

    /// Asks the server to stop `queryID`, from a second connection outside the session (which the query holds).
    private func kill(_ queryID: String) async {
        guard let credentials = state.withLockedValue({ $0.credentials }),
              let (side, _) = try? await WireConnection.open(endpoint, handshake: { _ in () }) else { return }
        defer { side.close() }
        let sql = "KILL QUERY WHERE query_id = \(Self.dialect.literal(queryID)) ASYNC"
        let request = Self.request(sql, credentials: credentials, database: nil, sessionID: nil, sessionTimeout: nil,
                                   queryID: UUID().uuidString)
        _ = try? await Self.perform(request, on: side, maxRows: 10, deadline: .now() + .seconds(10))
    }

    private func rows(_ sql: String) async throws -> [[CellValue]] {
        try await run(sql, maxRows: 100_000).rows
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        state.withLockedValue { $0.version }
    }

    func listDatabases() async throws -> [String] {
        try await rows("SELECT name FROM system.databases ORDER BY name")
            .compactMap { $0.first ?? nil }
            .filter { !Self.systemDatabases.contains($0) }
    }

    func currentDatabase() async throws -> String {
        state.withLockedValue { $0.database }
    }

    func listSchemas() async throws -> [SchemaInfo] {
        let database = state.withLockedValue { $0.database }
        let rows = try await rows("""
            SELECT name, engine FROM system.tables
            WHERE database = \(Self.dialect.literal(database)) AND NOT is_temporary AND name NOT LIKE '.inner%'
            ORDER BY name
            """)
        let tables = rows.compactMap { row -> TableInfo? in
            guard let name = row.first ?? nil else { return nil }
            let kind: TableKind = switch row.count > 1 ? row[1] ?? "" : "" {
            case "View", "LiveView", "WindowView": .view
            case "MaterializedView": .materializedView
            default: .table
            }
            return TableInfo(ref: TableRef(schema: nil, name: name), kind: kind)
        }
        return [SchemaInfo(name: database, tables: tables)]
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        let database = table.schema ?? state.withLockedValue { $0.database }
        let db = Self.dialect.literal(database)
        let name = Self.dialect.literal(table.name)
        let columnRows = try await rows("""
            SELECT name, type, default_kind, default_expression, comment, is_in_primary_key
            FROM system.columns WHERE database = \(db) AND table = \(name) ORDER BY position
            """)
        let columns = columnRows.map { row -> ColumnInfo in
            let type = row[1] ?? ""
            let defaultKind = row[2] ?? ""
            let expression = row[3] ?? ""
            let comment = row[4] ?? ""
            return ColumnInfo(
                name: row[0] ?? "",
                dataType: type,
                isNullable: type.hasPrefix("Nullable(") || type.hasPrefix("LowCardinality(Nullable("),
                defaultValue: expression.isEmpty ? nil : (defaultKind == "DEFAULT" || defaultKind.isEmpty ? expression : "\(defaultKind) \(expression)"),
                isPrimaryKey: row[5] == "1",
                comment: comment.isEmpty ? nil : comment
            )
        }

        var indexes: [IndexInfo] = []
        if let keys = try? await rows("""
            SELECT primary_key, sorting_key, partition_key FROM system.tables WHERE database = \(db) AND name = \(name)
            """).first {
            func parts(_ text: String?) -> [String] {
                (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let primary = parts(keys[0])
            let sorting = parts(keys[1])
            let partition = parts(keys[2])
            if !primary.isEmpty {
                indexes.append(IndexInfo(name: "PRIMARY KEY", columns: primary, isUnique: false, isPrimary: true,
                                         definition: "PRIMARY KEY (\(primary.joined(separator: ", ")))"))
            }
            if !sorting.isEmpty, sorting != primary {
                indexes.append(IndexInfo(name: "ORDER BY", columns: sorting, isUnique: false, isPrimary: false,
                                         definition: "ORDER BY (\(sorting.joined(separator: ", ")))"))
            }
            if !partition.isEmpty {
                indexes.append(IndexInfo(name: "PARTITION BY", columns: partition, isUnique: false, isPrimary: false,
                                         definition: "PARTITION BY \(keys[2] ?? "")"))
            }
        }
        if let skipping = try? await rows("""
            SELECT name, expr, type_full, granularity FROM system.data_skipping_indices WHERE database = \(db) AND table = \(name)
            """) {
            for row in skipping {
                let index = row[0] ?? ""
                let expression = row[1] ?? ""
                indexes.append(IndexInfo(name: index, columns: [expression], isUnique: false, isPrimary: false,
                                         definition: "INDEX \(index) \(expression) TYPE \(row[2] ?? "") GRANULARITY \(row[3] ?? "1")"))
            }
        }

        let qualified = Self.dialect.quoteIdentifier(database) + "." + Self.dialect.quoteIdentifier(table.name)
        let ddl = try? await rows("SHOW CREATE TABLE \(qualified)").first?.first ?? nil
        return TableStructure(columns: columns, indexes: indexes, foreignKeys: [], ddl: ddl)
    }

    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        let start = Date()
        let words = StatementTraits.words(sql, kind: .clickhouse, limit: 2)
        let outcome: Outcome
        do {
            outcome = try await run(sql, maxRows: max(0, maxRows))
        } catch let error as ClickHouseError {
            throw error.databaseError
        }
        if words.first == "USE" {
            // USE changes the session's database; read it back without naming one in the request.
            if let name = try? await run("SELECT currentDatabase()", maxRows: 1, useDatabase: false).rows.first?.first ?? nil {
                state.withLockedValue { $0.database = name }
            }
        } else if words == ["DROP", "DATABASE"] {
            let current = state.withLockedValue { $0.database }
            // Asked without naming a database, since the current one may be the one just dropped.
            let exists = try? await run("SELECT 1 FROM system.databases WHERE name = \(Self.dialect.literal(current))",
                                        maxRows: 1, useDatabase: false).rows
            if exists?.isEmpty == true { state.withLockedValue { $0.database = "default" } }
        }

        let duration = Date().timeIntervalSince(start)
        guard outcome.isRowSet else {
            let affected = words.first == "INSERT" || (outcome.writtenRows ?? 0) > 0 ? outcome.writtenRows : nil
            return QueryResult(statement: sql, columns: [], rows: [], rowsAffected: affected, duration: duration)
        }
        return QueryResult(statement: sql, columns: outcome.columns, rows: outcome.rows, rowsAffected: nil,
                           duration: duration, truncated: outcome.truncated)
    }

    func cancelCurrentQuery() async {
        let (connection, queryID) = state.withLockedValue { state -> (WireConnection?, String?) in
            guard let id = state.runningQueryID else { return (nil, nil) }
            defer { state.connection = nil }
            return (state.connection, id)
        }
        guard let queryID else { return }
        connection?.abort()
        await kill(queryID)
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
}

/// An exception reported by ClickHouse: "Code: 60. DB::Exception: Unknown table … (UNKNOWN_TABLE) (version …)".
struct ClickHouseError: Error, Sendable {
    var code: Int?
    var name: String?
    var message: String

    init(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.range(of: "Code: ") {
            text = String(text[start.lowerBound...])
            let digits = text.dropFirst(6).prefix { $0.isNumber }
            code = Int(digits)
        }
        if let exception = text.range(of: "DB::Exception: ") { text = String(text[exception.upperBound...]) }
        if let version = text.range(of: " (version ", options: .backwards) { text = String(text[..<version.lowerBound]) }
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
            let candidate = text[open.upperBound..<text.index(before: text.endIndex)]
            if !candidate.isEmpty, candidate.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                name = String(candidate)
                text = String(text[..<open.lowerBound])
            }
        }
        // Long exceptions end with a stack trace; the first line says what happened.
        message = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }

    var databaseError: DatabaseError {
        let detail = [name, code.map { "code \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return DatabaseError(message, detail: detail.isEmpty ? nil : detail)
    }
}

/// Reads TabSeparatedWithNamesAndTypes output line by line: names, types, then one row per line.
/// Any other format (a statement with its own FORMAT clause) is shown one line per row.
struct TSVReader {
    let maxRows: Int
    let tabular: Bool
    let format: String
    private(set) var columns: [String] = []
    private(set) var types: [String] = []
    private(set) var rows: [[CellValue]] = []
    private(set) var truncated = false
    /// Whether any output arrived; statements without a result (INSERT, CREATE) send none.
    private(set) var sawHeader = false
    private var pending: [UInt8] = []
    private var lineIndex = 0

    private static let exceptionStart = Array("Code: ".utf8)
    /// Newer servers mark an exception written into the body with this tag.
    private static let exceptionTag = Array("__exception__".utf8)

    init(maxRows: Int, tabular: Bool = true, format: String = ClickHouseDriver.format) {
        self.maxRows = maxRows
        self.tabular = tabular
        self.format = format
    }

    /// Takes the next bytes of the body. Returns false once the row limit is passed.
    mutating func feed<C: Collection>(_ bytes: C) throws -> Bool where C.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var start = 0
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            let keepGoing = try line(pending[start..<newline])
            start = newline + 1
            if !keepGoing {
                pending.removeAll()
                return false
            }
        }
        pending.removeFirst(start)
        return true
    }

    mutating func finish() throws {
        if !pending.isEmpty {
            let rest = pending
            pending.removeAll()
            _ = try line(rest[...])
        }
    }

    private mutating func line(_ bytes: ArraySlice<UInt8>) throws -> Bool {
        defer { lineIndex += 1 }
        sawHeader = true
        guard tabular else {
            if columns.isEmpty { columns = [format] }
            if rows.count >= maxRows { truncated = true; return false }
            rows.append([String(decoding: bytes, as: UTF8.self)])
            return true
        }
        let fields = Self.fields(bytes)
        switch lineIndex {
        case 0:
            columns = fields.map { $0 ?? "" }
        case 1:
            types = fields.map { $0 ?? "" }
        default:
            // An error after the status line was sent arrives as text in the body, on a line of its own or
            // after a row cut short.
            if fields.count != columns.count || bytes.starts(with: Self.exceptionStart) || bytes.starts(with: Self.exceptionTag) {
                let text = String(decoding: bytes, as: UTF8.self)
                if let start = text.range(of: "Code: "), text.contains("DB::Exception") {
                    throw ClickHouseError(String(text[start.lowerBound...]))
                }
                if fields.count != columns.count {
                    throw WireConnection.Failure.malformed("a row with \(fields.count) values for \(columns.count) columns")
                }
            }
            if rows.count >= maxRows {
                truncated = true
                return false
            }
            rows.append(fields)
        }
        return true
    }

    /// Splits a line on tabs and undoes TSV escaping; `\N` alone is NULL.
    static func fields(_ bytes: ArraySlice<UInt8>) -> [CellValue] {
        var fields: [CellValue] = []
        var field: [UInt8] = []
        var isNull = false
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let c = bytes[i]
            if c == 0x09 {
                fields.append(isNull && field.isEmpty ? nil : String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
                isNull = false
            } else if c == 0x5C, i + 1 < bytes.endIndex {
                i += 1
                switch bytes[i] {
                case UInt8(ascii: "n"): field.append(0x0A)
                case UInt8(ascii: "t"): field.append(0x09)
                case UInt8(ascii: "r"): field.append(0x0D)
                case UInt8(ascii: "b"): field.append(0x08)
                case UInt8(ascii: "f"): field.append(0x0C)
                case UInt8(ascii: "0"): field.append(0x00)
                case UInt8(ascii: "N") where field.isEmpty: isNull = true
                default: field.append(bytes[i])
                }
            } else {
                if isNull { isNull = false; field.append(contentsOf: Array("\\N".utf8)) }
                field.append(c)
            }
            i += 1
        }
        fields.append(isNull && field.isEmpty ? nil : String(decoding: field, as: UTF8.self))
        return fields
    }
}
