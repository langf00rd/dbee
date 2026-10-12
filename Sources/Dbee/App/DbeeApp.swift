import SwiftUI

@main
struct DbeeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // As early as possible: before AppKit looks for saved window state and before any library logs.
        PrivacyBootstrap.run()
    }

    var body: some Scene {
        WindowGroup("Dbee", id: "session") {
            SessionWindow()
        }
        .defaultSize(width: 760, height: 640)
        .windowToolbarStyle(.unified)
        .commands { DbeeCommands() }

        Settings {
            SettingsView()
        }
    }
}
