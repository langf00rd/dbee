import NIOConcurrencyHelpers

/// The cancel for one statement: sent at most once, from Stop, task cancellation or a row limit, and awaited
/// before the statement's turn on the connection ends, so it can't reach the statement after it.
final class StatementCancelSignal: Sendable {
    private enum State {
        case idle
        case fired(Task<Void, Never>)
        /// The statement ended without a cancel; later requests are ignored.
        case sealed
    }

    private let state = NIOLockedValueBox(State.idle)

    func fire(_ operation: @escaping @Sendable () async -> Void) {
        state.withLockedValue { state in
            if case .idle = state { state = .fired(Task { await operation() }) }
        }
    }

    /// Seals an unfired signal and returns true; returns false if a cancel was already sent.
    func sealIfIdle() -> Bool {
        state.withLockedValue { state in
            guard case .idle = state else { return false }
            state = .sealed
            return true
        }
    }

    func settled() async {
        let task = state.withLockedValue { state -> Task<Void, Never>? in
            if case .fired(let task) = state { return task }
            return nil
        }
        await task?.value
    }
}
