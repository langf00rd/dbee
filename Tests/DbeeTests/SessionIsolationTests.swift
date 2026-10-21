import Foundation
import Testing
@testable import Dbee

/// Work queued for one connection must not run on the one that replaced it, and closing a query tab
/// stops the work it started.
@MainActor
@Suite("Session isolation", .serialized)
struct SessionIsolationTests {
    private struct Timeout: Error {}

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let marker = ["CREATE TABLE marker (v TEXT)"]

    /// Creates a SQLite database with `setup` and returns its path.
    private func makeDatabase(_ setup: [String]) async throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbee-iso-\(UUID().uuidString).sqlite").path
        let driver = try SQLiteDriver.open(path: path, create: true)
        for sql in setup { _ = try await driver.execute(sql, maxRows: 0) }
        await driver.close()
        return path
    }

    private func remove(_ paths: String...) {
        for path in paths {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
    }

    private func connect(_ session: DatabaseSession, to path: String) async throws {
        var config = ConnectionConfig()
        config.kind = .sqlite
        config.filePath = path
        session.connect(config)
        try await waitFor {
            if case .failed = session.phase { return true }
            return session.isConnected
        }
        try #require(session.isConnected)
    }

    /// Holds the session's connection until `release` is called, standing in for a slow operation.
    private func holdConnection(_ session: DatabaseSession) async throws -> (task: Task<Void, Never>, release: () -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var held = false
        let task = Task { @MainActor in
            _ = try? await session.withExclusiveConnection { _ in
                held = true
                for await _ in stream { break }
            }
        }
        try await waitFor { held }
        return (task, { continuation.finish() })
    }

    private func rows(in path: String) async throws -> [[CellValue]] {
        let driver = try SQLiteDriver.open(path: path, create: false)
        defer { Task { await driver.close() } }
        return try await driver.execute("SELECT v FROM marker", maxRows: 0).rows
    }

    @Test func queuedWriteIsRefusedAfterReconnect() async throws {
        let a = try await makeDatabase(Self.marker)
        let b = try await makeDatabase(Self.marker)
        defer { remove(a, b) }
        let session = DatabaseSession()
        try await connect(session, to: a)
        try await waitFor { !session.isLoadingSchema }

        let hold = try await holdConnection(session)
        let write = Task { @MainActor in
            try await session.execute("INSERT INTO marker VALUES ('intended-for-a')")
        }
        try await Task.sleep(for: .milliseconds(30))
        await session.disconnect()
        try await connect(session, to: b)
        hold.release()
        await hold.task.value

        await #expect(throws: DatabaseError.self) { try await write.value }
        try await waitFor { !session.isLoadingSchema }
        #expect(try await rows(in: b).isEmpty)
        #expect(try await rows(in: a).isEmpty)
        // New work on the new connection runs normally.
        _ = try await session.execute("INSERT INTO marker VALUES ('for-b')")
        #expect(try await rows(in: b) == [["for-b"]])
        await session.disconnect()
    }

    @Test func queuedScriptIsRefusedAfterReconnect() async throws {
        let a = try await makeDatabase(Self.marker)
        let b = try await makeDatabase(Self.marker)
        defer { remove(a, b) }
        let session = DatabaseSession()
        try await connect(session, to: a)
        try await waitFor { !session.isLoadingSchema }

        let tab = session.newQueryTab(sql: "INSERT INTO marker VALUES ('one'); INSERT INTO marker VALUES ('two')")
        let hold = try await holdConnection(session)
        let run = Task { @MainActor in await session.run(tab.sql, in: tab) }
        try await Task.sleep(for: .milliseconds(30))
        await session.disconnect()
        try await connect(session, to: b)
        hold.release()
        await hold.task.value
        await run.value

        #expect(tab.errorMessage != nil)
        #expect(tab.results.isEmpty)
        try await waitFor { !session.isLoadingSchema }
        #expect(try await rows(in: b).isEmpty)
        await session.disconnect()
    }

    @Test func closingTabStopsItsQueuedWrite() async throws {
        let path = try await makeDatabase(Self.marker)
        defer { remove(path) }
        let session = DatabaseSession()
        try await connect(session, to: path)
        try await waitFor { !session.isLoadingSchema }

        let tab = session.newQueryTab(sql: "INSERT INTO marker VALUES ('closed-tab')")
        let hold = try await holdConnection(session)
        session.startRun(tab.sql, in: tab)
        try await waitFor { tab.isRunning }
        session.closeQueryTab(tab.id)
        #expect(session.queryTab(tab.id) == nil)
        hold.release()
        await hold.task.value
        try await waitFor { !tab.isRunning }

        let check = try await session.execute("SELECT count(*) FROM marker", recordHistory: false)
        #expect(check.rows == [["0"]])
        await session.disconnect()
    }

    /// Stop still works when the tab's task is owned by the session.
    @Test func stopRunCancelsQueuedStatement() async throws {
        let path = try await makeDatabase(Self.marker)
        defer { remove(path) }
        let session = DatabaseSession()
        try await connect(session, to: path)
        try await waitFor { !session.isLoadingSchema }

        let tab = session.newQueryTab(sql: "INSERT INTO marker VALUES ('stopped')")
        let hold = try await holdConnection(session)
        session.startRun(tab.sql, in: tab)
        try await waitFor { tab.isRunning }
        session.stopRun(in: tab)
        hold.release()
        await hold.task.value
        try await waitFor { !tab.isRunning }

        #expect(tab.errorMessage == "Query stopped")
        let check = try await session.execute("SELECT count(*) FROM marker", recordHistory: false)
        #expect(check.rows == [["0"]])
        await session.disconnect()
    }
}
