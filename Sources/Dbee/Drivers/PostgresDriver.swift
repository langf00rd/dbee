import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

/// PostgreSQL over one PostgresNIO connection.
///
/// Values come back in Postgres' own text format (what psql prints) and `maxRows` is enforced by the server
/// where that can't change what a statement does; see `PostgresWireAdapter`. Statements are serialized with a
/// FIFO gate. Cancelling uses the protocol's CancelRequest, which needs no password, so the password is only
/// used to sign in and isn't kept.
final class PostgresDriver: DatabaseDriver, @unchecked Sendable {
    let kind: DatabaseKind = .postgres

    /// Where and as whom to connect. Never persisted or logged.
    private struct Endpoint: Sendable {
        var dialHost: String
        var dialPort: Int
        /// The server's real name (differs from `dialHost` when tunnelled); used for SNI and certificate checks.
        var logicalHost: String
        var displayPort: Int
        var username: String
        var password: String?
        var database: String
        var tls: TLSMode
        var transport: DriverTransport = .direct

        init(config: ConnectionConfig, dialHost: String, dialPort: Int) {
            self.dialHost = dialHost
            self.dialPort = dialPort
            logicalHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
            displayPort = config.port
            let user = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
            username = user.isEmpty ? "postgres" : user
            password = config.password.isEmpty ? nil : config.password
            let database = config.database.trimmingCharacters(in: .whitespacesAndNewlines)
            self.database = database.isEmpty ? username : database
            tls = config.tls
        }

        var displayHost: String { logicalHost.isEmpty ? dialHost : logicalHost }
    }

    private struct State: Sendable {
        var endpoint: Endpoint?
        /// From the server's BackendKeyData; nil when it sent none (some poolers), which disables cancelling.
        var backendKey: PostgresBackendKey?
        /// Whether the session negotiated TLS, so the cancel connection does too.
        var usesTLS = false
        var versionNumber = 0
        var versionString = ""
        /// Cancel handle of the statement holding the gate, if any.
        var running: StatementCancelSignal?
        var closed = false
    }

    private static let logger = Logger(label: "app.dbee.postgres") { _ in SwiftLogNoOpLogHandler() }
    private static let connectTimeout = TimeAmount.seconds(15)
    private static let connectionIDs = NIOLockedValueBox(0)

    private let connection: PostgresConnection
    private let probe: PostgresWireProbe
    private let gate = PostgresStatementGate()
    private let state: NIOLockedValueBox<State>

    private init(connection: PostgresConnection, probe: PostgresWireProbe, endpoint: Endpoint,
                 backendKey: PostgresBackendKey?, usesTLS: Bool) {
        self.connection = connection
        self.probe = probe
        state = NIOLockedValueBox(State(endpoint: endpoint, backendKey: backendKey, usesTLS: usesTLS))
    }

    deinit {
        let connection = connection
        if !connection.isClosed {
            // Keep the connection alive until it has closed (PostgresNIO asserts on dropping an open one).
            connection.close().whenComplete { _ in _ = connection }
        }
    }

    // MARK: Connecting

    static func connect(config: ConnectionConfig, host: String, port: Int,
                        transport: DriverTransport = .direct) async throws -> PostgresDriver {
        var endpoint = Endpoint(config: config, dialHost: host, dialPort: port)
        endpoint.transport = transport
        let probe = PostgresWireProbe()
        let (connection, backendKey, usesTLS) = try await open(endpoint, probe: probe)
        var stored = endpoint
        stored.password = nil
        let driver = PostgresDriver(connection: connection, probe: probe, endpoint: stored,
                                    backendKey: backendKey, usesTLS: usesTLS)
        do {
            try await driver.loadSessionInfo()
        } catch {
            await driver.close()
            throw error
        }
        return driver
    }

