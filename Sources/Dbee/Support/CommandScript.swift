import Foundation

/// Statement splitting and highlighting for the query editor's non-SQL languages: Redis commands (one per
/// line, as in redis-cli) and mongosh-style MongoDB statements.
enum CommandScript {
    // MARK: Splitting

    /// Redis: every non-empty line is a command. Lines starting with # or // are comments. A line break inside
    /// a quoted argument doesn't end the command.
    static func splitRedis(_ script: String) -> [SQLSplitter.Statement] {
        let units = Array(script.utf16)
        var statements: [SQLSplitter.Statement] = []
        var start = 0
        var quote: UInt16?
        var i = 0
        func finish(_ end: Int) {
            appendTrimmed(units, start, end, to: &statements) { text in
                !(text.hasPrefix("#") || text.hasPrefix("//"))
            }
        }
        while i < units.count {
            let c = units[i]
            if let open = quote {
                if c == Char.backslash, open == Char.doubleQuote || (i + 1 < units.count && units[i + 1] == Char.singleQuote) {
                    i += 2
                    continue
                }
                if c == open { quote = nil }
            } else if c == Char.doubleQuote || c == Char.singleQuote {
                quote = c
            } else if c == Char.newline {
                finish(i)
                start = i + 1
            }
            i += 1
        }
        finish(units.count)
        return statements
    }

    /// MongoDB: statements end at a top-level `;`, or at a line break outside brackets when the next line
    /// doesn't continue the chain (a line starting with `.`). Strings, regex literals and // and /* */
    /// comments are skipped.
    static func splitMongo(_ script: String) -> [SQLSplitter.Statement] {
        let units = Array(script.utf16)
        let n = units.count
        var statements: [SQLSplitter.Statement] = []
        var start = 0
        var depth = 0
        var i = 0
        var lastSignificant: UInt16 = 0

        func finish(_ end: Int) {
            appendTrimmed(units, start, end, to: &statements) { _ in true }
        }
        func nextSignificant(after index: Int) -> UInt16? {
            var j = index
            while j < n {
                let c = units[j]
                if c == Char.space || c == Char.tab || c == Char.newline || c == Char.carriageReturn {
                    j += 1
                } else if c == Char.slash, j + 1 < n, units[j + 1] == Char.slash {
                    while j < n, units[j] != Char.newline { j += 1 }
                } else {
                    return c
                }
            }
            return nil
        }

        while i < n {
            let c = units[i]
            switch c {
            case Char.doubleQuote, Char.singleQuote, Char.backtick:
                i = endOfQuoted(units, from: i + 1, quote: c)
                lastSignificant = c
                continue
            case Char.slash where i + 1 < n && units[i + 1] == Char.slash:
                while i < n, units[i] != Char.newline { i += 1 }
                continue
            case Char.slash where i + 1 < n && units[i + 1] == Char.star:
                i += 2
                while i + 1 < n, !(units[i] == Char.star && units[i + 1] == Char.slash) { i += 1 }
                i = min(i + 2, n)
                continue
            case Char.slash where isRegexStart(after: lastSignificant):
                i = endOfRegex(units, from: i + 1)
                lastSignificant = Char.slash
                continue
            case Char.openBrace, Char.openBracket, Char.openParen:
                depth += 1
            case Char.closeBrace, Char.closeBracket, Char.closeParen:
                depth = max(0, depth - 1)
            case Char.semicolon where depth == 0:
                finish(i)
                start = i + 1
                lastSignificant = 0
                i += 1
                continue
            case Char.newline where depth == 0:
                if lastSignificant != 0, nextSignificant(after: i + 1) != Char.dot, lastSignificant != Char.dot {
                    finish(i)
                    start = i + 1
                    lastSignificant = 0
                }
                i += 1
                continue
            default:
                break
            }
            if c != Char.space, c != Char.tab, c != Char.carriageReturn, c != Char.newline { lastSignificant = c }
            i += 1
        }
        finish(n)
        return statements
    }

