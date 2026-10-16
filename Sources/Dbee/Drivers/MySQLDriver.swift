import Foundation
import Logging
import MySQLNIO
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// MySQL and MariaDB over a single MySQLNIO connection.
///
/// Every statement goes through the text protocol (COM_QUERY), so anything the `mysql` CLI accepts works,
/// including statements that can't be prepared, and values arrive in the server's own text form.
/// Results are decoded by `TextQueryCommand` instead of MySQLNIO's row types, which reject collation ids
/// above 255 (MariaDB 11 defaults to one) and don't expose affected-row counts for plain queries.
///
/// Privacy: the username and password stay in memory only, to re-authenticate after the server drops an
/// idle connection and for the short-lived connection `cancelCurrentQuery()` opens. `close()` drops them.
final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    let kind: DatabaseKind = .mysql

    private static let logger = Logger(label: "dbee.mysql", factory: { _ in SwiftLogNoOpLogHandler() })
    private static let connectTimeout = TimeAmount.seconds(15)
    private static let systemDatabases: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

    private let endpoint: Endpoint
    private let server: ServerInfo
    private let gate = SerialGate()
    private let state: NIOLockedValueBox<State>

    private struct State {
        var connection: MySQLConnection?
        var credentials: Credentials?
        var connectionID: UInt64
        /// Last known default database, restored after a reconnect.
        var database: String
        var maxAllowedPacket: Int
        var inTransaction = false
        /// The session runs with autocommit off (SERVER_STATUS_AUTOCOMMIT clear).
        var autocommitOff = false
        /// A statement changed session state a reconnect can't restore (variables, temporary tables, locks).
        var sessionModified = false
        /// Token of the statement currently on the wire, so a late cancel can't hit the next one.
        var runningQuery: UInt64?
        /// Stops the statement currently on the wire.
        var runningStop: StatementCancelSignal?
        fileprivate var runningCommand: TextQueryCommand?
        var nextQueryToken: UInt64 = 1
        var isClosed = false
    }

    private init(endpoint: Endpoint, server: ServerInfo, connection: MySQLConnection,
                 credentials: Credentials, session: SessionInfo) {
        self.endpoint = endpoint
        self.server = server
        state = NIOLockedValueBox(State(connection: connection, credentials: credentials,
                                        connectionID: session.connectionID, database: session.database,
                                        maxAllowedPacket: session.maxAllowedPacket))
    }

    deinit {
        // MySQLNIO asserts that connections are closed before they are released.
        guard let connection = state.withLockedValue({ $0.connection }), !connection.isClosed else { return }
        connection.close().whenComplete { _ in withExtendedLifetime(connection) {} }
    }

    // MARK: Connecting

    /// `timeout` bounds TCP connect, TLS and login together.
    static func connect(config: ConnectionConfig, host: String, port: Int, transport: DriverTransport = .direct,
                        timeout: TimeInterval = 15) async throws -> MySQLDriver {
        var endpoint = Endpoint(config: config, host: host, port: port)
        endpoint.willDial = transport.willDial
        let credentials = Credentials(username: config.username, password: config.password)
        let (connection, session) = try await openSession(to: endpoint, credentials: credentials,
                                                           database: config.database,
                                                           timeout: .milliseconds(Int64(timeout * 1000)))
        return MySQLDriver(endpoint: endpoint, server: ServerInfo(version: session.version, comment: session.comment),
                           connection: connection, credentials: credentials, session: session)
    }

    /// What a fresh session reports about itself.
    private struct SessionInfo {
        var connectionID: UInt64
        var version: String
        var comment: String
        var database: String
        var maxAllowedPacket: Int
    }

    /// Opens an authenticated connection whose results come back as utf8mb4.
    private static func openSession(to endpoint: Endpoint, credentials: Credentials, database: String,
                                    timeout: TimeAmount = connectTimeout) async throws -> (MySQLConnection, SessionInfo) {
        let connection = try await openConnection(to: endpoint, credentials: credentials, database: database, timeout: timeout)
        do {
            let row = try await fetch("""
                SELECT CONNECTION_ID(), VERSION(), @@version_comment, DATABASE(),
                       CONCAT_WS(',', @@character_set_client, @@character_set_connection, @@character_set_results),
                       @@max_allowed_packet
                """, on: connection).first ?? []
            let field = { (index: Int) -> String? in index < row.count ? row[index] : nil }
            // The handshake asks for utf8mb4_0900_ai_ci, which older MariaDB servers don't know and replace
            // with their default character set.
            if field(4) != "utf8mb4,utf8mb4,utf8mb4" {
                _ = try await fetch("SET NAMES utf8mb4", on: connection)
            }
            let info = SessionInfo(connectionID: field(0).flatMap { UInt64($0) } ?? 0, version: field(1) ?? "",
                                   comment: field(2) ?? "", database: field(3) ?? "",
                                   maxAllowedPacket: field(5).flatMap { Int($0) } ?? .max)
            return (connection, info)
        } catch {
            try? await connection.close().get()
            throw queryError(error)
        }
    }

    private static func openConnection(to endpoint: Endpoint, credentials: Credentials, database: String,
                                       timeout: TimeAmount) async throws -> MySQLConnection {
        let deadline = NIODeadline.now() + timeout
        do {
            let addresses = try await resolve(endpoint.host, port: endpoint.port)
            var lastError: Error = DatabaseError("Couldn't connect to \(endpoint.displayName).")
            // Try every resolved address ("localhost" is often ::1 first while the server only listens on IPv4).
            for address in addresses {
                do {
                    return try await open(address, endpoint: endpoint, credentials: credentials,
                                          database: database, deadline: deadline)
                } catch let error where isUnreachable(error) {
                    lastError = error
                }
            }
            throw lastError
        } catch {
            throw connectError(error, endpoint: endpoint, emptyPassword: credentials.password.isEmpty)
        }
    }

    private static func open(_ address: SocketAddress, endpoint: Endpoint, credentials: Credentials,
                             database: String, deadline: NIODeadline) async throws -> MySQLConnection {
        do {
            return try await handshake(address, tls: endpoint.tlsConfiguration, endpoint: endpoint,
                                       credentials: credentials, database: database, deadline: deadline)
        } catch let error where endpoint.tls == .preferred && isTLSFailure(error) {
            // "Preferred" falls back to plain TCP when TLS can't be negotiated (e.g. old TLS-1.0-only servers).
            return try await handshake(address, tls: nil, endpoint: endpoint,
                                       credentials: credentials, database: database, deadline: deadline)
        }
    }

    private static func handshake(_ address: SocketAddress, tls: TLSConfiguration?, endpoint: Endpoint,
                                  credentials: Credentials, database: String,
                                  deadline: NIODeadline) async throws -> MySQLConnection {
        // MySQLNIO quietly continues without TLS (sending the login) when the greeting doesn't offer it,
        // so when TLS is mandatory the relay checks the greeting first.
        let mustEncrypt = endpoint.tls == .required || endpoint.tls == .verifyFull
        if mustEncrypt, endpoint.tls == .verifyFull, endpoint.verificationHostname == nil {
            // Through the relay the peer address isn't the server's, so an IP literal can't be matched.
            throw DatabaseError("Verify Certificate needs the server's host name.",
                                detail: "Dbee checks MySQL certificates against a DNS name, not an IP address. Enter the server's host name, or set TLS to Required to encrypt without verifying the certificate.")
        }
        // Every dial (the relay's or MySQLNIO's) starts here, including reconnects and KILL side sessions.
        endpoint.willDial()
        let relay = mustEncrypt ? try await MySQLTLSRelay.open(to: address, deadline: deadline) : nil
        let future = MySQLConnection.connect(
            to: relay?.address ?? address,
            username: credentials.username,
            database: database,
            password: credentials.password,
            tlsConfiguration: tls,
            serverHostname: tls == nil ? nil : endpoint.verificationHostname,
            logger: logger,
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        let connection: MySQLConnection
        do {
            connection = try await awaitConnection(future, deadline: deadline)
            relay?.finishListening()
        } catch {
            relay?.close()
            throw error
        }
        // Backstop: never use an unencrypted session when TLS is mandatory.
        if mustEncrypt, !(await isEncrypted(connection)) {
            try? await connection.close().get()
            throw DatabaseError("The server doesn't support TLS.",
                                detail: "Set TLS to Off to connect without encryption, preferably through an SSH tunnel.")
        }
        if relay == nil {
            _ = try? await connection.channel.setOption(ChannelOptions.socketOption(.so_keepalive), value: 1).get()
        }
        do {
            try await installPacketMerger(on: connection)
        } catch {
            try? await connection.close().get()
            throw DatabaseError("Couldn't prepare the connection.", detail: String(describing: error))
        }
        return connection
    }

    /// MySQLNIO doesn't reassemble payloads of 16 MB or more, which the server splits across packets.
    private static func installPacketMerger(on connection: MySQLConnection) async throws {
        let channel = connection.channel
        try await channel.eventLoop.submit {
            let pipeline = channel.pipeline.syncOperations
            let decoder = try pipeline.context(handlerType: ByteToMessageHandler<MySQLPacketDecoder>.self)
            try pipeline.addHandler(MySQLPacketMerger(), position: .after(decoder.handler))
        }.get()
    }

    /// Waits for MySQLNIO's connect future with a deadline and task cancellation. A connection that
    /// completes after we gave up is closed as soon as it arrives.
    private static func awaitConnection(_ future: EventLoopFuture<MySQLConnection>,
                                        deadline: NIODeadline) async throws -> MySQLConnection {
        let eventLoop = future.eventLoop
        let promise = eventLoop.makePromise(of: MySQLConnection.self)
        let abandoned = NIOLockedValueBox(false)
        let timer = eventLoop.scheduleTask(deadline: deadline) {
            abandoned.withLockedValue { $0 = true }
            promise.fail(HandshakeTimeout())
        }
        future.whenComplete { result in
            timer.cancel()
            if abandoned.withLockedValue({ $0 }) {
                if case .success(let connection) = result {
                    connection.close().whenComplete { _ in withExtendedLifetime(connection) {} }
                }
            } else {
                promise.completeWith(result)
            }
        }
        return try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            abandoned.withLockedValue { $0 = true }
            promise.fail(CancellationError())
        }
    }

    private static func isEncrypted(_ connection: MySQLConnection) async -> Bool {
        let channel = connection.channel
        let found = try? await channel.eventLoop.submit {
            (try? channel.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self)) != nil
        }.get()
        return found ?? false
    }

    /// Resolves on NIO's blocking thread pool and returns every address, in system preference order.
    private static func resolve(_ host: String, port: Int) async throws -> [SocketAddress] {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "127.0.0.1" : trimmed
        return try await NIOThreadPool.singleton.runIfActive {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(name, String(port), &hints, &list)
            guard status == 0, let first = list else {
                throw DatabaseError("Couldn't find the server “\(name)”.",
                                    detail: String(cString: gai_strerror(status)))
            }
            defer { freeaddrinfo(first) }
            var addresses: [SocketAddress] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor?.pointee {
                cursor = info.ai_next
                guard let raw = info.ai_addr else { continue }
                let address: SocketAddress
                switch info.ai_family {
                case AF_INET:
                    address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { SocketAddress($0.pointee, host: name) }
                case AF_INET6:
                    address = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { SocketAddress($0.pointee, host: name) }
                default:
                    continue
                }
                if !addresses.contains(address) { addresses.append(address) }
            }
            guard !addresses.isEmpty else { throw DatabaseError("Couldn't find the server “\(name)”.") }
            return addresses
        }
    }

    // MARK: DatabaseDriver

    func serverVersion() async throws -> String {
        server.displayVersion
    }

    func listDatabases() async throws -> [String] {
        let rows = try await serialized { try await query("SHOW DATABASES", on: liveConnection()).rows }
        return rows.compactMap { $0.first ?? nil }.filter { !Self.systemDatabases.contains($0.lowercased()) }
    }

    func currentDatabase() async throws -> String {
        try await serialized { try await refreshDatabase(on: liveConnection()) }
    }

    func listSchemas() async throws -> [SchemaInfo] {
        try await serialized {
            let connection = try await liveConnection()
            let database = try await refreshDatabase(on: connection)
            guard !database.isEmpty else { return [] }
            let tables = try await query("SHOW FULL TABLES", on: connection).rows.compactMap { row -> TableInfo? in
                guard let name = row.first ?? nil else { return nil }
                let type = (row.count > 1 ? row[1] : nil)?.uppercased() ?? ""
                return TableInfo(ref: TableRef(schema: nil, name: name), kind: type.contains("VIEW") ? .view : .table)
            }
            let sorted = tables.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
            return [SchemaInfo(name: database, tables: sorted)]
        }
    }

    func tableStructure(_ table: TableRef) async throws -> TableStructure {
        try await serialized {
            let connection = try await liveConnection()
            let schema = table.schema.map(MySQLFormatting.stringLiteral) ?? "DATABASE()"
            let name = MySQLFormatting.stringLiteral(table.name)
            let filter = "TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name)"

            let columnRows = try await query("""
                SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT, GENERATION_EXPRESSION
                FROM information_schema.COLUMNS
                WHERE \(filter)
                ORDER BY ORDINAL_POSITION
                """, on: connection).rows
            guard !columnRows.isEmpty else {
                throw DatabaseError("“\(table.name)” doesn't exist, or you don't have access to it.")
            }

            let expression = server.supportsIndexExpressions ? "EXPRESSION" : "NULL"
            let indexRows = try await query("""
                SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, SUB_PART, INDEX_TYPE, \(expression), COLLATION
                FROM information_schema.STATISTICS
                WHERE \(filter)
                ORDER BY INDEX_NAME, SEQ_IN_INDEX
                """, on: connection).rows

            let foreignKeyRows = try await query("""
                SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.TABLE_SCHEMA, k.REFERENCED_TABLE_SCHEMA,
                       k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
                FROM information_schema.KEY_COLUMN_USAGE k
                JOIN information_schema.REFERENTIAL_CONSTRAINTS r
                  ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
                 AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
                 AND r.TABLE_NAME = k.TABLE_NAME
                WHERE k.TABLE_SCHEMA = \(schema) AND k.TABLE_NAME = \(name)
                  AND k.REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
                """, on: connection).rows

            let qualified = (table.schema.map { MySQLFormatting.quoteIdentifier($0) + "." } ?? "")
                + MySQLFormatting.quoteIdentifier(table.name)
            // Works for views too; DDL is optional, so missing privileges shouldn't fail the whole structure.
            let ddl = try? await query("SHOW CREATE TABLE \(qualified)", on: connection).rows.first.flatMap { $0.count > 1 ? $0[1] : nil }

            let indexes = Self.indexes(from: indexRows)
            let primaryKey = Set(indexes.first(where: \.isPrimary)?.columns ?? [])
            let columns = columnRows.map { row -> ColumnInfo in
                let field = { (index: Int) -> String? in index < row.count ? row[index] : nil }
                let columnName = field(0) ?? ""
                let columnType = field(1) ?? ""
                let comment = field(5) ?? ""
                return ColumnInfo(
                    name: columnName,
                    dataType: columnType,
                    isNullable: field(2)?.uppercased() == "YES",
                    defaultValue: MySQLFormatting.columnDefault(field(3), columnType: columnType, extra: field(4) ?? "",
                                                                generationExpression: field(6), isMariaDB: server.isMariaDB),
                    isPrimaryKey: primaryKey.contains(columnName),
                    comment: comment.isEmpty ? nil : comment
                )
            }
            return TableStructure(columns: columns, indexes: indexes,
                                  foreignKeys: Self.foreignKeys(from: foreignKeyRows, table: table), ddl: ddl)
        }
    }

    /// Two information_schema queries for the whole database instead of four per table.
    func diagramTables(in schema: SchemaInfo) async throws -> [DiagramTable] {
        try await serialized {
            let connection = try await liveConnection()
            let database = MySQLFormatting.stringLiteral(schema.name)
            let columnRows = try await query("""
                SELECT c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_KEY
                FROM information_schema.COLUMNS c
                JOIN information_schema.TABLES t
                  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
                WHERE c.TABLE_SCHEMA = \(database) AND t.TABLE_TYPE = 'BASE TABLE'
                ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
                """, on: connection).rows
            let foreignKeyRows = try await query("""
                SELECT k.TABLE_NAME, k.CONSTRAINT_NAME, k.COLUMN_NAME, k.TABLE_SCHEMA, k.REFERENCED_TABLE_SCHEMA,
                       k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
                FROM information_schema.KEY_COLUMN_USAGE k
                JOIN information_schema.REFERENTIAL_CONSTRAINTS r
                  ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
                 AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
                 AND r.TABLE_NAME = k.TABLE_NAME
                WHERE k.TABLE_SCHEMA = \(database) AND k.REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
                """, on: connection).rows

            var order: [String] = []
            var columns: [String: [ColumnInfo]] = [:]
            for row in columnRows {
                guard row.count == 5, let table = row[0], let name = row[1] else { continue }
                if columns[table] == nil { order.append(table) }
                columns[table, default: []].append(ColumnInfo(
                    name: name, dataType: row[2] ?? "", isNullable: row[3]?.uppercased() == "YES",
                    defaultValue: nil, isPrimaryKey: row[4] == "PRI", comment: nil
                ))
            }
            var foreignKeyRowsByTable: [String: [[CellValue]]] = [:]
            for row in foreignKeyRows {
                guard let table = row.first ?? nil else { continue }
                foreignKeyRowsByTable[table, default: []].append(Array(row.dropFirst()))
            }
            return order.map { name in
                let table = TableRef(schema: nil, name: name)
                return DiagramTable(ref: table, columns: columns[name] ?? [],
                                    foreignKeys: Self.foreignKeys(from: foreignKeyRowsByTable[name] ?? [], table: table))
            }
        }
    }

    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        try await serialized {
            let connection = try await liveConnection()
            let session = state.withLockedValue { ($0.maxAllowedPacket, $0.inTransaction || $0.autocommitOff) }
            // The server drops the connection when a packet exceeds max_allowed_packet.
            if sql.utf8.count + 1 > session.0 {
                let megabytes = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
                throw DatabaseError("The statement is too large for the server.",
                                    detail: "It is \(megabytes(sql.utf8.count)); the server's max_allowed_packet is \(megabytes(session.0)).")
            }
            let command = TextQueryCommand(sql: sql, maxRows: maxRows)
            // Past maxRows, stop the server instead of reading the rest of the result. Only for plain queries
            // outside a transaction, where stopping early can't leave locks or other work half done.
            let stopAtLimit = maxRows > 0 && !session.1 && MySQLFormatting.canStopEarly(sql)
            let clock = ContinuousClock()
            let start = clock.now
            try await run(command, on: connection, stopAtLimit: stopAtLimit)
            let elapsed = (clock.now - start).components
            let duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
            if MySQLFormatting.changesSessionState(sql) {
                state.withLockedValue { $0.sessionModified = true }
            }
            if command.droppedDatabase || MySQLFormatting.isUseStatement(sql) {
                _ = try? await refreshDatabase(on: connection)
            }
            return QueryResult(
                statement: sql,
                columns: command.columns.map(\.name),
                rows: command.rows,
                rowsAffected: command.isRowSet ? nil : command.affectedRows.map { Int(clamping: $0) },
                duration: duration,
                truncated: command.truncated,
                rowsMatched: command.isRowSet ? nil : command.rowsMatched.map { Int(clamping: $0) }
            )
        }
    }

    /// SERVER_STATUS_IN_TRANS from the latest OK/EOF packet.
    var isInTransaction: Bool? {
        get async { state.withLockedValue { $0.isClosed ? nil : $0.inTransaction } }
    }

    func cancelCurrentQuery() async {
        let running = state.withLockedValue { state -> (UInt64, StatementCancelSignal, TextQueryCommand)? in
            guard !state.isClosed, let token = state.runningQuery, let stop = state.runningStop,
                  let command = state.runningCommand else { return nil }
            return (token, stop, command)
        }
        guard let (token, stop, command) = running else { return }
        // Stop keeps the rows that have already arrived, like reaching the row limit.
        stop.fire { [weak self] in
            command.noteStopRequested()
            await self?.killQuery(token: token, command: command)
        }
        await stop.settled()
    }

    /// Sends KILL QUERY from a short-lived second session, if statement `token` is still the one running.
    private func killQuery(token: UInt64, command: TextQueryCommand) async {
        let snapshot = state.withLockedValue { state in
            (state.isClosed || state.runningQuery != token ? nil : state.connectionID, state.credentials)
        }
        guard let connectionID = snapshot.0, connectionID != 0, let credentials = snapshot.1,
              !command.hasFinished else { return }
        guard let killer = try? await Self.openSession(to: endpoint, credentials: credentials,
                                                       database: "", timeout: .seconds(8)).0 else { return }
        if state.withLockedValue({ $0.runningQuery == token && !$0.isClosed }), !command.hasFinished {
            _ = try? await Self.fetch("KILL QUERY \(connectionID)", on: killer)
        }
        try? await killer.close().get()
    }

    func close() async {
        let connection = state.withLockedValue { state -> MySQLConnection? in
            state.isClosed = true
            state.credentials = nil
            state.runningQuery = nil
            state.runningStop = nil
            state.runningCommand = nil
            defer { state.connection = nil }
            return state.connection
        }
        try? await connection?.close().get()
    }

    // MARK: Running commands

    /// Runs `body` with exclusive use of the connection, in call order.
    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        await gate.acquire()
        // Cancelled while queued (e.g. a superseded row count): don't start it at all.
        if Task.isCancelled {
            await gate.release()
            throw CancellationError()
        }
        do {
            let value = try await body()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }

    /// The open connection, reconnecting first if the server dropped it (e.g. after `wait_timeout`).
    /// Must be called inside `serialized`.
    private func liveConnection() async throws -> MySQLConnection {
        let snapshot = state.withLockedValue { state in
            (state.isClosed, state.connection, state.credentials, state.database, state.inTransaction,
             state.autocommitOff || state.sessionModified)
        }
        guard !snapshot.0, let credentials = snapshot.2 else { throw DatabaseError("Not connected.") }
        if let connection = snapshot.1, !connection.isClosed { return connection }

        try? await snapshot.1?.close().get()
        let session: (MySQLConnection, SessionInfo)
        do {
            session = try await Self.openSession(to: endpoint, credentials: credentials, database: snapshot.3)
        } catch {
            let reason = (error as? DatabaseError).map { [$0.message, $0.detail].compactMap { $0 }.joined(separator: " ") }
            throw DatabaseError("Lost connection to the server.", detail: reason ?? "Reconnecting failed.")
        }
        let adopted = state.withLockedValue { state -> Bool in
            guard !state.isClosed else { return false }
            state.connection = session.0
            state.connectionID = session.1.connectionID
            state.maxAllowedPacket = session.1.maxAllowedPacket
            state.inTransaction = false
            state.autocommitOff = false
            state.sessionModified = false
            return true
        }
        guard adopted else {
            try? await session.0.close().get()
            throw DatabaseError("Not connected.")
        }
        if snapshot.4 {
            throw DatabaseError("The connection to the server was lost and has been re-established.",
                                detail: "The open transaction was rolled back by the server. Run it again.")
        }
        // Raised before the statement runs, so nothing is committed by the new session's autocommit.
        if snapshot.5 {
            throw DatabaseError("The connection to the server was lost and has been re-established.",
                                detail: "Session settings (autocommit, user variables, temporary tables, locks) were reset. Check them and run the statement again.")
        }
        return session.0
    }

    private func query(_ sql: String, on connection: MySQLConnection) async throws -> TextQueryCommand {
        let command = TextQueryCommand(sql: sql, maxRows: 0)
        try await run(command, on: connection)
        return command
    }

    /// Runs `command`. Task cancellation stops it on the server with KILL QUERY; so does, with `stopAtLimit`,
    /// the first row beyond `maxRows`, after which the rows read so far are the (truncated) result.
    private func run(_ command: TextQueryCommand, on connection: MySQLConnection, stopAtLimit: Bool = false) async throws {
        let stop = StatementCancelSignal()
        let token = state.withLockedValue { state -> UInt64 in
            defer { state.nextQueryToken += 1 }
            state.runningQuery = state.nextQueryToken
            state.runningStop = stop
            state.runningCommand = command
            return state.nextQueryToken
        }
        if stopAtLimit {
            command.onLimitReached = {
                stop.fire {
                    command.noteStopRequested()
                    await self.killQuery(token: token, command: command)
                }
            }
        }
        var failure: Error?
        do {
            try await withTaskCancellationHandler {
                try await connection.send(command, logger: Self.logger).get()
            } onCancel: {
                stop.fire { await self.killQuery(token: token, command: command) }
            }
        } catch {
            failure = error
        }
        if !stop.sealIfIdle() {
            // Wait for the KILL to land, then absorb one that arrived after the statement had already finished,
            // so it can't interrupt the next statement.
            await stop.settled()
            _ = try? await Self.fetch("DO 0", on: connection)
        }
        state.withLockedValue { state in
            if state.runningQuery == token {
                state.runningQuery = nil
                state.runningStop = nil
                state.runningCommand = nil
            }
        }
        if let error = failure {
            if state.withLockedValue({ $0.isClosed }) { throw DatabaseError("Not connected.") }
            if let error = error as? MySQLServerError, error.code == TextQueryCommand.queryInterrupted, Task.isCancelled {
                throw CancellationError()
            }
            if !Self.isServerError(error), !connection.isClosed {
                // Unread packets may still be on the wire; they mustn't reach the next statement.
                try? await connection.close().get()
                if case MySQLError.protocolError = error {
                    throw DatabaseError("Dbee couldn't read the server's response.",
                                        detail: "The connection was reset. The next statement will reconnect.")
                }
            }
            throw Self.queryError(error)
        }
        if let flags = command.statusFlags {
            state.withLockedValue { state in
                state.inTransaction = flags & TextQueryCommand.statusInTransaction != 0
                state.autocommitOff = flags & TextQueryCommand.statusAutocommit == 0
            }
        }
    }

    private static func isServerError(_ error: Error) -> Bool {
        if error is MySQLServerError { return true }
        if case MySQLError.server = error { return true }
        return false
    }

    @discardableResult
    private func refreshDatabase(on connection: MySQLConnection) async throws -> String {
        let name = (try await query("SELECT DATABASE()", on: connection).rows.first?.first ?? nil) ?? ""
        state.withLockedValue { $0.database = name }
        return name
    }

    /// Runs a statement outside the serial queue (connection setup and the cancel connection).
    private static func fetch(_ sql: String, on connection: MySQLConnection) async throws -> [[CellValue]] {
        let command = TextQueryCommand(sql: sql, maxRows: 0)
        try await connection.send(command, logger: logger).get()
        return command.rows
    }

    // MARK: Structure helpers

    private static func indexes(from rows: [[CellValue]]) -> [IndexInfo] {
        struct Accumulator {
            var name: String
            var isUnique: Bool
            var type: String
            var columns: [String] = []
            var parts: [String] = []
        }
        var order: [String] = []
        var byName: [String: Accumulator] = [:]
        for row in rows {
            let field = { (index: Int) -> String? in index < row.count ? row[index] : nil }
            guard let name = field(0) else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = Accumulator(name: name, isUnique: field(1) == "0", type: field(4)?.uppercased() ?? "")
            }
            let column = field(2)
            let expression = field(5)
            var part = column.map(MySQLFormatting.quoteIdentifier) ?? "(\(expression ?? ""))"
            if let length = field(3) { part += "(\(length))" }
            if field(6) == "D" { part += " DESC" }
            byName[name]?.columns.append(column ?? "(\(expression ?? ""))")
            byName[name]?.parts.append(part)
        }
        let indexes = order.compactMap { byName[$0] }.map { index -> IndexInfo in
            let isPrimary = index.name == "PRIMARY"
            let keyword: String
            switch (isPrimary, index.isUnique, index.type) {
            case (true, _, _): keyword = "PRIMARY KEY"
            case (_, _, "FULLTEXT"): keyword = "FULLTEXT KEY"
            case (_, _, "SPATIAL"): keyword = "SPATIAL KEY"
            case (_, true, _): keyword = "UNIQUE KEY"
            default: keyword = "KEY"
            }
            var definition = keyword
            if !isPrimary { definition += " " + MySQLFormatting.quoteIdentifier(index.name) }
            definition += " (" + index.parts.joined(separator: ", ") + ")"
            if index.type == "HASH" { definition += " USING HASH" }
            return IndexInfo(name: index.name, columns: index.columns, isUnique: index.isUnique || isPrimary,
                             isPrimary: isPrimary, definition: definition)
        }
        return indexes.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func foreignKeys(from rows: [[CellValue]], table: TableRef) -> [ForeignKeyInfo] {
        var order: [String] = []
        var byName: [String: ForeignKeyInfo] = [:]
        for row in rows {
            let field = { (index: Int) -> String? in index < row.count ? row[index] : nil }
            guard let name = field(0), let column = field(1), let referencedTable = field(4) else { continue }
            if byName[name] == nil {
                order.append(name)
                let referencedSchema = field(3)
                let schema = referencedSchema == nil || referencedSchema == field(2) ? table.schema : referencedSchema
                byName[name] = ForeignKeyInfo(name: name, columns: [],
                                              referencedTable: TableRef(schema: schema, name: referencedTable),
                                              referencedColumns: [], onUpdate: field(6), onDelete: field(7))
            }
            byName[name]?.columns.append(column)
            byName[name]?.referencedColumns.append(field(5) ?? "")
        }
        return order.compactMap { byName[$0] }
    }

    // MARK: Errors

    private static func isUnreachable(_ error: Error) -> Bool {
        if let error = error as? IOError {
            return [ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EADDRNOTAVAIL, EAFNOSUPPORT, ETIMEDOUT].contains(error.errnoCode)
        }
        if case ChannelError.connectTimeout = error { return true }
        return false
    }

    private static func isTLSFailure(_ error: Error) -> Bool {
        error is NIOSSLError || error is BoringSSLError || error is NIOSSLExtraError
    }

    /// Maps errors from opening a connection to short, actionable messages.
    private static func connectError(_ error: Error, endpoint: Endpoint, emptyPassword: Bool) -> Error {
        let target = endpoint.displayName
        let plainHint = "If the server requires encrypted connections, set TLS to Required, or connect through an SSH tunnel."
        switch error {
        case is CancellationError, is DatabaseError:
            return error
        case is HandshakeTimeout, ChannelError.connectTimeout:
            return DatabaseError("Timed out connecting to \(target).",
                                 detail: "The server didn't respond like a MySQL server. Check the host and port, firewall rules, or the SSH tunnel.")
        case let error as IOError:
            switch error.errnoCode {
            case ECONNREFUSED:
                return DatabaseError("Couldn't connect to \(target).",
                                     detail: "The connection was refused. Check that the server is running and listening on this port.")
            case EHOSTUNREACH, ENETUNREACH:
                return DatabaseError("Couldn't connect to \(target).", detail: "The host is unreachable.")
            case ETIMEDOUT:
                return DatabaseError("Timed out connecting to \(target).")
            case ECONNRESET, EPIPE:
                return DatabaseError("The server closed the connection during login.",
                                     detail: endpoint.tls == .disabled ? plainHint : nil)
            default:
                return DatabaseError("Couldn't connect to \(target).", detail: String(cString: strerror(error.errnoCode)))
            }
        case let error as MySQLError:
            switch error {
            case .server(let packet):
                var result = serverError(code: packet.errorCode.rawValue, sqlState: packet.sqlState, message: packet.errorMessage)
                var hint: String?
                switch packet.errorCode.rawValue {
                case 3159, 1251:
                    hint = plainHint
                case 1045 where emptyPassword && endpoint.tls == .disabled:
                    // MySQLNIO always sends a caching_sha2_password scramble, which MySQL only accepts for
                    // password-less accounts once TLS lets it fall back to full authentication.
                    hint = "Accounts without a password that use caching_sha2_password can only sign in over TLS. Set TLS to Preferred or Required."
                default:
                    hint = nil
                }
                if let hint { result.detail = [result.detail, hint].compactMap { $0 }.joined(separator: "\n") }
                return result
            case .unsupportedAuthPlugin(let name):
                return DatabaseError("This account uses the “\(name)” authentication plugin, which isn't supported.",
                                     detail: "Use an account with caching_sha2_password or mysql_native_password.")
            case .closed:
                return DatabaseError("The server closed the connection during login.",
                                     detail: endpoint.tls == .disabled ? plainHint : nil)
            default:
                return DatabaseError("Authentication failed: \(error.message)",
                                     detail: endpoint.tls == .disabled ? plainHint : nil)
            }
        case let error as NIOSSLExtraError where error == .failedToValidateHostname:
            return DatabaseError("The server's TLS certificate isn't valid for “\(endpoint.certificateName)”.",
                                 detail: "Set TLS to Required to encrypt without verifying the certificate.")
        case let error as NIOSSLError:
            let reason: String
            switch error {
            case .handshakeFailed(let underlying): reason = tlsReason(underlying)
            case .uncleanShutdown: reason = "the server closed the connection"
            default: reason = "\(error)"
            }
            return DatabaseError(
                "The TLS handshake with the server failed.",
                detail: endpoint.tls == .verifyFull
                    ? "The certificate couldn't be verified (\(reason)). Set TLS to Required to encrypt without verifying it, e.g. for self-signed certificates."
                    : reason.prefix(1).uppercased() + reason.dropFirst() + "."
            )
        case is NIOSSLExtraError, is BoringSSLError:
            return DatabaseError("The TLS handshake with the server failed.", detail: shortDescription(error))
        default:
            return DatabaseError("Couldn't connect to \(target).", detail: shortDescription(error))
        }
    }

    /// Maps errors from running statements.
    private static func queryError(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is DatabaseError:
            return error
        case let error as MySQLServerError:
            return serverError(code: error.code, sqlState: error.sqlState, message: error.message)
        case let error as MySQLError:
            if case .server(let packet) = error {
                return serverError(code: packet.errorCode.rawValue, sqlState: packet.sqlState, message: packet.errorMessage)
            }
            if case .closed = error { return lostConnection }
            return DatabaseError(error.message)
        case is ChannelError, is IOError, is NIOSSLError:
            return lostConnection
        default:
            return DatabaseError(shortDescription(error))
        }
    }

    private static var lostConnection: DatabaseError {
        DatabaseError("Lost connection to the server.", detail: "The next statement will reconnect.")
    }

    private static func serverError(code: UInt16, sqlState: String?, message: String) -> DatabaseError {
        DatabaseError(message, detail: "ERROR \(code)" + (sqlState.map { " (\($0))" } ?? ""))
    }

    /// "CERTIFICATE_VERIFY_FAILED" from a BoringSSL error stack, as "certificate verify failed".
    private static func tlsReason(_ error: BoringSSLError) -> String {
        // e.g. "sslError([Error: 268435581 error:1000007d:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED at …/handshake.cc:288])"
        let text = "\(error)"
        guard let start = text.range(of: "error:")?.upperBound else { return "handshake failed" }
        let entry = text[start...].prefix { $0 != " " && $0 != "]" }
        guard let code = entry.split(separator: ":").last, code.count > 3,
              code.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" })
        else { return "handshake failed" }
        return code.replacingOccurrences(of: "_", with: " ").lowercased()
    }

    private static func shortDescription(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}