    /// Dials, negotiates TLS, authenticates and installs the wire adapter. Also returns the BackendKeyData
    /// and whether TLS is in use.
    private static func open(_ endpoint: Endpoint, probe: PostgresWireProbe) async throws
        -> (PostgresConnection, PostgresBackendKey?, Bool) {
        let started = NIODeadline.now()
        let tls: PostgresConnection.Configuration.TLS
        let serverName: String?
        do {
            (tls, serverName) = try tlsSettings(for: endpoint)
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError("Couldn't set up TLS.", detail: String(describing: error))
        }

        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
        let channel: any Channel
        do {
            channel = try await dial(endpoint, bootstrap: bootstrap)
        } catch {
            throw translate(error, endpoint: endpoint)
        }

        var configuration = PostgresConnection.Configuration(
            establishedChannel: channel,
            tls: tls,
            username: endpoint.username,
            password: endpoint.password,
            database: endpoint.database
        )
        // PostgresNIO applies this to the startup/authentication phase of an established channel.
        configuration.options.connectTimeout = max(connectTimeout - (NIODeadline.now() - started), .seconds(1))
        configuration.options.tlsServerName = serverName
        // Some poolers omit BackendKeyData; such sessions work, they just can't cancel statements.
        configuration.options.requireBackendKeyData = false

        // PostgresNIO doesn't expose BackendKeyData, so read it off the wire during startup.
        let backendKey = NIOLockedValueBox<PostgresBackendKey?>(nil)
        do {
            try await channel.eventLoop.submit {
                let capture = PostgresBackendKeyCapture(key: backendKey, awaitingSSLAnswer: endpoint.tls != .disabled)
                try channel.pipeline.syncOperations.addHandlerFacingBytes(capture)
            }.get()
        } catch {
            channel.close(promise: nil)
            throw DatabaseError("Couldn't prepare the connection.", detail: String(describing: error))
        }
        configuration.options.additionalStartupParameters = [
            ("application_name", "Dbee"),
            ("client_encoding", "UTF8"),
        ]

        let connection: PostgresConnection
        do {
            let id = connectionIDs.withLockedValue { value in
                value += 1
                return value
            }
            connection = try await PostgresConnection.connect(on: channel.eventLoop, configuration: configuration, id: id, logger: logger)
        } catch {
            channel.close(promise: nil)
            if let error = error as? PSQLError, [.messageDecodingFailure, .unexpectedBackendMessage].contains(error.code) {
                throw DatabaseError(
                    "\(endpoint.displayHost):\(endpoint.displayPort) doesn't appear to be a PostgreSQL server.",
                    detail: "Check the port number."
                )
            }
            throw translate(error, endpoint: endpoint)
        }

        let usesTLS: Bool
        do {
            usesTLS = try await channel.eventLoop.submit {
                let pipeline = channel.pipeline.syncOperations
                let adapter = PostgresWireAdapter(probe: probe)
                if let tlsHandler = try? pipeline.handler(type: NIOSSLClientHandler.self) {
                    try pipeline.addHandler(adapter, position: .after(tlsHandler))
                    return true
                }
                try pipeline.addHandlerFacingBytes(adapter)
                return false
            }.get()
        } catch {
            try? await connection.close()
            throw DatabaseError("Couldn't prepare the connection.", detail: String(describing: error))
        }
        return (connection, backendKey.withLockedValue { $0 }, usesTLS)
    }

    /// A TCP connection to the dial address, or the transport's own channel (an SSH direct-tcpip channel
    /// when tunnelled, so the tunnel's local listener isn't used at all).
    private static func dial(_ endpoint: Endpoint, bootstrap: ClientBootstrap) async throws -> any Channel {
        if let openChannel = endpoint.transport.openChannel { return try await openChannel() }
        endpoint.transport.willDial()
        return try await bootstrap.connect(host: endpoint.dialHost, port: endpoint.dialPort).get()
    }

    /// Maps the TLS mode to PostgresNIO settings plus the SNI / verification name.
    private static func tlsSettings(for endpoint: Endpoint) throws -> (PostgresConnection.Configuration.TLS, String?) {
        let (context, serverName) = try tlsContext(for: endpoint)
        guard let context else { return (.disable, nil) }
        return (endpoint.tls == .preferred ? .prefer(context) : .require(context), serverName)
    }

    /// The TLS context for the endpoint's mode (nil when TLS is off), plus the SNI / verification name.
    private static func tlsContext(for endpoint: Endpoint) throws -> (NIOSSLContext?, String?) {
        let host = endpoint.logicalHost
        // SNI can't carry IP literals; NIOSSL then verifies the certificate against the dialled address.
        let serverName = host.isEmpty || isIPAddress(host) ? nil : host

        func context(_ verification: CertificateVerification) throws -> NIOSSLContext {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = verification
            return try NIOSSLContext(configuration: configuration)
        }

        switch endpoint.tls {
        case .disabled:
            return (nil, nil)
        case .preferred, .required:
            return (try context(CertificateVerification.none), serverName)
        case .verifyFull:
            // An IP literal is matched against the dialled address, which is the tunnel's local end when
            // tunnelled. Fail rather than quietly skip the name check.
            if serverName == nil, !host.isEmpty, host != endpoint.dialHost {
                throw verifyNeedsHostName
            }
            return (try context(.fullVerification), serverName)
        }
    }

    static let verifyNeedsHostName = DatabaseError(
        "Verify Certificate needs the server's host name when connecting through an SSH tunnel.",
        detail: "Enter the database server's DNS name, or set TLS to Required to encrypt without verifying the certificate."
    )

    private static func isIPAddress(_ host: String) -> Bool {
        (try? SocketAddress(ipAddress: host, port: 0)) != nil
    }

    private func loadSessionInfo() async throws {
        let rows = try await fetch("SELECT current_setting('server_version_num'), current_setting('server_version')").rows
        guard let row = rows.first, row.count == 2 else { return }
        state.withLockedValue { state in
            state.versionNumber = row[0].flatMap { Int($0) } ?? 0
            state.versionString = row[1] ?? ""
        }
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        let version = state.withLockedValue { $0.versionString }
        // "16.4 (Debian 16.4-1.pgdg120+2)" -> "PostgreSQL 16.4"
        let short = version.split(separator: " ").first.map(String.init) ?? ""
        return short.isEmpty ? "PostgreSQL" : "PostgreSQL \(short)"
    }

    func listDatabases() async throws -> [String] {
        try await fetch("""
            SELECT datname FROM pg_catalog.pg_database
            WHERE NOT datistemplate AND datallowconn AND has_database_privilege(oid, 'CONNECT')
            ORDER BY datname
            """).rows.compactMap { $0.first ?? nil }
    }

