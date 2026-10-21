import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// Redis (and compatible servers such as Valkey) over one RESP connection.
///
/// The query editor sends one command per line, written as in redis-cli. The sidebar shows each database's
/// keys as a single table, which the browser pages through with SCAN.
///
/// Privacy: the username and password stay in memory only, to log in again when the connection drops or a
/// stopped command had to close it. `close()` drops them.
final class RedisDriver: CommandDriver, @unchecked Sendable {
    let kind: DatabaseKind = .redis

    static let keysTable = TableRef(schema: nil, name: "keys")
    /// The browser sorts keys by name, so it reads every matching key first; this caps that read.
    static let scanLimit = 100_000
    /// Elements of a hash, list, set or sorted set shown in the browser's value column.
    static let previewCount = 100

    private struct Credentials {
        var username: String
        var password: String
    }

    /// Keys matching one pattern, sorted, from the browser's last scan.
    private struct KeyScan {
        var database: Int
        var pattern: String
        var keys: [[UInt8]]
        var complete: Bool
    }

    private struct State {
        var connection: WireConnection?
        var credentials: Credentials?
        var selection: RedisSelection
        var version = ""
        /// A command is on the wire, so Stop has something to interrupt.
        var running = false
        var scan: KeyScan?
        var isClosed = false

        var database: Int { selection.database }
    }

    private let endpoint: WireConnection.Endpoint
    private let gate = PostgresStatementGate()
    private let state: NIOLockedValueBox<State>

    private init(endpoint: WireConnection.Endpoint, connection: WireConnection, credentials: Credentials,
                 database: Int, version: String) {
        self.endpoint = endpoint
        state = NIOLockedValueBox(State(connection: connection, credentials: credentials,
                                        selection: RedisSelection(database: database), version: version))
    }

    // MARK: Connecting

    static func connect(config: ConnectionConfig, host: String, port: Int,
                        transport: DriverTransport = .direct) async throws -> RedisDriver {
        let endpoint = WireConnection.Endpoint(config: config, dialHost: host, dialPort: port, transport: transport)
        let credentials = Credentials(username: config.username, password: config.password)
        let database = try databaseIndex(config.database.trimmingCharacters(in: .whitespaces)) ?? 0
        let (connection, version) = try await open(endpoint, credentials: credentials, database: database)
        return RedisDriver(endpoint: endpoint, connection: connection, credentials: credentials,
                           database: database, version: version)
    }

    /// "3", "db3" → 3; "" → nil.
    static func databaseIndex(_ name: String) throws -> Int? {
        guard !name.isEmpty else { return nil }
        let digits = name.lowercased().hasPrefix("db") ? String(name.dropFirst(2)) : name
        guard let index = Int(digits), index >= 0 else {
            throw DatabaseError("“\(name)” isn't a Redis database.", detail: "Redis databases are numbered: enter 0, 1, 2…")
        }
        return index
    }

    static func databaseName(_ index: Int) -> String { "db\(index)" }

    private static func open(_ endpoint: WireConnection.Endpoint, credentials: Credentials,
                             database: Int) async throws -> (WireConnection, String) {
        try await WireConnection.open(endpoint) { connection in
            let deadline = NIODeadline.now() + WireConnection.connectTimeout
            if !credentials.password.isEmpty {
                var arguments = [Array("AUTH".utf8)]
                if !credentials.username.isEmpty { arguments.append(Array(credentials.username.utf8)) }
                arguments.append(Array(credentials.password.utf8))
                if case .error(let message) = try await roundTrip([arguments], on: connection, deadline: deadline)[0] {
                    throw DatabaseError("Redis refused the login.", detail: message)
                }
            }
            if database != 0 {
                let reply = try await roundTrip([[Array("SELECT".utf8), Array(String(database).utf8)]],
                                                on: connection, deadline: deadline)[0]
                if case .error(let message) = reply {
                    if message.hasPrefix("NOAUTH") { throw DatabaseError("Redis needs a password.", detail: message) }
                    throw DatabaseError("Couldn't open database \(database).", detail: message)
                }
            }
            let info = try await roundTrip([[Array("INFO".utf8), Array("server".utf8)]], on: connection, deadline: deadline)[0]
            if case .error(let message) = info {
                if message.hasPrefix("NOAUTH") {
                    throw DatabaseError("Redis needs a password.", detail: message)
                }
                // Some managed services disable INFO; the connection still works.
                return ""
            }
            return versionString(fromInfo: info.string ?? "")
        }
    }

