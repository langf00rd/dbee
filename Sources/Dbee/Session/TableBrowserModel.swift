import Foundation
import Observation

/// State for browsing/editing one table: paging, filter, sort, loaded rows and pending edits.
@MainActor @Observable
final class TableBrowserModel {
    unowned let session: DatabaseSession
    let table: TableRef

    init(session: DatabaseSession, table: TableRef) {
        self.session = session
        self.table = table
    }
}