    func currentDatabase() async throws -> String {
        try await fetch("SELECT current_database()").rows.first?.first.flatMap { $0 } ?? ""
    }

    func listSchemas() async throws -> [SchemaInfo] {
        // "pg_" is reserved for system schemas, which covers pg_catalog, pg_toast* and pg_temp*.
        let rows = try await fetch("""
            SELECT n.nspname, c.relname, c.relkind::text
            FROM pg_catalog.pg_namespace n
            LEFT JOIN pg_catalog.pg_class c
              ON c.relnamespace = n.oid AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
            WHERE n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'pg\\_%'
            """).rows

        var tablesBySchema: [String: [TableInfo]] = [:]
        for row in rows {
            guard row.count == 3, let schema = row[0] else { continue }
            var tables = tablesBySchema[schema] ?? []
            if let name = row[1] {
                let kind: TableKind = switch row[2] {
                case "v": .view
                case "m": .materializedView
                default: .table
                }
                tables.append(TableInfo(ref: TableRef(schema: schema, name: name), kind: kind))
            }
            tablesBySchema[schema] = tables
        }
        return tablesBySchema
            .map { name, tables in
                SchemaInfo(name: name, tables: tables.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending })
            }
            .sorted { a, b in
                if (a.name == "public") != (b.name == "public") { return a.name == "public" }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        let version = state.withLockedValue { $0.versionNumber }
        let relation = try await relationInfo(table, version: version)
        let columns = try await columnInfo(relation.oid, version: version)
        let indexes = try await indexInfo(relation.oid, version: version)
        let foreignKeys = try await foreignKeyInfo(relation.oid)
        let ddl = try? await makeDDL(relation, columns: columns, indexes: indexes)
        return TableStructure(
            columns: columns.map(\.info),
            indexes: indexes.map(\.info),
            foreignKeys: foreignKeys,
            ddl: ddl
        )
    }

