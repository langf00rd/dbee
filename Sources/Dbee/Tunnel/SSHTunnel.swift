import Foundation
import Citadel
import NIOCore
import NIOPosix
import NIOSSH

/// Asks the user whether to trust an SSH host key. Implemented by the UI layer.
protocol HostKeyVerifier: Sendable {
    /// - Parameters:
    ///   - fingerprint: "SHA256:<base64>" in OpenSSH format.
    ///   - knownHostsStatus: result of the read-only ~/.ssh/known_hosts lookup.
    /// - Returns: true to continue connecting.
    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, knownHostsStatus: KnownHostsStatus) async -> Bool
}

enum KnownHostsStatus: Sendable, Equatable {
    /// Key matches an entry in ~/.ssh/known_hosts. The verifier is NOT consulted in this case.
    case trusted
    /// Host not present in known_hosts.
    case unknown
    /// Host is present with a DIFFERENT key. Possible man-in-the-middle.
    case mismatch
}

/// A local TCP listener on 127.0.0.1:<random port> whose connections are forwarded through an SSH
/// "direct-tcpip" channel to `targetHost:targetPort` as seen from the SSH server.
final class SSHTunnel: @unchecked Sendable {
    /// The port the database driver should dial on 127.0.0.1.
    let localPort: Int

    private init(localPort: Int) {
        self.localPort = localPort
    }

    static func open(ssh: SSHConfig, targetHost: String, targetPort: Int, verifier: any HostKeyVerifier) async throws -> SSHTunnel {
        fatalError("TODO")
    }

    /// Called when the SSH connection drops unexpectedly.
    func onDisconnect(_ handler: @escaping @Sendable () -> Void) {}

    /// Stops listening, closes forwarded channels and the SSH connection. Safe to call more than once.
    func close() async {}
}
