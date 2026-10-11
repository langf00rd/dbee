import Foundation

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

    /// Closes the connection. Safe to call more than once.
    func close() async
}

enum DriverFactory {
    /// Opens a driver. `host`/`port` are where to actually dial (127.0.0.1:<local> when tunnelled);
    /// `config.host` is the logical server name, used for TLS hostname verification.
    static func connect(config: ConnectionConfig, host: String, port: Int) async throws -> any DatabaseDriver {
        switch config.kind {
        case .postgres:
            return try await PostgresDriver.connect(config: config, host: host, port: port)
        case .mysql:
            return try await MySQLDriver.connect(config: config, host: host, port: port)
        case .sqlite:
            return try SQLiteDriver.open(path: config.filePath)
        }
    }
}
