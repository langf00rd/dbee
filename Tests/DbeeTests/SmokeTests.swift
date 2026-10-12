import Foundation
import Testing
@testable import Dbee

@Test func savedConnectionHasNoCredentials() {
    var config = ConnectionConfig()
    config.username = "alice"
    config.password = "secret"
    config.ssh.username = "deploy"
    config.ssh.password = "hunter2"
    config.ssh.passphrase = "pp"
    config.ssh.privateKeyPath = "/Users/alice/.ssh/id_ed25519"
    let saved = SavedConnection(from: config)
    let json = String(decoding: try! JSONEncoder().encode(saved), as: UTF8.self)
    for secret in ["alice", "secret", "deploy", "hunter2", "pp\"", "id_ed25519"] {
        #expect(!json.contains(secret))
    }
}