    /// Adds units[start..<end] without surrounding whitespace and comment-only lines, when `keep` accepts it.
    private static func appendTrimmed(_ units: [UInt16], _ start: Int, _ end: Int,
                                      to statements: inout [SQLSplitter.Statement], keep: (String) -> Bool) {
        var s = start
        var e = end
        // Leading blanks and // or /* */ comments aren't part of the statement.
        while s < e {
            if isBlank(units[s]) {
                s += 1
            } else if units[s] == Char.slash, s + 1 < e, units[s + 1] == Char.slash {
                while s < e, units[s] != Char.newline { s += 1 }
            } else if units[s] == Char.slash, s + 1 < e, units[s + 1] == Char.star {
                s += 2
                while s + 1 < e, !(units[s] == Char.star && units[s + 1] == Char.slash) { s += 1 }
                s = min(s + 2, e)
            } else {
                break
            }
        }
        while e > s, isBlank(units[e - 1]) { e -= 1 }
        let text = String(decoding: units[s..<e], as: UTF16.self)
        guard e > s, keep(text) else { return }
        statements.append(SQLSplitter.Statement(text: text, range: NSRange(location: s, length: e - s)))
    }

    private static func isBlank(_ c: UInt16) -> Bool {
        c == Char.space || c == Char.tab || c == Char.newline || c == Char.carriageReturn
    }

    private static func endOfQuoted(_ s: [UInt16], from index: Int, quote: UInt16) -> Int {
        var i = index
        while i < s.count {
            if s[i] == Char.backslash { i += 2; continue }
            if s[i] == quote { return i + 1 }
            i += 1
        }
        return s.count
    }

    /// After these a `/` starts a regex literal rather than dividing.
    private static func isRegexStart(after previous: UInt16) -> Bool {
        previous == 0 || previous == Char.colon || previous == Char.comma || previous == Char.openParen
            || previous == Char.openBracket || previous == Char.openBrace || previous == Char.equals
    }

    private static func endOfRegex(_ s: [UInt16], from index: Int) -> Int {
        var i = index
        var inClass = false
        while i < s.count, s[i] != Char.newline {
            let c = s[i]
            if c == Char.backslash { i += 2; continue }
            if c == Char.openBracket { inClass = true } else if c == Char.closeBracket { inClass = false }
            if c == Char.slash, !inClass {
                i += 1
                while i < s.count, isLetter(s[i]) { i += 1 }
                return i
            }
            i += 1
        }
        return i
    }

    // MARK: Highlighting