    private static func versionString(fromInfo info: String) -> String {
        let fields = parseInfo(info).reduce(into: [String: String]()) { $0[$1.key] = $1.value }
        if let valkey = fields["valkey_version"] { return "Valkey \(valkey)" }
        guard let version = fields["redis_version"] else { return "" }
        return "Redis \(version)"
    }

    /// INFO text as (section, key, value) rows.
    static func parseInfo(_ text: String) -> [(section: String, key: String, value: String)] {
        var rows: [(String, String, String)] = []
        var section = ""
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") {
                section = line.dropFirst().trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                rows.append((section, String(line[..<colon]), String(line[line.index(after: colon)...])))
            }
        }
        return rows
    }

    /// Sends `commands` in one write and reads one reply per command.
    private static func roundTrip(_ commands: [[[UInt8]]], on connection: WireConnection,
                                  deadline: NIODeadline? = nil) async throws -> [RESPValue] {
        var buffer = ByteBuffer()
        for command in commands { RESPParser.encode(command, into: &buffer) }
        try await connection.write(buffer)
        var replies: [RESPValue] = []
        replies.reserveCapacity(commands.count)
        for _ in commands {
            replies.append(try await connection.read(deadline: deadline) { try RESPParser.parse(&$0) })
        }
        return replies
    }

    // MARK: Running commands

    /// Runs `commands` as one pipeline, one exchange at a time, reconnecting first when the last
    /// connection was closed (by the server or by Stop).
    private func send(_ commands: [[[UInt8]]]) async throws -> [RESPValue] {
        await gate.acquire()
        defer { gate.release() }
        let connection = try await liveConnection()
        state.withLockedValue { $0.running = true }
        defer { state.withLockedValue { $0.running = false } }
        do {
            return try await Self.roundTrip(commands, on: connection)
        } catch {
            connection.close()
            state.withLockedValue { state in
                if state.connection === connection { state.connection = nil }
            }
            throw error
        }
    }

    private func send(_ arguments: String...) async throws -> RESPValue {
        try await send([arguments.map { Array($0.utf8) }])[0]
    }

    private func liveConnection() async throws -> WireConnection {
        let (connection, credentials, database, closed) = state.withLockedValue {
            ($0.connection, $0.credentials, $0.database, $0.isClosed)
        }
        guard !closed, let credentials else { throw DatabaseError("Not connected") }
        if let connection, connection.isOpen { return connection }
        let (fresh, _) = try await Self.open(endpoint, credentials: credentials, database: database)
        let replaced = state.withLockedValue { state -> Bool in
            guard !state.isClosed else { return false }
            state.connection = fresh
            // The server dropped any transaction along with the old connection.
            state.selection.queued = nil
            return true
        }
        guard replaced else {
            fresh.close()
            throw DatabaseError("Not connected")
        }
        return fresh
    }

    /// Throws for an error reply.
    private static func checked(_ reply: RESPValue) throws -> RESPValue {
        if case .error(let message) = reply { throw DatabaseError(message) }
        return reply
    }

    /// Whether the editor left a MULTI open on the connection.
    private var isInTransactionBlock: Bool { state.withLockedValue { $0.selection.isInTransaction } }

    /// The browser's own commands would be queued into the user's transaction and change what EXEC returns.
    private func ensureNoTransaction() throws {
        if isInTransactionBlock {
            throw DatabaseError("A Redis transaction is open in a query tab.",
                                detail: "Run EXEC or DISCARD there first.")
        }
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        state.withLockedValue { $0.version }
    }

    func listDatabases() async throws -> [String] {
        var count = 16
        if isInTransactionBlock {
            // Probing now would queue CONFIG and INFO into the user's transaction.
        } else if let reply = try? await send("CONFIG", "GET", "databases"), case .array(let items?) = reply,
           items.count >= 2, let value = items[1].integer {
            count = Int(value)
        } else if let info = try? await send("INFO", "keyspace").string {
            // CONFIG is often disabled on managed servers; the keyspace lists databases that hold keys.
            let used = Self.parseInfo(info).compactMap { Int($0.key.dropFirst(2)) }
            count = max(count, (used.max() ?? 0) + 1)
        }
        let current = state.withLockedValue { $0.database }
        return (0..<max(count, current + 1)).map(Self.databaseName)
    }

    func currentDatabase() async throws -> String {
        Self.databaseName(state.withLockedValue { $0.database })
    }

    func listSchemas() async throws -> [SchemaInfo] {
        let name = try await currentDatabase()
        return [SchemaInfo(name: name, tables: [TableInfo(ref: Self.keysTable, kind: .keys)])]
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        func column(_ name: String, _ type: String, key: Bool = false, nullable: Bool = true, comment: String? = nil) -> ColumnInfo {
            ColumnInfo(name: name, dataType: type, isNullable: nullable, defaultValue: nil, isPrimaryKey: key, comment: comment)
        }
        return TableStructure(
            columns: [
                column("key", "string", key: true, nullable: false),
                column("type", "string", nullable: false),
                column("ttl", "integer", comment: "Seconds until the key expires; empty when it doesn't."),
                column("size", "integer", comment: "Length of a string, or number of elements."),
                column("value", "string", comment: "The value, or its first \(Self.previewCount) elements as JSON."),
            ],
            indexes: [],
            foreignKeys: [],
            ddl: nil
        )
    }

    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        let start = Date()
        let arguments = try RedisCommandLine.arguments(sql)
        guard let first = arguments.first else { throw DatabaseError("Enter a Redis command.") }
        let name = String(decoding: first, as: UTF8.self).uppercased()
        let words = arguments.map { String(decoding: $0, as: UTF8.self).uppercased() }
        if ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "SYNC", "PSYNC"].contains(name) {
            throw DatabaseError("Dbee doesn't run \(name).", detail: "It streams replies without end; use redis-cli for it.")
        }
        if name == "QUIT" || name == "RESET" || (name == "HELLO" && words.dropFirst().first == "3") {
            throw DatabaseError("Dbee doesn't run \(words.prefix(2).joined(separator: " ")) from the editor.",
                                detail: "It would change the connection under Dbee.")
        }
        let raw = try await send([arguments])[0]
        state.withLockedValue { state in
            if state.selection.track(words, reply: raw) { state.scan = nil }
        }
        let reply = try Self.checked(raw)
        var result = Self.result(for: words, reply: reply, maxRows: maxRows)
        result.statement = sql
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    func cancelCurrentQuery() async {
        // RESP has no way to stop a command, so close the connection; the next command reconnects.
        let connection = state.withLockedValue { state -> WireConnection? in
            guard state.running else { return nil }
            let connection = state.connection
            state.connection = nil
            return connection
        }
        connection?.abort()
    }

    func close() async {
        let connection = state.withLockedValue { state -> WireConnection? in
            state.isClosed = true
            state.credentials = nil
            state.scan = nil
            defer { state.connection = nil }
            return state.connection
        }
        await connection?.closeAndWait()
    }

    // MARK: CommandDriver

    func useDatabase(_ name: String) async throws {
        guard let index = try Self.databaseIndex(name) else { return }
        try ensureNoTransaction()
        _ = try Self.checked(try await send("SELECT", String(index)))
        state.withLockedValue { state in
            state.selection.database = index
            state.scan = nil
        }
    }

    func page(of table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) async throws -> QueryResult {
        let start = Date()
        try ensureNoTransaction()
        let pattern = Self.pattern(filter)
        let database = state.withLockedValue { $0.database }
        var scan = state.withLockedValue { $0.scan }
        // The first page always rescans, so Reload and a new filter see current keys.
        if offset == 0 || scan?.pattern != pattern || scan?.database != database {
            scan = try await scanKeys(matching: pattern, database: database)
            state.withLockedValue { $0.scan = scan }
        }
        var keys = scan?.keys ?? []
        let sortsByKey = sort == nil || sort?.column == "key"
        if sortsByKey, sort?.ascending == false { keys.reverse() }
        let slice = Array(keys.dropFirst(max(0, offset)).prefix(max(0, limit)))
        var rows = try await describe(slice)
        if let sort, !sortsByKey, let index = ["key", "type", "ttl", "size", "value"].firstIndex(of: sort.column) {
            // Only the key order is known for every page; other columns sort the page that was read.
            rows.sort { lhs, rhs in
                let ordered = Self.precedes(lhs[index], rhs[index], numeric: index == 2 || index == 3)
                return sort.ascending ? ordered : Self.precedes(rhs[index], lhs[index], numeric: index == 2 || index == 3)
            }
        }
        return QueryResult(statement: "SCAN 0 MATCH \(RedisCommandLine.quoted(pattern))",
                           columns: ["key", "type", "ttl", "size", "value"], rows: rows, rowsAffected: nil,
                           duration: Date().timeIntervalSince(start))
    }

    func count(of table: TableRef, filter: String?) async throws -> Int? {
        try ensureNoTransaction()
        let pattern = Self.pattern(filter)
        if pattern == "*" {
            return try Self.checked(try await send("DBSIZE")).integer.map(Int.init)
        }
        let scan = state.withLockedValue { $0.scan }
        guard let scan, scan.pattern == pattern, scan.complete else { return nil }
        return scan.keys.count
    }

    private static func pattern(_ filter: String?) -> String {
        let text = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "*" : text
    }

    private static func precedes(_ lhs: CellValue, _ rhs: CellValue, numeric: Bool) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (l?, r?):
            if numeric, let a = Int(l), let b = Int(r) { return a < b }
            return l.localizedStandardCompare(r) == .orderedAscending
        }
    }

    private func scanKeys(matching pattern: String, database: Int) async throws -> KeyScan {
        var cursor = "0"
        var seen = Set<[UInt8]>()
        var complete = true
        repeat {
            let reply = try Self.checked(try await send("SCAN", cursor, "MATCH", pattern, "COUNT", "1000"))
            let parts = reply.elements
            guard parts.count == 2, let next = parts[0].string else {
                throw WireConnection.Failure.malformed("unexpected SCAN reply")
            }
            for key in parts[1].elements {
                if case .bulk(let bytes?) = key { seen.insert(bytes) }
            }
            cursor = next
            if seen.count >= Self.scanLimit {
                complete = cursor == "0"
                break
            }
        } while cursor != "0"
        let keys = seen.sorted { RedisFormatting.text($0).localizedStandardCompare(RedisFormatting.text($1)) == .orderedAscending }
        return KeyScan(database: database, pattern: pattern, keys: keys, complete: complete)
    }

    /// Type, TTL, size and a value preview for each key, read in two pipelines.
    private func describe(_ keys: [[UInt8]]) async throws -> [[CellValue]] {
        guard !keys.isEmpty else { return [] }
        let meta = try await send(keys.flatMap { key in
            [[Array("TYPE".utf8), key], [Array("TTL".utf8), key]]
        })
        let types = stride(from: 0, to: meta.count, by: 2).map { meta[$0].string ?? "none" }
        let ttls = stride(from: 1, to: meta.count, by: 2).map { meta[$0].integer }

        let n = String(Self.previewCount)
        let last = String(Self.previewCount - 1)
        var commands: [[[UInt8]]] = []
        for (key, type) in zip(keys, types) {
            func command(_ words: String...) -> [[UInt8]] {
                var arguments = [Array(words[0].utf8), key]
                arguments += words.dropFirst().map { Array($0.utf8) }
                return arguments
            }
            switch type {
            case "string": commands += [command("STRLEN"), command("GETRANGE", "0", "65535")]
            case "hash": commands += [command("HLEN"), command("HSCAN", "0", "COUNT", n)]
            case "list": commands += [command("LLEN"), command("LRANGE", "0", last)]
            case "set": commands += [command("SCARD"), command("SSCAN", "0", "COUNT", n)]
            case "zset": commands += [command("ZCARD"), command("ZRANGE", "0", last, "WITHSCORES")]
            case "stream": commands += [command("XLEN"), command("XRANGE", "-", "+", "COUNT", "20")]
            default: break
            }
        }
        let values = commands.isEmpty ? [] : try await send(commands)

        var rows: [[CellValue]] = []
        var next = 0
        for (index, key) in keys.enumerated() {
            let type = types[index]
            var size: CellValue = nil
            var value: CellValue = nil
            if ["string", "hash", "list", "set", "zset", "stream"].contains(type), next + 1 < values.count {
                size = values[next].integer.map { String($0) }
                value = Self.preview(values[next + 1], type: type)
                next += 2
            }
            let ttl: CellValue = switch ttls[index] {
            case let seconds? where seconds >= 0: String(seconds)
            default: nil
            }
            rows.append([RedisFormatting.text(key), type, ttl, size, value])
        }
        return rows
    }

    private static func preview(_ reply: RESPValue, type: String) -> CellValue {
        if case .error(let message) = reply { return "(\(message))" }
        switch type {
        case "string":
            return RedisFormatting.cell(reply)
        case "hash":
            return RedisFormatting.jsonPairs(reply.elements.count == 2 ? reply.elements[1].elements : [])
        case "set":
            return RedisFormatting.json(reply.elements.count == 2 ? reply.elements[1] : .array([]))
        case "zset":
            return RedisFormatting.jsonPairs(reply.elements)
        case "stream":
            let entries = reply.elements.map { entry -> String in
                let parts = entry.elements
                let id = RedisFormatting.jsonText(parts.first?.string ?? "")
                let fields = parts.count > 1 ? RedisFormatting.jsonPairs(parts[1].elements) : "{}"
                return "{\"id\": \(id), \"fields\": \(fields)}"
            }
            return "[" + entries.joined(separator: ", ") + "]"
        default:
            return RedisFormatting.json(reply)
        }
    }

    // MARK: Results

    /// Lays a reply out as a grid. Replies that are really pairs or scan pages get matching columns.
    static func result(for words: [String], reply: RESPValue, maxRows: Int) -> QueryResult {
        let name = words.first ?? ""
        func make(_ columns: [String], _ rows: [[CellValue]]) -> QueryResult {
            let limit = max(0, maxRows)
            return QueryResult(statement: "", columns: columns, rows: Array(rows.prefix(limit)), rowsAffected: nil,
                               duration: 0, truncated: rows.count > limit)
        }
        func pairs(_ items: [RESPValue]) -> [[CellValue]] {
            stride(from: 0, to: items.count - items.count % 2, by: 2).map {
                [RedisFormatting.cell(items[$0]), RedisFormatting.cell(items[$0 + 1])]
            }
        }

        switch reply {
        case .simple(let text) where text == "OK":
            return QueryResult(statement: "", columns: [], rows: [], rowsAffected: nil, duration: 0)
        case .bulk(let bytes?) where name == "INFO" || (name == "CLIENT" && words.dropFirst().first == "LIST"):
            let text = RedisFormatting.text(bytes)
            if name == "INFO" {
                return make(["section", "field", "value"], parseInfo(text).map { [$0.section, $0.key, $0.value] })
            }
            return make(["client"], text.split(whereSeparator: \.isNewline).map { [String($0)] })
        case .array(let items?):
            let withScores = words.contains("WITHSCORES")
            if ["SCAN", "SSCAN", "HSCAN", "ZSCAN"].contains(name), items.count == 2 {
                let cursor = items[0].string
                let elements = items[1].elements
                let columns: [String]
                var rows: [[CellValue]]
                switch name {
                case "HSCAN": columns = ["field", "value"]; rows = pairs(elements)
                case "ZSCAN": columns = ["member", "score"]; rows = pairs(elements)
                case "SSCAN": columns = ["member"]; rows = elements.map { [RedisFormatting.cell($0)] }
                default: columns = ["key"]; rows = elements.map { [RedisFormatting.cell($0)] }
                }
                // The cursor to continue from goes on every row, so it is there even when the page is empty.
                if rows.isEmpty { rows = [Array(repeating: nil, count: columns.count)] }
                return make(["next cursor"] + columns, rows.map { [cursor] + $0 })
            }
            if name == "HGETALL" || (name == "CONFIG" && words.dropFirst().first == "GET")
                || (name == "HRANDFIELD" && words.contains("WITHVALUES")) {
                return make(["field", "value"], pairs(items))
            }
            if name.hasPrefix("Z"), withScores {
                return make(["member", "score"], pairs(items))
            }
            return make(["value"], items.map { [RedisFormatting.cell($0)] })
        default:
            return make(["value"], [[RedisFormatting.cell(reply)]])
        }
    }
}

