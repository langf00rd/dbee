import AppKit
import Logging

/// Process-wide privacy settings, applied once before any window or library code runs:
/// no library logging, no saved window state, no URL cache.
enum PrivacyBootstrap {
    @MainActor private static var didRun = false

    @MainActor static func run() {
        guard !didRun else { return }
        didRun = true
        // Libraries (PostgresNIO, MySQLNIO, swift-nio-ssh) would otherwise log hosts, users and SQL.
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
        UserDefaults.standard.register(defaults: [
            "ApplePersistenceIgnoreState": true,
            "NSQuitAlwaysKeepsWindows": false,
        ])
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
    }
}

/// Weak list of every window's session, so quitting can close connections and wipe secrets.
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()

    private struct Entry {
        weak var session: DatabaseSession?
    }

    private var entries: [Entry] = []

    func register(_ session: DatabaseSession) {
        entries.removeAll { $0.session == nil }
        guard !entries.contains(where: { $0.session === session }) else { return }
        entries.append(Entry(session: session))
    }

    var sessions: [DatabaseSession] { entries.compactMap(\.session) }

    /// Disconnects every live session concurrently. Secrets are wiped first, synchronously, and the wait
    /// ends after `timeout` so a stuck server or tunnel can never block quitting.
    func disconnectAll(timeout: Duration) async {
        let sessions = self.sessions
        for session in sessions { session.wipeSecrets() }
        let tasks = sessions.map { session in Task { await session.disconnect() } }
        await Self.waitForAll(tasks, timeout: timeout)
    }

    /// Returns when every task has finished or `timeout` has passed, whichever comes first. The tasks
    /// keep running; awaiting an unstructured task's value can't be cancelled, so a task group won't do.
    static func waitForAll(_ tasks: [Task<Void, Never>], timeout: Duration) async {
        guard !tasks.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                for task in tasks { await task.value }
                once.resume()
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume()
            }
        }
    }
}

/// Resumes a continuation the first time `resume()` is called and ignores later calls.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

extension DatabaseSession {
    /// Whether any browsed table has edits that haven't been committed.
    var hasUncommittedTableChanges: Bool {
        browserModels.values.contains { $0.hasChanges }
    }

    /// Whether the session holds a connection, a connection attempt, or credentials in memory.
    var holdsConnectionState: Bool {
        config != nil || phase != .idle
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        PrivacyBootstrap.run()
        // A saved login whose favorite is gone (for example removed while another build was running) is deleted.
        if !FavoritesStore.shared.storedDataIsUnreadable {
            LoginVault.shared.prune(keeping: FavoritesStore.shared.favorites.map(\.id))
        }
        // Keep native window tabbing: windows can be merged into tabs, each one an independent session.
        NSWindow.allowsAutomaticWindowTabbing = true
        // Belt and braces next to ApplePersistenceIgnoreState: no window (Settings, panels) is ever restorable.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { window?.isRestorable = false }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = SessionRegistry.shared.sessions.filter(\.holdsConnectionState)
        guard !sessions.isEmpty else { return .terminateNow }
        if sessions.contains(where: \.hasUncommittedTableChanges), !confirmQuitDiscardingChanges() {
            return .terminateCancel
        }
        Task {
            await SessionRegistry.shared.disconnectAll(timeout: .seconds(3))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuitDiscardingChanges() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit and discard uncommitted changes?"
        alert.informativeText = "Some tables have edits that haven’t been saved to the database. They’ll be lost if you quit."
        let quit = alert.addButton(withTitle: "Discard Changes and Quit")
        quit.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
