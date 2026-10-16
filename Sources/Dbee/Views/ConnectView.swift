import AppKit
import SwiftUI

/// The connection screen shown while a window's session isn't connected: an optional favorites sidebar
/// next to a grouped form. Credentials typed here live only in this view's state; they are wiped after a
/// successful connect and whenever the view goes away.
struct ConnectView: View {
    @Bindable var session: DatabaseSession

    @State private var config = ConnectionConfig()
    @State private var selection: SidebarItem? = .newConnection
    @State private var localError: String?
    @State private var notice: String?
    @State private var renameTarget: SavedConnection?
    @State private var renameText = ""
    /// "Remember with Touch ID" for the favorite being edited or saved.
    @State private var rememberLogin = false
    /// Non-nil while the Touch ID prompt for a saved login is up.
    @State private var unlockingFavorite: SavedConnection.ID?
    @FocusState private var focus: Field?

    private var settings: AppSettings { .shared }
    private var store: FavoritesStore { .shared }
    private var logins: LoginVault { .shared }

    enum SidebarItem: Hashable {
        case newConnection
        case favorite(SavedConnection.ID)
    }

    enum Field: Hashable {
        case name, host, port, database, user, password
        case filePath
        case sshHost, sshPort, sshUser, sshPassword, sshKey, sshPassphrase
    }