// MARK: - Supporting types

/// Where to dial and how to secure it. Contains no secrets.
private struct Endpoint: Sendable {
    var host: String
    var port: Int
    var tls: TLSMode
    /// Logical server name (differs from `host` when tunnelled), used for messages and certificate checks.
    var serverName: String
    var serverPort: Int
    /// See `DriverTransport.willDial`.
    var willDial: @Sendable () -> Void = {}

    init(config: ConnectionConfig, host: String, port: Int) {
        self.host = host
        self.port = port
        tls = config.tls
        let logical = config.host.trimmingCharacters(in: .whitespaces)
        serverName = logical.isEmpty ? host : logical
        serverPort = config.port
    }

    var displayName: String {
        let name = serverName.isEmpty ? "127.0.0.1" : serverName
        return name.contains(":") ? "[\(name)]:\(serverPort)" : "\(name):\(serverPort)"
    }

    var certificateName: String { serverName.isEmpty ? host : serverName }

    var tlsConfiguration: TLSConfiguration? {
        switch tls {
        case .disabled:
            return nil
        case .preferred, .required:
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            // Encrypting with an old protocol beats not encrypting when the certificate isn't checked anyway.
            configuration.minimumTLSVersion = .tlsv1
            return configuration
        case .verifyFull:
            return .makeClientConfiguration()
        }
    }

