import Foundation
import MySQLNIO

final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    let kind: DatabaseKind = .mysql

    static func connect(config: ConnectionConfig, host: String, port: Int) async throws -> MySQLDriver {
        fatalError("TODO")
    }

    func serverVersion() async throws -> String { fatalError("TODO") }
    func listDatabases() async throws -> [String] { fatalError("TODO") }
    func currentDatabase() async throws -> String { fatalError("TODO") }
    func listSchemas() async throws -> [SchemaInfo] { fatalError("TODO") }
    func tableStructure(_ table: TableRef) async throws -> TableStructure { fatalError("TODO") }
    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult { fatalError("TODO") }
    func cancelCurrentQuery() async {}
    func close() async {}
}
