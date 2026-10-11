import SwiftUI

@main
struct DbeeApp: App {
    var body: some Scene {
        WindowGroup("Dbee", id: "session") {
            SessionWindow()
        }
        Settings {
            SettingsView()
        }
    }
}
