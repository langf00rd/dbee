import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// Meilisearch over its HTTP API, on one keep-alive connection.
///
/// The query editor takes requests as Meilisearch's documentation writes them: a method and a path, then an
/// optional JSON body (`POST /indexes/movies/search { "q": "batman" }`). Requests that start a task (adding
/// documents, changing settings) wait for the task to finish, so the next request sees its result. The
/// sidebar lists indexes; the browser pages through documents and filters with Meilisearch's filter syntax.
///
/// Privacy: the API key stays in memory only, to reconnect; `close()` drops it.
final class MeilisearchDriver: CommandDriver, @unchecked Sendable {
    let kind: DatabaseKind = .meilisearch

    /// The sidebar's single section.
    static let schemaName = "Indexes"
    /// Documents read to infer an index's fields for the structure view.
    static let sampleSize = 100

    private struct State {
        var connection: WireConnection?
        /// After this the server may have closed the idle connection, so the next request opens a new one.
        var idleDeadline: NIODeadline?
        /// nil once closed. Empty when the server runs without a master key.
        var apiKey: String?
        var version = ""
        /// A query tab's request is running (including the wait for its task), so Stop has something to stop.
        var executing = false
        var cancelled = false
        var isClosed = false
        var primaryKeys: [String: String] = [:]
        /// The number of documents the browser's last page reported, for `count`.
        var lastTotal: (index: String, filter: String, total: Int)?
    }

    private let endpoint: WireConnection.Endpoint
    private let gate = PostgresStatementGate()
    private let state: NIOLockedValueBox<State>

    private init(endpoint: WireConnection.Endpoint, connection: WireConnection?, idleDeadline: NIODeadline?,
                 apiKey: String, version: String) {
        self.endpoint = endpoint
        state = NIOLockedValueBox(State(connection: connection, idleDeadline: idleDeadline, apiKey: apiKey, version: version))
    }

    // MARK: Connecting

    static func connect(config: ConnectionConfig, host: String, port: Int,
                        transport: DriverTransport = .direct) async throws -> MeilisearchDriver {
        let endpoint = WireConnection.Endpoint(config: config, dialHost: host, dialPort: port, transport: transport)
        let apiKey = config.password
        let (connection, (version, head)) = try await WireConnection.open(endpoint) { connection -> (String, HTTPWire.Head) in
            let deadline = NIODeadline.now() + WireConnection.connectTimeout
            let health = try await connection.exchange(request("GET", "/health", apiKey: ""), deadline: deadline)
            guard health.head.isSuccess, (try? JSONValue.parse(health.body))?["status"] != nil else {
                throw DatabaseError("\(endpoint.displayName) didn't answer like a Meilisearch server.",
                                    detail: "HTTP \(health.head.status) \(health.head.reason). Check the port number and the TLS setting.")
            }
            let version = try await connection.exchange(request("GET", "/version", apiKey: apiKey), deadline: deadline)
            if version.head.isSuccess {
                let number = (try? JSONValue.parse(version.body))?["pkgVersion"]?.string
                return (number.map { "Meilisearch " + $0 } ?? "Meilisearch", version.head)
            }
            if version.head.status == 401 {
                throw DatabaseError("Meilisearch needs an API key.", detail: Self.error(from: version).message)
            }
            // A key without the version action can still be fine for indexes and search.
            let indexes = try await connection.exchange(request("GET", "/indexes?limit=1", apiKey: apiKey), deadline: deadline)
            guard indexes.head.isSuccess else {
                throw DatabaseError("Meilisearch refused the API key.", detail: Self.error(from: indexes).message)
            }
            return ("Meilisearch", indexes.head)
        }
        let keep = head.keepsAlive
        if !keep { connection.close() }
        return MeilisearchDriver(endpoint: endpoint, connection: keep ? connection : nil,
                                 idleDeadline: .now() + head.idleLimit, apiKey: apiKey, version: version)
    }