    /// Name for SNI and hostname verification. NIOSSL rejects IP literals there and checks the peer address instead.
    var verificationHostname: String? {
        guard tls == .verifyFull else { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        let isIP = inet_pton(AF_INET, certificateName, &v4) == 1 || inet_pton(AF_INET6, certificateName, &v6) == 1
        return isIP ? nil : certificateName
    }
}

/// Login secrets, held in memory only.
private struct Credentials: Sendable {
    var username: String
    var password: String
}

private struct ServerInfo: Sendable {
    var displayVersion: String
    var isMariaDB: Bool
    var version: [Int]

    init(version: String, comment: String) {
        let description = MySQLFormatting.serverDescription(version: version, comment: comment)
        displayVersion = description.display
        isMariaDB = description.isMariaDB
        self.version = description.numbers
    }

    /// information_schema.STATISTICS.EXPRESSION exists from MySQL 8.0.13 (functional indexes).
    var supportsIndexExpressions: Bool {
        guard !isMariaDB else { return false }
        let padded = version + [0, 0, 0]
        return (padded[0], padded[1], padded[2]) >= (8, 0, 13)
    }
}

private struct HandshakeTimeout: Error {}

/// An ERR packet received while running a statement.
private struct MySQLServerError: Error {
    var code: UInt16
    var sqlState: String?
    var message: String

