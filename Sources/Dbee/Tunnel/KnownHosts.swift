import Foundation
import Crypto
import NIOCore
import NIOSSH

/// A server host key in SSH wire format, with the OpenSSH-style fingerprint and type label.
struct SSHHostKey: Hashable, Sendable {
    /// Wire-format public key blob: `string algorithm` followed by the key data.
    let blob: [UInt8]
    /// Algorithm name embedded in the blob, e.g. "ssh-ed25519" or "ecdsa-sha2-nistp256".
    let algorithm: String

    /// Returns nil when the blob does not start with a valid algorithm string.
    init?(blob: [UInt8]) {
        var reader = SSHWireReader(blob)
        guard let algorithm = reader.readUTF8(), !algorithm.isEmpty else { return nil }
        self.blob = blob
        self.algorithm = algorithm
    }

    init(_ key: NIOSSHPublicKey) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let blob = Array(buffer.readableBytesView)
        var reader = SSHWireReader(blob)
        self.blob = blob
        self.algorithm = reader.readUTF8() ?? ""
    }

    /// "SHA256:<unpadded base64>", identical to `ssh-keygen -l -E sha256`.
    var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// Short key type as OpenSSH prints it ("ED25519", "ECDSA", "RSA", …).
    var displayType: String { Self.displayType(forAlgorithm: algorithm) }

    static func displayType(forAlgorithm algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": "RSA"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": "ECDSA"
        case "ssh-dss": "DSA"
        case "sk-ssh-ed25519@openssh.com": "ED25519-SK"
        case "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK"
        default: algorithm.uppercased()
        }
    }
}

/// Read-only view of OpenSSH known_hosts files. Dbee never writes these files.
///
/// Supports plain and wildcard host patterns, negation (`!pattern`), comma lists, `[host]:port`,
/// hashed entries (`|1|salt|hash`), `@revoked` and `@cert-authority` markers, and comments.
struct KnownHosts: Sendable {
    enum Marker: Sendable, Equatable {
        case none
        case revoked
        case certAuthority
    }

    enum Hosts: Sendable, Equatable {
        /// Comma-separated patterns, possibly negated or containing `*` / `?`.
        case patterns([String])
        /// `|1|base64(salt)|base64(HMAC-SHA1(salt, hostname))`.
        case hashed(salt: [UInt8], hash: [UInt8])
    }

    struct Entry: Sendable, Equatable {
        var marker: Marker
        var hosts: Hosts
        var key: SSHHostKey
    }

    /// Result of checking a server key against the entries for one host.
    enum Verdict: Sendable, Equatable {
        /// A matching entry holds this key.
        case trusted
        /// The host isn't listed.
        case unknown
        /// An entry with the same algorithm holds a different key. Possible man-in-the-middle.
        case mismatch
        /// The host is listed only with other key types (display names, e.g. ["ECDSA"]).
        case otherKeyTypesKnown([String])
        /// The key is listed as `@revoked`. Never acceptable.
        case revoked
    }

    var entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Parses the contents of a known_hosts file. Malformed lines are skipped, like OpenSSH does.
    init(contents: String) {
        entries = contents.split(whereSeparator: \.isNewline).compactMap { Self.parseLine(Substring($0)) }
    }

    /// Reads and merges the given files. Missing or unreadable files are ignored.
    init(files: [URL]) {
        var entries: [Entry] = []
        for url in files {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            entries += KnownHosts(contents: String(decoding: data, as: UTF8.self)).entries
        }
        self.entries = entries
    }

    /// The files OpenSSH consults by default (user files first, then the system-wide ones).
    static var defaultFiles: [URL] {
        let ssh = userHomeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        return [
            ssh.appendingPathComponent("known_hosts"),
            ssh.appendingPathComponent("known_hosts2"),
            URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts"),
            URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts2"),
        ]
    }

    static func loadDefault() -> KnownHosts {
        KnownHosts(files: defaultFiles)
    }