    var body: some View {
        Group {
            if settings.allowFavorites {
                NavigationSplitView {
                    sidebar
                } detail: {
                    form
                }
            } else {
                form
            }
        }
        .frame(minWidth: settings.allowFavorites ? 680 : 480, idealWidth: 760, minHeight: 500, idealHeight: 560)
        .navigationTitle(selectedFavorite?.name ?? "New Connection")
        .onAppear(perform: prefillFromSession)
        .onDisappear {
            config.wipeSecrets()
            config = ConnectionConfig()
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .connected {
                rememberLoginAfterConnecting()
                config.wipeSecrets()
            }
        }
        .alert("Rename Favorite", isPresented: isRenaming, presenting: renameTarget) { target in
            TextField("Name", text: $renameText)
            Button("Rename") { rename(target.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { selection }, set: select)) {
            Label("New Connection", systemImage: "plus.circle")
                .tag(SidebarItem.newConnection)
            Section("Favorites") {
                ForEach(store.favorites) { favorite in
                    FavoriteRow(favorite: favorite, hasSavedLogin: logins.hasLogin(for: favorite.id))
                        .tag(SidebarItem.favorite(favorite.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Kept out of the list rows, which are single-line and would truncate it.
            if store.favorites.isEmpty {
                VStack(spacing: 2) {
                    Text("No Favorites")
                        .font(.callout.weight(.medium))
                    Text("Use Save as Favorite to keep a connection here.")
                        .font(.caption)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .accessibilityElement(children: .combine)
            }
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            sidebarMenu(for: items)
        } primaryAction: { items in
            if let item = items.first { open(item) }
        }
        .onDeleteCommand {
            if case .favorite(let id) = selection { delete(id) }
        }
        .disabled(isConnecting)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
    }

    @ViewBuilder
    private func sidebarMenu(for items: Set<SidebarItem>) -> some View {
        let ids = items.compactMap { item -> SavedConnection.ID? in
            if case .favorite(let id) = item { id } else { nil }
        }
        if ids.count == 1, let favorite = store.favorite(ids[0]) {
            Button("Rename…") {
                renameText = favorite.name
                renameTarget = favorite
            }
            Button("Duplicate") { duplicate(favorite) }
            if logins.hasLogin(for: favorite.id) {
                Button("Forget Saved Login") { forgetLogin(favorite.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { delete(favorite.id) }
        } else if ids.count > 1 {
            Button("Delete \(ids.count) Favorites", role: .destructive) {
                for id in ids { delete(id) }
            }
        } else {
            Button("New Connection") { select(.newConnection) }
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            if let errorMessage {
                errorSection(errorMessage)
            }

            Section {
                Picker("Type", selection: kindBinding) {
                    ForEach(DatabaseKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                TextField("Name", text: $config.name, prompt: Text("Optional"))
                    .focused($focus, equals: .name)
            }

            if config.kind == .sqlite {
                fileSection
            } else {
                serverSection
                authenticationSection
                encryptionSection
                sshSection
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        .disabled(isConnecting)
        // Keeps the fields at a readable width in a large window.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .onChange(of: focus) { previous, _ in fieldDidLoseFocus(previous) }
        .onChange(of: config.host) { old, new in
            // A pasted connection URL arrives in one change; a typed one is handled when the field loses focus.
            if new.contains("://"), !old.contains("://") { applyConnectionURL() }
        }
    }

    private func errorSection(_ message: String) -> some View {
        let lines = message.split(separator: "\n", maxSplits: 1).map(String.init)
        return Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lines.first ?? message)
                        .fontWeight(.medium)
                    if lines.count > 1 {
                        Text(lines[1])
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Couldn't connect. \(message)")
        }
    }

    private var serverSection: some View {
        Section {
            TextField(
                config.ssh.enabled ? "Host (from SSH server)" : "Host",
                text: $config.host,
                prompt: Text(config.ssh.enabled ? "127.0.0.1" : "Required")
            )
            .focused($focus, equals: .host)
            PortField("Port", port: $config.port, defaultPort: config.kind.defaultPort)
                .focused($focus, equals: .port)
            if config.kind.hasDatabases {
                TextField(config.kind == .scylla ? "Keyspace" : "Database", text: $config.database,
                          prompt: Text(config.kind == .redis ? "0" : "Optional"))
                    .focused($focus, equals: .database)
            }
        } header: {
            Text("Server")
        } footer: {
            if let invalidURLField, invalidURLField != .sshHost {
                invalidURLNote(invalidURLField)
            } else if config.ssh.enabled {
                footerText("The database’s address as seen from the SSH server. Leave it empty to use 127.0.0.1 when the database runs on that server.")
            }
        }
    }

    private var authenticationSection: some View {
        Section {
            if config.kind.hasUsername {
                TextField("User", text: $config.username,
                          prompt: Text(config.kind.requiresUsername ? "Required" : config.kind == .clickhouse ? "default" : "Optional"))
                    .focused($focus, equals: .user)
            }
            SecureField(config.kind == .meilisearch ? "API Key" : "Password", text: $config.password,
                        prompt: config.kind == .meilisearch ? Text("Optional") : nil)
                .focused($focus, equals: .password)
            if settings.allowFavorites, logins.isSupported {
                Toggle(isOn: rememberLoginBinding) {
                    Text("Remember with Touch ID")
                    Text(selectedFavorite == nil ? "Saved with the favorite" : "Saved after you connect or update the favorite")
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            privacyNote
        }
    }

    private var encryptionSection: some View {
        Section {
            Picker("TLS", selection: $config.tls) {
                ForEach(TLSMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } header: {
            Text("Encryption")
        } footer: {
            footerText(Self.explanation(for: config.tls))
        }
    }

    private var sshSection: some View {
        Section {
            Toggle("Connect over SSH", isOn: $config.ssh.enabled)
            if config.ssh.enabled {
                TextField("SSH Host", text: $config.ssh.host, prompt: Text("server.example.com"))
                    .focused($focus, equals: .sshHost)
                PortField("SSH Port", port: $config.ssh.port, defaultPort: 22)
                    .focused($focus, equals: .sshPort)
                TextField("SSH User", text: $config.ssh.username, prompt: Text("Required"))
                    .focused($focus, equals: .sshUser)
                Picker("Authentication", selection: $config.ssh.authMethod) {
                    ForEach(SSHAuthMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                switch config.ssh.authMethod {
                case .password:
                    SecureField("SSH Password", text: $config.ssh.password, prompt: Text("Required"))
                        .focused($focus, equals: .sshPassword)
                case .privateKey:
                    LabeledContent("Private Key") {
                        HStack(spacing: 8) {
                            pathText(config.ssh.privateKeyPath, placeholder: "None")
                            Button("Choose…", action: chooseKeyFile)
                                .focused($focus, equals: .sshKey)
                                .accessibilityLabel("Choose Private Key")
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first(where: \.isFileURL) else { return false }
                        config.ssh.privateKeyPath = url.path(percentEncoded: false)
                        return true
                    }
                    SecureField("Passphrase", text: $config.ssh.passphrase, prompt: Text("Optional"))
                        .focused($focus, equals: .sshPassphrase)
                }
            }
        } header: {
            Text("SSH Tunnel")
        } footer: {
            if invalidURLField == .sshHost {
                invalidURLNote(.sshHost)
            }
        }
    }

    private var fileSection: some View {
        Section {
            LabeledContent("File") {
                HStack(spacing: 8) {
                    pathText(config.filePath, placeholder: "No file chosen")
                    Button("Choose…", action: chooseDatabaseFile)
                        .focused($focus, equals: .filePath)
                        .accessibilityLabel("Choose Database File")
                }
            }
            HStack {
                Spacer()
                Button("New Database…", action: createDatabaseFile)
                    .help("Create an empty SQLite database file and open it")
            }
        } header: {
            Text("Database File")
        } footer: {
            privacyNote
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            config.filePath = url.path(percentEncoded: false)
            localError = nil
            return true
        }
    }

    private var privacyNote: some View {
        Label {
            Text(rememberLogin && settings.allowFavorites && config.kind.isNetworked
                ? "The login is encrypted with a key in this Mac’s Secure Enclave and opens only with Touch ID. It can’t be read on any other Mac."
                : "Credentials are kept in memory only while connected. Dbee never saves passwords, usernames, or keys unless you turn on Remember with Touch ID.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// Grouped forms trail-align footers by default; System Settings keeps them under the rows' labels.
    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func invalidURLNote(_ field: Field) -> some View {
        Label {
            Text(Self.invalidURLMessage(for: field))
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathText(_ path: String, placeholder: String) -> some View {
        let display = path.isEmpty ? placeholder : (path as NSString).abbreviatingWithTildeInPath
        return Text(display)
            .foregroundStyle(path.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }

    // MARK: Action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if unlockingFavorite != nil {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for Touch ID…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                } else if case .connecting(let message) = session.phase {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button("Cancel") { session.cancelConnect() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    if let notice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 12)
                    if settings.allowFavorites {
                        Button(selectedFavorite == nil ? "Save as Favorite" : "Update Favorite", action: saveFavorite)
                            .disabled(!canSaveFavorite)
                    }
                    if let favorite = unlockableFavorite {
                        Button {
                            unlockAndConnect(favorite)
                        } label: {
                            Label("Connect with Touch ID", systemImage: "touchid")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Connect", action: connect)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canConnect)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // Opaque window background, so the strip continues the grouped form instead of a white bar.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: State

    private var isConnecting: Bool {
        if unlockingFavorite != nil { return true }
        if case .connecting = session.phase { return true }
        return false
    }

    private var errorMessage: String? {
        if let localError { return localError }
        if case .failed(let message) = session.phase { return message }
        return nil
    }

    private var selectedFavorite: SavedConnection? {
        guard case .favorite(let id) = selection else { return nil }
        return store.favorite(id)
    }

    private var canConnect: Bool { Self.isComplete(Self.prepared(config)) }

    private var invalidURLField: Field? { Self.invalidURLField(in: Self.prepared(config)) }

    private var canSaveFavorite: Bool {
        let prepared = Self.prepared(config)
        guard Self.invalidURLField(in: prepared) == nil else { return false }
        let hasTarget = switch prepared.kind {
        case .sqlite: !prepared.filePath.isEmpty
        case .postgres, .mysql, .clickhouse, .scylla, .redis, .mongodb, .meilisearch: !prepared.host.isEmpty || (prepared.ssh.enabled && !prepared.ssh.host.isEmpty)
        }
        guard hasTarget else { return false }
        guard let stored = selectedFavorite else { return true }
        var current = Self.favorite(from: prepared)
        current.id = stored.id
        if FavoritesStore.sanitized(current) != stored { return true }
        // Same server details: Update only matters when it changes the saved login.
        let hasLogin = logins.hasLogin(for: stored.id)
        return rememberLogin ? (!hasLogin && hasCredentials) : hasLogin
    }

    /// Whether the form holds a login (typed, or opened from the vault) rather than just server details.
    private var hasCredentials: Bool { !config.username.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The selected favorite, when its saved login can stand in for the empty credential fields. The form must
    /// still point at the same server: edited server details never receive the saved login.
    private var unlockableFavorite: SavedConnection? {
        guard let favorite = selectedFavorite,
              favorite.kind.isNetworked,
              logins.hasLogin(for: favorite.id),
              !hasCredentials
        else { return nil }
        return Self.sameServer(Self.prepared(config), as: favorite) ? favorite : nil
    }

    static func sameServer(_ config: ConnectionConfig, as favorite: SavedConnection) -> Bool {
        LoginTarget(Self.favorite(from: config)) == LoginTarget(favorite)
    }

    /// Turning the toggle off for a favorite that has a saved login forgets it right away.
    private var rememberLoginBinding: Binding<Bool> {
        Binding(get: { rememberLogin }, set: { on in
            rememberLogin = on
            if !on, let favorite = selectedFavorite, logins.hasLogin(for: favorite.id) { forgetLogin(favorite.id) }
        })
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    /// Switching the engine also switches the port and TLS mode to the new engine's defaults, unless the user
    /// changed them (see `DatabaseKind.defaultTLS`).
    private var kindBinding: Binding<DatabaseKind> {
        Binding(get: { config.kind }, set: { kind in
            guard kind != config.kind else { return }
            if config.port == config.kind.defaultPort { config.port = kind.defaultPort }
            if config.tls == config.kind.defaultTLS { config.tls = kind.defaultTLS }
            config.kind = kind
            localError = nil
        })
    }

    // MARK: Actions

    /// Only called for user-initiated sidebar selection; programmatic changes assign `selection` directly.
    private func select(_ item: SidebarItem?) {
        guard let item, item != selection else { return }
        selection = item
        localError = nil
        if case .failed = session.phase { session.phase = .idle }
        config.wipeSecrets()
        switch item {
        case .newConnection:
            config = ConnectionConfig()
            rememberLogin = false
        case .favorite(let id):
            guard let favorite = store.favorite(id) else { return }
            config = favorite.makeConfig()
            rememberLogin = logins.hasLogin(for: id)
            if favorite.kind.isNetworked, !rememberLogin { moveFocus(to: .user) }
        }
    }

    /// Double-click or Return on a sidebar row: connect when nothing is missing (asking for Touch ID when the
    /// favorite has a saved login), otherwise jump to the gap.
    private func open(_ item: SidebarItem) {
        select(item)
        if let favorite = unlockableFavorite {
            unlockAndConnect(favorite)
        } else if canConnect {
            connect()
        } else {
            moveFocus(to: Self.firstMissingField(in: Self.prepared(config)))
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        var request = Self.prepared(config)
        guard Self.isComplete(request) else {
            moveFocus(to: Self.firstMissingField(in: request))
            return
        }
        localError = nil
        notice = nil
        session.phase = .connecting("Connecting…")
        session.connect(request)
        request.wipeSecrets()
    }

    private func saveFavorite() {
        var prepared = Self.prepared(config)
        defer { prepared.wipeSecrets() }
        var favorite = Self.favorite(from: prepared)
        let existing = selectedFavorite
        if let existing { favorite.id = existing.id }
        store.save(favorite)
        guard let saved = store.favorite(favorite.id) else { return }
        config.name = saved.name
        selection = .favorite(saved.id)

        var message = existing == nil ? "Saved to Favorites" : "Favorite updated"
        if !rememberLogin || !saved.kind.isNetworked {
            logins.forget(saved.id)
        } else if hasCredentials, Self.isComplete(prepared) {
            do {
                try logins.save(prepared, for: saved)
                message = existing == nil ? "Saved with Touch ID login" : "Favorite and login updated"
            } catch {
                rememberLogin = false
                localError = "Couldn’t save the login.\n\(error.localizedDescription)"
            }
        } else if let existing, LoginTarget(existing) != LoginTarget(saved), logins.hasLogin(for: saved.id) {
            // The server changed and there's no login in the form to re-seal for it.
            logins.forget(saved.id)
            rememberLogin = false
            message = "Saved login removed: the server changed"
        } else if !logins.hasLogin(for: saved.id) {
            message += ". Enter the login to remember it"
        }
        showNotice(message)
    }

    /// Touch ID, then connect with the saved login. Cancelling leaves the form ready for typing the login.
    private func unlockAndConnect(_ favorite: SavedConnection) {
        guard unlockingFavorite == nil, !isConnecting else { return }
        localError = nil
        notice = nil
        if case .failed = session.phase { session.phase = .idle }
        unlockingFavorite = favorite.id
        Task {
            defer { unlockingFavorite = nil }
            do {
                var unlocked = try await logins.open(favorite)
                defer { unlocked.wipeSecrets() }
                // The user may have picked something else while the prompt was up.
                guard selection == .favorite(favorite.id), !hasCredentials else { return }
                // Straight to the session: the opened login never enters the editable form, so it can't be
                // read off the screen or sent to a host typed in afterwards.
                var request = Self.prepared(unlocked)
                defer { request.wipeSecrets() }
                guard Self.sameServer(request, as: favorite), Self.isComplete(request) else {
                    localError = "The saved login doesn’t fit this connection.\nEnter the login to connect."
                    return
                }
                unlockingFavorite = nil
                session.phase = .connecting("Connecting…")
                session.connect(request)
            } catch let error as LoginVaultError {
                rememberLogin = logins.hasLogin(for: favorite.id)
                if error != .cancelled { localError = error.localizedDescription }
                moveFocus(to: .user)
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    /// After a successful connect from a favorite with Remember with Touch ID on, seal the login that worked.
    /// Skipped when the form's server details differ from the favorite's (the user must update it first).
    private func rememberLoginAfterConnecting() {
        guard rememberLogin, settings.allowFavorites, logins.isSupported,
              let favorite = selectedFavorite, favorite.kind.isNetworked, hasCredentials
        else { return }
        var prepared = Self.prepared(config)
        defer { prepared.wipeSecrets() }
        guard Self.sameServer(prepared, as: favorite) else { return }
        try? logins.save(prepared, for: favorite)
    }

    private func forgetLogin(_ id: SavedConnection.ID) {
        logins.forget(id)
        if selection == .favorite(id) { rememberLogin = false }
        showNotice("Saved login forgotten")
    }

    private func duplicate(_ favorite: SavedConnection) {
        var copy = favorite
        copy.id = UUID()
        copy.name = "\(favorite.name) Copy"
        store.save(copy)
    }

    private func delete(_ id: SavedConnection.ID) {
        store.remove(id)
        // Keep whatever is in the form; it simply isn't tied to a favorite anymore.
        if selection == .favorite(id) {
            selection = .newConnection
            rememberLogin = false
        }
    }

    private func rename(_ id: SavedConnection.ID) {
        store.rename(id, to: ConnectionString.scrubbed(renameText))
        if selection == .favorite(id), let renamed = store.favorite(id) { config.name = renamed.name }
        renameTarget = nil
    }

    private func prefillFromSession() {
        // A reconnect (e.g. after the tunnel dropped) brings this view back while the session still holds
        // the last config; show it so a failed attempt can be retried without retyping.
        guard let existing = session.config, config == ConnectionConfig() else { return }
        config = existing
        let saved = Self.favorite(from: Self.prepared(existing))
        selection = store.favorites.first { candidate in
            var probe = saved
            probe.id = candidate.id
            return FavoritesStore.sanitized(probe) == candidate
        }.map { .favorite($0.id) } ?? .newConnection
        guard case .favorite(let id) = selection, let favorite = store.favorite(id) else { return }
        rememberLogin = logins.hasLogin(for: id)
        // A login that came from Touch ID isn't shown again; Connect with Touch ID asks for it instead.
        if rememberLogin, Self.sameServer(Self.prepared(existing), as: favorite) {
            config.wipeSecrets()
            config = favorite.makeConfig()
        }
    }

    private func fieldDidLoseFocus(_ field: Field?) {
        switch field {
        case .host:
            if config.host.contains("://") {
                applyConnectionURL()
            } else if let parts = ConnectionString.splitHost(config.host) {
                config.host = parts.host
                if let user = parts.user { config.username = user }
                if let port = parts.port { config.port = port }
            }
        case .sshHost:
            if let parts = ConnectionString.splitHost(config.ssh.host) {
                config.ssh.host = parts.host
                if let user = parts.user { config.ssh.username = user }
                if let port = parts.port { config.ssh.port = port }
            }
        default:
            break
        }
    }

    private func applyConnectionURL() {
        var parsed = config
        guard ConnectionString.apply(config.host, to: &parsed) else { return }
        config = parsed
        parsed.wipeSecrets()
        localError = nil
        showNotice("Filled in from the connection URL")
    }

    private func moveFocus(to field: Field?) {
        // Deferred so it wins over the sidebar keeping focus after a click.
        Task { @MainActor in focus = field }
    }

    private func showNotice(_ message: String) {
        withAnimation { notice = message }
        AccessibilityNotification.Announcement(message).post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if notice == message { withAnimation { notice = nil } }
        }
    }

    // MARK: Panels

    private func chooseDatabaseFile() {
        let panel = NSOpenPanel()
        panel.title = "Open SQLite Database"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !config.filePath.isEmpty {
            let current = URL(fileURLWithPath: (config.filePath as NSString).expandingTildeInPath)
            panel.directoryURL = current.deletingLastPathComponent()
        }
        present(panel) { url in
            config.filePath = url.path(percentEncoded: false)
            localError = nil
        }
    }

    private func createDatabaseFile() {
        let panel = NSSavePanel()
        panel.title = "New SQLite Database"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled.sqlite"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        present(panel) { url in
            do {
                try Self.createEmptyDatabase(at: url)
                config.filePath = url.path(percentEncoded: false)
                localError = nil
                connect()
            } catch {
                localError = "Couldn’t create “\(url.lastPathComponent)”\n\(error.localizedDescription)"
            }
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Private Key"
        panel.message = "Dbee reads the key only while connecting and never copies it."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let current = config.ssh.privateKeyPath
        panel.directoryURL = current.isEmpty
            ? KnownHosts.userHomeDirectory.appendingPathComponent(".ssh", isDirectory: true)
            : URL(fileURLWithPath: (current as NSString).expandingTildeInPath).deletingLastPathComponent()
        present(panel) { url in
            config.ssh.privateKeyPath = url.path(percentEncoded: false)
        }
    }

    private func present(_ panel: NSSavePanel, then handle: @escaping @MainActor (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { handle(url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}

// MARK: - Form logic

extension ConnectView {
    /// The config as it will be used: trimmed, defaults applied, "user@host:port" shortcuts expanded, and
    /// every credential that the chosen options don't need cleared.
    static func prepared(_ input: ConnectionConfig) -> ConnectionConfig {
        var c = input
        // The name becomes the window title and possibly a favorite's name, so a URL typed there is scrubbed.
        c.name = ConnectionString.scrubbed(c.name)

        // A URL still sitting in the host field (typed rather than pasted, or pasted over another URL) is
        // parsed here, so it never reaches a connection or a favorite as a raw string. Typed credentials
        // are kept when the URL has none. An unsupported scheme stays and is reported by `invalidURLField`.
        if c.kind != .sqlite, c.host.contains("://") {
            let (username, password) = (c.username, c.password)
            if ConnectionString.apply(c.host, to: &c) {
                if c.username.isEmpty { c.username = username }
                if c.password.isEmpty { c.password = password }
            }
        }

        if c.kind == .sqlite {
            var file = ConnectionConfig()
            file.name = c.name
            file.kind = .sqlite
            file.port = DatabaseKind.sqlite.defaultPort
            file.tls = c.tls
            file.filePath = c.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
            c.wipeSecrets()
            return file
        }

        c.filePath = ""
        c.host = c.host.trimmingCharacters(in: .whitespacesAndNewlines)
        c.username = c.username.trimmingCharacters(in: .whitespacesAndNewlines)
        c.database = c.database.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = ConnectionString.splitHost(c.host) {
            c.host = parts.host
            if let user = parts.user { c.username = user }
            if let port = parts.port { c.port = port }
        }
        if c.port == 0 { c.port = c.kind.defaultPort }

        c.ssh.host = c.ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
        c.ssh.username = c.ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
        c.ssh.privateKeyPath = c.ssh.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = ConnectionString.splitHost(c.ssh.host) {
            c.ssh.host = parts.host
            if let user = parts.user { c.ssh.username = user }
            if let port = parts.port { c.ssh.port = port }
        }
        if c.ssh.port == 0 { c.ssh.port = 22 }

        if !c.ssh.enabled {
            c.ssh.wipeSecrets()
            c.ssh.username = ""
            c.ssh.privateKeyPath = ""
        } else if c.ssh.authMethod == .password {
            c.ssh.privateKeyPath = ""
            c.ssh.passphrase = ""
        } else {
            c.ssh.password = ""
        }
        return c
    }

    /// Whether `config` (already `prepared`) has everything needed to attempt a connection.
    static func isComplete(_ c: ConnectionConfig) -> Bool {
        firstMissingField(in: c) == nil
    }

    static func firstMissingField(in c: ConnectionConfig) -> Field? {
        let validPort = 1...65535
        switch c.kind {
        case .sqlite:
            return c.filePath.isEmpty ? .filePath : nil
        case .postgres, .mysql, .clickhouse, .scylla, .redis, .mongodb, .meilisearch:
            if let field = invalidURLField(in: c) { return field }
            if !c.ssh.enabled, c.host.isEmpty { return .host }
            if !validPort.contains(c.port) { return .port }
            if c.username.isEmpty, c.kind.requiresUsername { return .user }
            guard c.ssh.enabled else { return nil }
            if c.ssh.host.isEmpty { return .sshHost }
            if !validPort.contains(c.ssh.port) { return .sshPort }
            if c.ssh.username.isEmpty { return .sshUser }
            switch c.ssh.authMethod {
            case .password: return c.ssh.password.isEmpty ? .sshPassword : nil
            case .privateKey: return c.ssh.privateKeyPath.isEmpty ? .sshKey : nil
            }
        }
    }

    /// A host or database field (in a `prepared` config) that still holds a connection URL, which happens
    /// when its scheme isn't one Dbee understands. Such a config can't be connected or saved.
    static func invalidURLField(in c: ConnectionConfig) -> Field? {
        guard c.kind != .sqlite else { return nil }
        if c.host.contains("://") { return .host }
        if c.database.contains("://") { return .database }
        if c.ssh.enabled, c.ssh.host.contains("://") { return .sshHost }
        return nil
    }

    static func invalidURLMessage(for field: Field) -> String {
        switch field {
        case .database: "Enter only the database name here. Paste connection URLs into the Host field."
        case .sshHost: "Enter the SSH server’s host name, not a URL."
        default: "Dbee reads postgres://, mysql://, sqlite://, clickhouse://, cassandra://, redis:// and mongodb:// URLs, and http(s):// URLs for ClickHouse and Meilisearch. For other URLs, enter the host name instead."
        }
    }

    /// A favorite for `config` (already `prepared`), named after the server when the user gave no name.
    /// Every stored text field is scrubbed, so nothing credential-like from a URL ends up in UserDefaults.
    static func favorite(from config: ConnectionConfig) -> SavedConnection {
        var favorite = SavedConnection(from: config)
        favorite.host = ConnectionString.scrubbed(favorite.host)
        favorite.sshHost = ConnectionString.scrubbed(favorite.sshHost)
        favorite.database = ConnectionString.scrubbed(favorite.database)
        favorite.name = ConnectionString.scrubbed(favorite.name)
        if config.name.isEmpty || favorite.name.isEmpty {
            favorite.name = suggestedName(for: config)
        }
        favorite.name = nameWithoutUsernames(favorite.name, config: config)
        return FavoritesStore.sanitized(favorite)
    }

    /// A name typed as "user@host" would persist the user name, so "user@" parts matching the
    /// connection's database or SSH user are dropped from the favorite's name.
    static func nameWithoutUsernames(_ name: String, config: ConnectionConfig) -> String {
        var result = name
        for user in [config.username, config.ssh.username] where !user.isEmpty {
            result = result.replacingOccurrences(of: user + "@", with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? suggestedName(for: config) : result
    }

    /// Built from scrubbed fields, so a URL left in the form can't carry credentials into the name.
    static func suggestedName(for input: ConnectionConfig) -> String {
        var c = input
        c.host = ConnectionString.scrubbed(c.host)
        c.ssh.host = ConnectionString.scrubbed(c.ssh.host)
        c.database = ConnectionString.scrubbed(c.database)
        switch c.kind {
        case .sqlite:
            return c.filePath.isEmpty ? "SQLite Database" : URL(fileURLWithPath: c.filePath).lastPathComponent
        case .postgres, .mysql, .clickhouse, .scylla, .redis, .mongodb, .meilisearch:
            let server = !c.host.isEmpty ? c.host : (c.ssh.enabled && !c.ssh.host.isEmpty ? c.ssh.host : "")
            switch (c.database.isEmpty, server.isEmpty) {
            case (true, true): return c.kind.displayName
            case (true, false): return server
            case (false, true): return c.database
            case (false, false): return "\(c.database) @ \(server)"
            }
        }
    }

    /// Plain-language description of each TLS mode, shown under the picker.
    static func explanation(for mode: TLSMode) -> String {
        switch mode {
        case .disabled:
            "Traffic isn’t encrypted. Use this only through an SSH tunnel or on a network you trust."
        case .preferred:
            "Encrypts the connection when the server supports it, without checking its certificate. Falls back to an unencrypted connection otherwise."
        case .required:
            "Always encrypts the connection, but accepts any certificate, including the self-signed ones common on VPS setups."
        case .verifyFull:
            "Always encrypts the connection and checks that the server’s certificate is valid and matches the host name. Needs the server’s host name, not an IP address, for MySQL and for any connection through an SSH tunnel."
        }
    }

    /// Creates an empty file, which SQLite treats as a new, empty database. When replacing an existing
    /// database (the save panel already asked), its leftover journal files are removed so they can't be
    /// replayed into the new one.
    static func createEmptyDatabase(at url: URL) throws {
        let path = url.path(percentEncoded: false)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            for suffix in ["-wal", "-shm", "-journal"] {
                try? fileManager.removeItem(atPath: path + suffix)
            }
        }
        try Data().write(to: url)
    }
}

// MARK: - Subviews

/// Sidebar row for a favorite: engine icon, name, and where it points.
private struct FavoriteRow: View {
    let favorite: SavedConnection
    let hasSavedLogin: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(favorite.name)
                    .lineLimit(1)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: favorite.kind.symbolName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if hasSavedLogin {
                Image(systemName: "touchid")
                    .foregroundStyle(.secondary)
                    .help("Login saved. Double-click to connect with Touch ID.")
            }
        }
        .help(location)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(favorite.name), \(favorite.kind.displayName), \(location)\(hasSavedLogin ? ", login saved with Touch ID" : "")")
    }

    private var location: String {
        switch favorite.kind {
        case .sqlite:
            return (favorite.filePath as NSString).abbreviatingWithTildeInPath
        case .postgres, .mysql, .clickhouse, .scylla, .redis, .mongodb, .meilisearch:
            let host = favorite.host.isEmpty ? "127.0.0.1" : favorite.host
            let address = host.contains(":") ? "[\(host)]:\(favorite.port)" : "\(host):\(favorite.port)"
            return favorite.sshEnabled ? "\(address) via SSH" : address
        }
    }
}

/// Digits-only port field. Empty means "use the default", which is shown as the placeholder and bound as 0.
private struct PortField: View {
    let title: String
    @Binding var port: Int
    let defaultPort: Int
    @State private var text: String

    init(_ title: String, port: Binding<Int>, defaultPort: Int) {
        self.title = title
        _port = port
        self.defaultPort = defaultPort
        _text = State(initialValue: Self.text(for: port.wrappedValue))
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(String(defaultPort)))
            .onChange(of: text) { old, new in
                var candidate = new.filter { $0.isASCII && $0.isNumber }
                if candidate.count > 5 || (Int(candidate) ?? 0) > 65535 { candidate = old }
                if candidate != new {
                    text = candidate
                    return
                }
                let value = Int(candidate) ?? 0
                if value != port { port = value }
            }
            .onChange(of: port) { _, new in
                if (Int(text) ?? 0) != new { text = Self.text(for: new) }
            }
    }

    private static func text(for port: Int) -> String {
        port > 0 ? String(port) : ""
    }
}