    /// Two catalog queries for the whole schema instead of several per table. Partitions are left out:
    /// they repeat their parent's columns, and the foreign keys cloned onto them (conparentid <> 0) with it.
    func diagramTables(in schema: SchemaInfo) async throws -> [DiagramTable] {
        let version = state.withLockedValue { $0.versionNumber }
        let notPartition = version >= 100_000 ? "AND NOT c.relispartition" : ""
        let topLevelConstraint = version >= 110_000 ? "AND con.conparentid = 0" : ""
        let columnRows = try await fetch("""
            SELECT c.relname, a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
                   EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                            WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey))
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
            WHERE n.nspname = $1::text AND c.relkind IN ('r', 'p', 'f') \(notPartition)
            ORDER BY c.relname, a.attnum
            """, [schema.name]).rows
        let foreignKeyRows = try await fetch("""
            SELECT c.relname, con.conname,
                   (SELECT json_agg(a.attname ORDER BY k.ord)
                      FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum),
                   fn.nspname, fc.relname,
                   (SELECT json_agg(a.attname ORDER BY k.ord)
                      FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum),
                   con.confupdtype::text, con.confdeltype::text
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_class fc ON fc.oid = con.confrelid
            JOIN pg_catalog.pg_namespace fn ON fn.oid = fc.relnamespace
            WHERE n.nspname = $1::text AND con.contype = 'f' \(notPartition) \(topLevelConstraint)
            ORDER BY c.relname, con.conname
            """, [schema.name]).rows

        var order: [String] = []
        var columns: [String: [ColumnInfo]] = [:]
        for row in columnRows {
            guard row.count == 5, let table = row[0], let name = row[1] else { continue }
            if columns[table] == nil { order.append(table) }
            columns[table, default: []].append(ColumnInfo(
                name: name, dataType: row[2] ?? "", isNullable: row[3] != "t",
                defaultValue: nil, isPrimaryKey: row[4] == "t", comment: nil
            ))
        }
        var foreignKeys: [String: [ForeignKeyInfo]] = [:]
        for row in foreignKeyRows {
            guard row.count == 8, let table = row[0], let name = row[1], let target = row[4] else { continue }
            foreignKeys[table, default: []].append(ForeignKeyInfo(
                name: name,
                columns: Self.jsonStrings(row[2]),
                referencedTable: TableRef(schema: row[3], name: target),
                referencedColumns: Self.jsonStrings(row[5]),
                onUpdate: Self.referentialAction(row[6]),
                onDelete: Self.referentialAction(row[7])
            ))
        }
        return order.map { table in
            DiagramTable(ref: TableRef(schema: schema.name, name: table),
                         columns: columns[table] ?? [], foreignKeys: foreignKeys[table] ?? [])
        }
    }

    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        // A portal stopped at the row limit never processes the remaining rows, so a locking clause would
        // lock only the rows fetched. Such statements run to completion and are truncated client-side.
        let limitOnServer = !StatementTraits.hasLockingClause(sql, kind: .postgres)
        let raw = try await run(PostgresQuery(unsafeSQL: sql), maxRows: maxRows, limitOnServer: limitOnServer)
        var columns = raw.columns
        var rows = raw.rows
        var truncated = raw.truncated
        if raw.outcome.copyBinary {
            throw DatabaseError("Binary COPY output isn't supported.", detail: "Use FORMAT text or FORMAT csv.")
        }
        if let lines = raw.outcome.copyLines {
            columns = ["COPY"]
            rows = lines.map { [$0] }
            truncated = raw.outcome.copyTruncated
        }
        let affected = raw.outcome.commandTag.flatMap(Self.rowCount(fromCommandTag:))
        return QueryResult(
            statement: sql,
            columns: columns,
            rows: rows,
            rowsAffected: truncated ? nil : affected,
            duration: raw.duration,
            truncated: truncated
        )
    }

    /// From the latest ReadyForQuery status byte: 'T' (in a transaction) or 'E' (failed transaction).
    var isInTransaction: Bool? {
        get async { state.withLockedValue { $0.closed } ? nil : probe.isInTransactionBlock }
    }

    func cancelCurrentQuery() async {
        guard let signal = state.withLockedValue({ $0.closed ? nil : $0.running }) else { return }
        signal.fire { [weak self] in await self?.sendCancelRequest() }
        await signal.settled()
    }

    /// Sends a CancelRequest with the session's BackendKeyData on a new connection, the way libpq does.
    /// Only called while a statement holds the gate, which it keeps until the request has been sent and the
    /// connection has drained, so the request can't reach a later statement.
    private func sendCancelRequest() async {
        let target = state.withLockedValue { state -> (Endpoint, PostgresBackendKey, Bool)? in
            guard !state.closed, let endpoint = state.endpoint, let key = state.backendKey else { return nil }
            return (endpoint, key, state.usesTLS)
        }
        guard let (endpoint, key, usesTLS) = target else { return }
        // Best effort: if this fails, the statement simply keeps running.
        try? await Self.sendCancelRequest(key, endpoint: endpoint, usesTLS: usesTLS)
    }

    private static func sendCancelRequest(_ key: PostgresBackendKey, endpoint: Endpoint, usesTLS: Bool) async throws {
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(8))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        let channel = try await dial(endpoint, bootstrap: bootstrap)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(8)) { channel.close(promise: nil) }
        defer {
            timeout.cancel()
            channel.close(promise: nil)
        }
        if usesTLS {
            // SSLRequest: length 8, code 80877103. The server answers with a single byte.
            let answer = channel.eventLoop.makePromise(of: UInt8.self)
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(PostgresSSLAnswerReader(answer: answer))
            }.get()
            var request = ByteBuffer()
            request.writeInteger(Int32(8))
            request.writeInteger(Int32(80877103))
            try await channel.writeAndFlush(request).get()
            if try await answer.futureResult.get() == UInt8(ascii: "S") {
                let (tlsContext, serverName) = try tlsContext(for: endpoint)
                guard let context = tlsContext else { return }
                try await channel.eventLoop.submit {
                    let handler = try NIOSSLClientHandler(context: context, serverHostname: serverName)
                    try channel.pipeline.syncOperations.addHandlerFacingBytes(handler)
                }.get()
            } else if endpoint.tls != .preferred {
                return
            }
        }
        // CancelRequest: length 16, code 80877102, process id, secret.
        var request = ByteBuffer()
        request.writeInteger(Int32(16))
        request.writeInteger(Int32(80877102))
        request.writeInteger(key.processID)
        request.writeInteger(key.secret)
        try await channel.writeAndFlush(request).get()
        // The server closes the connection once it has handled the request.
        try? await channel.closeFuture.get()
    }

    func close() async {
        let alreadyClosed = state.withLockedValue { state in
            let wasClosed = state.closed
            state.closed = true
            state.endpoint = nil
            return wasClosed
        }
        guard !alreadyClosed else { return }
        try? await connection.close()
    }

    /// True after `close()`, or when the server or network dropped the connection.
    var isClosed: Bool {
        state.withLockedValue { $0.closed } || connection.isClosed
    }

    // MARK: Running statements

    private struct RawResult {
        var columns: [String]
        var rows: [[CellValue]]
        var truncated: Bool
        var outcome: PostgresWireProbe.Outcome
        var duration: TimeInterval
    }

    /// Runs one statement under the gate. `maxRows <= 0` reads everything. With `limitOnServer`, the server
    /// stops after `maxRows + 1` rows, unless a transaction block is open (see `execute`).
    private func run(_ query: PostgresQuery, maxRows: Int = 0, limitOnServer: Bool = true) async throws -> RawResult {
        await gate.acquire()
        let signal = StatementCancelSignal()
        let isOpen = state.withLockedValue { state -> Bool in
            if !state.closed { state.running = signal }
            return !state.closed
        }
        guard isOpen else {
            gate.release()
            throw DatabaseError("The connection is closed.")
        }
        // Cancelled while waiting for the gate: don't start it at all.
        if Task.isCancelled {
            finishStatement(signal)
            throw CancellationError()
        }
        do {
            let result = try await perform(query, maxRows: maxRows, limitOnServer: limitOnServer, signal: signal)
            finishStatement(signal)
            return result
        } catch {
            finishStatement(signal)
            throw error
        }
    }

    /// Releases the gate, after the cancel (if one was sent) has landed and the connection has drained.
    /// When the task is cancelled PostgresNIO stops delivering rows at once, but the statement keeps running on
    /// the server until the cancel reaches it, and the connection is busy until then. That wait happens here
    /// in the background, still holding the gate, so the caller returns right away.
    private func finishStatement(_ signal: StatementCancelSignal) {
        if signal.sealIfIdle() {
            endStatement(signal)
            return
        }
        Task { [self] in
            await signal.settled()
            // A round trip after the cancelled statement: done once it has completed, and it absorbs a cancel
            // that arrived only after the statement finished by itself.
            probe.begin(rowLimit: 0)
            if !connection.isClosed {
                _ = try? await connection.query("SELECT 1", logger: Self.logger).collect()
            }
            _ = probe.finish()
            endStatement(signal)
        }
    }

    private func endStatement(_ signal: StatementCancelSignal) {
        state.withLockedValue { state in
            if state.running === signal { state.running = nil }
        }
        gate.release()
    }

    private func perform(_ query: PostgresQuery, maxRows: Int, limitOnServer: Bool,
                         signal: StatementCancelSignal) async throws -> RawResult {
        let keep = maxRows > 0 ? maxRows : Int.max
        // Ask for one row more than we keep, to know whether the result was cut off. Inside a transaction
        // block a partly run statement could leave work undone (e.g. functions with side effects), so the
        // server runs everything and the extra rows are dropped here.
        let serverLimit = limitOnServer && !probe.isInTransactionBlock
        let limit: Int32 = serverLimit && maxRows > 0 && maxRows < Int(Int32.max) ? Int32(maxRows + 1) : 0
        probe.begin(rowLimit: limit, copyLineLimit: keep)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (columns, rows, truncated) = try await withTaskCancellationHandler {
                // PostgresNIO never answers a query sent on a connection that has already closed (for example
                // after the SSH tunnel dropped while idle), so fail it here instead of waiting forever.
                guard !connection.isClosed else {
                    throw DatabaseError("The connection to the server was lost.", detail: "Reconnect to continue.")
                }
                let sequence = try await connection.query(query, logger: Self.logger)
                let columns = sequence.columns.map(\.name)
                var rows: [[CellValue]] = []
                var truncated = false
                for try await row in sequence {
                    // Keep draining (without storing) so the connection stays in sync.
                    guard rows.count < keep else {
                        truncated = true
                        continue
                    }
                    var values: [CellValue] = []
                    values.reserveCapacity(columns.count)
                    for cell in row {
                        values.append(cell.bytes.map { String(buffer: $0) })
                    }
                    rows.append(values)
                }
                return (columns, rows, truncated)
            } onCancel: {
                signal.fire { [weak self] in await self?.sendCancelRequest() }
            }
            let outcome = probe.finish()
            if outcome.framingProblem {
                throw DatabaseError("Dbee couldn't read this result.", detail: "Unexpected message layout from the PostgreSQL client library.")
            }
            let elapsed = clock.now - start
            let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return RawResult(columns: columns, rows: rows, truncated: truncated, outcome: outcome, duration: duration)
        } catch {
            _ = probe.finish()
            throw Self.translate(error, endpoint: state.withLockedValue { $0.endpoint })
        }
    }

    /// Runs a catalog query with text parameters ($1, $2…); nil binds NULL.
    private func fetch(_ sql: String, _ binds: [String?] = []) async throws -> RawResult {
        var bindings = PostgresBindings(capacity: binds.count)
        for value in binds {
            if let value { bindings.append(value) } else { bindings.appendNull() }
        }
        return try await run(PostgresQuery(unsafeSQL: sql, binds: bindings))
    }

    /// Row count from a command tag: "INSERT 0 5" -> 5, "UPDATE 3" -> 3, "CREATE TABLE" -> nil.
    static func rowCount(fromCommandTag tag: String) -> Int? {
        let parts = tag.split(separator: " ")
        guard parts.count >= 2, let first = parts.first, let count = parts.last.flatMap({ Int($0) }) else { return nil }
        switch first {
        case "INSERT", "UPDATE", "DELETE", "SELECT", "MERGE", "COPY", "MOVE", "FETCH":
            return count
        default:
            return nil
        }
    }

    // MARK: Errors

    private static func translate(_ error: any Error, endpoint: Endpoint?) -> any Error {
        if error is DatabaseError || error is CancellationError { return error }
        let place = endpoint.map { "\($0.displayHost):\($0.displayPort)" } ?? "the server"

        if let error = error as? PSQLError {
            switch error.code {
            case .server:
                return serverError(error.serverInfo)
            case .sslUnsupported:
                return DatabaseError(
                    "The server doesn't support TLS.",
                    detail: "Set TLS to Preferred, or to Off when connecting through an SSH tunnel."
                )
            case .connectionError, .failedToAddSSLHandler:
                if let underlying = error.underlying { return translate(underlying, endpoint: endpoint) }
                return DatabaseError("Couldn't connect to \(place).")
            case .serverClosedConnection:
                if let underlying = error.underlying, !(underlying is ChannelError) {
                    return translate(underlying, endpoint: endpoint)
                }
                return DatabaseError("The server closed the connection.")
            case .clientClosedConnection:
                return DatabaseError("The connection is closed.")
            case .uncleanShutdown:
                return DatabaseError("The connection was closed unexpectedly.")
            case .unsupportedAuthMechanism:
                return DatabaseError(
                    "The server asked for an authentication method Dbee doesn't support.",
                    detail: "Supported methods are SCRAM-SHA-256, MD5 and password."
                )
            case .authMechanismRequiresPassword:
                return DatabaseError("The server requires a password.")
            case .saslError:
                return DatabaseError("SCRAM authentication failed.")
            case .queryCancelled:
                return DatabaseError("The query was cancelled.")
            case .tooManyParameters:
                return DatabaseError("The statement has too many parameters.")
            case .receivedUnencryptedDataAfterSSLRequest:
                return DatabaseError("TLS negotiation with the server failed.")
            default:
                return DatabaseError("PostgreSQL protocol error.", detail: "The server sent a message Dbee didn't expect (\(error.code)).")
            }
        }
        if let error = error as? ChannelError, case .connectTimeout = error {
            return DatabaseError("Timed out connecting to \(place).", detail: "Check the host, port and firewall settings.")
        }
        if let error = error as? NIOConnectionError {
            if error.dnsAError != nil || error.dnsAAAAError != nil, error.connectionErrors.isEmpty {
                return DatabaseError("Couldn't find the host \(endpoint?.displayHost ?? "").", detail: "Check the host name.")
            }
            if let first = error.connectionErrors.first?.error {
                return DatabaseError("Couldn't connect to \(place).", detail: reason(for: first))
            }
            return DatabaseError("Couldn't connect to \(place).")
        }
        if let error = error as? IOError {
            return DatabaseError("Couldn't connect to \(place).", detail: reason(for: error))
        }
        if let error = error as? NIOSSLExtraError {
            if error == .failedToValidateHostname {
                return DatabaseError(
                    "The server's certificate isn't valid for \(endpoint?.displayHost ?? "this host").",
                    detail: "Use TLS Required to connect without verifying the certificate."
                )
            }
            return DatabaseError("TLS handshake failed.", detail: String(describing: error))
        }
        if let error = error as? NIOSSLError {
            if case .handshakeFailed(let inner) = error, String(describing: inner).contains("CERTIFICATE_VERIFY_FAILED") {
                return DatabaseError(
                    "The server's certificate couldn't be verified.",
                    detail: "It isn't signed by a certificate authority this Mac trusts. Use TLS Required to connect without verifying it."
                )
            }
            if case .uncleanShutdown = error {
                return DatabaseError("The connection was closed unexpectedly.")
            }
            return DatabaseError("TLS handshake failed.", detail: String(describing: error))
        }
        if let error = error as? PostgresError, case .connectionClosed = error {
            return DatabaseError("The connection is closed.")
        }
        return DatabaseError("PostgreSQL error.", detail: String(describing: error))
    }

    private static func serverError(_ info: PSQLError.ServerInfo?) -> DatabaseError {
        guard let info else { return DatabaseError("The server reported an error.") }
        var lines: [String] = []
        if let detail = info[.detail] { lines.append("Detail: \(detail)") }
        if let hint = info[.hint] { lines.append("Hint: \(hint)") }
        if let context = info[.locationContext] { lines.append("Where: \(context)") }
        if let position = info[.position] { lines.append("Position: \(position)") }
        if let state = info[.sqlState] { lines.append("SQLSTATE \(state)") }
        return DatabaseError(info[.message] ?? "The server reported an error.", detail: lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }

    private static func reason(for error: any Error) -> String {
        if let error = error as? IOError {
            return String(cString: strerror(error.errnoCode))
        }
        if let error = error as? ChannelError, case .connectTimeout = error {
            return "Timed out."
        }
        return String(describing: error)
    }
}

