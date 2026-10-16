import Foundation

// MARK: - Database kinds

enum DatabaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgres
    case mysql
    case sqlite
    case clickhouse
    case scylla
    case redis
    case mongodb
    case meilisearch

    var id: String { rawValue }

    /// The engines whose query editor speaks SQL or a dialect of it (CQL).
    static let sqlKinds: [DatabaseKind] = allCases.filter(\.isSQL)

    var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL / MariaDB"
        case .sqlite: "SQLite"
        case .clickhouse: "ClickHouse"
        case .scylla: "ScyllaDB / Cassandra"
        case .redis: "Redis"
        case .mongodb: "MongoDB"
        case .meilisearch: "Meilisearch"
        }
    }

    var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlite: 0
        case .clickhouse: 8123
        case .scylla: 9042
        case .redis: 6379
        case .mongodb: 27017
        case .meilisearch: 7700
        }
    }

    /// Whether the engine has a schema level between database and table.
    var hasSchemas: Bool { self == .postgres }

    /// Whether the connection goes over the network (and can therefore use TLS / SSH).
    var isNetworked: Bool { self != .sqlite }

    /// Whether the query editor speaks SQL (or CQL, which reads like it). Redis, MongoDB and Meilisearch take
    /// their own commands.
    var isSQL: Bool {
        switch self {
        case .postgres, .mysql, .sqlite, .clickhouse, .scylla: true
        case .redis, .mongodb, .meilisearch: false
        }
    }

    /// Whether the table browser reads pages with generated SELECT and COUNT statements. The other engines
    /// page through tables with driver calls (see `CommandDriver`); CQL has no OFFSET.
    var pagesWithSQL: Bool { isSQL && self != .scylla }

    /// Whether the engine has transactions, which the table browser needs to commit edits.
    var hasTransactions: Bool { self == .postgres || self == .mysql || self == .sqlite }

    /// Whether tables can have foreign keys, so a relationship diagram means something.
    var hasForeignKeys: Bool { hasTransactions }

    /// Whether a connection needs a user name. The other servers often run without authentication
    /// (ClickHouse then uses `default`).
    var requiresUsername: Bool { self == .postgres || self == .mysql }

    /// Whether the engine has user names at all. Meilisearch only takes an API key.
    var hasUsername: Bool { isNetworked && self != .meilisearch }

    /// Whether the server has several databases (keyspaces for ScyllaDB) to switch between.
    var hasDatabases: Bool { self != .meilisearch }

    /// TLS for a new connection. Engines other than PostgreSQL and MySQL rarely offer TLS unless set up for
    /// it, and some don't answer a TLS attempt at all, which would stall every connect.
    var defaultTLS: TLSMode { self == .postgres || self == .mysql ? .preferred : .disabled }

    var symbolName: String {
        switch self {
        case .postgres: "cylinder.split.1x2"
        case .mysql: "cylinder"
        case .sqlite: "doc.text"
        case .clickhouse: "chart.bar"
        case .scylla: "circle.hexagongrid"
        case .redis: "key"
        case .mongodb: "leaf"
        case .meilisearch: "magnifyingglass"
        }
    }
}

enum TLSMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Plain TCP. Only sensible through an SSH tunnel.
    case disabled
    /// Use TLS if the server offers it, without certificate verification.
    case preferred
    /// Require TLS, but accept any certificate (self-signed VPS setups).
    case required
    /// Require TLS and verify the certificate chain and hostname.
    case verifyFull

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: "Off"
        case .preferred: "Preferred"
        case .required: "Required"
        case .verifyFull: "Verify Certificate"
        }
    }
}

// MARK: - Connection configuration (in-memory only)

enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }
    var displayName: String { self == .password ? "Password" : "Private Key" }
}

/// SSH tunnel settings. Holds secrets, so this type is deliberately NOT Codable.
struct SSHConfig: Equatable, Sendable {
    var enabled = false
    var host = ""
    var port = 22
    var username = ""
    var authMethod: SSHAuthMethod = .privateKey
    /// Secret. Never persisted.
    var password = ""
    /// Path to an OpenSSH private key file. The key is read at connect time and never copied.
    var privateKeyPath = ""
    /// Secret. Never persisted.
    var passphrase = ""

    mutating func wipeSecrets() {
        password = ""
        passphrase = ""
    }
}

/// Everything needed to open a connection. Holds secrets, so this type is deliberately NOT Codable
/// and must never be written to disk, UserDefaults, the Keychain or logs.
struct ConnectionConfig: Equatable, Sendable {
    var name = ""
    var kind: DatabaseKind = .postgres
    var host = ""
    var port = DatabaseKind.postgres.defaultPort
    var username = ""
    /// Secret. Never persisted.
    var password = ""
    var database = ""
    var tls: TLSMode = .preferred
    /// SQLite only: path to the database file.
    var filePath = ""
    var ssh = SSHConfig()

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .sqlite: return URL(fileURLWithPath: filePath).lastPathComponent
        default: return database.isEmpty ? host : "\(database) @ \(host)"
        }
    }

    mutating func wipeSecrets() {
        password = ""
        ssh.wipeSecrets()
    }
}

