import AppKit
import Foundation
import Observation

enum SidebarSelection: Hashable {
    case table(TableRef)
    case query(UUID)
    /// The relationship diagram of the schema with this name.
    case diagram(String)
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
    /// Not observed: `browserModel(for:)` fills it lazily from view bodies, which must not invalidate the view.
    @ObservationIgnored var browserModels: [TableRef: TableBrowserModel] = [:]
    /// Relationship diagrams by schema name, kept so a rearranged layout survives switching to a table and back.
    @ObservationIgnored var diagramModels: [String: RelationshipDiagramModel] = [:]

    let settings = AppSettings.shared
    /// Asks the user to trust unknown SSH host keys. Replaceable so tests can run without a modal alert.
    var hostKeyVerifier: any HostKeyVerifier = AlertHostKeyVerifier()
    /// The window showing this session, so prompts can be sheets on it. Set by the window's view.
    @ObservationIgnored weak var window: NSWindow?

    private var driver: (any DatabaseDriver)?
    private var tunnel: SSHTunnel?
    private var connectTask: Task<Void, Never>?
    /// Bumped by every connect, cancel and disconnect; see `performConnect`.
    private var connectGeneration = 0
    /// Bumped by every schema refresh and disconnect; see `refreshSchema`.
    private var schemaGeneration = 0
    private var queryCounter = 0