// MARK: - Structure

extension PostgresDriver {
    private struct Relation {
        var oid: String
        var kind: String
        /// Schema-qualified, quoted as needed.
        var qualifiedName: String
        var comment: String?
        var unlogged: Bool
        var partitionKey: String?
        var partitionBound: String?
        var parents: String?
        var isPartition: Bool
        var foreignServer: String?
    }

    private struct Column {
        var info: ColumnInfo
        var quotedName: String
        var identity: String
        var generated: String
        var rawDefault: String?
    }

    private struct Index {
        var info: IndexInfo
        /// Backs a PRIMARY KEY / UNIQUE / EXCLUDE constraint (so it's part of CREATE TABLE).
        var ownedByConstraint: Bool
    }

    private func relationInfo(_ table: TableRef, version: Int) async throws -> Relation {
        let partitioning = version >= 100_000
            ? """
              c.relispartition,
              CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid) END,
              CASE WHEN c.relispartition THEN pg_catalog.pg_get_expr(c.relpartbound, c.oid) END,
              """
            : "false, NULL, NULL,"
        let rows = try await fetch("""
            SELECT c.oid::text, c.relkind::text,
                   quote_ident(n.nspname) || '.' || quote_ident(c.relname),
                   pg_catalog.obj_description(c.oid, 'pg_class'),
                   c.relpersistence = 'u',
                   \(partitioning)
                   (SELECT string_agg(i.inhparent::regclass::text, ', ' ORDER BY i.inhseqno)
                      FROM pg_catalog.pg_inherits i WHERE i.inhrelid = c.oid),
                   (SELECT quote_ident(s.srvname)
                      FROM pg_catalog.pg_foreign_table ft
                      JOIN pg_catalog.pg_foreign_server s ON s.oid = ft.ftserver
                     WHERE ft.ftrelid = c.oid)
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = $2::text
              AND (n.nspname = $1::text OR ($1::text IS NULL AND pg_catalog.pg_table_is_visible(c.oid)))
            ORDER BY n.nspname = $1::text DESC
            LIMIT 1
            """, [table.schema, table.name]).rows
        guard let row = rows.first, row.count == 10, let oid = row[0] else {
            throw DatabaseError("“\(table.name)” doesn't exist.", detail: "It may have been dropped or renamed. Refresh the sidebar.")
        }
        return Relation(
            oid: oid,
            kind: row[1] ?? "r",
            qualifiedName: row[2] ?? table.name,
            comment: row[3],
            unlogged: row[4] == "t",
            partitionKey: row[6],
            partitionBound: row[7],
            parents: row[8],
            isPartition: row[5] == "t",
            foreignServer: row[9]
        )
    }

