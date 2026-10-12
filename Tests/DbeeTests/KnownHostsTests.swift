import Foundation
import Testing
@testable import Dbee

/// Helpers shared by the SSH test files. Everything happens in a private temp directory;
/// the user's real ~/.ssh is never read or written by these tests.
enum SSHTestTools {
    static let sshKeygen = "/usr/bin/ssh-keygen"

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbee-ssh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DatabaseError("\(executable) exited with \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Generates a key pair with ssh-keygen and returns the private key path.
    @discardableResult
    static func generateKey(in dir: URL, name: String, type: String, bits: Int? = nil,
                            passphrase: String = "", extra: [String] = []) throws -> URL {
        let path = dir.appendingPathComponent(name)
        var args = ["-q", "-t", type, "-N", passphrase, "-C", "test-\(name)", "-f", path.path]
        if let bits { args += ["-b", String(bits)] }
        try run(sshKeygen, args + extra)
        return path
    }

    /// The "type base64" part of a .pub file.
    static func publicKeyLine(_ privateKeyPath: URL) throws -> (type: String, base64: String) {
        let text = try String(contentsOf: privateKeyPath.appendingPathExtension("pub"), encoding: .utf8)
        let fields = text.split(separator: " ")
        return (String(fields[0]), String(fields[1]))
    }

    static func hostKey(_ privateKeyPath: URL) throws -> SSHHostKey {
        let line = try publicKeyLine(privateKeyPath)
        return try #require(SSHHostKey(blob: Array(Data(base64Encoded: line.base64)!)))
    }

    /// `ssh-keygen -l -E sha256` fingerprint of a public key file.
    static func fingerprint(ofPublicKeyFile path: URL) throws -> String {
        let output = try run(sshKeygen, ["-l", "-E", "sha256", "-f", path.path])
        return String(output.split(separator: " ")[1])
    }
}

@Suite("KnownHosts")
final class KnownHostsTests {
    let dir: URL
    let hostA: URL      // ed25519
    let hostB: URL      // ed25519, different key
    let hostEC: URL     // ecdsa p-256

    init() throws {
        dir = try SSHTestTools.makeTempDirectory()
        hostA = try SSHTestTools.generateKey(in: dir, name: "host_a", type: "ed25519")
        hostB = try SSHTestTools.generateKey(in: dir, name: "host_b", type: "ed25519")
        hostEC = try SSHTestTools.generateKey(in: dir, name: "host_ec", type: "ecdsa", bits: 256)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ hosts: String, _ key: URL, marker: String? = nil) throws -> String {
        let pub = try SSHTestTools.publicKeyLine(key)
        return [marker, hosts, pub.type, pub.base64, "comment here"].compactMap { $0 }.joined(separator: " ")
    }

    @Test func fingerprintMatchesSSHKeygen() throws {
        for key in [hostA, hostB, hostEC] {
            let expected = try SSHTestTools.fingerprint(ofPublicKeyFile: key.appendingPathExtension("pub"))
            let parsed = try SSHTestTools.hostKey(key)
            #expect(parsed.fingerprint == expected)
            #expect(parsed.fingerprint.hasPrefix("SHA256:"))
            #expect(!parsed.fingerprint.hasSuffix("="))
        }
        #expect(try SSHTestTools.hostKey(hostA).displayType == "ED25519")
        #expect(try SSHTestTools.hostKey(hostEC).displayType == "ECDSA")
        #expect(SSHHostKey.displayType(forAlgorithm: "ssh-rsa") == "RSA")
    }

    @Test func plainHostAndCommaList() throws {
        let known = KnownHosts(contents: try line("db.example.com,10.0.0.5", hostA))
        let key = try SSHTestTools.hostKey(hostA)
        #expect(known.status(host: "db.example.com", port: 22, key: key) == .trusted)
        #expect(known.status(host: "10.0.0.5", port: 22, key: key) == .trusted)
        #expect(known.status(host: "DB.Example.COM", port: 22, key: key) == .trusted)
        #expect(known.status(host: "other.example.com", port: 22, key: key) == .unknown)
        // A plain entry only covers port 22.
        #expect(known.status(host: "db.example.com", port: 2222, key: key) == .unknown)
    }

    @Test func bracketedPortSyntax() throws {
        let known = KnownHosts(contents: try line("[db.example.com]:2222", hostA))
        let key = try SSHTestTools.hostKey(hostA)
        #expect(known.status(host: "db.example.com", port: 2222, key: key) == .trusted)
        #expect(known.status(host: "db.example.com", port: 22, key: key) == .unknown)
        #expect(known.status(host: "db.example.com", port: 2223, key: key) == .unknown)
        #expect(KnownHosts.lookupName(host: "Example.com", port: 22) == "example.com")
        #expect(KnownHosts.lookupName(host: "example.com", port: 2200) == "[example.com]:2200")
    }

    @Test func hashedEntriesFromSSHKeygen() throws {
        let file = dir.appendingPathComponent("known_hosts_hashed")
        let text = [
            try line("db.example.com", hostA),
            try line("[db.example.com]:2222", hostEC),
        ].joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        try SSHTestTools.run(SSHTestTools.sshKeygen, ["-H", "-f", file.path])

        let hashed = try String(contentsOf: file, encoding: .utf8)
        #expect(hashed.hasPrefix("|1|"))
        #expect(!hashed.contains("db.example.com"))

        let known = KnownHosts(files: [file])
        #expect(known.entries.count == 2)
        #expect(known.status(host: "db.example.com", port: 22, key: try SSHTestTools.hostKey(hostA)) == .trusted)
        #expect(known.status(host: "db.example.com", port: 2222, key: try SSHTestTools.hostKey(hostEC)) == .trusted)
        #expect(known.status(host: "db.example.com", port: 22, key: try SSHTestTools.hostKey(hostB)) == .mismatch)
        #expect(known.status(host: "nope.example.com", port: 22, key: try SSHTestTools.hostKey(hostA)) == .unknown)
    }