    /// Tokens for Redis and MongoDB text: strings, numbers, comments, and the language's words (Redis
    /// commands at the start of a line, MongoDB methods and constructors). `$operators` are parameters.
    static func tokens(_ s: UnsafeBufferPointer<UInt16>, kind: DatabaseKind) -> [SQLHighlighter.Token] {
        let n = s.count
        var tokens: [SQLHighlighter.Token] = []
        let words = SQLKeywords.keywords(for: kind)
        var atLineStart = true
        var lastSignificant: UInt16 = 0
        func add(_ start: Int, _ end: Int, _ kind: SQLHighlighter.TokenKind) {
            guard end > start else { return }
            tokens.append(SQLHighlighter.Token(range: NSRange(location: start, length: end - start), kind: kind))
        }

        var i = 0
        while i < n {
            let c = s[i]
            let next: UInt16 = i + 1 < n ? s[i + 1] : 0
            if c == Char.newline {
                atLineStart = true
                i += 1
                continue
            }
            if c == Char.space || c == Char.tab || c == Char.carriageReturn {
                i += 1
                continue
            }
            let wasLineStart = atLineStart
            atLineStart = false
            switch c {
            case Char.slash where next == Char.slash, Char.hash where kind == .redis && wasLineStart:
                var end = i
                while end < n, s[end] != Char.newline { end += 1 }
                add(i, end, .comment)
                i = end
                atLineStart = true
                continue
            case Char.slash where next == Char.star && kind == .mongodb:
                var end = i + 2
                while end + 1 < n, !(s[end] == Char.star && s[end + 1] == Char.slash) { end += 1 }
                end = min(end + 2, n)
                add(i, end, .comment)
                i = end
            case Char.slash where kind == .mongodb && isRegexStart(after: lastSignificant):
                var end = i + 1
                var inClass = false
                while end < n, s[end] != Char.newline {
                    let r = s[end]
                    if r == Char.backslash { end += 2; continue }
                    if r == Char.openBracket { inClass = true } else if r == Char.closeBracket { inClass = false }
                    if r == Char.slash, !inClass {
                        end += 1
                        while end < n, isLetter(s[end]) { end += 1 }
                        break
                    }
                    end += 1
                }
                end = min(end, n)
                add(i, end, .string)
                i = end
            case Char.doubleQuote, Char.singleQuote, Char.backtick:
                var end = i + 1
                while end < n {
                    if s[end] == Char.backslash { end += 2; continue }
                    if s[end] == c { end += 1; break }
                    end += 1
                }
                end = min(end, n)
                add(i, end, .string)
                i = end
            case Char.dollar where kind == .mongodb && isLetter(next):
                var end = i + 1
                while end < n, isLetter(s[end]) || isDigit(s[end]) { end += 1 }
                add(i, end, .parameter)
                i = end
            case _ where isDigit(c) || ((c == Char.minus || c == Char.dot) && isDigit(next)
                                         && (i == 0 || !isLetter(s[i - 1]))):
                var end = i + 1
                while end < n, isDigit(s[end]) || s[end] == Char.dot || s[end] == Char.lowerE || s[end] == Char.upperE { end += 1 }
                // Redis keys like 123abc are words, not numbers.
                if kind == .redis, end < n, isLetter(s[end]) || s[end] == Char.colon {
                    while end < n, !isBlank(s[end]) { end += 1 }
                } else {
                    add(i, end, .number)
                }
                i = end
            case _ where isLetter(c):
                var end = i + 1
                // Redis module commands have dots (JSON.GET); mongosh words don't.
                while end < n, isLetter(s[end]) || isDigit(s[end]) || (kind == .redis && s[end] == Char.dot) { end += 1 }
                let word = String(decoding: UnsafeBufferPointer(rebasing: s[i..<end]), as: UTF16.self).uppercased()
                let isKeyword = kind == .redis ? (wasLineStart || lastSignificant == 0) && words.contains(word) : words.contains(word)
                if isKeyword {
                    add(i, end, .keyword)
                } else if kind == .mongodb, ["ObjectId", "ISODate", "NumberLong", "NumberInt", "NumberDecimal",
                                             "Timestamp", "BinData", "UUID"].contains(where: { $0.uppercased() == word }) {
                    add(i, end, .function)
                }
                if kind == .redis, !isKeyword {
                    // A bare argument runs to the next space.
                    while end < n, !isBlank(s[end]) { end += 1 }
                }
                i = end
            default:
                i += 1
            }
            lastSignificant = s[max(0, i - 1)]
        }
        return tokens
    }

    private static func isLetter(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == Char.underscore || c >= 0x80
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private enum Char {
        static let tab: UInt16 = 0x09
        static let newline: UInt16 = 0x0A
        static let carriageReturn: UInt16 = 0x0D
        static let space: UInt16 = 0x20
        static let doubleQuote: UInt16 = 0x22
        static let hash: UInt16 = 0x23
        static let dollar: UInt16 = 0x24
        static let singleQuote: UInt16 = 0x27
        static let openParen: UInt16 = 0x28
        static let closeParen: UInt16 = 0x29
        static let star: UInt16 = 0x2A
        static let comma: UInt16 = 0x2C
        static let minus: UInt16 = 0x2D
        static let dot: UInt16 = 0x2E
        static let slash: UInt16 = 0x2F
        static let colon: UInt16 = 0x3A
        static let semicolon: UInt16 = 0x3B
        static let equals: UInt16 = 0x3D
        static let upperE: UInt16 = 0x45
        static let openBracket: UInt16 = 0x5B
        static let backslash: UInt16 = 0x5C
        static let closeBracket: UInt16 = 0x5D
        static let underscore: UInt16 = 0x5F
        static let backtick: UInt16 = 0x60
        static let lowerE: UInt16 = 0x65
        static let openBrace: UInt16 = 0x7B
        static let closeBrace: UInt16 = 0x7D
    }
}
