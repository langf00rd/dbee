import AppKit
import Foundation
import Observation

enum SidebarSelection: Hashable {
    case table(TableRef)
    case query(UUID)
}

/// One editor tab in the query workspace. Lives in memory only.
@MainActor @Observable
final class QueryTab: Identifiable {
    let id = UUID()
    var title: String
    var sql: String
    var results: [QueryResult] = []
    var selectedResultID: QueryResult.ID?
    var errorMessage: String?
    var isRunning = false
    /// Index of the statement that failed, when running a script.
    var failedStatementRange: NSRange?

    init(title: String, sql: String = "") {
        self.title = title
        self.sql = sql
    }
}

struct HistoryEntry: Identifiable, Sendable {
    let id = UUID()
    var sql: String
    var date: Date
    var database: String
    var duration: TimeInterval?
    var succeeded: Bool
}

/// State for one connection window. Owns the driver and the optional SSH tunnel.
///
/// Privacy: the full `ConnectionConfig` (including secrets) is held in memory only while connected so the
/// user can switch databases / reconnect without retyping. It is wiped on disconnect and on deinit,
/// and is never written anywhere.
@MainActor @Observable
final class DatabaseSession {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
    }

    var phase: Phase = .idle
    private(set) var config: ConnectionConfig?
    private(set) var serverVersion = ""
    private(set) var databases: [String] = []
    private(set) var currentDatabase = ""
    private(set) var schemas: [SchemaInfo] = []
    private(set) var isLoadingSchema = false
    var schemaError: String?
    /// Set when the connection/tunnel dropped while connected.
    var connectionLost = false

    var selection: SidebarSelection?
    var queryTabs: [QueryTab] = []
    private(set) var history: [HistoryEntry] = []
    /// Per-table browser state so switching tables keeps page/filter/pending edits.
    var browserModels: [TableRef: TableBrowserModel] = [:]

    let settings = AppSettings.shared

    private var driver: (any DatabaseDriver)?
    private var tunnel: SSHTunnel?
    private var connectTask: Task<Void, Never>?
    private var queryCounter = 0

    var kind: DatabaseKind { config?.kind ?? .postgres }
    var dialect: SQLDialect { SQLDialect(kind: kind) }
    var isConnected: Bool { phase == .connected }
    var title: String { config?.displayName ?? "Dbee" }
    var subtitle: String {
        guard let config, isConnected else { return "" }
        var parts: [String] = []
        if config.kind != .sqlite, !currentDatabase.isEmpty { parts.append(currentDatabase) }
        if config.ssh.enabled { parts.append("via SSH") }
        if !serverVersion.isEmpty { parts.append(serverVersion) }
        return parts.joined(separator: " · ")
    }

    var allTables: [TableInfo] { schemas.flatMap(\.tables) }

    // MARK: Connecting

    /// Starts connecting. The caller should wipe its own copy of the secrets afterwards.
    func connect(_ newConfig: ConnectionConfig) {
        connectTask?.cancel()
        connectTask = Task { await performConnect(newConfig) }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        Task { await tearDown() }
        phase = .idle
    }

    private func performConnect(_ newConfig: ConnectionConfig) async {
        await tearDown()
        connectionLost = false
        do {
            var dialHost = newConfig.host
            var dialPort = newConfig.port
            if newConfig.kind.isNetworked && newConfig.ssh.enabled {
                phase = .connecting("Opening SSH tunnel to \(newConfig.ssh.host)…")
                let target = newConfig.host.trimmingCharacters(in: .whitespaces)
                let tunnel = try await SSHTunnel.open(
                    ssh: newConfig.ssh,
                    targetHost: target.isEmpty ? "127.0.0.1" : target,
                    targetPort: newConfig.port,
                    verifier: AlertHostKeyVerifier()
                )
                try Task.checkCancellation()
                self.tunnel = tunnel
                tunnel.onDisconnect { [weak self] in
                    Task { @MainActor in self?.handleConnectionLost() }
                }
                dialHost = "127.0.0.1"
                dialPort = tunnel.localPort
            }
            phase = .connecting("Connecting to \(newConfig.kind.displayName)…")
            let driver = try await DriverFactory.connect(config: newConfig, host: dialHost, port: dialPort)
            if Task.isCancelled {
                await driver.close()
                throw CancellationError()
            }
            self.driver = driver
            self.config = newConfig
            serverVersion = (try? await driver.serverVersion()) ?? ""
            currentDatabase = (try? await driver.currentDatabase()) ?? newConfig.database
            databases = (try? await driver.listDatabases()) ?? []
            phase = .connected
            if queryTabs.isEmpty { newQueryTab() }
            await refreshSchema()
        } catch is CancellationError {
            await tearDown()
            phase = .idle
        } catch {
            await tearDown()
            phase = .failed(Self.describe(error))
        }
    }

    private func handleConnectionLost() {
        guard isConnected else { return }
        connectionLost = true
    }

    /// Reconnects with the in-memory config (e.g. after the tunnel dropped). Keeps tabs.
    func reconnect() {
        guard let config else { return }
        connect(config)
    }

    func disconnect() async {
        connectTask?.cancel()
        await tearDown()
        config?.wipeSecrets()
        config = nil
        schemas = []
        databases = []
        currentDatabase = ""
        serverVersion = ""
        browserModels = [:]
        selection = nil
        history = []
        connectionLost = false
        phase = .idle
    }

    private func tearDown() async {
        let driver = self.driver
        let tunnel = self.tunnel
        self.driver = nil
        self.tunnel = nil
        await driver?.close()
        await tunnel?.close()
    }

    /// Switches the active database. Postgres requires a new connection (reusing the tunnel's
    /// config), MySQL issues USE.
    func switchDatabase(_ name: String) async {
        guard var config, name != currentDatabase else { return }
        switch config.kind {
        case .mysql:
            do {
                _ = try await execute("USE \(dialect.quoteIdentifier(name))", recordHistory: false)
                currentDatabase = name
                self.config?.database = name
                browserModels = [:]
                selection = selection.flatMap { if case .query = $0 { $0 } else { nil } }
                await refreshSchema()
            } catch {
                schemaError = Self.describe(error)
            }
        case .postgres:
            config.database = name
            browserModels = [:]
            selection = selection.flatMap { if case .query = $0 { $0 } else { nil } }
            connect(config)
        case .sqlite:
            break
        }
    }

    // MARK: Schema

    func refreshSchema() async {
        guard let driver else { return }
        isLoadingSchema = true
        defer { isLoadingSchema = false }
        do {
            schemas = try await driver.listSchemas()
            schemaError = nil
        } catch {
            schemaError = Self.describe(error)
        }
    }

    func structure(of table: TableRef) async throws -> TableStructure {
        guard let driver else { throw DatabaseError("Not connected") }
        return try await driver.tableStructure(table)
    }

    func browserModel(for table: TableRef) -> TableBrowserModel {
        if let model = browserModels[table] { return model }
        let model = TableBrowserModel(session: self, table: table)
        browserModels[table] = model
        return model
    }

    // MARK: Executing

    /// Executes one statement on the session's connection.
    func execute(_ sql: String, maxRows: Int? = nil, recordHistory: Bool = true) async throws -> QueryResult {
        guard let driver else { throw DatabaseError("Not connected") }
        let start = Date()
        do {
            let result = try await driver.execute(sql, maxRows: maxRows ?? settings.maxQueryRows)
            if recordHistory { record(sql, duration: result.duration, succeeded: true) }
            return result
        } catch {
            if recordHistory { record(sql, duration: Date().timeIntervalSince(start), succeeded: false) }
            throw error
        }
    }

    /// Runs several statements in order inside one transaction; rolls back on the first failure.
    /// Used to commit table edits.
    func executeInTransaction(_ statements: [String]) async throws {
        guard !statements.isEmpty else { return }
        _ = try await execute(dialect.beginTransaction, recordHistory: false)
        do {
            for statement in statements {
                _ = try await execute(statement)
            }
            _ = try await execute(dialect.commit, recordHistory: false)
        } catch {
            _ = try? await execute(dialect.rollback, recordHistory: false)
            throw error
        }
    }

    /// Splits `sql` into statements and runs them one after another in `tab`, stopping at the first error.
    /// `baseOffset` is the UTF-16 offset of `sql` within the tab's full text (for error highlighting).
    func run(_ sql: String, in tab: QueryTab, baseOffset: Int = 0) async {
        guard !tab.isRunning else { return }
        let statements = SQLSplitter.split(sql, kind: kind)
        guard !statements.isEmpty else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        tab.failedStatementRange = nil
        var results: [QueryResult] = []
        var schemaMayHaveChanged = false
        for statement in statements {
            if Task.isCancelled { break }
            do {
                let result = try await execute(statement.text)
                results.append(result)
                if Self.isSchemaChanging(statement.text) { schemaMayHaveChanged = true }
            } catch {
                tab.errorMessage = Self.describe(error)
                tab.failedStatementRange = NSRange(location: statement.range.location + baseOffset, length: statement.range.length)
                break
            }
        }
        tab.results = results
        tab.selectedResultID = results.last(where: \.isRowSet)?.id ?? results.last?.id
        tab.isRunning = false
        if schemaMayHaveChanged { await refreshSchema() }
    }

    func cancelRunningQuery() async {
        await driver?.cancelCurrentQuery()
    }

    // MARK: Query tabs

    @discardableResult
    func newQueryTab(sql: String = "") -> QueryTab {
        queryCounter += 1
        let tab = QueryTab(title: "Query \(queryCounter)", sql: sql)
        queryTabs.append(tab)
        selection = .query(tab.id)
        return tab
    }

    func closeQueryTab(_ id: UUID) {
        queryTabs.removeAll { $0.id == id }
        if selection == .query(id) {
            selection = queryTabs.last.map { .query($0.id) }
        }
    }

    func queryTab(_ id: UUID) -> QueryTab? { queryTabs.first { $0.id == id } }

    // MARK: History

    private func record(_ sql: String, duration: TimeInterval?, succeeded: Bool) {
        guard settings.keepQueryHistory else { return }
        history.insert(HistoryEntry(sql: sql, date: Date(), database: currentDatabase, duration: duration, succeeded: succeeded), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    func clearHistory() { history = [] }

    // MARK: Helpers

    static func isSchemaChanging(_ sql: String) -> Bool {
        let head = sql.drop(while: { $0.isWhitespace }).prefix(10).uppercased()
        return ["CREATE", "DROP", "ALTER", "RENAME", "TRUNCATE"].contains { head.hasPrefix($0) }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DatabaseError {
            return [e.message, e.detail].compactMap { $0 }.joined(separator: "\n")
        }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

/// Shows an NSAlert asking the user to trust an SSH host key. Nothing is remembered between connections.
struct AlertHostKeyVerifier: HostKeyVerifier {
    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            let hostLabel = port == 22 ? host : "[\(host)]:\(port)"
            switch knownHostsStatus {
            case .mismatch:
                alert.alertStyle = .critical
                alert.messageText = "The host key for \(hostLabel) has changed"
                alert.informativeText = """
                The key offered by the server does not match the one in ~/.ssh/known_hosts. \
                Someone could be intercepting this connection.

                \(keyType) key fingerprint:
                \(fingerprint)
                """
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Connect Anyway")
                return alert.runModal() == .alertSecondButtonReturn
            case .unknown, .trusted:
                alert.alertStyle = .warning
                alert.messageText = "Trust the host key for \(hostLabel)?"
                alert.informativeText = """
                This server isn't in ~/.ssh/known_hosts. Verify the fingerprint with your server before continuing. \
                Dbee won't remember this decision.

                \(keyType) key fingerprint:
                \(fingerprint)
                """
                alert.addButton(withTitle: "Connect")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
    }
}