    init(packet: ByteBuffer) {
        var buffer = packet
        buffer.moveReaderIndex(forwardBy: 1)
        code = buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0
        if buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == UInt8(ascii: "#") {
            buffer.moveReaderIndex(forwardBy: 1)
            sqlState = buffer.readString(length: min(5, buffer.readableBytes))
        }
        message = buffer.readString(length: buffer.readableBytes) ?? ""
    }
}

/// FIFO async lock serializing operations on the driver's single connection.
private actor SerialGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Text protocol

/// COM_QUERY with text-protocol result decoding. MySQLNIO drives it on the connection's event loop;
/// read its properties only after the `send` future has completed.
private final class TextQueryCommand: MySQLCommand, @unchecked Sendable {
    static let statusInTransaction: UInt16 = 0x0001
    static let statusAutocommit: UInt16 = 0x0002
    /// ER_QUERY_INTERRUPTED, the error a statement stopped by KILL QUERY ends with.
    static let queryInterrupted: UInt16 = 1317
    private static let statusMoreResults: UInt16 = 0x0008
    private static let statusDatabaseDropped: UInt16 = 0x0100

    struct Column {
        var name: String
        var rendering: MySQLFormatting.CellRendering
    }

    private enum Phase {
        case awaitingResponse
        case columnDefinitions(remaining: Int)
        case columnsEOF
        case rows
        case done
    }