/// A connection "favorite". Contains NO credentials: no usernames, passwords, passphrases or key paths.
/// This is the only connection-related type that may ever be persisted, and only when the user opts in.
struct SavedConnection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: DatabaseKind
    var host: String
    var port: Int
    var database: String
    var tls: TLSMode
    var filePath: String
    var sshEnabled: Bool
    var sshHost: String
    var sshPort: Int
    var sshAuthMethod: SSHAuthMethod

    init(from config: ConnectionConfig) {
        name = config.displayName
        kind = config.kind
        host = config.host
        port = config.port
        database = config.database
        tls = config.tls
        filePath = config.filePath
        sshEnabled = config.ssh.enabled
        sshHost = config.ssh.host
        sshPort = config.ssh.port
        sshAuthMethod = config.ssh.authMethod
    }

    /// Builds a config with every credential field empty, ready for the user to fill in.
    func makeConfig() -> ConnectionConfig {
        var c = ConnectionConfig()
        c.name = name
        c.kind = kind
        c.host = host
        c.port = port
        c.database = database
        c.tls = tls
        c.filePath = filePath
        c.ssh.enabled = sshEnabled
        c.ssh.host = sshHost
        c.ssh.port = sshPort
        c.ssh.authMethod = sshAuthMethod
        return c
    }
}

// MARK: - Schema

struct TableRef: Hashable, Sendable, Identifiable {
    /// nil for engines without schemas (MySQL uses the current database, SQLite uses "main").
    var schema: String?
    var name: String

    var id: String { (schema.map { $0 + "." } ?? "") + name }
    var displayName: String { name }
}

enum TableKind: String, Sendable {
    case table
    case view
    case materializedView
    /// A MongoDB collection.
    case collection
    /// The keys of one Redis database, browsed as a single table.
    case keys
    /// A Meilisearch index.
    case searchIndex

    var symbolName: String {
        switch self {
        case .table: "tablecells"
        case .view: "eye"
        case .materializedView: "eye.square"
        case .collection: "doc.on.doc"
        case .keys: "key"
        case .searchIndex: "doc.text.magnifyingglass"
        }
    }
}

struct TableInfo: Hashable, Sendable, Identifiable {
    var ref: TableRef
    var kind: TableKind
    var id: String { ref.id }
}

struct SchemaInfo: Hashable, Sendable, Identifiable {
    var name: String
    var tables: [TableInfo]
    var id: String { name }
}

struct ColumnInfo: Hashable, Sendable, Identifiable {
    var name: String
    var dataType: String
    var isNullable: Bool
    var defaultValue: String?
    var isPrimaryKey: Bool
    var comment: String?
    var id: String { name }
}

struct IndexInfo: Hashable, Sendable, Identifiable {
    var name: String
    var columns: [String]
    var isUnique: Bool
    var isPrimary: Bool
    var definition: String?
    var id: String { name }
}

struct ForeignKeyInfo: Hashable, Sendable, Identifiable {
    var name: String
    var columns: [String]
    var referencedTable: TableRef
    var referencedColumns: [String]
    var onUpdate: String?
    var onDelete: String?
    var id: String { name }
}

struct TableStructure: Sendable {
    var columns: [ColumnInfo]
    var indexes: [IndexInfo]
    var foreignKeys: [ForeignKeyInfo]
    /// CREATE statement when the engine can produce one cheaply.
    var ddl: String?

    var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
}

/// One table of the relationship diagram: its columns and the foreign keys it holds.
struct DiagramTable: Hashable, Sendable, Identifiable {
    var ref: TableRef
    var columns: [ColumnInfo]
    var foreignKeys: [ForeignKeyInfo]
    var id: String { ref.id }
}

// MARK: - Results

/// A single cell. nil means SQL NULL. Binary data is rendered as a hex string ("\\x0a1b…").
typealias CellValue = String?

struct QueryResult: Sendable, Identifiable {
    var id = UUID()
    /// The statement that produced this result.
    var statement: String
    var columns: [String]
    var rows: [[CellValue]]
    /// Rows affected for DML/DDL, when the driver knows it.
    var rowsAffected: Int?
    var duration: TimeInterval
    /// True when the driver stopped reading because `maxRows` was reached.
    var truncated: Bool = false
    /// Rows an UPDATE matched, when the driver reports it separately from `rowsAffected` (MySQL counts
    /// only rows it actually changed). nil when unknown or the same as `rowsAffected`.
    var rowsMatched: Int? = nil

    var isRowSet: Bool { !columns.isEmpty }

    var summary: String {
        let time = Self.format(duration)
        if isRowSet {
            let n = rows.count
            return "\(n.formatted()) row\(n == 1 ? "" : "s")\(truncated ? " (limited)" : "") in \(time)"
        }
        if let rowsAffected {
            return "\(rowsAffected.formatted()) row\(rowsAffected == 1 ? "" : "s") affected in \(time)"
        }
        return "Executed in \(time)"
    }

    static func format(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.2f s", t)
    }
}

struct DatabaseError: LocalizedError, Sendable {
    var message: String
    var detail: String?

    init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    var errorDescription: String? { message }
    var failureReason: String? { detail }
}

/// Sort applied to a browsed table (server side) or a query result (client side).
struct GridSort: Equatable, Sendable {
    var column: String
    var ascending: Bool
    /// Position of the sorted column among the result's columns, so a result with two columns of the same
    /// name (a join) sorts by the one that was clicked. nil when only the name is known; SQL sorts use the name.
    var columnIndex: Int? = nil

    /// Whether this sort is on the column `name` at `index`.
    func isOn(_ name: String, at index: Int) -> Bool {
        columnIndex.map { $0 == index } ?? (column == name)
    }

    /// The column to sort `columns` by: `columnIndex` when it still names that column, else the first match.
    func index(in columns: [String]) -> Int? {
        if let columnIndex, columnIndex < columns.count, columns[columnIndex] == column { return columnIndex }
        return columns.firstIndex(of: column)
    }
}
