import Foundation
import Logging
import Testing
@testable import Dbee

@MainActor
@Suite struct AppShellTests {
    // MARK: Sidebar sections

    private func table(_ name: String, schema: String? = nil, kind: TableKind = .table) -> TableInfo {
        TableInfo(ref: TableRef(schema: schema, name: name), kind: kind)
    }

    @Test func sectionsSortSchemasAndTablesInFinderOrder() {
        let schemas = [
            SchemaInfo(name: "public", tables: [table("table10", schema: "public"), table("Accounts", schema: "public"), table("table2", schema: "public"), table("accounts_log", schema: "public")]),
            SchemaInfo(name: "audit", tables: [table("events", schema: "audit")]),
        ]
        let sections = SidebarSchemaSection.sorted(schemas)
        #expect(sections.map(\.id) == ["audit", "public"])
        #expect(sections[1].tables.map(\.ref.name) == ["Accounts", "accounts_log", "table2", "table10"])
    }

    @Test func singleSectionTitleOnlyReplacesALoneSection() {
        let one = SidebarSchemaSection.sorted([SchemaInfo(name: "main", tables: [])], singleSectionTitle: "app.sqlite")
        #expect(one.map(\.title) == ["app.sqlite"])
        #expect(one.map(\.id) == ["main"])

        let two = SidebarSchemaSection.sorted(
            [SchemaInfo(name: "a", tables: []), SchemaInfo(name: "b", tables: [])],
            singleSectionTitle: "ignored"
        )
        #expect(two.map(\.title) == ["a", "b"])
    }

    @Test func filterIsCaseAndDiacriticInsensitiveAndDropsEmptySections() {
        let sections = SidebarSchemaSection.sorted([
            SchemaInfo(name: "public", tables: [table("Users", schema: "public"), table("orders", schema: "public"), table("café_menu", schema: "public")]),
            SchemaInfo(name: "audit", tables: [table("events", schema: "audit")]),
        ])
        let users = SidebarSchemaSection.filtered(sections, by: "USER")
        #expect(users.map(\.id) == ["public"])
        #expect(users.first?.tables.map(\.ref.name) == ["Users"])

        let cafe = SidebarSchemaSection.filtered(sections, by: " cafe ")
        #expect(cafe.first?.tables.map(\.ref.name) == ["café_menu"])

        #expect(SidebarSchemaSection.filtered(sections, by: "nothing-matches").isEmpty)
        #expect(SidebarSchemaSection.filtered(sections, by: "  ") == sections)
    }

    @Test func filteringFiveThousandTablesIsFast() {
        let tables = (0..<5_000).map { table("table_\($0)", schema: "public") }
        let sections = SidebarSchemaSection.sorted([SchemaInfo(name: "public", tables: tables.shuffled())])
        #expect(sections.first?.tables.first?.ref.name == "table_0")
        #expect(sections.first?.tables.last?.ref.name == "table_4999")
        let start = Date()
        let filtered = SidebarSchemaSection.filtered(sections, by: "_42")
        #expect(Date().timeIntervalSince(start) < 0.25)
        #expect(filtered.first?.tables.count == 111) // _42, _420…_429, _4200…_4299
    }

    // MARK: Destructive actions

    @Test func tableActionsUseTheDialect() {
        let users = table("users", schema: "public")
        let postgres = SQLDialect(kind: .postgres)
        #expect(SidebarTableAction.truncate(users).sql(postgres) == postgres.truncate(users.ref))
        #expect(SidebarTableAction.drop(users).sql(postgres) == postgres.drop(users.ref, kind: .table))

        let view = table("active_users", kind: .view)
        let mysql = SQLDialect(kind: .mysql)
        #expect(SidebarTableAction.drop(view).sql(mysql) == mysql.drop(view.ref, kind: .view))
        #expect(SidebarTableAction.drop(view).menuTitle == "Drop View…")
        #expect(SidebarTableAction.drop(view).confirmButtonTitle == "Drop View")
        #expect(SidebarTableAction.drop(users).menuTitle == "Drop Table…")
        #expect(SidebarTableAction.truncate(users).confirmationTitle.contains("users"))
        #expect(SidebarTableAction.truncate(users).id != SidebarTableAction.drop(users).id)
    }

