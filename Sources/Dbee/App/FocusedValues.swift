import SwiftUI

/// The `DatabaseSession` of the key window, published by `SessionWindow` for menu commands.
struct FocusedSessionKey: FocusedValueKey {
    typealias Value = DatabaseSession
}

/// Window-level UI state of the key window (disconnect confirmation), published by `SessionWindow`.
struct FocusedSessionWindowStateKey: FocusedValueKey {
    typealias Value = SessionWindowState
}

extension FocusedValues {
    var session: DatabaseSession? {
        get { self[FocusedSessionKey.self] }
        set { self[FocusedSessionKey.self] = newValue }
    }

    var sessionWindowState: SessionWindowState? {
        get { self[FocusedSessionWindowStateKey.self] }
        set { self[FocusedSessionWindowStateKey.self] = newValue }
    }
}