    let sql: String
    /// Rows beyond this are read off the wire and discarded. 0 means no limit.
    let maxRows: Int
    private(set) var columns: [Column] = []
    private(set) var rows: [[CellValue]] = []
    private(set) var truncated = false
    private(set) var affectedRows: UInt64?
    /// "Rows matched: N" from an UPDATE's OK packet info. MySQL's affected count leaves out rows that
    /// matched but already held the new values.
    private(set) var rowsMatched: UInt64?
    private(set) var statusFlags: UInt16?
    private var resultSets = 0
    private var currentColumns: [Column] = []
    private var renderings: [MySQLFormatting.CellRendering] = []
    private var phase = Phase.awaitingResponse
    /// Called once, on the event loop, when the first row beyond `maxRows` arrives. Set before sending.
    var onLimitReached: (@Sendable () -> Void)?
    /// Set (from any thread) just before the driver interrupts the statement on purpose.
    private let stopRequested = NIOLockedValueBox(false)

    /// Set once the server has sent the statement's final response.
    private let finished = NIOLockedValueBox(false)

    func noteStopRequested() {
        stopRequested.withLockedValue { $0 = true }
    }

    var hasFinished: Bool { finished.withLockedValue { $0 } }

    init(sql: String, maxRows: Int) {
        self.sql = sql
        self.maxRows = maxRows
    }

