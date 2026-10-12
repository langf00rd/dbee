import Foundation
import Testing
@testable import Dbee

/// "kind:text" pairs, which read well in failure messages.
private func lex(_ sql: String, _ kind: DatabaseKind = .postgres) -> [String] {
    let ns = sql as NSString
    return SQLHighlighter.tokens(in: sql, kind: kind).map { "\($0.kind):\(ns.substring(with: $0.range))" }
}

@Suite struct SQLHighlighterTests {
    @Test func keywordsAreCaseInsensitive() {
        #expect(lex("select id from Users WHERE x = 1") == [
            "keyword:select", "keyword:from", "keyword:WHERE", "number:1",
        ])
    }

    @Test func emptyAndBlankInput() {
        #expect(lex("").isEmpty)
        #expect(lex("  \n\t ").isEmpty)
        #expect(SQLHighlighter.tokens(in: "" as NSString, kind: .mysql).isEmpty)
    }

    @Test func stringsWithDoubledQuotes() {
        #expect(lex("SELECT 'it''s', ''") == ["keyword:SELECT", "string:'it''s'", "string:''"])
    }

    @Test func unterminatedStringRunsToEnd() {
        #expect(lex("SELECT 'abc\nFROM t") == ["keyword:SELECT", "string:'abc\nFROM t"])
    }

    @Test func lineComments() {
        #expect(lex("-- note\nSELECT 1") == ["comment:-- note", "keyword:SELECT", "number:1"])
        #expect(lex("SELECT 1 -- trailing") == ["keyword:SELECT", "number:1", "comment:-- trailing"])
        #expect(lex("-- crlf\r\nSELECT") == ["comment:-- crlf", "keyword:SELECT"])
    }

    @Test func blockCommentsSpanLines() {
        #expect(lex("/* a\n b */ SELECT") == ["comment:/* a\n b */", "keyword:SELECT"])
        #expect(lex("SELECT /* open") == ["keyword:SELECT", "comment:/* open"])
    }

    @Test func postgresBlockCommentsNest() {
        #expect(lex("/* a /* b */ c */ SELECT", .postgres) == ["comment:/* a /* b */ c */", "keyword:SELECT"])
        #expect(lex("/* a /* b */ c */ SELECT", .mysql) == ["comment:/* a /* b */", "keyword:SELECT"])
    }

    @Test func dollarQuotedStrings() {
        #expect(lex("SELECT $$ it's -- not a comment $$") == ["keyword:SELECT", "string:$$ it's -- not a comment $$"])
        #expect(lex("AS $fn$ BEGIN $$x$$ END $fn$;") == ["keyword:AS", "string:$fn$ BEGIN $$x$$ END $fn$"])
        #expect(lex("SELECT $tag$ open") == ["keyword:SELECT", "string:$tag$ open"])
    }

    @Test func postgresPositionalParameters() {
        #expect(lex("WHERE id = $1 AND b = $12") == ["keyword:WHERE", "parameter:$1", "keyword:AND", "parameter:$12"])
    }

    @Test func postgresOperatorsAreNotParameters() {
        #expect(lex("data ? 'key'", .postgres) == ["string:'key'"])
        #expect(lex("x::int", .postgres) == ["type:int"])
    }

    @Test func numbers() {
        #expect(lex("1 2.5 .5 1e10 1.5E-3 0xFF 7.") == [
            "number:1", "number:2.5", "number:.5", "number:1e10", "number:1.5E-3", "number:0xFF", "number:7.",
        ])
    }

    @Test func digitsInsideIdentifiersAreNotNumbers() {
        #expect(lex("t1 x2y _3 t.c1").isEmpty)
    }

    @Test func quotedIdentifiersAreNeverKeywords() {
        #expect(lex(#"SELECT "select" FROM "my ""table""""#) == [
            "keyword:SELECT", #"quotedIdentifier:"select""#, "keyword:FROM", #"quotedIdentifier:"my ""table""""#,
        ])
    }

    @Test func qualifiedNamesAreNotKeywords() {
        #expect(lex("SELECT t.select, t.from FROM t") == ["keyword:SELECT", "keyword:FROM"])
    }

    @Test func functionsNeedParentheses() {
        #expect(lex("SELECT count(*), left (name, 2) FROM a LEFT JOIN b") == [
            "keyword:SELECT", "function:count", "function:left", "number:2", "keyword:FROM", "keyword:LEFT", "keyword:JOIN",
        ])
        #expect(lex("CREATE TABLE t (id integer, name varchar(20))") == [
            "keyword:CREATE", "keyword:TABLE", "type:integer", "type:varchar", "number:20",
        ])
    }

    @Test func mysqlLexicalRules() {
        #expect(lex(#"SELECT `order`, "a\"b" # note"#, .mysql) == [
            "keyword:SELECT", "quotedIdentifier:`order`", #"string:"a\"b""#, "comment:# note",
        ])
        #expect(lex(#"'it\'s'"#, .mysql) == [#"string:'it\'s'"#])
    }

    @Test func mysqlDoubleDashNeedsWhitespace() {
        #expect(lex("SELECT 1--1", .mysql) == ["keyword:SELECT", "number:1", "number:1"])
        #expect(lex("SELECT 1-- 1", .mysql) == ["keyword:SELECT", "number:1", "comment:-- 1"])
        #expect(lex("SELECT 1--1", .postgres) == ["keyword:SELECT", "number:1", "comment:--1"])
    }

    @Test func backslashIsLiteralInStandardStrings() {
        #expect(lex(#"SELECT 'C:\' , 1"#, .postgres) == ["keyword:SELECT", #"string:'C:\'"#, "number:1"])
        #expect(lex(#"SELECT E'it\'s', 1"#, .postgres) == ["keyword:SELECT", #"string:E'it\'s'"#, "number:1"])
    }

    @Test func prefixedLiterals() {
        #expect(lex("X'FF' n'abc' B'01'", .sqlite) == ["string:X'FF'", "string:n'abc'", "string:B'01'"])
    }

    @Test func sqliteIdentifiersAndParameters() {
        #expect(lex("SELECT [my col] FROM t WHERE a = ? AND b = :name AND c = @v AND d = $x AND e = ?2", .sqlite) == [
            "keyword:SELECT", "quotedIdentifier:[my col]", "keyword:FROM", "keyword:WHERE", "parameter:?",
            "keyword:AND", "parameter::name", "keyword:AND", "parameter:@v", "keyword:AND", "parameter:$x",
            "keyword:AND", "parameter:?2",
        ])
    }

    @Test func mysqlVariables() {
        #expect(lex("SET @x = @@session.sql_mode", .mysql) == ["keyword:SET", "parameter:@x", "parameter:@@session"])
    }

    @Test func rangesAreUTF16Offsets() {
        let sql = "SELECT '😀é' AS 名前, 1"
        let tokens = SQLHighlighter.tokens(in: sql, kind: .postgres)
        #expect(tokens.map(\.kind) == [.keyword, .string, .keyword, .number])
        #expect(tokens[1].range == NSRange(location: 7, length: 5))
        #expect(tokens[3].range == NSRange(location: (sql as NSString).length - 1, length: 1))
    }

    @Test func stringAndNSStringEntryPointsAgree() {
        let sql = "/* x */ SELECT 'a', \"b\", $1, 2.5 FROM t -- y\n"
        #expect(SQLHighlighter.tokens(in: sql, kind: .postgres) == SQLHighlighter.tokens(in: sql as NSString, kind: .postgres))
    }

    @Test func tokensAreSortedAndBinarySearchable() {
        let sql = String(repeating: "SELECT 'a' FROM t; -- c\n", count: 50)
        let tokens = SQLHighlighter.tokens(in: sql, kind: .postgres)
        #expect(zip(tokens, tokens.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location })
        #expect(SQLHighlighter.firstTokenIndex(endingAfter: 0, in: tokens) == 0)
        let index = SQLHighlighter.firstTokenIndex(endingAfter: 8, in: tokens)
        #expect(tokens[index].kind == .string)
        #expect(SQLHighlighter.firstTokenIndex(endingAfter: (sql as NSString).length, in: tokens) == tokens.count)
    }

    @Test func largeDocument() {
        let line = "INSERT INTO events (id, name, payload) VALUES (42, 'name''s', '{\"k\": 1}'); -- row\n"
        let sql = String(repeating: line, count: 5_000)
        let tokens = SQLHighlighter.tokens(in: sql as NSString, kind: .postgres)
        #expect(tokens.count == 5_000 * 7)
        #expect(tokens.prefix(7).map(\.kind) == [.keyword, .keyword, .keyword, .number, .string, .string, .comment])
        #expect(NSMaxRange(tokens.last!.range) <= (sql as NSString).length)
    }

    @Test func keywordListsHaveNoGaps() {
        for kind in DatabaseKind.sqlKinds {
            let words = SQLKeywords.completionWords(for: kind)
            #expect(words == words.sorted())
            #expect(Set(words).count == words.count)
            #expect(SQLKeywords.keywords(for: kind).contains("SELECT"))
        }
        #expect(SQLKeywords.keywords(for: .mysql).contains("AUTO_INCREMENT"))
        #expect(SQLKeywords.keywords(for: .sqlite).contains("PRAGMA"))
        #expect(SQLKeywords.keywords(for: .postgres).contains("ILIKE"))
    }

    // MARK: Completion

    @Suite struct Completion {
        @Test func keywordsFollowTheCaseOfThePrefix() {
            #expect(SQLCompletion.candidates(for: "sel", words: [], kind: .postgres).first == "select")
            #expect(SQLCompletion.candidates(for: "SEL", words: [], kind: .postgres).first == "SELECT")
        }

        @Test func schemaObjectsComeFirst() {
            let words = ["users", "user_roles", "Sessions"]
            let candidates = SQLCompletion.candidates(for: "us", words: words, kind: .postgres)
            #expect(Set(candidates.prefix(2)) == ["user_roles", "users"])
            #expect(candidates.contains("using"))
            #expect(!candidates.contains("Sessions"))
            #expect(SQLCompletion.candidates(for: "SE", words: words, kind: .postgres).first == "Sessions")
        }

        @Test func exactMatchesOfferNothing() {
            #expect(!SQLCompletion.candidates(for: "users", words: ["users"], kind: .postgres).contains("users"))
            #expect(SQLCompletion.candidates(for: "select", words: [], kind: .postgres).isEmpty)
        }

        @Test func emptyPrefixOffersSchemaObjectsOnly() {
            #expect(SQLCompletion.candidates(for: "", words: ["orders", "Accounts", "orders", ""], kind: .postgres) == ["Accounts", "orders"])
            #expect(SQLCompletion.candidates(for: "", words: [], kind: .mysql).isEmpty)
        }

        @Test func duplicatesAreRemoved() {
            let candidates = SQLCompletion.candidates(for: "or", words: ["orders", "orders", "ORDER"], kind: .postgres)
            #expect(candidates.filter { $0.lowercased() == "orders" }.count == 1)
            #expect(candidates.filter { $0.lowercased() == "order" }.count == 1)
        }
    }

    // MARK: Editing helpers

    @Suite struct Editing {
        @Test func commentsLinesAtTheSmallestIndent() {
            #expect(SQLEditing.toggleLineComments("SELECT 1\n  FROM t\n") == "-- SELECT 1\n--   FROM t\n")
            #expect(SQLEditing.toggleLineComments("  a\n    b") == "  -- a\n  --   b")
        }

        @Test func uncommentsWhenEveryLineIsCommented() {
            #expect(SQLEditing.toggleLineComments("  -- a\n  --b\n") == "  a\n  b\n")
        }

        @Test func mixedBlocksGetCommented() {
            #expect(SQLEditing.toggleLineComments("-- a\nb") == "-- -- a\n-- b")
        }

        @Test func blankLinesAreLeftAlone() {
            #expect(SQLEditing.toggleLineComments("a\n\nb") == "-- a\n\n-- b")
            #expect(SQLEditing.toggleLineComments("") == "-- ")
            #expect(SQLEditing.toggleLineComments("  \n") == "  -- \n")
        }

        @Test func togglingTwiceRestoresTheText() {
            let block = "SELECT *\n  FROM t\n WHERE x = 1\n"
            #expect(SQLEditing.toggleLineComments(SQLEditing.toggleLineComments(block)) == block)
        }

        @Test func indentAndOutdent() {
            #expect(SQLEditing.indent("a\n\nb", width: 2) == "  a\n\n  b")
            #expect(SQLEditing.outdent("    a\n b\n\tc\nd", width: 2) == "  a\nb\nc\nd")
        }
    }

    // MARK: Result sorting and labels

    @Suite struct Results {
        @Test func numericColumnsSortNumericallyWithNullsLast() {
            let rows: [[CellValue]] = [["10"], ["9"], ["100"], [nil], ["2.5"], ["-1"]]
            let ascending = QueryResultSorter.sorted(rows, column: 0, ascending: true).map { $0[0] }
            #expect(ascending == ["-1", "2.5", "9", "10", "100", nil])
            let descending = QueryResultSorter.sorted(rows, column: 0, ascending: false).map { $0[0] }
            #expect(descending == ["100", "10", "9", "2.5", "-1", nil])
        }

        @Test func textColumnsSortLikeFinder() {
            let rows: [[CellValue]] = [["b"], ["a10"], [nil], ["a2"], ["A"]]
            let sorted = QueryResultSorter.sorted(rows, column: 0, ascending: true).map { $0[0] }
            #expect(sorted == ["A", "a2", "a10", "b", nil])
        }

        @Test func tiesKeepTheirOriginalOrder() {
            let rows: [[CellValue]] = [["1", "first"], ["1", "second"], ["0", "zero"], ["1", "third"]]
            let sorted = QueryResultSorter.sorted(rows, column: 0, ascending: false).map { $0[1] }
            #expect(sorted == ["first", "second", "third", "zero"])
        }

        @Test func missingCellsSortLikeNulls() {
            let rows: [[CellValue]] = [[], ["b"], ["a"]]
            #expect(QueryResultSorter.sorted(rows, column: 0, ascending: true).map(\.count) == [1, 1, 0])
        }

        @Test func numberParsing() {
            #expect(QueryResultSorter.number(from: "-3.5") == -3.5)
            #expect(QueryResultSorter.number(from: "1e6") == 1_000_000)
            #expect(QueryResultSorter.number(from: ".5") == 0.5)
            for text in ["nan", "inf", "Infinity", " 1", "abc", "", "1 2"] {
                #expect(QueryResultSorter.number(from: text) == nil)
            }
        }

        @Test func resultTitles() {
            let update = QueryResult(statement: "-- bump\nupdate t set a = 1", columns: [], rows: [], rowsAffected: 3, duration: 0.01)
            #expect(QueryResultLabels.title(for: update, index: 0) == "UPDATE (3 affected)")
            let create = QueryResult(statement: "CREATE TABLE x (id int)", columns: [], rows: [], rowsAffected: nil, duration: 0)
            #expect(QueryResultLabels.title(for: create, index: 1) == "CREATE")
            let select = QueryResult(statement: "SELECT 1", columns: ["?column?"], rows: [["1"]], rowsAffected: nil, duration: 0)
            #expect(QueryResultLabels.title(for: select, index: 1) == "Result 2 (1 row)")
            let odd = QueryResult(statement: "  ", columns: [], rows: [], rowsAffected: nil, duration: 0)
            #expect(QueryResultLabels.verb(for: odd) == "Statement")
        }

        @Test func scriptFailureNamesTheFailedStatement() {
            #expect(QueryResultLabels.failure(succeeded: 2, total: 3) == "Statement 3 of 3 failed")
            #expect(QueryResultLabels.failure(succeeded: 0, total: 4) == "Statement 1 of 4 failed")
            #expect(QueryResultLabels.failure(succeeded: 1, total: nil) == "Statement 2 failed")
            // A lone statement needs no "Statement 1" prefix.
            #expect(QueryResultLabels.failure(succeeded: 0, total: 1) == nil)
            #expect(QueryResultLabels.failure(succeeded: 0, total: nil) == nil)
        }

        @MainActor @Test func historyAppendTerminatesThePreviousStatement() {
            #expect(QueryHistoryView.appending("SELECT 2", to: "SELECT 1") == "SELECT 1;\n\nSELECT 2")
            #expect(QueryHistoryView.appending("SELECT 2", to: "SELECT 1;  \n") == "SELECT 1;\n\nSELECT 2")
            #expect(QueryHistoryView.appending("SELECT 2", to: " \n") == "SELECT 2")
        }
    }
}
