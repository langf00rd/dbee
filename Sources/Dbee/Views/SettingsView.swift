import SwiftUI

/// The app's Settings window: General and Privacy panes in the style of System Settings.
struct SettingsView: View {
    private enum Tab: Hashable { case general, privacy }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            PrivacySettingsPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(Tab.privacy)
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable private var settings = AppSettings.shared

    private static let pageSizes = [50, 100, 200, 500, 1_000]
    private static let rowLimits = [1_000, 10_000, 50_000, 100_000]

    var body: some View {
        Form {
            Section {
                Picker("Rows per page", selection: $settings.pageSize) {
                    ForEach(Self.options(Self.pageSizes, including: settings.pageSize), id: \.self) { size in
                        Text(size.formatted()).tag(size)
                    }
                }
            } header: {
                Text("Table Browser")
            } footer: {
                SettingsFooter("How many rows to load at a time when browsing a table.")
            }

            Section {
                Picker("Maximum rows per query", selection: $settings.maxQueryRows) {
                    ForEach(Self.options(Self.rowLimits, including: settings.maxQueryRows), id: \.self) { limit in
                        Text(limit.formatted()).tag(limit)
                    }
                }
                LabeledContent("Font size") {
                    HStack(spacing: 6) {
                        Text("\(Int(settings.editorFontSize)) pt")
                            .monospacedDigit()
                        Stepper("Font size", value: $settings.editorFontSize, in: 10...24, step: 1)
                            .labelsHidden()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue("\(Int(settings.editorFontSize)) points")
            } header: {
                Text("Query Editor")
            } footer: {
                SettingsFooter("Results stop loading once they reach the row limit, which keeps large queries responsive.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The standard choices, plus the current value if it was set to something else.
    private static func options(_ standard: [Int], including current: Int) -> [Int] {
        standard.contains(current) || current <= 0 ? standard : (standard + [current]).sorted()
    }
}

// MARK: - Privacy

private struct PrivacySettingsPane: View {
    @Bindable private var settings = AppSettings.shared
    private var favorites: FavoritesStore { .shared }
    private var logins: LoginVault { .shared }

    @State private var confirmingRemoveAll = false
    @State private var confirmingForgetLogins = false
    @State private var offeringRemovalAfterDisable = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow saving favorites", isOn: $settings.allowFavorites)
                HStack {
                    Text(savedCountText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove All Favorites…", role: .destructive) {
                        confirmingRemoveAll = true
                    }
                    .disabled(favorites.favorites.isEmpty)
                }
            } header: {
                Text("Favorites")
            } footer: {
                SettingsFooter("Favorites remember a connection’s type, host, port, database and SSH server. Logins are saved only for favorites where you turn on Remember with Touch ID.")
            }

            Section {
                HStack {
                    Text(savedLoginsText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget All Saved Logins…", role: .destructive) {
                        confirmingForgetLogins = true
                    }
                    .disabled(logins.savedIDs.isEmpty)
                }
            } header: {
                Text("Touch ID Logins")
            } footer: {
                SettingsFooter("Each saved login is encrypted with a key in this Mac’s Secure Enclave plus a secret in your Keychain. It opens only after Touch ID, never with your Mac password, and stops working if your fingerprints change. Forgetting a login makes every copy of it unreadable.")
            }

            Section {
                Toggle("Keep query history during a session", isOn: $settings.keepQueryHistory)
            } header: {
                Text("Session")
            } footer: {
                SettingsFooter("History stays in memory and is cleared when the window closes.")
            }

            Section {
                Toggle("Ask before destructive actions", isOn: $settings.confirmDestructiveActions)
            } footer: {
                SettingsFooter("Confirm before saving table edits, deleting rows, or dropping and emptying tables.")
            }

            Section {
                ForEach(Self.neverStored, id: \.title) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName: item.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Dbee Never Stores")
            } footer: {
                SettingsFooter("Credentials stay in memory only while you’re connected and are cleared when you disconnect. Touch ID logins are the only exception, and only in encrypted form.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.allowFavorites) { _, allowed in
            if !allowed, !favorites.favorites.isEmpty { offeringRemovalAfterDisable = true }
        }
        .confirmationDialog(
            "Remove all saved favorites?",
            isPresented: $confirmingRemoveAll
        ) {
            Button("Remove All Favorites", role: .destructive) { favorites.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(savedCountText) will be removed from this Mac, along with their saved logins. This can’t be undone.")
        }
        .confirmationDialog(
            "Forget all saved logins?",
            isPresented: $confirmingForgetLogins
        ) {
            Button("Forget All Saved Logins", role: .destructive) { logins.forgetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your favorites stay. You’ll type the login the next time you connect.")
        }
        .confirmationDialog(
            "Also remove your saved favorites?",
            isPresented: $offeringRemovalAfterDisable
        ) {
            Button("Remove Favorites", role: .destructive) { favorites.removeAll() }
            Button("Keep Favorites", role: .cancel) {}
        } message: {
            Text("Favorites are hidden while saving is turned off. You can keep them for later or remove them now.")
        }
    }

    private var savedCountText: String {
        switch favorites.favorites.count {
        case 0: "No saved favorites"
        case 1: "1 saved favorite"
        case let n: "\(n) saved favorites"
        }
    }

    private var savedLoginsText: String {
        switch logins.savedIDs.count {
        case 0: "No saved logins"
        case 1: "1 saved login"
        case let n: "\(n) saved logins"
        }
    }

    private static let neverStored: [(title: String, symbol: String)] = [
        ("Passwords or usernames in readable form", "key"),
        ("SSH key files", "lock"),
        ("Query history", "clock.arrow.circlepath"),
        ("Window state", "macwindow"),
    ]
}

/// Small secondary text under a settings section, like the explanations in System Settings.
private struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