    @Test func wildcardsAndNegation() throws {
        let known = KnownHosts(contents: try line("*.example.com,!secret.example.com,db?.internal", hostA))
        let key = try SSHTestTools.hostKey(hostA)
        #expect(known.status(host: "web.example.com", port: 22, key: key) == .trusted)
        #expect(known.status(host: "secret.example.com", port: 22, key: key) == .unknown)
        #expect(known.status(host: "db1.internal", port: 22, key: key) == .trusted)
        #expect(known.status(host: "db12.internal", port: 22, key: key) == .unknown)
        #expect(KnownHosts.wildcardMatch("[a.b]:22", pattern: "[*]:22"))
        #expect(!KnownHosts.wildcardMatch("abc", pattern: "a?"))
        #expect(KnownHosts.wildcardMatch("abc", pattern: "*"))
    }

    @Test func mismatchOnlyForSameAlgorithm() throws {
        let keyA = try SSHTestTools.hostKey(hostA)
        let keyB = try SSHTestTools.hostKey(hostB)
        let keyEC = try SSHTestTools.hostKey(hostEC)

        let sameType = KnownHosts(contents: try line("db.example.com", hostA))
        #expect(sameType.status(host: "db.example.com", port: 22, key: keyB) == .mismatch)

        // Only an ECDSA key is known: an Ed25519 key isn't a mismatch, but the host isn't unknown either.
        let otherType = KnownHosts(contents: try line("db.example.com", hostEC))
        #expect(otherType.status(host: "db.example.com", port: 22, key: keyA) == .otherKeyTypesKnown(["ECDSA"]))
        #expect(otherType.status(host: "other.example.com", port: 22, key: keyA) == .unknown)

        // A same-type mismatch wins over other known types.
        let both = KnownHosts(contents: [try line("db.example.com", hostEC), try line("db.example.com", hostB)]
            .joined(separator: "\n"))
        #expect(both.status(host: "db.example.com", port: 22, key: keyA) == .mismatch)

        // Several keys for one host: any equal key of the same type is trusted.
        let multiple = KnownHosts(contents: [try line("db.example.com", hostB), try line("db.example.com", hostEC),
                                             try line("db.example.com", hostA)].joined(separator: "\n"))
        #expect(multiple.status(host: "db.example.com", port: 22, key: keyA) == .trusted)
        #expect(multiple.status(host: "db.example.com", port: 22, key: keyEC) == .trusted)
    }

    @Test func revokedAndCertAuthorityMarkers() throws {
        let keyA = try SSHTestTools.hostKey(hostA)
        let revoked = KnownHosts(contents: [try line("db.example.com", hostA),
                                            try line("*", hostA, marker: "@revoked")].joined(separator: "\n"))
        #expect(revoked.status(host: "db.example.com", port: 22, key: keyA) == .revoked)
        // Revoking a different key doesn't affect this one, and revoked entries don't count as known types.
        let otherRevoked = KnownHosts(contents: try line("*", hostEC, marker: "@revoked"))
        #expect(otherRevoked.status(host: "db.example.com", port: 22, key: keyA) == .unknown)

        let ca = KnownHosts(contents: try line("*.example.com", hostA, marker: "@cert-authority"))
        #expect(ca.status(host: "db.example.com", port: 22, key: keyA) == .unknown)

        let unknownMarker = KnownHosts(contents: try line("db.example.com", hostA, marker: "@bogus"))
        #expect(unknownMarker.entries.isEmpty)
    }

    @Test func commentsBlankAndMalformedLinesAreSkipped() throws {
        let pub = try SSHTestTools.publicKeyLine(hostA)
        let text = """
        # a comment

           \t
        db.example.com
        db.example.com ssh-ed25519
        db.example.com ssh-ed25519 !!!notbase64!!!
        db.example.com ecdsa-sha2-nistp256 \(pub.base64)
        |1|bad|hash ssh-ed25519 \(pub.base64)
        db.example.com 2048 35 12345
          db.example.com \(pub.type) \(pub.base64) trailing comment
        """
        let known = KnownHosts(contents: text)
        #expect(known.entries.count == 1)
        #expect(known.status(host: "db.example.com", port: 22, key: try SSHTestTools.hostKey(hostA)) == .trusted)
    }

    @Test func filesAreMergedAndMissingFilesIgnored() throws {
        let first = dir.appendingPathComponent("kh1")
        let second = dir.appendingPathComponent("kh2")
        try (try line("one.example.com", hostA)).write(to: first, atomically: true, encoding: .utf8)
        try (try line("two.example.com", hostEC)).write(to: second, atomically: true, encoding: .utf8)
        let known = KnownHosts(files: [first, dir.appendingPathComponent("missing"), second])
        #expect(known.entries.count == 2)
        #expect(known.status(host: "two.example.com", port: 22, key: try SSHTestTools.hostKey(hostEC)) == .trusted)
    }

    @Test func defaultFilesPointAtStandardLocations() {
        let paths = KnownHosts.defaultFiles.map(\.path)
        #expect(paths.contains { $0.hasSuffix("/.ssh/known_hosts") })
        #expect(paths.contains("/etc/ssh/ssh_known_hosts"))
    }
}