    /// The real home directory, even when running inside an App Sandbox container.
    static var userHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The name OpenSSH looks up: "host" on port 22, otherwise "[host]:port". Lowercased.
    static func lookupName(host: String, port: Int) -> String {
        let host = host.lowercased()
        return port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Checks a server key against the known entries for `host:port`.
    ///
    /// A revoked key is always revoked, even if another entry trusts it. Otherwise the key is trusted if any
    /// matching entry holds the same key; it is a mismatch if an entry with the same algorithm holds a
    /// different key; `otherKeyTypesKnown` if the host is only listed with other algorithms; else unknown.
    func status(host: String, port: Int, key: SSHHostKey) -> Verdict {
        let name = Self.lookupName(host: host, port: port)
        var trusted = false
        var differentKeySameAlgorithm = false
        var otherKeyTypes: [String] = []
        for entry in entries where entry.matches(name) {
            switch entry.marker {
            case .certAuthority:
                continue
            case .revoked:
                if entry.key.blob == key.blob { return .revoked }
            case .none:
                if entry.key.blob == key.blob {
                    trusted = true
                } else if entry.key.algorithm == key.algorithm {
                    differentKeySameAlgorithm = true
                } else if !otherKeyTypes.contains(entry.key.displayType) {
                    otherKeyTypes.append(entry.key.displayType)
                }
            }
        }
        if trusted { return .trusted }
        if differentKeySameAlgorithm { return .mismatch }
        return otherKeyTypes.isEmpty ? .unknown : .otherKeyTypesKnown(otherKeyTypes)
    }

    // MARK: Parsing

    static func parseLine(_ line: Substring) -> Entry? {
        var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).makeIterator()
        guard var first = fields.next(), !first.hasPrefix("#") else { return nil }

        var marker = Marker.none
        if first.hasPrefix("@") {
            switch first {
            case "@revoked": marker = .revoked
            case "@cert-authority": marker = .certAuthority
            default: return nil
            }
            guard let next = fields.next() else { return nil }
            first = next
        }

        guard let typeField = fields.next(), let keyField = fields.next(),
              let blobData = Data(base64Encoded: String(keyField)),
              let key = SSHHostKey(blob: Array(blobData)),
              key.algorithm == typeField
        else { return nil }

        guard let hosts = parseHosts(first) else { return nil }
        return Entry(marker: marker, hosts: hosts, key: key)
    }

    private static func parseHosts(_ field: Substring) -> Hosts? {
        if field.hasPrefix("|") {
            // |1|salt|hash
            let parts = field.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0].isEmpty, parts[1] == "1",
                  let salt = Data(base64Encoded: String(parts[2])),
                  let hash = Data(base64Encoded: String(parts[3])),
                  hash.count == Insecure.SHA1.byteCount
            else { return nil }
            return .hashed(salt: Array(salt), hash: Array(hash))
        }
        let patterns = field.split(separator: ",").map { String($0).lowercased() }
        return patterns.isEmpty ? nil : .patterns(patterns)
    }
}

extension KnownHosts.Entry {
    /// Whether this entry applies to `name` (already in lookup form, see `KnownHosts.lookupName`).
    func matches(_ name: String) -> Bool {
        switch hosts {
        case .hashed(let salt, let hash):
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Array(name.utf8), using: SymmetricKey(data: salt))
            return Array(mac) == hash
        case .patterns(let patterns):
            var matched = false
            for pattern in patterns {
                if pattern.hasPrefix("!") {
                    // A matching negated pattern rejects the whole line.
                    if KnownHosts.wildcardMatch(name, pattern: String(pattern.dropFirst())) { return false }
                } else if KnownHosts.wildcardMatch(name, pattern: pattern) {
                    matched = true
                }
            }
            return matched
        }
    }
}

extension KnownHosts {
    /// OpenSSH-style glob: `*` matches any run of characters, `?` exactly one. Case-insensitive.
    static func wildcardMatch(_ string: String, pattern: String) -> Bool {
        let s = Array(string.lowercased().unicodeScalars)
        let p = Array(pattern.lowercased().unicodeScalars)
        var si = 0, pi = 0
        var starPi = -1, starSi = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                si += 1
                pi += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                starSi = si
                pi += 1
            } else if starPi >= 0 {
                pi = starPi + 1
                starSi += 1
                si = starSi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
