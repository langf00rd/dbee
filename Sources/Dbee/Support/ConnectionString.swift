import Foundation

/// Understands what people paste into the connect form's host fields: connection URLs such as
/// `postgres://user:pass@db.example.com:5432/app?sslmode=require`, `rediss://:pass@cache:6380/2`,
/// `mongodb://user:pass@db1,db2/app?tls=true` or `clickhouse://default@olap:8123/logs`, and ssh-style
/// `user@host:port`. An http(s):// URL is read for ClickHouse and Meilisearch, which speak HTTP, when one of
/// them is already selected.
/// Parsed credentials only ever land in the in-memory `ConnectionConfig`.
enum ConnectionString {
    /// Fills `config` from a connection URL. Returns false, leaving `config` untouched, when `string`
    /// isn't a supported URL. The connection name and SSH settings are kept.
    static func apply(_ string: String, to config: inout ConnectionConfig) -> Bool {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("jdbc:") { s.removeFirst(5) }
        guard let separator = s.range(of: "://") else { return false }

        let kind: DatabaseKind
        let scheme = s[..<separator.lowerBound].lowercased()
        switch scheme {
        case "postgres", "postgresql", "pgsql": kind = .postgres
        case "mysql", "mariadb": kind = .mysql
        case "sqlite", "sqlite3", "file": kind = .sqlite
        case "redis", "rediss", "valkey", "valkeys": kind = .redis
        case "mongodb": kind = .mongodb
        case "clickhouse", "ch": kind = .clickhouse
        case "cassandra", "scylla", "scylladb", "cql": kind = .scylla
        case "http", "https":
            guard config.kind == .clickhouse || config.kind == .meilisearch else { return false }
            kind = config.kind
        default: return false
        }
        let isHTTP = scheme == "http" || scheme == "https"
        if kind == .mongodb, let hosts = mongoHostList(s, after: separator.upperBound) {
            // A replica set lists several hosts; Dbee connects to the first one.
            s.replaceSubrange(hosts, with: s[hosts].split(separator: ",").first.map(String.init) ?? "")
        }

        if kind == .sqlite {
            var path = String(s[separator.upperBound...])
            if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<query]) }
            path = path.removingPercentEncoding ?? path
            if path.hasPrefix("localhost/") { path.removeFirst("localhost".count) }
            guard !path.isEmpty, path != "/" else { return false }
            config.kind = .sqlite
            config.port = DatabaseKind.sqlite.defaultPort
            config.filePath = path
            config.host = ""
            config.username = ""
            config.password = ""
            config.database = ""
            return true
        }

        guard let components = URLComponents(string: s), var host = components.host, !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        var database = components.path
        while database.hasPrefix("/") { database.removeFirst() }
        if database.isEmpty { database = query["dbname"] ?? query["database"] ?? "" }

        config.kind = kind
        config.host = host
        config.port = components.port ?? (isHTTP ? (scheme == "https" ? 443 : 80) : kind.defaultPort)
        config.username = components.user ?? query["user"] ?? ""
        config.password = components.password ?? query["password"] ?? query["key"] ?? ""
        config.database = kind.hasDatabases ? database : ""
        config.filePath = ""
        if kind == .mongodb {
            // MongoDB URLs mean plain TCP unless they set tls=true, which verifies the certificate unless
            // told otherwise.
            let insecure = query["tlsallowinvalidcertificates"] == "true" || query["tlsinsecure"] == "true"
            let enabled = (query["tls"] ?? query["ssl"])?.lowercased() == "true"
            config.tls = enabled ? (insecure ? .required : .verifyFull) : .disabled
        } else if let tls = tlsMode(query) {
            config.tls = tls
        } else if scheme == "rediss" || scheme == "valkeys" || scheme == "https" || query["secure"] == "true" {
            config.tls = .verifyFull
        } else if kind.defaultTLS == .disabled {
            config.tls = .disabled
        }
        return true
    }

    /// The host list of a mongodb:// URL (between the userinfo and the path) when it has several hosts.
    private static func mongoHostList(_ s: String, after start: String.Index) -> Range<String.Index>? {
        let rest = s[start...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        let authority = rest[..<end]
        let hostStart = authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authority.startIndex
        guard authority[hostStart...].contains(",") else { return nil }
        return hostStart..<end
    }

    /// Splits "user@host", "host:port" or "user@[::1]:2222". Returns nil when there is neither a user nor
    /// a port to pull out, or when `string` is a URL.
    static func splitHost(_ string: String) -> (user: String?, host: String, port: Int?)? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("://") else { return nil }

        var user: String?
        var rest = s
        if let at = s.lastIndex(of: "@") {
            let name = String(s[..<at])
            rest = String(s[s.index(after: at)...])
            guard !name.isEmpty, !rest.isEmpty else { return nil }
            user = name
        }

        var host = rest
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":"), let p = Int(tail.dropFirst()), (1...65535).contains(p) { port = p }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":"),
                  let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) {
            host = String(rest[..<colon])
            port = p
        }
        guard user != nil || port != nil || host != rest, !host.isEmpty else { return nil }
        return (user, host, port)
    }

    /// Removes anything credential-like from a string that is about to be persisted (a favorite's name,
    /// host or database): a URL is reduced to its host and path without userinfo or query, and
    /// "user:password@" or "password=" style parameters are cut off. Idempotent.
    static func scrubbed(_ string: String) -> String {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // "?password=…" and everything after it goes first, so an "@" inside such a value can't confuse
        // the userinfo handling below.
        if let query = s.range(of: "(?i)[?&;]\\s*(password|passwd|pass|pwd|user|username)\\s*=", options: .regularExpression) {
            s = String(s[..<query.lowerBound])
        }
        if let separator = s.range(of: "://") {
            s = String(s[separator.upperBound...])
            // The last "@" ends the userinfo even when an unencoded password contains "/", "?" or "#".
            if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
            if let end = s.firstIndex(where: { "?#;".contains($0) }) { s = String(s[..<end]) }
        }
        while let userInfo = s.range(of: "[^\\s@/:]+:[^\\s@/]*@", options: .regularExpression) {
            s.removeSubrange(userInfo)
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tlsMode(_ query: [String: String]) -> TLSMode? {
        let raw = (query["sslmode"] ?? query["ssl-mode"] ?? query["ssl"] ?? query["tls"])?.lowercased()
        switch raw {
        case "disable", "disabled", "false", "0", "off": return .disabled
        case "allow", "prefer", "preferred": return .preferred
        case "require", "required", "true", "1", "on": return .required
        case "verify-ca", "verify-full", "verify_ca", "verify_identity": return .verifyFull
        default: return nil
        }
    }
}