/// The database a Redis connection has selected, kept in step with the editor's commands. Inside MULTI a
/// command only answers QUEUED, so a queued SELECT (or FLUSHDB…) takes effect only once EXEC reports it ran;
/// DISCARD, a failed EXEC and a WATCH abort leave the selection as it was.
struct RedisSelection: Equatable, Sendable {
    var database: Int
    /// Commands queued since MULTI (upper-cased words), or nil outside a transaction.
    var queued: [[String]]?

    init(database: Int) {
        self.database = database
    }

    var isInTransaction: Bool { queued != nil }

    /// Follows `reply` to the command `words`. Returns true when the keys the connection sees may have
    /// changed (another database selected, or one flushed or swapped), so a cached key scan is stale.
    mutating func track(_ words: [String], reply: RESPValue) -> Bool {
        let name = words.first ?? ""
        if case .error = reply {
            // A failed EXEC (EXECABORT) and DISCARD both end the transaction; any other failed command isn't queued.
            if name == "EXEC" || name == "DISCARD" { queued = nil }
            return false
        }
        switch name {
        case "MULTI":
            queued = []
            return false
        case "DISCARD":
            queued = nil
            return false
        case "EXEC":
            let commands = queued ?? []
            queued = nil
            // A null reply means WATCH aborted the transaction: nothing ran.
            guard case .array(let results?) = reply else { return false }
            var changed = false
            for (command, result) in zip(commands, results) {
                if case .error = result { continue }
                if apply(command) { changed = true }
            }
            return changed
        default:
            if queued != nil {
                queued?.append(words)
                return false
            }
            return apply(words)
        }
    }

    /// Applies a command that ran. Returns true when the visible keys may have changed.
    private mutating func apply(_ words: [String]) -> Bool {
        switch words.first {
        case "SELECT":
            guard let index = words.dropFirst().first.flatMap({ Int($0) }) else { return false }
            database = index
            return true
        case "FLUSHDB", "FLUSHALL", "SWAPDB":
            return true
        default:
            return false
        }
    }
}