    private static func request(_ method: String, _ target: String, body: [UInt8] = [], apiKey: String) -> HTTPWire.Request {
        var headers: [(name: String, value: String)] = [("Accept", "application/json")]
        if !apiKey.isEmpty { headers.append(("Authorization", "Bearer " + apiKey)) }
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) {
            headers.append(("Content-Type", "application/json"))
        }
        return HTTPWire.Request(method: method, target: target, headers: headers, body: body)
    }

    /// The error a non-2xx response describes.
    static func error(from response: HTTPWire.Response) -> DatabaseError {
        if let json = try? JSONValue.parse(response.body), let message = json["message"]?.string {
            return DatabaseError(message, detail: json["code"]?.string)
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DatabaseError("Meilisearch answered HTTP \(response.head.status) \(response.head.reason).",
                             detail: text.isEmpty ? nil : String(text.prefix(300)))
    }

    // MARK: Requests

    /// One request on the connection; the caller holds the gate.
    private func exchange(_ method: String, _ target: String, body: [UInt8] = []) async throws -> HTTPWire.Response {
        let connection = try await liveConnection()
        let request = state.withLockedValue { state -> HTTPWire.Request? in
            guard let apiKey = state.apiKey else { return nil }
            return Self.request(method, target, body: body, apiKey: apiKey)
        }
        guard let request else { throw DatabaseError("Not connected") }
        do {
            let response = try await connection.exchange(request)
            state.withLockedValue { state in
                if response.head.keepsAlive {
                    state.idleDeadline = .now() + response.head.idleLimit
                } else if state.connection === connection {
                    state.connection = nil
                }
            }
            if !response.head.keepsAlive { connection.close() }
            return response
        } catch {
            connection.close()
            state.withLockedValue { state in
                if state.connection === connection { state.connection = nil }
            }
            if state.withLockedValue({ $0.cancelled }) { throw WireConnection.Failure.cancelled }
            throw error
        }
    }

    /// `exchange`, failing for a non-2xx response.
    private func checked(_ method: String, _ target: String, body: [UInt8] = []) async throws -> JSONValue {
        let response = try await exchange(method, target, body: body)
        guard response.head.isSuccess else { throw Self.error(from: response) }
        return response.body.isEmpty ? .null : try JSONValue.parse(response.body)
    }

    private func liveConnection() async throws -> WireConnection {
        let (connection, idleDeadline, closed) = state.withLockedValue { ($0.connection, $0.idleDeadline, $0.isClosed) }
        guard !closed else { throw DatabaseError("Not connected") }
        if let connection {
            if connection.isOpen, idleDeadline.map({ NIODeadline.now() < $0 }) ?? true { return connection }
            connection.close()
        }
        let (fresh, _) = try await WireConnection.open(endpoint) { _ in () }
        let replaced = state.withLockedValue { state -> Bool in
            guard !state.isClosed else { return false }
            state.connection = fresh
            state.idleDeadline = nil
            return true
        }
        guard replaced else {
            fresh.close()
            throw DatabaseError("Not connected")
        }
        return fresh
    }

    private func checkCancelled() throws {
        if state.withLockedValue({ $0.cancelled }) { throw WireConnection.Failure.cancelled }
        try Task.checkCancellation()
    }

    /// Waits until task `uid` has finished and returns it; throws when it failed.
    private func waitForTask(_ uid: Int) async throws -> JSONValue {
        var delay = 25
        while true {
            try checkCancelled()
            let task = try await checked("GET", "/tasks/\(uid)")
            switch task["status"]?.string {
            case "succeeded":
                return task
            case "failed":
                let error = task["error"]
                throw DatabaseError(error?["message"]?.string ?? "The task failed.",
                                    detail: [error?["code"]?.string, "task \(uid)"].compactMap { $0 }.joined(separator: " · "))
            case "canceled":
                throw DatabaseError("Task \(uid) was canceled.")
            default:
                try await Task.sleep(for: .milliseconds(delay))
                delay = min(delay * 2, 1000)
            }
        }
    }

    private func primaryKey(of index: String) async throws -> String? {
        if let known = state.withLockedValue({ $0.primaryKeys[index] }) { return known }
        let info = try await checked("GET", "/indexes/" + HTTPWire.escape(index))
        guard let key = info["primaryKey"]?.string else { return nil }
        state.withLockedValue { $0.primaryKeys[index] = key }
        return key
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        state.withLockedValue { $0.version }
    }

    /// Meilisearch has no databases: an instance holds indexes.
    func listDatabases() async throws -> [String] { [] }

    func currentDatabase() async throws -> String { "" }

    func listSchemas() async throws -> [SchemaInfo] {
        await gate.acquire()
        defer { gate.release() }
        var names: [String] = []
        var keys: [String: String] = [:]
        var offset = 0
        while true {
            let page = try await checked("GET", "/indexes?offset=\(offset)&limit=1000")
            let results = page["results"]?.array ?? []
            for index in results {
                guard let uid = index["uid"]?.string else { continue }
                names.append(uid)
                if let key = index["primaryKey"]?.string { keys[uid] = key }
            }
            offset += results.count
            if results.isEmpty || offset >= (page["total"]?.int ?? 0) { break }
        }
        state.withLockedValue { $0.primaryKeys = keys }
        let tables = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { TableInfo(ref: TableRef(schema: nil, name: $0), kind: .searchIndex) }
        return [SchemaInfo(name: Self.schemaName, tables: tables)]
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        await gate.acquire()
        defer { gate.release() }
        let path = "/indexes/" + HTTPWire.escape(table.name)
        let primaryKey = try await primaryKey(of: table.name)
        let settings = try await checked("GET", path + "/settings")
        let stats = try? await checked("GET", path + "/stats")
        let sample = (try? await checked("GET", path + "/documents?limit=\(Self.sampleSize)"))?["results"]?.array ?? []

        let distribution = stats?["fieldDistribution"]?.object
        let total = stats?["numberOfDocuments"]?.int
        let columns = Self.inferColumns(sample, primaryKey: primaryKey, fieldDistribution: distribution,
                                        documents: total, settings: settings)
        return TableStructure(columns: columns, indexes: [], foreignKeys: [], ddl: settings.pretty)
    }

    /// Fields in the order documents list them, the primary key first, then fields only the index statistics
    /// know about. Types are the JSON types seen in `sample`.
    static func inferColumns(_ sample: [JSONValue], primaryKey: String?, fieldDistribution: JSONObject?,
                             documents: Int?, settings: JSONValue) -> [ColumnInfo] {
        var order: [String] = []
        var types: [String: [String]] = [:]
        for document in sample {
            for field in document.object?.fields ?? [] {
                if types[field.key] == nil {
                    order.append(field.key)
                    types[field.key] = []
                }
                let type = field.value.typeName
                if field.value != .null, types[field.key]?.contains(type) == false { types[field.key]?.append(type) }
            }
        }
        for field in fieldDistribution?.keys.sorted() ?? [] where types[field] == nil {
            order.append(field)
            types[field] = []
        }
        if let primaryKey {
            order.removeAll { $0 == primaryKey }
            order.insert(primaryKey, at: 0)
        }

        func attributes(_ name: String) -> [String] {
            settings[name]?.array?.compactMap(\.string) ?? []
        }
        let searchable = attributes("searchableAttributes")
        let filterable = attributes("filterableAttributes")
        let sortable = attributes("sortableAttributes")
        func covers(_ list: [String], _ field: String) -> Bool {
            list.contains("*") || list.contains(field) || list.contains { field.hasPrefix($0 + ".") }
        }

        return order.map { field in
            var notes: [String] = []
            if covers(searchable, field) { notes.append("searchable") }
            if covers(filterable, field) { notes.append("filterable") }
            if covers(sortable, field) { notes.append("sortable") }
            if let count = fieldDistribution?[field]?.int, let documents, count < documents {
                notes.append("in \(count.formatted()) of \(documents.formatted()) documents")
            }
            let text = notes.joined(separator: ", ")
            let comment = text.isEmpty ? nil : text.prefix(1).uppercased() + text.dropFirst()
            let seen = types[field] ?? []
            return ColumnInfo(name: field, dataType: seen.isEmpty ? "unknown" : seen.joined(separator: " | "),
                              isNullable: field != primaryKey, defaultValue: nil, isPrimaryKey: field == primaryKey,
                              comment: comment)
        }
    }

    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        let start = Date()
        let request = try MeilisearchRequest.parse(sql)
        await gate.acquire()
        defer { gate.release() }
        state.withLockedValue {
            $0.executing = true
            $0.cancelled = false
        }
        defer { state.withLockedValue { $0.executing = false } }
        let response = try await exchange(request.method, request.target, body: Array((request.body ?? "").utf8))
        guard response.head.isSuccess else { throw Self.error(from: response) }

        var result: QueryResult
        if response.body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D }) {
            result = QueryResult(statement: sql, columns: [], rows: [], rowsAffected: nil, duration: 0)
        } else {
            var json = try JSONValue.parse(response.body)
            if response.head.status == 202, let uid = json["taskUid"]?.int {
                json = try await waitForTask(uid)
                if let index = json["indexUid"]?.string {
                    // Settings and index changes can change the primary key.
                    state.withLockedValue { $0.primaryKeys[index] = nil }
                }
            }
            result = Self.grid(json, maxRows: maxRows)
        }
        result.statement = sql
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    func cancelCurrentQuery() async {
        // HTTP has no way to stop a request, so close the connection; a task the request started keeps running
        // on the server.
        let connection = state.withLockedValue { state -> WireConnection? in
            guard state.executing else { return nil }
            state.cancelled = true
            defer { state.connection = nil }
            return state.connection
        }
        connection?.abort()
    }

    func close() async {
        let connection = state.withLockedValue { state -> WireConnection? in
            state.isClosed = true
            state.apiKey = nil
            defer { state.connection = nil }
            return state.connection
        }
        await connection?.closeAndWait()
    }

    // MARK: CommandDriver

    func useDatabase(_ name: String) async throws {}

    func page(of table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) async throws -> QueryResult {
        let start = Date()
        await gate.acquire()
        defer { gate.release() }
        let filterText = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = "/indexes/" + HTTPWire.escape(table.name) + "/documents"
        let primaryKey = try await primaryKey(of: table.name)
        let body = Self.fetchBody(filter: filterText, limit: limit, offset: offset)
        var response = try await exchange("POST", path + "/fetch", body: Array(body.utf8))
        if response.head.status == 404 || response.head.status == 405, filterText.isEmpty,
           (try? JSONValue.parse(response.body))?["code"]?.string != "index_not_found" {
            // Meilisearch before 1.2 only lists documents with GET, without filters.
            response = try await exchange("GET", path + "?offset=\(max(0, offset))&limit=\(max(1, limit))")
        }
        guard response.head.isSuccess else { throw Self.error(from: response) }
        let json = try JSONValue.parse(response.body)
        if let total = json["total"]?.int {
            state.withLockedValue { $0.lastTotal = (table.name, filterText, total) }
        }
        let documents = json["results"]?.array ?? []
        var result = Self.documentGrid(documents, maxRows: limit, primaryKey: primaryKey)
        if documents.isEmpty { result.columns = [] }
        if let sort, let index = sort.index(in: result.columns) {
            // Meilisearch lists documents in storage order; sorting applies to the page that was read.
            result.rows.sort { lhs, rhs in
                sort.ascending ? Self.precedes(lhs[index], rhs[index]) : Self.precedes(rhs[index], lhs[index])
            }
        }
        result.statement = "POST " + path + "/fetch\n" + body
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    func count(of table: TableRef, filter: String?) async throws -> Int? {
        let filterText = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let last = state.withLockedValue({ $0.lastTotal }), last.index == table.name, last.filter == filterText {
            return last.total
        }
        await gate.acquire()
        defer { gate.release() }
        if filterText.isEmpty {
            return try await checked("GET", "/indexes/" + HTTPWire.escape(table.name) + "/stats")["numberOfDocuments"]?.int
        }
        let body = Self.fetchBody(filter: filterText, limit: 0, offset: 0)
        return try await checked("POST", "/indexes/" + HTTPWire.escape(table.name) + "/documents/fetch",
                                 body: Array(body.utf8))["total"]?.int
    }

    /// The body of a documents/fetch request.
    static func fetchBody(filter: String, limit: Int, offset: Int) -> String {
        var fields = [JSONObject.Field(key: "offset", value: .number(String(max(0, offset)))),
                      JSONObject.Field(key: "limit", value: .number(String(max(0, limit))))]
        if !filter.isEmpty { fields.append(JSONObject.Field(key: "filter", value: .string(filter))) }
        return JSONValue.object(JSONObject(fields: fields)).json
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

    // MARK: Results

    /// Lays a response out as a grid: the hits of a search, the results of a list, an array's items, or else an
    /// object's fields as rows.
    static func grid(_ json: JSONValue, maxRows: Int) -> QueryResult {
        switch json {
        case .object(let object):
            if let hits = object["hits"]?.array { return documentGrid(hits, maxRows: maxRows) }
            if let results = object["results"]?.array { return documentGrid(results, maxRows: maxRows) }
            let rows = object.fields.map { [$0.key, $0.value.cell] as [CellValue] }
            return table(["field", "value"], rows, maxRows: maxRows)
        case .array(let items):
            return documentGrid(items, maxRows: maxRows)
        default:
            return table(["value"], [[json.cell]], maxRows: maxRows)
        }
    }

    /// One row per document and one column per top-level field, the primary key first.
    static func documentGrid(_ documents: [JSONValue], maxRows: Int, primaryKey: String? = nil) -> QueryResult {
        guard documents.allSatisfy({ $0.object != nil }) else {
            return table(["value"], documents.map { [$0.cell] }, maxRows: maxRows)
        }
        var columns: [String] = []
        var position: [String: Int] = [:]
        for document in documents {
            for key in document.object?.keys ?? [] where position[key] == nil {
                position[key] = columns.count
                columns.append(key)
            }
        }
        if let primaryKey, let index = columns.firstIndex(of: primaryKey), index != 0 {
            columns.insert(columns.remove(at: index), at: 0)
            position = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })
        }
        let rows = documents.prefix(max(0, maxRows)).map { document -> [CellValue] in
            var row = [CellValue](repeating: nil, count: columns.count)
            for field in document.object?.fields ?? [] {
                if let index = position[field.key] { row[index] = field.value.cell }
            }
            return row
        }
        // No documents still reads as a row set, so the grid says "No rows" rather than "Executed".
        return QueryResult(statement: "", columns: columns.isEmpty ? [primaryKey ?? "id"] : columns, rows: rows,
                           rowsAffected: nil, duration: 0, truncated: documents.count > max(0, maxRows))
    }

    private static func table(_ columns: [String], _ rows: [[CellValue]], maxRows: Int) -> QueryResult {
        let limit = max(0, maxRows)
        return QueryResult(statement: "", columns: columns, rows: Array(rows.prefix(limit)), rowsAffected: nil,
                           duration: 0, truncated: rows.count > limit)
    }
}