    var isRowSet: Bool { resultSets > 0 }
    var droppedDatabase: Bool { (statusFlags ?? 0) & Self.statusDatabaseDropped != 0 }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        phase = .awaitingResponse
        let packet = try MySQLPacket.encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)
        return MySQLCommandState(response: Self.split(packet))
    }

    /// A payload of 16 MB or more goes out as 0xFFFFFF-byte packets plus a shorter (possibly empty) last one;
    /// MySQLNIO's encoder would otherwise write a wrapped-around length.
    static func split(_ packet: MySQLPacket) -> [MySQLPacket] {
        var payload = packet.payload
        guard payload.readableBytes >= MySQLPacketMerger.maxPayload else { return [packet] }
        var packets: [MySQLPacket] = []
        while payload.readableBytes >= MySQLPacketMerger.maxPayload {
            packets.append(MySQLPacket(payload: payload.readSlice(length: MySQLPacketMerger.maxPayload)!))
        }
        packets.append(MySQLPacket(payload: payload))
        return packets
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        guard let header = packet.payload.getInteger(at: packet.payload.readerIndex, as: UInt8.self) else {
            throw MySQLError.protocolError
        }
        if header == 0xFF {
            let error = MySQLServerError(packet: packet.payload)
            let wasRows: Bool
            if case .rows = phase { wasRows = true } else { wasRows = false }
            phase = .done
            finished.withLockedValue { $0 = true }
            // Stopped on purpose while reading the first result set: the rows so far are the result.
            if error.code == Self.queryInterrupted, wasRows, resultSets == 1, !rows.isEmpty,
               stopRequested.withLockedValue({ $0 }) {
                truncated = true
                return MySQLCommandState(done: true)
            }
            return MySQLCommandState(done: true, error: error)
        }
        let deprecateEOF = capabilities.contains(.CLIENT_DEPRECATE_EOF)
        switch phase {
        case .awaitingResponse:
            if header == 0x00 {
                return try finish(okPacket: &packet.payload)
            }
            if header == 0xFB {
                // LOCAL INFILE request (never negotiated): answer with an empty file and wait for OK/ERR.
                return MySQLCommandState(response: [MySQLPacket()])
            }
            guard let count = packet.payload.readMySQLLengthEncodedInteger(), count > 0, count < 1 << 16 else {
                throw MySQLError.protocolError
            }
            resultSets += 1
            currentColumns = []
            currentColumns.reserveCapacity(Int(count))
            phase = .columnDefinitions(remaining: Int(count))
        case .columnDefinitions(let remaining):
            currentColumns.append(try Self.decodeColumn(&packet.payload))
            if remaining > 1 {
                phase = .columnDefinitions(remaining: remaining - 1)
            } else {
                if resultSets == 1 {
                    columns = currentColumns
                    renderings = currentColumns.map(\.rendering)
                }
                phase = deprecateEOF ? .rows : .columnsEOF
            }
        case .columnsEOF:
            guard header == 0xFE else { throw MySQLError.protocolError }
            phase = .rows
        case .rows:
            // A terminator starts with 0xFE and is short; a row can only start with 0xFE for a value of 16 MB+.
            if header == 0xFE, packet.payload.readableBytes < (deprecateEOF ? 0xFF_FFFF : 9) {
                return deprecateEOF ? try finish(okPacket: &packet.payload) : try finish(eofPacket: &packet.payload)
            }
            // Only the first result set is kept; later ones (multi-result CALLs) are drained.
            guard resultSets == 1 else { break }
            if maxRows > 0, rows.count >= maxRows {
                if !truncated, let onLimitReached {
                    self.onLimitReached = nil
                    onLimitReached()
                }
                truncated = true
            } else {
                rows.append(try decodeRow(&packet.payload))
            }
        case .done:
            throw MySQLError.protocolError
        }
        return MySQLCommandState()
    }

    private func finish(okPacket buffer: inout ByteBuffer) throws -> MySQLCommandState {
        buffer.moveReaderIndex(forwardBy: 1)
        guard let affected = buffer.readMySQLLengthEncodedInteger(),
              buffer.readMySQLLengthEncodedInteger() != nil, // last insert id
              let status = buffer.readInteger(endianness: .little, as: UInt16.self)
        else { throw MySQLError.protocolError }
        if resultSets == 0 {
            affectedRows = (affectedRows ?? 0) + affected
            // Then warnings and the human-readable info ("Rows matched: 1  Changed: 0  Warnings: 0").
            if buffer.readInteger(endianness: .little, as: UInt16.self) != nil,
               let info = buffer.readString(length: buffer.readableBytes),
               let matched = Self.rowsMatched(inInfo: info) {
                rowsMatched = (rowsMatched ?? 0) + matched
            }
        }
        return finish(status: status)
    }

    static func rowsMatched(inInfo info: String) -> UInt64? {
        guard let range = info.range(of: "Rows matched: ") else { return nil }
        return UInt64(info[range.upperBound...].prefix(while: \.isNumber))
    }

    private func finish(eofPacket buffer: inout ByteBuffer) throws -> MySQLCommandState {
        buffer.moveReaderIndex(forwardBy: 1)
        guard buffer.readInteger(endianness: .little, as: UInt16.self) != nil, // warnings
              let status = buffer.readInteger(endianness: .little, as: UInt16.self)
        else { throw MySQLError.protocolError }
        return finish(status: status)
    }

    private func finish(status: UInt16) -> MySQLCommandState {
        statusFlags = status
        if status & Self.statusMoreResults != 0 {
            phase = .awaitingResponse
            return MySQLCommandState()
        }
        phase = .done
        finished.withLockedValue { $0 = true }
        return MySQLCommandState(done: true)
    }

    private func decodeRow(_ buffer: inout ByteBuffer) throws -> [CellValue] {
        var row: [CellValue] = []
        row.reserveCapacity(renderings.count)
        for rendering in renderings {
            guard let marker = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
                throw MySQLError.protocolError
            }
            if marker == 0xFB {
                buffer.moveReaderIndex(forwardBy: 1)
                row.append(nil)
                continue
            }
            guard let length = buffer.readMySQLLengthEncodedInteger(),
                  length <= UInt64(buffer.readableBytes),
                  let value = buffer.readSlice(length: Int(length))
            else { throw MySQLError.protocolError }
            row.append(MySQLFormatting.render(value, as: rendering))
        }
        return row
    }

    /// `Protocol::ColumnDefinition41`, keeping only what rendering needs.
    private static func decodeColumn(_ buffer: inout ByteBuffer) throws -> Column {
        // catalog, schema, table, org_table
        for _ in 0..<4 {
            guard buffer.skipMySQLLengthEncodedString() else { throw MySQLError.protocolError }
        }
        guard let name = buffer.readMySQLLengthEncodedString(),
              buffer.skipMySQLLengthEncodedString(), // org_name
              buffer.readMySQLLengthEncodedInteger() != nil, // length of fixed fields
              let charset = buffer.readInteger(endianness: .little, as: UInt16.self),
              buffer.readInteger(endianness: .little, as: UInt32.self) != nil, // display length
              let type = buffer.readInteger(as: UInt8.self)
        else { throw MySQLError.protocolError }
        return Column(name: name, rendering: MySQLFormatting.rendering(type: type, charset: charset))
    }
}

