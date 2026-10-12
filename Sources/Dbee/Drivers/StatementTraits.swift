import Foundation

/// Lexical facts about a single SQL statement that drivers need before running it. Comments, string
/// literals, quoted identifiers and Postgres dollar quotes are skipped, so only bare words count.
enum StatementTraits {
    /// The first `limit` bare words, upper-cased (ASCII only; identifiers are compared as keywords).
    static func words(_ sql: String, kind: DatabaseKind, limit: Int = .max) -> [String] {
        var result: [String] = []
        scan(sql, kind: kind) { word in
            result.append(word)
            return result.count < limit
        }
        return result
    }

    static func leadingKeyword(_ sql: String, kind: DatabaseKind) -> String? {
        words(sql, kind: kind, limit: 1).first
    }

    /// `SELECT … FOR UPDATE / FOR NO KEY UPDATE / FOR SHARE / FOR KEY SHARE`, or MySQL's `LOCK IN SHARE MODE`.
    /// Such statements lock rows as they're read, so they must run to completion.
    static func hasLockingClause(_ sql: String, kind: DatabaseKind) -> Bool {
        // Cheap pre-check: most statements never mention either keyword.
        guard sql.range(of: "for", options: .caseInsensitive) != nil
                || sql.range(of: "lock", options: .caseInsensitive) != nil else { return false }
        var window: [String] = []
        var found = false
        scan(sql, kind: kind) { word in
            window.append(word)
            if window.count > 4 { window.removeFirst() }
            let tail = window.suffix(4)
            func ends(with pattern: [String]) -> Bool { tail.count >= pattern.count && Array(tail.suffix(pattern.count)) == pattern }
            if ends(with: ["FOR", "UPDATE"]) || ends(with: ["FOR", "NO", "KEY", "UPDATE"]) || ends(with: ["FOR", "SHARE"])
                || ends(with: ["FOR", "KEY", "SHARE"]) || ends(with: ["LOCK", "IN", "SHARE", "MODE"]) {
                found = true
                return false
            }
            return true
        }
        return found
    }

    /// Calls `visit` with each bare word until it returns false.
    private static func scan(_ sql: String, kind: DatabaseKind, visit: (String) -> Bool) {
        let s = Array(sql.utf8)
        let n = s.count
        let isMySQL = kind == .mysql
        var i = 0

        func isWordStart(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A || c == 0x5F || c >= 0x80 }
        func isWordPart(_ c: UInt8) -> Bool { isWordStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x24 }
        func skipQuoted(_ quote: UInt8, backslash: Bool) {
            i += 1
            while i < n {
                if backslash, s[i] == 0x5C { i += 2; continue }
                if s[i] == quote {
                    if i + 1 < n, s[i + 1] == quote { i += 2; continue }
                    i += 1
                    return
                }
                i += 1
            }
        }

        while i < n {
            let c = s[i]
            switch c {
            case 0x27: // '
                skipQuoted(c, backslash: isMySQL || (i > 0 && (s[i - 1] | 0x20) == 0x65 && (i < 2 || !isWordPart(s[i - 2]))))
            case 0x22: // "
                skipQuoted(c, backslash: isMySQL)
            case 0x60 where isMySQL: // `
                skipQuoted(c, backslash: false)
            case 0x2D where i + 1 < n && s[i + 1] == 0x2D: // --
                while i < n, s[i] != 0x0A { i += 1 }
            case 0x23 where isMySQL: // #
                while i < n, s[i] != 0x0A { i += 1 }
            case 0x2F where i + 1 < n && s[i + 1] == 0x2A: // /*
                var depth = 0
                while i < n {
                    if i + 1 < n, s[i] == 0x2F, s[i + 1] == 0x2A {
                        depth += 1
                        i += 2
                    } else if i + 1 < n, s[i] == 0x2A, s[i + 1] == 0x2F {
                        depth -= 1
                        i += 2
                        if depth == 0 || isMySQL { break }
                    } else {
                        i += 1
                    }
                }
            case 0x24 where !isMySQL: // $tag$ … $tag$
                var end = i + 1
                while end < n, isWordPart(s[end]), s[end] != 0x24 { end += 1 }
                guard end < n, s[end] == 0x24 else { i += 1; continue }
                let tag = Array(s[i...end])
                i = end + 1
                while i < n {
                    if s[i] == 0x24, i + tag.count <= n, Array(s[i..<(i + tag.count)]) == tag {
                        i += tag.count
                        break
                    }
                    i += 1
                }
            default:
                if isWordStart(c) {
                    let start = i
                    while i < n, isWordPart(s[i]) { i += 1 }
                    // A string prefix (E'', N'', X'', B'', _utf8mb4'') belongs to the literal that follows.
                    if i < n, s[i] == 0x27 { continue }
                    let word = String(decoding: s[start..<i], as: UTF8.self).uppercased()
                    if !visit(word) { return }
                } else if c >= 0x30 && c <= 0x39 {
                    while i < n, isWordPart(s[i]) || s[i] == 0x2E { i += 1 }
                } else {
                    i += 1
                }
            }
        }
    }
}
