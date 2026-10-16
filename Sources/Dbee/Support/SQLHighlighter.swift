import Foundation

/// Splits SQL text into coloured tokens. Pure and thread-safe; ranges are UTF-16 offsets (NSString / NSRange).
///
/// Understands the lexical rules that matter for colouring: '' and backslash escapes, E'' / N'' / X'' / B''
/// literals, double-quoted identifiers (strings in MySQL), backticks, SQLite [brackets], -- and # comments
/// (MySQL needs whitespace after --), nested /* */ comments in Postgres, $tag$ dollar quotes and
/// placeholders ($1, ?, :name, @var). Unterminated strings and comments run to the end of the text.
enum SQLHighlighter {
    enum TokenKind: Sendable, Equatable, CaseIterable {
        case keyword
        case type
        case function
        case string
        case quotedIdentifier
        case number
        case comment
        case parameter
    }

    struct Token: Sendable, Equatable {
        var range: NSRange
        var kind: TokenKind
    }

    static func tokens(in text: String, kind: DatabaseKind) -> [Token] {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { scan($0, kind: kind) }
    }

    /// Same as `tokens(in:kind:)` but reads the characters straight out of an NSString (e.g. a text storage)
    /// without bridging it to a Swift String first.
    static func tokens(in text: NSString, kind: DatabaseKind) -> [Token] {
        let length = text.length
        guard length > 0 else { return [] }
        let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: length)
        defer { buffer.deallocate() }
        text.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length))
        return scan(UnsafeBufferPointer(buffer), kind: kind)
    }

    /// Index of the first token whose range ends after `location`, for binary-searching sorted token lists.
    static func firstTokenIndex(endingAfter location: Int, in tokens: [Token]) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Scanner

    private static func scan(_ s: UnsafeBufferPointer<UInt16>, kind: DatabaseKind) -> [Token] {
        if !kind.isSQL { return CommandScript.tokens(s, kind: kind) }
        let n = s.count
        var tokens: [Token] = []
        tokens.reserveCapacity(n / 8)
        let keywords = SQLKeywords.keywords(for: kind)

        func add(_ start: Int, _ end: Int, _ tokenKind: TokenKind) {
            guard end > start else { return }
            tokens.append(Token(range: NSRange(location: start, length: end - start), kind: tokenKind))
        }

        var i = 0
        while i < n {
            let c = s[i]
            let next: UInt16 = i + 1 < n ? s[i + 1] : 0

            switch c {
            case Char.space, Char.tab, Char.newline, Char.carriageReturn, Char.formFeed:
                i += 1

            case Char.minus where next == Char.minus
                && (kind != .mysql || i + 2 >= n || s[i + 2] <= Char.space):
                let end = endOfLine(s, from: i + 2)
                add(i, end, .comment)
                i = end

            case Char.hash where kind == .mysql || kind == .clickhouse,
                 Char.slash where next == Char.slash && kind == .scylla:
                let end = endOfLine(s, from: i + 1)
                add(i, end, .comment)
                i = end

            case Char.slash where next == Char.star:
                let end = endOfBlockComment(s, from: i + 2, nested: kind == .postgres)
                add(i, end, .comment)
                i = end

            case Char.singleQuote:
                let end = endOfQuoted(s, from: i + 1, quote: Char.singleQuote, backslashEscapes: kind == .mysql || kind == .clickhouse)
                add(i, end, .string)
                i = end

            case Char.doubleQuote:
                if kind == .mysql {
                    let end = endOfQuoted(s, from: i + 1, quote: Char.doubleQuote, backslashEscapes: true)
                    add(i, end, .string)
                    i = end
                } else {
                    let end = endOfQuoted(s, from: i + 1, quote: Char.doubleQuote, backslashEscapes: kind == .clickhouse)
                    add(i, end, .quotedIdentifier)
                    i = end
                }

            case Char.backtick where kind != .postgres:
                let end = endOfQuoted(s, from: i + 1, quote: Char.backtick, backslashEscapes: kind == .clickhouse)
                add(i, end, .quotedIdentifier)
                i = end

            case Char.openBracket where kind == .sqlite:
                var end = i + 1
                while end < n, s[end] != Char.closeBracket { end += 1 }
                end = min(end + 1, n)
                add(i, end, .quotedIdentifier)
                i = end

            case Char.dollar:
                if kind == .postgres {
                    if isDigit(next) {
                        let end = endOfDigits(s, from: i + 1)
                        add(i, end, .parameter)
                        i = end
                    } else if let tagEnd = dollarTagEnd(s, from: i) {
                        let end = endOfDollarQuote(s, tagStart: i, tagEnd: tagEnd)
                        add(i, end, .string)
                        i = end
                    } else {
                        i += 1
                    }
                } else if kind == .scylla, next == Char.dollar, let tagEnd = dollarTagEnd(s, from: i) {
                    // CQL function bodies: $$ … $$.
                    let end = endOfDollarQuote(s, tagStart: i, tagEnd: tagEnd)
                    add(i, end, .string)
                    i = end
                } else if kind == .sqlite, isIdentifierStart(next) {
                    let end = endOfIdentifier(s, from: i + 1)
                    add(i, end, .parameter)
                    i = end
                } else {
                    i += 1
                }

            case Char.question where kind != .postgres:
                let end = endOfDigits(s, from: i + 1)
                add(i, end, .parameter)
                i = end

            case Char.colon where kind == .sqlite && isIdentifierStart(next):
                let end = endOfIdentifier(s, from: i + 1)
                add(i, end, .parameter)
                i = end

            case Char.at where kind != .postgres:
                var start = i + 1
                if kind == .mysql, next == Char.at { start += 1 }
                if start < n, isIdentifierStart(s[start]) {
                    let end = endOfIdentifier(s, from: start)
                    add(i, end, .parameter)
                    i = end
                } else {
                    i += 1
                }

            case _ where isDigit(c) || (c == Char.dot && isDigit(next) && (i == 0 || !isIdentifierPart(s[i - 1]))):
                let end = endOfNumber(s, from: i)
                add(i, end, .number)
                i = end

            case _ where isIdentifierStart(c):
                let end = endOfIdentifier(s, from: i + 1)
                // Prefixed literals: E'..' (Postgres, backslash escapes), N'..', X'..', B'..'.
                if end - i == 1, end < n, s[end] == Char.singleQuote {
                    let lower = c | 0x20
                    let isEscapeString = lower == Char.lowerE && kind == .postgres
                    if isEscapeString || lower == Char.lowerN || lower == Char.lowerX || lower == Char.lowerB {
                        let stringEnd = endOfQuoted(s, from: end + 1, quote: Char.singleQuote,
                                                    backslashEscapes: isEscapeString || kind == .mysql)
                        add(i, stringEnd, .string)
                        i = stringEnd
                        continue
                    }
                }
                let qualified = i > 0 && s[i - 1] == Char.dot
                if !qualified, let word = upperCasedASCIIWord(s, start: i, end: end) {
                    if SQLKeywords.functions(for: kind).contains(word), nextNonBlank(s, from: end) == Char.openParen {
                        add(i, end, .function)
                    } else if keywords.contains(word) {
                        add(i, end, .keyword)
                    } else if SQLKeywords.types(for: kind).contains(word) {
                        add(i, end, .type)
                    }
                }
                i = end

            default:
                i += 1
            }
        }
        return tokens
    }

    // MARK: Scanner helpers

    private enum Char {
        static let tab: UInt16 = 0x09
        static let newline: UInt16 = 0x0A
        static let formFeed: UInt16 = 0x0C
        static let carriageReturn: UInt16 = 0x0D
        static let space: UInt16 = 0x20
        static let doubleQuote: UInt16 = 0x22
        static let hash: UInt16 = 0x23
        static let dollar: UInt16 = 0x24
        static let singleQuote: UInt16 = 0x27
        static let openParen: UInt16 = 0x28
        static let star: UInt16 = 0x2A
        static let plus: UInt16 = 0x2B
        static let minus: UInt16 = 0x2D
        static let dot: UInt16 = 0x2E
        static let slash: UInt16 = 0x2F
        static let colon: UInt16 = 0x3A
        static let question: UInt16 = 0x3F
        static let at: UInt16 = 0x40
        static let openBracket: UInt16 = 0x5B
        static let backslash: UInt16 = 0x5C
        static let closeBracket: UInt16 = 0x5D
        static let underscore: UInt16 = 0x5F
        static let backtick: UInt16 = 0x60
        static let lowerB: UInt16 = 0x62
        static let lowerE: UInt16 = 0x65
        static let lowerN: UInt16 = 0x6E
        static let lowerX: UInt16 = 0x78
    }

    @inline(__always) private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    @inline(__always) private static func isASCIILetter(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    /// Letters, underscore and any non-ASCII code unit (identifiers may contain Unicode letters).
    @inline(__always) static func isIdentifierStart(_ c: UInt16) -> Bool {
        isASCIILetter(c) || c == Char.underscore || c >= 0x80
    }

    @inline(__always) static func isIdentifierPart(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || isDigit(c) || c == Char.dollar
    }

    private static func endOfIdentifier(_ s: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        var j = start
        while j < s.count, isIdentifierPart(s[j]) { j += 1 }
        return j
    }

    private static func endOfDigits(_ s: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        var j = start
        while j < s.count, isDigit(s[j]) { j += 1 }
        return j
    }

    private static func endOfLine(_ s: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        var j = start
        while j < s.count, s[j] != Char.newline, s[j] != Char.carriageReturn { j += 1 }
        return j
    }

    private static func endOfBlockComment(_ s: UnsafeBufferPointer<UInt16>, from start: Int, nested: Bool) -> Int {
        let n = s.count
        var depth = 1
        var j = start
        while j < n {
            if s[j] == Char.star, j + 1 < n, s[j + 1] == Char.slash {
                depth -= 1
                j += 2
                if depth == 0 { return j }
            } else if nested, s[j] == Char.slash, j + 1 < n, s[j + 1] == Char.star {
                depth += 1
                j += 2
            } else {
                j += 1
            }
        }
        return n
    }

    /// Index just past the closing quote (doubled quotes are escapes), or the end of the text.
    private static func endOfQuoted(_ s: UnsafeBufferPointer<UInt16>, from start: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        let n = s.count
        var j = start
        while j < n {
            let c = s[j]
            if backslashEscapes, c == Char.backslash {
                j += 2
            } else if c == quote {
                if j + 1 < n, s[j + 1] == quote {
                    j += 2
                } else {
                    return j + 1
                }
            } else {
                j += 1
            }
        }
        return n
    }

    private static func endOfNumber(_ s: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        let n = s.count
        var j = start
        if s[j] == 0x30, j + 1 < n, (s[j + 1] | 0x20) == Char.lowerX {
            j += 2
            while j < n, isDigit(s[j]) || ((s[j] | 0x20) >= 0x61 && (s[j] | 0x20) <= 0x66) { j += 1 }
            return j
        }
        j = endOfDigits(s, from: j)
        if j < n, s[j] == Char.dot {
            j = endOfDigits(s, from: j + 1)
        }
        if j < n, (s[j] | 0x20) == Char.lowerE {
            var k = j + 1
            if k < n, s[k] == Char.plus || s[k] == Char.minus { k += 1 }
            if k < n, isDigit(s[k]) { j = endOfDigits(s, from: k) }
        }
        return j
    }

    /// For a `$` at `start`, returns the index just past the opening `$tag$` delimiter, or nil when
    /// this is not a dollar quote.
    private static func dollarTagEnd(_ s: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let n = s.count
        var j = start + 1
        guard j < n else { return nil }
        if s[j] == Char.dollar { return j + 1 }
        guard isIdentifierStart(s[j]) else { return nil }
        j += 1
        while j < n, isIdentifierStart(s[j]) || isDigit(s[j]) { j += 1 }
        return j < n && s[j] == Char.dollar ? j + 1 : nil
    }

    /// Index just past the closing delimiter matching s[tagStart..<tagEnd], or the end of the text.
    private static func endOfDollarQuote(_ s: UnsafeBufferPointer<UInt16>, tagStart: Int, tagEnd: Int) -> Int {
        let n = s.count
        let tagLength = tagEnd - tagStart
        var j = tagEnd
        while j + tagLength <= n {
            if s[j] == Char.dollar {
                var k = 1
                while k < tagLength, s[j + k] == s[tagStart + k] { k += 1 }
                if k == tagLength { return j + tagLength }
            }
            j += 1
        }
        return n
    }

    private static func nextNonBlank(_ s: UnsafeBufferPointer<UInt16>, from start: Int) -> UInt16? {
        var j = start
        while j < s.count, s[j] == Char.space || s[j] == Char.tab { j += 1 }
        return j < s.count ? s[j] : nil
    }

    /// Upper-cased ASCII word, or nil when the word cannot be a keyword (too long or non-ASCII).
    private static func upperCasedASCIIWord(_ s: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> String? {
        let length = end - start
        guard length <= 32 else { return nil }
        for j in start..<end where s[j] >= 0x80 { return nil }
        return String(unsafeUninitializedCapacity: length) { buffer in
            for k in 0..<length {
                let c = s[start + k]
                buffer[k] = UInt8(c >= 0x61 && c <= 0x7A ? c - 0x20 : c)
            }
            return length
        }
    }
}