    private func columnInfo(_ oid: String, version: Int) async throws -> [Column] {
        let identity = version >= 100_000 ? "a.attidentity::text" : "''"
        let generated = version >= 120_000 ? "a.attgenerated::text" : "''"
        let rows = try await fetch("""
            SELECT a.attname, quote_ident(a.attname),
                   pg_catalog.format_type(a.atttypid, a.atttypmod),
                   a.attnotnull,
                   pg_catalog.pg_get_expr(d.adbin, d.adrelid),
                   \(identity), \(generated),
                   EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                            WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)),
                   pg_catalog.col_description(a.attrelid, a.attnum)
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, [oid]).rows
        return rows.compactMap { row in
            guard row.count == 9, let name = row[0] else { return nil }
            let identity = row[5] ?? ""
            let generated = row[6] ?? ""
            let rawDefault = row[4]
            let displayDefault: String? = switch (identity, generated) {
            case ("a", _): "GENERATED ALWAYS AS IDENTITY"
            case ("d", _): "GENERATED BY DEFAULT AS IDENTITY"
            case (_, "s"): rawDefault.map { "GENERATED ALWAYS AS (\($0)) STORED" }
            case (_, "v"): rawDefault.map { "GENERATED ALWAYS AS (\($0)) VIRTUAL" }
            default: rawDefault
            }
            return Column(
                info: ColumnInfo(
                    name: name,
                    dataType: row[2] ?? "",
                    isNullable: row[3] != "t",
                    defaultValue: displayDefault,
                    isPrimaryKey: row[7] == "t",
                    comment: row[8]
                ),
                quotedName: row[1] ?? name,
                identity: identity,
                generated: generated,
                rawDefault: rawDefault
            )
        }
    }

    private func indexInfo(_ oid: String, version: Int) async throws -> [Index] {
        let keyCount = version >= 110_000 ? "i.indnkeyatts" : "i.indnatts"
        let rows = try await fetch("""
            SELECT ic.relname, i.indisunique, i.indisprimary,
                   pg_catalog.pg_get_indexdef(i.indexrelid),
                   (SELECT json_agg(pg_catalog.pg_get_indexdef(i.indexrelid, k, true) ORDER BY k)
                      FROM generate_series(1, \(keyCount)) k),
                   EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con
                            WHERE con.conindid = i.indexrelid AND con.conrelid = i.indrelid
                              AND con.contype IN ('p', 'u', 'x'))
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = $1::oid
            ORDER BY i.indisprimary DESC, ic.relname
            """, [oid]).rows
        return rows.compactMap { row in
            guard row.count == 6, let name = row[0] else { return nil }
            return Index(
                info: IndexInfo(
                    name: name,
                    columns: Self.jsonStrings(row[4]),
                    isUnique: row[1] == "t",
                    isPrimary: row[2] == "t",
                    definition: row[3]
                ),
                ownedByConstraint: row[5] == "t"
            )
        }
    }

    private func foreignKeyInfo(_ oid: String) async throws -> [ForeignKeyInfo] {
        let rows = try await fetch("""
            SELECT con.conname,
                   (SELECT json_agg(a.attname ORDER BY k.ord)
                      FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum),
                   fn.nspname, fc.relname,
                   (SELECT json_agg(a.attname ORDER BY k.ord)
                      FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum),
                   con.confupdtype::text, con.confdeltype::text
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class fc ON fc.oid = con.confrelid
            JOIN pg_catalog.pg_namespace fn ON fn.oid = fc.relnamespace
            WHERE con.conrelid = $1::oid AND con.contype = 'f'
            ORDER BY con.conname
            """, [oid]).rows
        return rows.compactMap { row in
            guard row.count == 7, let name = row[0], let table = row[3] else { return nil }
            return ForeignKeyInfo(
                name: name,
                columns: Self.jsonStrings(row[1]),
                referencedTable: TableRef(schema: row[2], name: table),
                referencedColumns: Self.jsonStrings(row[4]),
                onUpdate: Self.referentialAction(row[5]),
                onDelete: Self.referentialAction(row[6])
            )
        }
    }

    /// CREATE statement assembled from the catalogs (an approximation of pg_dump's output).
    private func makeDDL(_ relation: Relation, columns: [Column], indexes: [Index]) async throws -> String {
        let name = relation.qualifiedName
        var parts: [String] = []

        switch relation.kind {
        case "v", "m":
            let definition = try await fetch("SELECT pg_catalog.pg_get_viewdef($1::oid, true)", [relation.oid])
                .rows.first?.first.flatMap { $0 } ?? ""
            var body = definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.hasSuffix(";") { body += ";" }
            let keyword = relation.kind == "m" ? "MATERIALIZED VIEW" : "VIEW"
            parts.append("CREATE \(keyword) \(name) AS\n\(body)")

        default:
            let constraints = try await fetch("""
                SELECT quote_ident(conname), pg_catalog.pg_get_constraintdef(oid, true)
                FROM pg_catalog.pg_constraint
                WHERE conrelid = $1::oid AND contype IN ('p', 'u', 'f', 'c', 'x') AND conislocal
                ORDER BY CASE contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'f' THEN 2 WHEN 'c' THEN 3 ELSE 4 END, conname
                """, [relation.oid]).rows

            if relation.isPartition, let parent = relation.parents, let bound = relation.partitionBound {
                parts.append("CREATE TABLE \(name) PARTITION OF \(parent)\n\(bound);")
            } else {
                var lines = columns.map { column -> String in
                    var line = "    \(column.quotedName) \(column.info.dataType)"
                    switch (column.identity, column.generated) {
                    case ("a", _): line += " GENERATED ALWAYS AS IDENTITY"
                    case ("d", _): line += " GENERATED BY DEFAULT AS IDENTITY"
                    case (_, "s"): line += " GENERATED ALWAYS AS (\(column.rawDefault ?? "")) STORED"
                    case (_, "v"): line += " GENERATED ALWAYS AS (\(column.rawDefault ?? "")) VIRTUAL"
                    default: if let value = column.rawDefault { line += " DEFAULT \(value)" }
                    }
                    if !column.info.isNullable { line += " NOT NULL" }
                    return line
                }
                for row in constraints where row.count == 2 {
                    lines.append("    CONSTRAINT \(row[0] ?? "") \(row[1] ?? "")")
                }
                let keyword = relation.kind == "f" ? "FOREIGN TABLE" : (relation.unlogged ? "UNLOGGED TABLE" : "TABLE")
                var statement = "CREATE \(keyword) \(name) (\n\(lines.joined(separator: ",\n"))\n)"
                if let parents = relation.parents { statement += "\nINHERITS (\(parents))" }
                if let key = relation.partitionKey { statement += "\nPARTITION BY \(key)" }
                if let server = relation.foreignServer { statement += "\nSERVER \(server)" }
                parts.append(statement + ";")
            }
        }

        let indexDefinitions = indexes.filter { !$0.ownedByConstraint }.compactMap { $0.info.definition.map { $0 + ";" } }
        if !indexDefinitions.isEmpty { parts.append(indexDefinitions.joined(separator: "\n")) }

        var comments: [String] = []
        if let comment = relation.comment {
            let keyword = switch relation.kind {
            case "v": "VIEW"
            case "m": "MATERIALIZED VIEW"
            case "f": "FOREIGN TABLE"
            default: "TABLE"
            }
            comments.append("COMMENT ON \(keyword) \(name) IS \(Self.literal(comment));")
        }
        for column in columns {
            if let comment = column.info.comment {
                comments.append("COMMENT ON COLUMN \(name).\(column.quotedName) IS \(Self.literal(comment));")
            }
        }
        if !comments.isEmpty { parts.append(comments.joined(separator: "\n")) }

        return parts.joined(separator: "\n\n")
    }

    private static func literal(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return value.contains("\\") ? "E'\(escaped.replacingOccurrences(of: "\\", with: "\\\\"))'" : "'\(escaped)'"
    }

    private static func jsonStrings(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func referentialAction(_ code: String?) -> String? {
        switch code {
        case "a": "NO ACTION"
        case "r": "RESTRICT"
        case "c": "CASCADE"
        case "n": "SET NULL"
        case "d": "SET DEFAULT"
        default: nil
        }
    }
}

/// Reads the server's one-byte answer to SSLRequest.
private final class PostgresSSLAnswerReader: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let answer: EventLoopPromise<UInt8>

    init(answer: EventLoopPromise<UInt8>) {
        self.answer = answer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let byte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) {
            answer.succeed(byte)
        }
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // No-op if already answered; otherwise the promise must not be dropped unfulfilled.
        answer.fail(ChannelError.ioOnClosedChannel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        answer.fail(ChannelError.eof)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        answer.fail(error)
    }
}

/// FIFO async mutex: one statement at a time on the connection.
final class PostgresStatementGate: Sendable {
    private struct State: Sendable {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = NIOLockedValueBox(State())

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLockedValue { state -> Bool in
                if state.busy {
                    state.waiters.append(continuation)
                    return false
                }
                state.busy = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    func release() {
        let next = state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.busy = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Adds `handler` closest to the wire bytes: first in a socket channel, or right behind the codec that
    /// turns SSH channel data into bytes when the channel is an SSH tunnel's direct-tcpip channel.
    func addHandlerFacingBytes(_ handler: some ChannelHandler) throws {
        if let codec = try? self.handler(type: SSHChannelByteCodec.self) {
            try addHandler(handler, position: .after(codec))
        } else {
            try addHandler(handler, position: .first)
        }
    }
}