/// Joins payloads the server split into 0xFFFFFF-byte packets (anything of 16 MB or more) before MySQLNIO's
/// handler sees them; MySQLNIO's decoder passes each piece on as if it were a whole packet.
private final class MySQLPacketMerger: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = MySQLPacket
    typealias InboundOut = MySQLPacket

    static let maxPayload = 0xFF_FFFF

    private var pending: ByteBuffer?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var packet = unwrapInboundIn(data)
        if packet.payload.readableBytes == Self.maxPayload {
            if pending == nil { pending = context.channel.allocator.buffer(capacity: 2 * Self.maxPayload) }
            pending?.writeBuffer(&packet.payload)
            return
        }
        guard var merged = pending else {
            context.fireChannelRead(data)
            return
        }
        pending = nil
        merged.writeBuffer(&packet.payload)
        context.fireChannelRead(wrapInboundOut(MySQLPacket(payload: merged)))
    }
}

fileprivate extension ByteBuffer {
    mutating func readMySQLLengthEncodedInteger() -> UInt64? {
        guard let first = readInteger(as: UInt8.self) else { return nil }
        switch first {
        case 0xFC: return readInteger(endianness: .little, as: UInt16.self).map(UInt64.init)
        case 0xFD:
            guard let bytes = readBytes(length: 3) else { return nil }
            return UInt64(bytes[0]) | UInt64(bytes[1]) << 8 | UInt64(bytes[2]) << 16
        case 0xFE: return readInteger(endianness: .little, as: UInt64.self)
        case 0xFB, 0xFF: return nil
        default: return UInt64(first)
        }
    }

    mutating func readMySQLLengthEncodedString() -> String? {
        guard let length = readMySQLLengthEncodedInteger(), length <= UInt64(readableBytes) else { return nil }
        return readString(length: Int(length))
    }

    mutating func skipMySQLLengthEncodedString() -> Bool {
        guard let length = readMySQLLengthEncodedInteger(), length <= UInt64(readableBytes) else { return false }
        moveReaderIndex(forwardBy: Int(length))
        return true
    }
}