/// A request typed in the query editor: `METHOD /path` and an optional JSON body.
struct MeilisearchRequest: Equatable, Sendable {
    var method: String
    /// The path and query, percent-encoded.
    var target: String
    var body: String?

    static func parse(_ text: String) throws -> MeilisearchRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let methodEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        let method = trimmed[..<methodEnd].uppercased()
        guard CommandScript.httpMethods.contains(method) else {
            throw DatabaseError("Start a request with GET, POST, PUT, PATCH or DELETE and a path.",
                                detail: "For example: GET /indexes, or POST /indexes/movies/search { \"q\": \"batman\" }")
        }
        var rest = trimmed[methodEnd...].drop { $0 == " " || $0 == "\t" }
        let pathEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        var path = String(rest[..<pathEnd])
        guard !path.isEmpty else {
            throw DatabaseError("Add a path after \(method).", detail: "For example: \(method) /indexes")
        }
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            // A URL copied from the docs: keep its path, the connection decides the server.
            if let components = URLComponents(string: path) {
                path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            }
        }
        if !path.hasPrefix("/") { path = "/" + path }
        rest = rest[pathEnd...]
        let body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            do {
                _ = try JSONValue.parse(body)
            } catch {
                throw DatabaseError("The request body isn't valid JSON.", detail: error.localizedDescription)
            }
        }
        return MeilisearchRequest(method: method, target: encodePath(path), body: body.isEmpty ? nil : body)
    }

    /// Percent-encodes what can't appear in a request target (spaces, non-ASCII), keeping existing escapes.
    static func encodePath(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            if scalar.isASCII, allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            }
        }
        return out
    }

    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/?&=:@!$'()*+,;%[]")
}