    // MARK: Connection footer

    private var secretConfig: ConnectionConfig {
        var config = ConnectionConfig()
        config.username = "alice_user"
        config.password = "s3cret-pw"
        config.ssh.username = "deploy_user"
        config.ssh.password = "ssh-pw"
        config.ssh.passphrase = "key-passphrase"
        config.ssh.privateKeyPath = "/Users/alice/.ssh/id_ed25519"
        return config
    }

    @Test func footerNeverShowsCredentials() {
        var config = secretConfig
        config.kind = .postgres
        config.host = "db.example.com"
        config.ssh.enabled = true
        config.ssh.host = "vps.example.com"
        let summary = ConnectionSummary(config: config)
        let text = [summary.location, summary.detail, summary.accessibilityLabel].joined(separator: "|")
        for secret in ["alice_user", "s3cret-pw", "deploy_user", "ssh-pw", "key-passphrase", "id_ed25519"] {
            #expect(!text.contains(secret))
        }
    }

    @Test func footerDescribesTransport() {
        var config = secretConfig
        config.kind = .postgres
        config.host = "127.0.0.1"
        config.port = 5432
        config.ssh.enabled = true
        config.ssh.host = "vps.example.com"
        var summary = ConnectionSummary(config: config)
        #expect(summary.location == "vps.example.com")
        #expect(summary.security == .sshTunnel)

        config.ssh.enabled = false
        config.kind = .mysql
        config.host = "db.example.com"
        config.port = 3307
        config.tls = .verifyFull
        summary = ConnectionSummary(config: config)
        #expect(summary.location == "db.example.com:3307")
        #expect(summary.security == .tlsVerified)
        #expect(summary.symbolName == DatabaseKind.mysql.symbolName)

        config.tls = .required
        #expect(ConnectionSummary(config: config).security == .tlsUnverified)
        config.tls = .preferred
        #expect(ConnectionSummary(config: config).security == nil)

        var sqlite = ConnectionConfig()
        sqlite.kind = .sqlite
        sqlite.filePath = "/tmp/data/app.sqlite"
        let file = ConnectionSummary(config: sqlite)
        #expect(file.location == "app.sqlite")
        #expect(file.security == nil)
    }

    // MARK: Session registry and privacy bootstrap

    @Test func registryHoldsSessionsWeaklyAndOnce() async {
        let registry = SessionRegistry()
        let kept = DatabaseSession()
        registry.register(kept)
        registry.register(kept)
        do {
            let transient = DatabaseSession()
            registry.register(transient)
            #expect(registry.sessions.count == 2)
        }
        #expect(registry.sessions.count == 1)
        #expect(registry.sessions.first === kept)
        #expect(!kept.holdsConnectionState)
        #expect(!kept.hasUncommittedTableChanges)

        await registry.disconnectAll(timeout: .seconds(1))
        #expect(kept.phase == .idle)
        #expect(kept.config == nil)
    }

    /// Quitting waits at most `timeout` for disconnects, however long they take.
    @Test func disconnectWaitIsBoundedByTimeout() async {
        let slow = Task { _ = try? await Task.sleep(for: .seconds(2)) }
        let start = ContinuousClock.now
        await SessionRegistry.waitForAll([slow], timeout: .milliseconds(200))
        // Well under the 2 s task, with slack for a busy main actor while the rest of the suite runs.
        #expect(ContinuousClock.now - start < .milliseconds(1800))
        slow.cancel()

        let quick = Task {}
        let quickStart = ContinuousClock.now
        await SessionRegistry.waitForAll([quick], timeout: .seconds(5))
        #expect(ContinuousClock.now - quickStart < .seconds(1))
    }

    @Test func privacyBootstrapIsIdempotentAndSilencesLogging() {
        PrivacyBootstrap.run()
        PrivacyBootstrap.run()
        #expect(URLCache.shared.memoryCapacity == 0)
        #expect(URLCache.shared.diskCapacity == 0)
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered["ApplePersistenceIgnoreState"] as? Bool == true)
        #expect(registered["NSQuitAlwaysKeepsWindows"] as? Bool == false)
        #expect(Logger(label: "dbee.test").handler is SwiftLogNoOpLogHandler)
    }
}