// MARK: - Formatting

/// Pure helpers turning MySQL wire values and metadata into Dbee's models.
enum MySQLFormatting {
    enum CellRendering: Sendable, Equatable {
        case text
        /// Binary strings, BLOBs and spatial values, as "\x0a1b…".
        case hex
        /// BIT(n), as its unsigned integer value.
        case bitInteger
    }

    /// The `binary` character set id: marks BINARY/VARBINARY/BLOB (and every non-string type).
    static let binaryCharset: UInt16 = 63

    static func rendering(type: UInt8, charset: UInt16) -> CellRendering {
        switch type {
        case 0x10: // BIT
            return .bitInteger
        case 0xFF, 0xF2: // GEOMETRY, VECTOR
            return .hex
        case 0x0F, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE: // VARCHAR, *BLOB, VAR_STRING, STRING
            return charset == binaryCharset ? .hex : .text
        default:
            return .text
        }
    }

    static func render(_ value: ByteBuffer, as rendering: CellRendering) -> String {
        switch rendering {
        case .text:
            return String(buffer: value)
        case .hex:
            return hex(value.readableBytesView)
        case .bitInteger:
            let number = value.readableBytesView.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return String(number)
        }
    }

    static func hex<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = [UInt8(ascii: "\\"), UInt8(ascii: "x")]
        output.reserveCapacity(2 + bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// `name` with embedded backticks doubled.
    static func quoteIdentifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// A utf8mb4 string literal written as hex, so it is correct whatever `sql_mode`
    /// (NO_BACKSLASH_ESCAPES, ANSI_QUOTES) the session uses.
    static func stringLiteral(_ value: String) -> String {
        let digits = hex(Array(value.utf8)).dropFirst(2)
        return "CONVERT(X'\(digits)' USING utf8mb4)"
    }

    /// "MySQL 8.4.2", "MariaDB 11.4.2", "Percona Server 8.0.36", "TiDB v7.5.0".
    static func serverDescription(version: String, comment: String) -> (display: String, isMariaDB: Bool, numbers: [Int]) {
        let lowered = (version + " " + comment).lowercased()
        var raw = Substring(version)
        if lowered.contains("mariadb"), raw.hasPrefix("5.5.5-") { raw = raw.dropFirst(6) }
        let numeric = String(raw.prefix { $0.isNumber || $0 == "." })
        let numbers = numeric.split(separator: ".").compactMap { Int($0) }
        if lowered.contains("mariadb") {
            return ("MariaDB \(numeric)", true, numbers)
        }
        if let range = version.range(of: "TiDB-", options: .caseInsensitive) {
            return ("TiDB " + version[range.upperBound...].prefix { !$0.isWhitespace }, false, numbers)
        }
        if lowered.contains("percona") {
            return ("Percona Server \(numeric)", false, numbers)
        }
        return ("MySQL \(numeric)", false, numbers)
    }

    /// A column default as SQL: literals quoted, expressions as-is, AUTO_INCREMENT and generated columns spelled out.
    /// MariaDB already reports quoted literals and "NULL" for "no default"; MySQL reports bare values.
    static func columnDefault(_ raw: String?, columnType: String, extra: String,
                              generationExpression: String?, isMariaDB: Bool) -> String? {
        let extra = extra.lowercased()
        if extra.contains("auto_increment") { return "AUTO_INCREMENT" }
        if let expression = generationExpression, !expression.isEmpty, !extra.contains("default_generated"),
           extra.contains("generated") || extra.contains("persistent") {
            let stored = extra.contains("stored") || extra.contains("persistent")
            return "AS (\(expression)) \(stored ? "STORED" : "VIRTUAL")"
        }
        guard let raw else { return nil }
        if isMariaDB { return raw == "NULL" ? nil : raw }
        if extra.contains("default_generated") { return raw }
        let baseType = String(columnType.lowercased().prefix { $0.isLetter })
        let numericTypes: Set<String> = ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal",
                                         "numeric", "float", "double", "real", "bit", "year", "bool", "boolean"]
        if numericTypes.contains(baseType) || raw.uppercased().hasPrefix("CURRENT_TIMESTAMP") { return raw }
        return "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A query whose reading can be cut short with KILL QUERY once enough rows have arrived: a plain
    /// SELECT-like statement without a locking clause. (A function with side effects in the select list would
    /// still be stopped part way; that's accepted for the sake of not streaming whole tables.)
    static func canStopEarly(_ sql: String) -> Bool {
        guard let first = StatementTraits.leadingKeyword(sql, kind: .mysql),
              ["SELECT", "WITH", "TABLE", "VALUES"].contains(first) else { return false }
        let words = StatementTraits.words(sql, kind: .mysql)
        return !words.contains("INTO") && !StatementTraits.hasLockingClause(sql, kind: .mysql)
    }

    /// Statements that leave session state behind which a reconnect would silently lose: SET (variables,
    /// autocommit, sql_mode, names), LOCK TABLES, temporary tables and prepared statements.
    static func changesSessionState(_ sql: String) -> Bool {
        let words = StatementTraits.words(sql, kind: .mysql, limit: 2)
        switch words.first {
        case "SET", "LOCK", "PREPARE": return true
        case "CREATE": return words.count > 1 && words[1] == "TEMPORARY"
        default: return false
        }
    }

    static func isUseStatement(_ sql: String) -> Bool {
        let head = sql.drop { $0.isWhitespace }
        guard head.count > 3, head.prefix(3).uppercased() == "USE" else { return false }
        let next = head[head.index(head.startIndex, offsetBy: 3)]
        return next.isWhitespace || next == "`"
    }
}
