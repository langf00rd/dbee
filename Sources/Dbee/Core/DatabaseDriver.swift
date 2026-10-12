import Foundation
import NIOCore

/// One live connection to a database server. Implementations hold exactly one underlying
/// connection so that session state (transactions, `SET`, temp tables) behaves like a terminal client.
/// Calls may arrive concurrently from different tasks; implementations must serialize them.
protocol DatabaseDriver: AnyObject, Sendable {
    var kind: DatabaseKind { get }

    /// Human readable server version, e.g. "PostgreSQL 16.2".
    func serverVersion() async throws -> String

    /// Databases visible to the user. SQLite returns ["main"].
    func listDatabases() async throws -> [String]

    /// The database the connection is currently using.
    func currentDatabase() async throws -> String

    /// Schemas with their tables and views, sorted by name. System schemas
    /// (pg_catalog, information_schema, pg_toast…, mysql/sys/performance_schema) are excluded.
    /// MySQL and SQLite return a single SchemaInfo named after the current database / "main",
    /// whose TableRefs have `schema == nil`.
    func listSchemas() async throws -> [SchemaInfo]

    func tableStructure(_ table: TableRef) async throws -> TableStructure

    /// Executes exactly one SQL statement. Row sets are read up to `maxRows` rows; when more rows exist
    /// the result is marked `truncated`. Non-row statements report `rowsAffected` when known.
    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult

    /// Best-effort cancellation of the statement currently running on this connection.
    func cancelCurrentQuery() async

    /// Whether the connection is inside a transaction (opened by the user's own BEGIN), or nil when the
    /// driver can't tell. Table commits refuse to start inside one, since their BEGIN/COMMIT would end it.
    var isInTransaction: Bool? { get async }

    /// Closes the connection. Safe to call more than once.
    func close() async
}

extension DatabaseDriver {
    var isInTransaction: Bool? { get async { nil } }
}

/// A driver for an engine without SQL (Redis, MongoDB). The table browser can't generate SELECT and
/// COUNT statements for it, so the driver pages through a table itself.
protocol CommandDriver: DatabaseDriver {
    /// One page of `table`. `filter` is in the engine's own syntax: a key pattern (Redis) or a JSON
    /// query document (MongoDB). nil or blank for none.
    func page(of table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) async throws -> QueryResult

    /// Number of rows `filter` matches, or nil when the engine can't count them cheaply.
    func count(of table: TableRef, filter: String?) async throws -> Int?

    /// Makes `name` the connection's current database.
    func useDatabase(_ name: String) async throws
}

/// How a driver reaches its server when that isn't a plain TCP dial to host:port, i.e. through an SSH tunnel.
struct DriverTransport: Sendable {
    /// Called right before every TCP dial to host:port, including side connections (cancel, reconnect).
    /// A tunnel uses it to let exactly that connection through its local listener.
    var willDial: @Sendable () -> Void = {}
    /// Opens a byte channel already connected to the server, used instead of dialing host:port by drivers
    /// that can run over one (Postgres, Redis, MongoDB). Nothing else on the Mac can reach such a channel.
    var openChannel: (@Sendable () async throws -> any Channel)?

    static let direct = DriverTransport()

    static func through(_ tunnel: SSHTunnel) -> DriverTransport {
        DriverTransport(
            willDial: { [weak tunnel] in tunnel?.allowNextLocalConnection() },
            openChannel: { [weak tunnel] in
                guard let tunnel else { throw DatabaseError("The SSH tunnel is closed.") }
                return try await tunnel.openForwardedChannel()
            }
        )
    }
}

enum DriverFactory {
    /// Opens a driver. `host`/`port` are where to actually dial (127.0.0.1:<local> when tunnelled);
    /// `config.host` is the logical server name, used for TLS hostname verification.
    static func connect(config: ConnectionConfig, host: String, port: Int,
                        transport: DriverTransport = .direct) async throws -> any DatabaseDriver {
        switch config.kind {
        case .postgres:
            return try await PostgresDriver.connect(config: config, host: host, port: port, transport: transport)
        case .mysql:
            return try await MySQLDriver.connect(config: config, host: host, port: port, transport: transport)
        case .sqlite:
            // Opens off the main actor so a slow or network volume can't stall the UI.
            return try await SQLiteDriver.connect(path: config.filePath)
        case .redis:
            return try await RedisDriver.connect(config: config, host: host, port: port, transport: transport)
        case .mongodb:
            return try await MongoDriver.connect(config: config, host: host, port: port, transport: transport)
        }
    }
}