    /// Serializes use of the connection across statements; see `withExclusiveConnection`.
    @ObservationIgnored private let lease = ConnectionLease()
    /// Bumped whenever the connection is replaced or closed, or its current database changes. Work captures
    /// it when submitted and is refused if it changed before the work got the connection, so a statement
    /// queued for one database never runs on another; see `withLease`.
    @ObservationIgnored private var contextEpoch = 0
    /// Each query tab's running script, so Stop and closing the tab reach it; see `startRun`.
    @ObservationIgnored private var queryTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// The query tab whose statement holds the lease, so Stop only interrupts that tab's own statement.
    @ObservationIgnored private var leaseOwner: UUID?
    /// Whether a query tab left a transaction open (BEGIN without COMMIT/ROLLBACK). Only consulted when
    /// the driver can't tell (`DatabaseDriver.isInTransaction` is nil).
    @ObservationIgnored private var userTransactionOpen = false
    /// SSH host keys the user accepted while this session is connected ("host:port fingerprint"), so a
    /// reconnect doesn't ask again for the same key. Memory only; cleared on disconnect.
    @ObservationIgnored private var acceptedHostKeys: Set<String> = []

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
        connectGeneration += 1
        let generation = connectGeneration
        connectTask = Task { await performConnect(newConfig, generation: generation) }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        Task { await tearDown() }
        phase = .idle
    }

    /// Each attempt carries the generation it was started with. Once a newer `connect`, `cancelConnect`
    /// or `disconnect` bumps the counter, a stale attempt only closes what it opened itself and never
    /// touches the session's state, so it can't clobber the connection that replaced it.
    private func performConnect(_ newConfig: ConnectionConfig, generation: Int) async {
        await tearDown()
        guard generation == connectGeneration else { return }
        connectionLost = false
        var openedTunnel: SSHTunnel?
        var openedDriver: (any DatabaseDriver)?
        do {
            var dialHost = newConfig.host
            var dialPort = newConfig.port
            if newConfig.kind.isNetworked && newConfig.ssh.enabled {
                phase = .connecting("Opening SSH tunnel to \(newConfig.ssh.host)…")
                let target = newConfig.host.trimmingCharacters(in: .whitespaces)
                (hostKeyVerifier as? AlertHostKeyVerifier)?.prepare(window: window ?? NSApp.keyWindow,
                                                                    connectionName: newConfig.displayName)
                let tunnel = try await SSHTunnel.open(
                    ssh: newConfig.ssh,
                    targetHost: target.isEmpty ? "127.0.0.1" : target,
                    targetPort: newConfig.port,
                    verifier: SessionPinningVerifier(base: hostKeyVerifier, accepted: acceptedHostKeys) { [weak self] key in
                        self?.acceptedHostKeys.insert(key)
                    }
                )
                openedTunnel = tunnel
                // Only the driver's own connections may use the tunnel, not any other process on this Mac.
                tunnel.restrictLocalConnections()
                try ensureCurrent(generation)
                dialHost = "127.0.0.1"
                dialPort = tunnel.localPort
            }
            phase = .connecting("Connecting to \(newConfig.kind.displayName)…")
            let driver: any DatabaseDriver
            do {
                driver = try await DriverFactory.connect(config: newConfig, host: dialHost, port: dialPort,
                                                         transport: openedTunnel.map(DriverTransport.through) ?? .direct)
            } catch let error where !(error is CancellationError) {
                // Through a tunnel the driver often only sees "connection closed"; the SSH server's reason is clearer.
                if let reason = openedTunnel?.lastForwardingFailure {
                    throw DatabaseError(reason, detail: Self.describe(error))
                }
                throw error
            }
            openedDriver = driver
            try ensureCurrent(generation)

            self.tunnel = openedTunnel
            self.driver = driver
            contextEpoch += 1
            self.config = newConfig
            userTransactionOpen = false
            if let tunnel = openedTunnel {
                tunnel.onDisconnect { [weak self, weak tunnel] in
                    Task { @MainActor in
                        guard let self, let tunnel, self.tunnel === tunnel else { return }
                        self.handleConnectionLost()
                    }
                }
            }
            openedTunnel = nil
            openedDriver = nil

            let version = (try? await driver.serverVersion()) ?? ""
            let current = (try? await driver.currentDatabase()) ?? newConfig.database
            let names = (try? await driver.listDatabases()) ?? []
            guard generation == connectGeneration else { return }
            serverVersion = version
            currentDatabase = current
            databases = names
            phase = .connected
            if queryTabs.isEmpty {
                newQueryTab()
            } else if selection == nil, let first = queryTabs.first {
                selection = .query(first.id)
            }
            await refreshSchema()
        } catch {
            await openedDriver?.close()
            await openedTunnel?.close()
            guard generation == connectGeneration else { return }
            await tearDown()
            if error is CancellationError || Task.isCancelled {
                phase = .idle
            } else {
                phase = .failed(Self.describe(error))
            }
        }
    }

    private func ensureCurrent(_ generation: Int) throws {
        if Task.isCancelled || generation != connectGeneration { throw CancellationError() }
    }

    /// Called for the session's current tunnel only (checked by the caller).
    private func handleConnectionLost() {
        guard config != nil else { return }
        connectionLost = true
    }

    /// Reconnects with the in-memory config (e.g. after the tunnel dropped). Keeps tabs.
    func reconnect() {
        guard let config else { return }
        connect(config)
    }

    func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        schemaGeneration += 1
        await tearDown()
        config?.wipeSecrets()
        config = nil
        acceptedHostKeys = []
        userTransactionOpen = false
        schemas = []
        schemaError = nil
        isLoadingSchema = false
        databases = []
        currentDatabase = ""
        serverVersion = ""
        browserModels = [:]
        diagramModels = [:]
        selection = nil
        history = []
        // Tabs keep their SQL for the next connection, but no data read from this server outlives it.
        for tab in queryTabs {
            tab.results = []
            tab.selectedResultID = nil
            tab.errorMessage = nil
            tab.failedStatementRange = nil
        }
        connectionLost = false
        phase = .idle
    }

    /// Wipes the in-memory secrets right away, without waiting for the connection to close.
    /// Used when quitting, so the wipe never depends on a server or tunnel answering.
    func wipeSecrets() {
        config?.wipeSecrets()
        acceptedHostKeys = []
    }

    private func tearDown() async {
        let driver = self.driver
        let tunnel = self.tunnel
        self.driver = nil
        self.tunnel = nil
        contextEpoch += 1
        // Their statements were meant for this connection; anything not yet sent must not reach the next one.
        for (_, entry) in queryTasks { entry.task.cancel() }
        await driver?.close()
        await tunnel?.close()
    }

    /// Switches the active database. MySQL issues USE. Postgres needs a new connection: it is opened
    /// first (through the existing SSH tunnel, if any) and only replaces the current one once it works,
    /// so a database the user can't open leaves the working connection alone.
    func switchDatabase(_ name: String) async {
        guard let config, name != currentDatabase else { return }
        switch config.kind {
        case .mysql, .clickhouse:
            do {
                let use = "USE \(dialect.quoteIdentifier(name))"
                try await withLease { driver in
                    _ = try await driver.execute(use, maxRows: 0)
                    contextEpoch += 1
                }
                currentDatabase = name
                self.config?.database = name
                databaseDidChange()
                await refreshSchema()
            } catch {
                schemaError = Self.describe(error)
            }
        case .postgres:
            await switchPostgresDatabase(name, config: config)
        case .scylla, .redis, .mongodb:
            do {
                try await withLease { driver in
                    guard let driver = driver as? any CommandDriver else { return }
                    try await driver.useDatabase(name)
                    contextEpoch += 1
                }
                currentDatabase = (try? await withLease { try await $0.currentDatabase() }) ?? name
                self.config?.database = currentDatabase
                databaseDidChange()
                await refreshSchema()
            } catch {
                schemaError = Self.describe(error)
            }
        case .sqlite, .meilisearch:
            break
        }
    }

    private func switchPostgresDatabase(_ name: String, config: ConnectionConfig) async {
        var newConfig = config
        newConfig.database = name
        // Without a live connection (or with a dropped tunnel) there is nothing to keep: connect afresh.
        guard isConnected, !connectionLost, driver != nil, !config.ssh.enabled || tunnel != nil else {
            connect(newConfig)
            return
        }
        let generation = connectGeneration
        let dialHost = tunnel != nil ? "127.0.0.1" : config.host
        let dialPort = tunnel?.localPort ?? config.port
        let newDriver: any DatabaseDriver
        do {
            newDriver = try await DriverFactory.connect(config: newConfig, host: dialHost, port: dialPort,
                                                        transport: tunnel.map(DriverTransport.through) ?? .direct)
        } catch {
            guard generation == connectGeneration else { return }
            schemaError = "Couldn’t open \(name).\n" + Self.describe(error)
            return
        }
        // Swap under the lease so no statement or table commit is split across the two connections.
        do {
            try await lease.acquire()
        } catch {
            await newDriver.close()
            return
        }
        guard generation == connectGeneration, isConnected, driver != nil else {
            lease.release()
            await newDriver.close()
            return
        }
        let oldDriver = driver
        driver = newDriver
        contextEpoch += 1
        userTransactionOpen = false
        lease.release()
        await oldDriver?.close()

        self.config?.database = name
        currentDatabase = (try? await withLease { try await $0.currentDatabase() }) ?? name
        databaseDidChange()
        await refreshSchema()
    }

    /// Forgets everything tied to the previous database: browsed tables (their SQL is unqualified on
    /// MySQL, so it would now hit the new database) and a table selection.
    private func databaseDidChange() {
        browserModels = [:]
        diagramModels = [:]
        selection = selection.flatMap { if case .query = $0 { $0 } else { nil } }
    }

    /// Follows a query tab statement that changed the connection's current database (MySQL `USE` and
    /// `DROP DATABASE`, Redis `SELECT`, MongoDB `use`), so the sidebar, picker and table browser follow.
    private func adoptCurrentDatabase(_ name: String) async {
        guard name != currentDatabase else { return }
        currentDatabase = name
        config?.database = name
        databaseDidChange()
        await refreshSchema()
    }

    // MARK: Schema

    /// Only the latest refresh on the current driver updates `schemas`, `schemaError` and the spinner,
    /// so a refresh still running on a replaced or closed connection can't overwrite newer state.
    func refreshSchema() async {
        guard let driver else { return }
        schemaGeneration += 1
        let generation = schemaGeneration
        isLoadingSchema = true
        let outcome: Result<[SchemaInfo], Error>
        do {
            outcome = .success(try await withLease { current in
                guard current === driver else { throw CancellationError() }
                return try await current.listSchemas()
            })
        } catch {
            outcome = .failure(error)
        }
        guard generation == schemaGeneration else { return }
        isLoadingSchema = false
        guard self.driver === driver else { return }
        switch outcome {
        case .success(let loaded):
            schemas = loaded
            schemaError = nil
        case .failure(let error):
            schemaError = Self.describe(error)
        }
    }

    func structure(of table: TableRef) async throws -> TableStructure {
        try await withLease { try await $0.tableStructure(table) }
    }

    func diagramTables(in schema: SchemaInfo) async throws -> [DiagramTable] {
        try await withLease { try await $0.diagramTables(in: schema) }
    }

    func diagramModel(for schema: String) -> RelationshipDiagramModel {
        if let model = diagramModels[schema] { return model }
        let model = RelationshipDiagramModel(session: self, schema: schema)
        diagramModels[schema] = model
        return model
    }

    /// Whether the engine has foreign keys to draw.
    var supportsDiagram: Bool { kind.hasForeignKeys }

    /// Shows the relationship diagram of `schema`, or else of the selected table's schema, or the first one.
    func showDiagram(schema: String? = nil) {
        guard supportsDiagram, let name = schema ?? diagramSchemaForSelection else { return }
        selection = .diagram(name)
    }

    private var diagramSchemaForSelection: String? {
        switch selection {
        case .diagram(let name):
            return name
        case .table(let ref):
            if let owner = schemas.first(where: { $0.tables.contains { $0.ref == ref } }) { return owner.name }
        case .query, nil:
            break
        }
        return schemas.first?.name
    }

    /// One page of a Redis or MongoDB table, read by the driver (see `CommandDriver`).
    func page(of table: TableRef, filter: String?, sort: GridSort?, limit: Int, offset: Int) async throws -> QueryResult {
        try await withLease { driver in
            guard let driver = driver as? any CommandDriver else { throw DatabaseError("This connection can't page tables itself.") }
            return try await driver.page(of: table, filter: filter, sort: sort, limit: limit, offset: offset)
        }
    }

    /// Rows a Redis or MongoDB table filter matches, or nil when the driver can't count them.
    func rowCount(of table: TableRef, filter: String?) async throws -> Int? {
        try await withLease { driver in
            guard let driver = driver as? any CommandDriver else { return nil }
            return try await driver.count(of: table, filter: filter)
        }
    }

    func browserModel(for table: TableRef) -> TableBrowserModel {
        if let model = browserModels[table] { return model }
        let model = TableBrowserModel(session: self, table: table)
        browserModels[table] = model
        return model
    }

    // MARK: Executing

    /// Runs `body` with the connection to itself for one operation. Every statement the session sends goes
    /// through here, in FIFO order; `owner` names the query tab the statement belongs to, if any.
    /// The work is bound to the connection and database current when it was submitted (or to `epoch`,
    /// for a script's later statements): if either changed while it waited, it fails without sending anything.
    private func withLease<T>(owner: UUID? = nil, epoch: Int? = nil,
                              _ body: (any DatabaseDriver) async throws -> T) async throws -> T {
        let submitted = epoch ?? contextEpoch
        try await lease.acquire()
        defer { lease.release() }
        guard let driver else { throw DatabaseError("Not connected") }
        guard submitted == contextEpoch else {
            throw DatabaseError("The connection changed before this statement ran, so it wasn’t sent.",
                                detail: "Run it again if it should go to the current database.")
        }
        leaseOwner = owner
        defer { leaseOwner = nil }
        return try await body(driver)
    }

    /// Runs `body` with exclusive use of the connection: no other tab, table load or schema refresh can
    /// send a statement until it returns. `body` must use the driver it is given, never `execute`
    /// (which would wait for the lease forever). Fails if the connection was replaced meanwhile.
    func withExclusiveConnection<T>(_ body: (any DatabaseDriver) async throws -> T) async throws -> T {
        try await withLease { driver in
            let result = try await body(driver)
            guard self.driver === driver else {
                throw DatabaseError("The connection changed while the operation was running.",
                                    detail: "Check the data and try again.")
            }
            return result
        }
    }

    /// Executes one statement on the session's connection.
    func execute(_ sql: String, maxRows: Int? = nil, recordHistory: Bool = true) async throws -> QueryResult {
        try await execute(sql, maxRows: maxRows, recordHistory: recordHistory, owner: nil)
    }

    private func execute(_ sql: String, maxRows: Int?, recordHistory: Bool, owner: UUID?) async throws -> QueryResult {
        let start = Date()
        do {
            let limit = maxRows ?? settings.maxQueryRows
            let result = try await withLease(owner: owner) { try await $0.execute(sql, maxRows: limit) }
            if recordHistory { record(sql, duration: result.duration, succeeded: true) }
            return result
        } catch {
            if recordHistory { record(sql, duration: Date().timeIntervalSince(start), succeeded: false) }
            throw error
        }
    }

    /// One statement of a query tab's script, refused if the connection context moved off `epoch`. When the
    /// statement itself switched the database, that is detected while still holding the connection and the
    /// new epoch and database are returned, so the script's next statements follow its own switch while
    /// work other callers queued for the old database is refused.
    private func executeScriptStatement(_ sql: String, owner: UUID, epoch: Int)
        async throws -> (result: QueryResult, epoch: Int, database: String?) {
        let start = Date()
        let limit = settings.maxQueryRows
        let followsDatabase = Self.mayChangeDatabase(sql, kind: kind)
        do {
            let outcome = try await withLease(owner: owner, epoch: epoch) { driver -> (QueryResult, Int, String?) in
                let result = try await driver.execute(sql, maxRows: limit)
                guard followsDatabase, let name = try? await driver.currentDatabase(), name != currentDatabase else {
                    return (result, epoch, nil)
                }
                contextEpoch += 1
                return (result, contextEpoch, name)
            }
            record(sql, duration: outcome.0.duration, succeeded: true)
            return outcome
        } catch {
            record(sql, duration: Date().timeIntervalSince(start), succeeded: false)
            throw error
        }
    }

    /// Runs several statements in order inside one transaction, holding the connection throughout so no
    /// other tab's statement can land inside it. Rolls back on the first failure, including a failure
    /// thrown by `verify`, which sees each statement's result and may run checks on the same connection.
    /// Used to commit table edits. Refuses to start while a query tab has a transaction open, since
    /// BEGIN/COMMIT would silently end it.
    func executeInTransaction(
        _ statements: [String],
        verify: ((_ index: Int, _ result: QueryResult, _ driver: any DatabaseDriver) async throws -> Void)? = nil
    ) async throws {
        guard !statements.isEmpty else { return }
        let dialect = self.dialect
        let maxRows = settings.maxQueryRows
        try await withExclusiveConnection { driver in
            if await driver.isInTransaction ?? userTransactionOpen {
                throw DatabaseError(
                    "A transaction is open in a query tab.",
                    detail: "Commit or roll it back there first, then save these changes."
                )
            }
            _ = try await driver.execute(dialect.beginTransaction, maxRows: 0)
            do {
                for (index, statement) in statements.enumerated() {
                    let start = Date()
                    do {
                        let result = try await driver.execute(statement, maxRows: maxRows)
                        record(statement, duration: result.duration, succeeded: true)
                        try await verify?(index, result, driver)
                    } catch {
                        record(statement, duration: Date().timeIntervalSince(start), succeeded: false)
                        throw error
                    }
                }
                _ = try await driver.execute(dialect.commit, maxRows: 0)
            } catch {
                _ = try? await driver.execute(dialect.rollback, maxRows: 0)
                throw error
            }
        }
    }

    /// Starts running `sql` in `tab` as a task the session owns, so Stop and closing the tab can reach it.
    func startRun(_ sql: String, in tab: QueryTab, baseOffset: Int = 0) {
        let id = tab.id
        let token = UUID()
        let task = Task { @MainActor in
            await run(sql, in: tab, baseOffset: baseOffset)
            if queryTasks[id]?.token == token { queryTasks[id] = nil }
        }
        queryTasks[id] = (token, task)
    }

    /// Stops `tab`'s script: statements still waiting for the connection are dropped, and the one on the
    /// connection is interrupted if it is this tab's. Another tab's query or a table load keeps running.
    func stopRun(in tab: QueryTab) {
        queryTasks[tab.id]?.task.cancel()
        if leaseOwner == tab.id, let driver {
            Task { await driver.cancelCurrentQuery() }
        }
    }

    /// Splits `sql` into statements and runs them one after another in `tab`, stopping at the first error.
    /// `baseOffset` is the UTF-16 offset of `sql` within the tab's full text (for error highlighting).
    /// Every statement must reach the connection and database the script started on (or switched to itself).
    func run(_ sql: String, in tab: QueryTab, baseOffset: Int = 0) async {
        guard !tab.isRunning else { return }
        let statements = SQLSplitter.split(sql, kind: kind)
        guard !statements.isEmpty else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        tab.failedStatementRange = nil
        var results: [QueryResult] = []
        var schemaMayHaveChanged = false
        var epoch = contextEpoch
        for statement in statements {
            // A closed tab has no Stop button or results left, so its remaining statements don't run.
            if Task.isCancelled || !queryTabs.contains(where: { $0 === tab }) { break }
            do {
                let outcome = try await executeScriptStatement(statement.text, owner: tab.id, epoch: epoch)
                results.append(outcome.result)
                if Self.isSchemaChanging(statement.text, kind: kind) { schemaMayHaveChanged = true }
                trackTransaction(statement.text)
                if let database = outcome.database {
                    epoch = outcome.epoch
                    await adoptCurrentDatabase(database)
                }
            } catch {
                tab.errorMessage = error is CancellationError || Task.isCancelled ? "Query stopped" : Self.describe(error)
                tab.failedStatementRange = NSRange(location: statement.range.location + baseOffset, length: statement.range.length)
                break
            }
        }
        tab.results = results
        tab.selectedResultID = results.last(where: \.isRowSet)?.id ?? results.last?.id
        tab.isRunning = false
        if schemaMayHaveChanged {
            await refreshSchema()
            schemaDidChange()
        }
    }

    /// After DDL from a query tab: browsed tables may have lost columns or keys, or be gone. Every
    /// browser is marked stale, so it reloads when shown again and edits can't be committed against the
    /// old structure. Browsers (without pending edits) and the selection of tables that no longer exist
    /// are dropped.
    private func schemaDidChange() {
        for model in diagramModels.values { model.markStale() }
        guard schemaError == nil else {
            for model in browserModels.values { model.markStale() }
            return
        }
        let existing = Set(allTables.map(\.ref))
        for (ref, model) in browserModels {
            if !existing.contains(ref), !model.hasChanges {
                browserModels[ref] = nil
            } else {
                model.markStale()
            }
        }
        if case .table(let ref) = selection, !existing.contains(ref) {
            selection = queryTabs.last.map { .query($0.id) }
        }
        let schemaNames = Set(schemas.map(\.name))
        diagramModels = diagramModels.filter { schemaNames.contains($0.key) }
        if case .diagram(let name) = selection, !schemaNames.contains(name) {
            selection = queryTabs.last.map { .query($0.id) }
        }
    }

    /// Keeps `userTransactionOpen` in step with transaction statements the user runs.
    private func trackTransaction(_ sql: String) {
        guard kind.hasTransactions else { return }
        if let opens = Self.transactionEffect(sql, kind: kind) {
            userTransactionOpen = opens
        } else if kind == .mysql, Self.isSchemaChanging(sql) {
            // MySQL commits implicitly before DDL.
            userTransactionOpen = false
        }
    }

    /// Interrupts the statement `tab` is running, if it is the one on the connection right now.
    /// A statement still waiting for the connection is stopped by cancelling the tab's task instead.
    func cancelRunningQuery(in tab: QueryTab) async {
        guard leaseOwner == tab.id else { return }
        await driver?.cancelCurrentQuery()
    }

    /// Interrupts the query tab statement currently on the connection. Never interrupts table loads,
    /// counts, schema reads or a table commit. Prefer `cancelRunningQuery(in:)`, which also leaves
    /// other tabs alone.
    func cancelRunningQuery() async {
        guard leaseOwner != nil else { return }
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

    /// Closing a running tab stops it: its Stop button and results go away with it.
    func closeQueryTab(_ id: UUID) {
        if let tab = queryTab(id) { stopRun(in: tab) }
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

    /// Statements after which the sidebar and table browsers should be refreshed: DDL, for Redis and MongoDB
    /// the commands that create, drop or empty collections, indexes and databases, and for Meilisearch any
    /// request that changes indexes.
    static func isSchemaChanging(_ sql: String, kind: DatabaseKind = .postgres) -> Bool {
        switch kind {
        case .redis:
            let head = sql.split(whereSeparator: \.isWhitespace).first?.uppercased() ?? ""
            return ["FLUSHDB", "FLUSHALL", "SWAPDB"].contains(head)
        case .mongodb:
            let text = sql.replacingOccurrences(of: " ", with: "")
            let changes = [".drop(", ".insertOne(", ".insertMany(", ".insert(", ".createIndex(", ".dropIndex(",
                           ".renameCollection(", "db.createCollection(", "db.createView(", "db.dropDatabase(",
                           "{create:", "{drop:", "{\"create\":", "{\"drop\":", "db.runCommand("]
            return changes.contains { text.contains($0) }
        case .meilisearch:
            guard let request = try? MeilisearchRequest.parse(sql), request.method != "GET" else { return false }
            return request.target.hasPrefix("/indexes") || request.target.hasPrefix("/swap-indexes")
        default:
            let head = sql.drop(while: { $0.isWhitespace }).prefix(10).uppercased()
            return ["CREATE", "DROP", "ALTER", "RENAME", "TRUNCATE", "COMMENT", "ATTACH", "DETACH"].contains { head.hasPrefix($0) }
        }
    }

    /// Statements that can change the connection's current database.
    static func mayChangeDatabase(_ sql: String, kind: DatabaseKind) -> Bool {
        let words = sql.split(whereSeparator: \.isWhitespace).prefix(2).map { $0.uppercased() }
        switch kind {
        case .mysql:
            return mayChangeMySQLDatabase(sql)
        case .clickhouse:
            return words.first == "USE" || words == ["DROP", "DATABASE"]
        case .scylla:
            return words.first == "USE" || words == ["DROP", "KEYSPACE"]
        case .redis:
            // EXEC runs a SELECT queued inside MULTI.
            return words.first == "SELECT" || words.first == "EXEC"
        case .mongodb:
            return words.first == "USE" || sql.contains("dropDatabase")
        case .postgres, .sqlite, .meilisearch:
            return false
        }
    }

    /// MySQL statements that can change the connection's default database.
    static func mayChangeMySQLDatabase(_ sql: String) -> Bool {
        if MySQLFormatting.isUseStatement(sql) { return true }
        let words = sql.split(whereSeparator: \.isWhitespace).prefix(2).map { $0.uppercased() }
        return words == ["DROP", "DATABASE"] || words == ["DROP", "SCHEMA"]
    }

    /// true when `sql` opens a transaction, false when it ends one, nil otherwise.
    /// `ROLLBACK TO [SAVEPOINT]` and `COMMIT`/`ROLLBACK ... AND CHAIN` keep the transaction open.
    static func transactionEffect(_ sql: String, kind: DatabaseKind) -> Bool? {
        let words = sql.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).map { $0.uppercased() }
        guard let first = words.first else { return nil }
        let isChained = words.suffix(2) == ["AND", "CHAIN"] && !words.contains("NO")
        switch first {
        case "BEGIN":
            // Postgres DO blocks and MySQL routines are split as whole statements, so a bare BEGIN here
            // is always a transaction start (BEGIN, BEGIN WORK, BEGIN IMMEDIATE…).
            return true
        case "START":
            return words.dropFirst().first == "TRANSACTION" ? true : nil
        case "COMMIT", "END":
            if first == "END", kind == .mysql { return nil }
            return isChained ? nil : false
        case "ABORT":
            return kind == .postgres ? false : nil
        case "ROLLBACK":
            if words.dropFirst().contains("TO") { return nil }
            return isChained ? nil : false
        default:
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DatabaseError {
            return [e.message, e.detail].compactMap { $0 }.joined(separator: "\n")
        }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

/// FIFO lock over a session's single connection. Unlike the drivers' own serialization (one statement at
/// a time), a holder can keep it across several statements, e.g. BEGIN … COMMIT. A waiter whose task is
/// cancelled leaves the queue with `CancellationError`.
@MainActor
final class ConnectionLease {
    private var isHeld = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        guard isHeld else {
            try Task.checkCancellation()
            isHeld = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.removeWaiter(id) }
        }
    }

    /// Hands the lease to the next waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func removeWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Wraps the session's verifier so a host key the user already accepted for this session (same host,
/// port and fingerprint, still not in known_hosts) is accepted again on reconnect without asking.
/// Nothing is written anywhere; the session forgets these keys on disconnect.
struct SessionPinningVerifier: HostKeyVerifier {
    let base: any HostKeyVerifier
    let accepted: Set<String>
    let onAccept: @MainActor @Sendable (String) -> Void

    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool {
        let id = "\(host.lowercased()):\(port) \(fingerprint)"
        guard knownHostsStatus == .unknown else {
            return await base.confirmHostKey(host: host, port: port, keyType: keyType, fingerprint: fingerprint,
                                              knownHostsStatus: knownHostsStatus)
        }
        if accepted.contains(id) { return true }
        let trusted = await base.confirmHostKey(host: host, port: port, keyType: keyType, fingerprint: fingerprint,
                                                knownHostsStatus: knownHostsStatus)
        if trusted { await onAccept(id) }
        return trusted
    }

    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownKeyTypes: [String]) async -> Bool {
        let id = "\(host.lowercased()):\(port) \(fingerprint) other:\(knownKeyTypes.joined(separator: ","))"
        if accepted.contains(id) { return true }
        let trusted = await base.confirmHostKey(host: host, port: port, keyType: keyType, fingerprint: fingerprint,
                                                knownKeyTypes: knownKeyTypes)
        if trusted { await onAccept(id) }
        return trusted
    }
}

/// Asks the user to trust an unknown SSH host key, as a sheet on the session's window when there is one.
/// A key that conflicts with ~/.ssh/known_hosts (changed or `@revoked`) is refused, as OpenSSH does,
/// with an explanation instead of an override. Decisions last only for the session window.
@MainActor
final class AlertHostKeyVerifier: HostKeyVerifier {
    private weak var window: NSWindow?
    private var connectionName = ""

    /// Called before each connection attempt with the window to attach the prompt to.
    func prepare(window: NSWindow?, connectionName: String) {
        self.window = window
        self.connectionName = connectionName
    }

    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool {
        let alert = NSAlert()
        let hostLabel = port == 22 ? host : "[\(host)]:\(port)"
        let connection = connectionName.isEmpty || connectionName == host ? "" : " for “\(connectionName)”"
        guard knownHostsStatus == .unknown || knownHostsStatus == .trusted else {
            alert.alertStyle = .critical
            alert.messageText = "Dbee refused to connect to \(hostLabel)"
            alert.informativeText = """
            The host key offered by the server doesn’t match ~/.ssh/known_hosts: the key listed there is \
            different, or this key is marked @revoked. Someone could be intercepting this connection\(connection).

            If the server’s key really changed, remove the old entry with:
            ssh-keygen -R \(port == 22 ? host : "'[\(host)]:\(port)'")
            then connect again and check the new fingerprint.

            \(keyType) key fingerprint:
            \(fingerprint)
            """
            alert.addButton(withTitle: "OK")
            _ = await present(alert)
            return false
        }
        alert.alertStyle = .warning
        alert.messageText = "Trust the host key for \(hostLabel)?"
        alert.informativeText = """
        This server isn't in ~/.ssh/known_hosts. Verify the fingerprint with your server before \
        continuing\(connection). Dbee remembers this decision only until you disconnect.

        \(keyType) key fingerprint:
        \(fingerprint)
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    /// known_hosts has this host only under other key types. OpenSSH treats that as suspicious, so the
    /// alert is critical and Cancel is the default button.
    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownKeyTypes: [String]) async -> Bool {
        let alert = NSAlert()
        let hostLabel = port == 22 ? host : "[\(host)]:\(port)"
        let connection = connectionName.isEmpty || connectionName == host ? "" : " (“\(connectionName)”)"
        alert.alertStyle = .critical
        alert.messageText = "~/.ssh/known_hosts has a different type of key for \(hostLabel)"
        alert.informativeText = """
        known_hosts lists a \(knownKeyTypes.joined(separator: ", ")) key for this host\(connection), but the \
        server offered a \(keyType) key. Verify the fingerprint before continuing. Dbee remembers this \
        decision only until you disconnect.

        \(keyType) key fingerprint:
        \(fingerprint)
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Connect")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return await present(alert) == .alertSecondButtonReturn
    }

    /// A sheet on the session's window; app-modal only when there is no window to attach to.
    /// Cancelling the connection attempt dismisses the sheet as Cancel.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return alert.runModal() }
        let box = SheetBox(window: window, alert: alert)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in box.window.endSheet(box.alert.window, returnCode: .cancel) }
        }
    }

    /// Carries the sheet's window and alert into the cancellation handler; only touched on the main actor.
    private struct SheetBox: @unchecked Sendable {
        let window: NSWindow
        let alert: NSAlert
    }
}
