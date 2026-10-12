import Foundation
import Testing
@testable import Dbee

@Suite struct SQLSplitterTests {
    private func texts(_ script: String, _ kind: DatabaseKind) -> [String] {
        let statements = SQLSplitter.split(script, kind: kind)
        assertRangesMatch(statements, in: script)
        return statements.map(\.text)
    }

    private func assertRangesMatch(_ statements: [SQLSplitter.Statement], in script: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        let ns = script as NSString
        var previousEnd = 0
        for statement in statements {
            #expect(statement.range.location >= previousEnd, sourceLocation: sourceLocation)
            #expect(NSMaxRange(statement.range) <= ns.length, sourceLocation: sourceLocation)
            if NSMaxRange(statement.range) <= ns.length {
                #expect(ns.substring(with: statement.range) == statement.text, sourceLocation: sourceLocation)
            }
            #expect(!statement.text.isEmpty, sourceLocation: sourceLocation)
            #expect(statement.text.trimmingCharacters(in: .whitespacesAndNewlines) == statement.text, sourceLocation: sourceLocation)
            previousEnd = NSMaxRange(statement.range)
        }
    }

    // MARK: Basics

    @Test(arguments: DatabaseKind.allCases)
    func emptyAndBlankInput(kind: DatabaseKind) {
        #expect(texts("", kind).isEmpty)
        #expect(texts("   \n\t\r\n  ", kind).isEmpty)
        #expect(texts(";", kind).isEmpty)
        #expect(texts(" ; ;\n;; ", kind).isEmpty)
    }

    @Test(arguments: DatabaseKind.allCases)
    func commentOnlyInput(kind: DatabaseKind) {
        #expect(texts("-- just a comment", kind).isEmpty)
        #expect(texts("-- one;\n-- two;\n", kind).isEmpty)
        #expect(texts("/* block; comment */", kind).isEmpty)
        #expect(texts("/* a */ ; -- b\n ; /* c", kind).isEmpty)
        #expect(texts("SELECT 1; -- trailing; comment", kind) == ["SELECT 1"])
    }

    @Test(arguments: DatabaseKind.allCases)
    func splitsOnTopLevelSemicolons(kind: DatabaseKind) {
        #expect(texts("SELECT 1; SELECT 2;", kind) == ["SELECT 1", "SELECT 2"])
        #expect(texts("SELECT 1;SELECT 2", kind) == ["SELECT 1", "SELECT 2"])
        #expect(texts("SELECT 1", kind) == ["SELECT 1"])
        #expect(texts("SELECT 1;;;SELECT 2;;", kind) == ["SELECT 1", "SELECT 2"])
        #expect(texts("\n\n  UPDATE t\n  SET a = 1\n  WHERE b = 2  ;\n\n", kind) == ["UPDATE t\n  SET a = 1\n  WHERE b = 2"])
    }

    @Test(arguments: DatabaseKind.allCases)
    func trimsSurroundingCommentsButKeepsInnerOnes(kind: DatabaseKind) {
        let script = "-- leading\n/* block */ SELECT /* ; */ 1 -- inner;\n FROM t -- trailing\n;\nSELECT 2 /* tail */"
        #expect(texts(script, kind) == ["SELECT /* ; */ 1 -- inner;\n FROM t", "SELECT 2"])
    }

    @Test(arguments: DatabaseKind.allCases)
    func handlesCRLFAndTrailingWhitespace(kind: DatabaseKind) {
        #expect(texts("-- c\r\nSELECT 1;\r\nSELECT 2   \r\n\t", kind) == ["SELECT 1", "SELECT 2"])
        let statements = SQLSplitter.split("SELECT 1   \n\t", kind: kind)
        #expect(statements.map(\.range) == [NSRange(location: 0, length: 8)])
    }

    // MARK: Strings and identifiers

    @Test(arguments: DatabaseKind.allCases)
    func semicolonsInsideQuotes(kind: DatabaseKind) {
        #expect(texts("SELECT ';'; SELECT 2", kind) == ["SELECT ';'", "SELECT 2"])
        #expect(texts("SELECT 'it''s; fine'; SELECT 2", kind) == ["SELECT 'it''s; fine'", "SELECT 2"])
        #expect(texts("SELECT \"a;b\" FROM \"x\"\"y;\"; SELECT 2", kind) == ["SELECT \"a;b\" FROM \"x\"\"y;\"", "SELECT 2"])
    }

    @Test(arguments: DatabaseKind.allCases)
    func commentMarkersInsideQuotes(kind: DatabaseKind) {
        let script = "SELECT '--;', '/* ;', \"-- x;\"; SELECT '*/;'"
        #expect(texts(script, kind) == ["SELECT '--;', '/* ;', \"-- x;\"", "SELECT '*/;'"])
    }

    @Test(arguments: DatabaseKind.allCases)
    func quotesInsideComments(kind: DatabaseKind) {
        let script = "-- it's a 'comment;\nSELECT 1; /* don't \" ` ; */ SELECT 2; -- '\nSELECT 3"
        #expect(texts(script, kind) == ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    @Test func backslashesInStandardStrings() {
        // Postgres (standard_conforming_strings) and SQLite: a backslash does not escape the quote.
        for kind in [DatabaseKind.postgres, .sqlite] {
            #expect(texts("SELECT 'C:\\'; SELECT 2", kind) == ["SELECT 'C:\\'", "SELECT 2"])
            #expect(texts("SELECT * FROM t WHERE type='\\'; SELECT 2", kind) == ["SELECT * FROM t WHERE type='\\'", "SELECT 2"])
        }
        // MySQL: it does, so the string is unterminated and swallows the rest.
        #expect(texts("SELECT 'C:\\'; SELECT 2", .mysql) == ["SELECT 'C:\\'; SELECT 2"])
    }

    @Test func mysqlBackslashEscapes() {
        #expect(texts("SELECT 'a\\';b'; SELECT 2", .mysql) == ["SELECT 'a\\';b'", "SELECT 2"])
        #expect(texts("SELECT \"a\\\";b\"; SELECT 2", .mysql) == ["SELECT \"a\\\";b\"", "SELECT 2"])
        #expect(texts("SELECT 'a\\\\'; SELECT 2", .mysql) == ["SELECT 'a\\\\'", "SELECT 2"])
        #expect(texts("SELECT `a``;b`, `c;`; SELECT 2", .mysql) == ["SELECT `a``;b`, `c;`", "SELECT 2"])
    }

    @Test func postgresEscapeStrings() {
        #expect(texts("SELECT E'a\\';b'; SELECT 2", .postgres) == ["SELECT E'a\\';b'", "SELECT 2"])
        #expect(texts("SELECT e'\\\\'; SELECT 2", .postgres) == ["SELECT e'\\\\'", "SELECT 2"])
        #expect(texts("SELECT E'it''s;'; SELECT 2", .postgres) == ["SELECT E'it''s;'", "SELECT 2"])
        // Only a standalone E prefixes an escape string.
        #expect(texts("SELECT date'\\'; SELECT 2", .postgres) == ["SELECT date'\\'", "SELECT 2"])
        #expect(texts("SELECT U&'\\0041'; SELECT 2", .postgres) == ["SELECT U&'\\0041'", "SELECT 2"])
    }

    @Test func sqliteIdentifierQuotes() {
        #expect(texts("SELECT [a;b], `c;d` FROM t; SELECT 2", .sqlite) == ["SELECT [a;b], `c;d` FROM t", "SELECT 2"])
        // Brackets are array subscripts in Postgres, not quotes.
        #expect(texts("SELECT a[1]; SELECT 2", .postgres) == ["SELECT a[1]", "SELECT 2"])
    }

    @Test(arguments: DatabaseKind.allCases)
    func unterminatedTokensRunToEnd(kind: DatabaseKind) {
        #expect(texts("SELECT 1; SELECT 'abc; SELECT 2", kind) == ["SELECT 1", "SELECT 'abc; SELECT 2"])
        #expect(texts("SELECT \"abc; SELECT 2", kind) == ["SELECT \"abc; SELECT 2"])
        #expect(texts("SELECT 1; /* unterminated; SELECT 2", kind) == ["SELECT 1"])
        #expect(texts("SELECT 'x'''", kind) == ["SELECT 'x'''"])
        // Trailing whitespace inside an unterminated token is still trimmed.
        #expect(texts("SELECT 'abc  \n\t", kind) == ["SELECT 'abc"])
    }

    // MARK: Comments

    @Test func nestedBlockComments() {
        let script = "/* outer /* inner; */ still comment; */ SELECT 1; SELECT 2"
        #expect(texts(script, .postgres) == ["SELECT 1", "SELECT 2"])
        // MySQL and SQLite end the comment at the first */.
        #expect(texts(script, .mysql) == ["still comment", "*/ SELECT 1", "SELECT 2"])
        #expect(texts(script, .sqlite) == ["still comment", "*/ SELECT 1", "SELECT 2"])
    }

    @Test func hashComments() {
        #expect(texts("SELECT 1 # note; more\n; SELECT 2", .mysql) == ["SELECT 1", "SELECT 2"])
        // In Postgres # is the XOR operator.
        #expect(texts("SELECT 1 # 2; SELECT 3", .postgres) == ["SELECT 1 # 2", "SELECT 3"])
    }

    @Test func mysqlDoubleDashNeedsWhitespace() {
        #expect(texts("SELECT 5--1;\nSELECT 2", .mysql) == ["SELECT 5--1", "SELECT 2"])
        // With whitespace after it, -- is a comment that hides the semicolon.
        #expect(texts("SELECT 5 -- 1;\nSELECT 2", .mysql) == ["SELECT 5 -- 1;\nSELECT 2"])
        #expect(texts("SELECT 5 --\tx;\n;SELECT 2", .mysql) == ["SELECT 5", "SELECT 2"])
        #expect(texts("SELECT 5 --", .mysql) == ["SELECT 5"])
        #expect(texts("SELECT 5--1;\nSELECT 2", .postgres) == ["SELECT 5--1;\nSELECT 2"])
    }

    @Test func serverInterpretedCommentsAreKept() {
        #expect(texts("/*!40101 SET NAMES utf8mb4 */;\n/*M!100100 SET x = 1 */;\n/* plain */;", .mysql)
            == ["/*!40101 SET NAMES utf8mb4 */", "/*M!100100 SET x = 1 */"])
        #expect(texts("/*+ SeqScan(t) */ SELECT * FROM t; /* note */ SELECT 2", .postgres)
            == ["/*+ SeqScan(t) */ SELECT * FROM t", "SELECT 2"])
        #expect(texts("/*+ hint */ SELECT 1", .sqlite) == ["SELECT 1"])
    }

    // MARK: Postgres dollar quotes and bodies

    @Test func dollarQuotedFunctionBodies() {
        let function = """
        CREATE OR REPLACE FUNCTION inc(i int) RETURNS int AS $$
        BEGIN
          -- don't stop here;
          RETURN i + 1; /* nor here; */
        END;
        $$ LANGUAGE plpgsql
        """
        #expect(texts(function + ";\nSELECT inc(1);", .postgres) == [function, "SELECT inc(1)"])

        let tagged = "DO $body$ BEGIN RAISE NOTICE '$$;'; PERFORM $$x;$$; END $body$"
        #expect(texts(tagged + "; SELECT 2", .postgres) == [tagged, "SELECT 2"])
        #expect(texts("SELECT $a$x;$b$;$a$; SELECT 2", .postgres) == ["SELECT $a$x;$b$;$a$", "SELECT 2"])
        #expect(texts("SELECT $é$;$é$; SELECT 2", .postgres) == ["SELECT $é$;$é$", "SELECT 2"])
    }

    @Test func dollarSignsThatAreNotQuotes() {
        #expect(texts("SELECT $1, $2; SELECT 3", .postgres) == ["SELECT $1, $2", "SELECT 3"])
        #expect(texts("SELECT a$b$, c$$; SELECT 3", .postgres) == ["SELECT a$b$, c$$", "SELECT 3"])
        #expect(texts("SELECT $$x; SELECT 3", .postgres) == ["SELECT $$x; SELECT 3"])
        // Other engines have no dollar quoting.
        #expect(texts("SELECT $$; SELECT 3", .mysql) == ["SELECT $$", "SELECT 3"])
        #expect(texts("SELECT $x; SELECT 3", .sqlite) == ["SELECT $x", "SELECT 3"])
    }

    @Test func postgresBeginAtomicBodies() {
        let function = """
        CREATE FUNCTION f(a int) RETURNS int LANGUAGE sql
        BEGIN ATOMIC
          INSERT INTO log VALUES (a);
          SELECT CASE WHEN a > 0 THEN 1 ELSE 0 END;
        END
        """
        #expect(texts(function + "; SELECT f(1)", .postgres) == [function, "SELECT f(1)"])
        let procedure = "CREATE OR REPLACE PROCEDURE p() LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END"
        #expect(texts(procedure + ";SELECT 3", .postgres) == [procedure, "SELECT 3"])
    }

    @Test(arguments: DatabaseKind.allCases)
    func transactionBeginIsNotABlock(kind: DatabaseKind) {
        #expect(texts("BEGIN; INSERT INTO t VALUES (1); END; COMMIT;", kind)
            == ["BEGIN", "INSERT INTO t VALUES (1)", "END", "COMMIT"])
        #expect(texts("SELECT CASE WHEN a THEN 1 END; SELECT 2", kind) == ["SELECT CASE WHEN a THEN 1 END", "SELECT 2"])
    }

    @Test func postgresParenthesesKeepRuleActionsTogether() {
        let rule = "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2))"
        #expect(texts(rule + "; SELECT 1", .postgres) == [rule, "SELECT 1"])
    }

    // MARK: SQLite triggers

    @Test func sqliteTriggerBodiesStayWhole() {
        let trigger = """
        CREATE TRIGGER audit AFTER UPDATE ON items
        WHEN CASE WHEN new.qty > 0 THEN 1 ELSE 0 END
        BEGIN
          INSERT INTO log(msg) VALUES ('updated; ' || new.id);
          UPDATE totals SET n = CASE WHEN n IS NULL THEN 1 ELSE n + 1 END;
          UPDATE items SET touched = new.end WHERE id = new.id;
        END
        """
        #expect(texts(trigger + ";\nSELECT 1;", .sqlite) == [trigger, "SELECT 1"])
        let temp = "create temp trigger t2 before delete on x begin select raise(abort, 'no;'); end"
        #expect(texts(temp + "; select 2", .sqlite) == [temp, "select 2"])
        #expect(texts("CREATE TABLE trigger_log (id INTEGER); SELECT 1", .sqlite) == ["CREATE TABLE trigger_log (id INTEGER)", "SELECT 1"])
    }

    // MARK: MySQL routines and DELIMITER

    @Test func mysqlRoutinesWithoutDelimiter() {
        let procedure = """
        CREATE DEFINER=`root`@`localhost` PROCEDURE p(IN x INT)
        BEGIN
          DECLARE i INT DEFAULT 0;
          IF x > 0 THEN SET i = 1; ELSEIF x < 0 THEN SET i = -1; END IF;
          WHILE i < 10 DO SET i = i + 1; END WHILE;
          lbl: LOOP LEAVE lbl; END LOOP lbl;
          REPEAT SET i = i - 1; UNTIL i <= 0 END REPEAT;
          CASE x WHEN 1 THEN SELECT 1; ELSE SELECT 2; END CASE;
          SELECT CASE WHEN x THEN 1 ELSE 0 END;
          BEGIN SELECT 1; END;
          IF x THEN SELECT IF(x, 1, 0); END IF;
        END
        """
        #expect(texts(procedure + ";\nCALL p(1);", .mysql) == [procedure, "CALL p(1)"])

        let trigger = "CREATE TRIGGER trg BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.a = 1; SET NEW.end = 2; END"
        #expect(texts(trigger + "; SELECT 1", .mysql) == [trigger, "SELECT 1"])
        let simpleTrigger = "CREATE TRIGGER trg BEFORE INSERT ON t FOR EACH ROW SET NEW.a = 1"
        #expect(texts(simpleTrigger + "; SELECT 1", .mysql) == [simpleTrigger, "SELECT 1"])
        let event = "CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO BEGIN DELETE FROM t; DELETE FROM u; END"
        #expect(texts(event + "; SELECT 1", .mysql) == [event, "SELECT 1"])
        #expect(texts("CREATE TABLE event (begin DATE); SELECT 1", .mysql) == ["CREATE TABLE event (begin DATE)", "SELECT 1"])
        #expect(texts("CREATE DEFINER = root@localhost SQL SECURITY INVOKER VIEW v AS SELECT 1; SELECT 2", .mysql)
            == ["CREATE DEFINER = root@localhost SQL SECURITY INVOKER VIEW v AS SELECT 1", "SELECT 2"])
    }

    @Test func mysqlDelimiterCommand() {
        let script = """
        DELIMITER $$
        CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$
        SELECT 'a$$b'$$
        delimiter ;
        CALL p();
        DELIMITER //
        SELECT 3 //
        DELIMITER ;;
        SELECT 4;;
        """
        #expect(texts(script, .mysql) == [
            "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
            "SELECT 'a$$b'",
            "CALL p()",
            "SELECT 3",
            "SELECT 4",
        ])
        // Only recognised at the start of a statement, and only for MySQL.
        #expect(texts("SELECT delimiter FROM t; SELECT 2", .mysql) == ["SELECT delimiter FROM t", "SELECT 2"])
        #expect(texts("DELIMITER\nSELECT 1", .mysql) == ["DELIMITER\nSELECT 1"])
    }

    // MARK: Unicode ranges

    @Test(arguments: DatabaseKind.allCases)
    func utf16RangesWithEmojiAndMultibyteText(kind: DatabaseKind) {
        let script = "-- 💥 é\nSELECT '😀;' AS \"🎉\";\n\t/* 世界 */ SELECT 'e\u{301}', 👩‍👩‍👧 ;  SELECT 3"
        let statements = SQLSplitter.split(script, kind: kind)
        #expect(statements.map(\.text) == ["SELECT '😀;' AS \"🎉\"", "SELECT 'e\u{301}', 👩‍👩‍👧", "SELECT 3"])
        assertRangesMatch(statements, in: script)
        let ns = script as NSString
        #expect(statements[0].range == ns.range(of: "SELECT '😀;' AS \"🎉\""))
        #expect(statements[1].range == ns.range(of: "SELECT 'e\u{301}', 👩‍👩‍👧", options: .literal))
        #expect(statements[2].range == NSRange(location: ns.length - 8, length: 8))
    }

    @Test func rangesForCombiningMarkAfterSemicolon() {
        let script = "SELECT 1;\u{301}SELECT 2"
        let statements = SQLSplitter.split(script, kind: .postgres)
        assertRangesMatch(statements, in: script)
        #expect(statements.first?.text == "SELECT 1")
    }

    // MARK: Cursor lookup

    @Test func statementAtCursor() {
        let script = "SELECT 1;\n\nSELECT 2;\n-- note\nSELECT 3  ;  "
        func at(_ cursor: Int) -> String? { SQLSplitter.statement(at: cursor, in: script, kind: .postgres)?.text }
        let ns = script as NSString
        let second = ns.range(of: "SELECT 2").location
        let third = ns.range(of: "SELECT 3").location
        #expect(at(0) == "SELECT 1")
        #expect(at(4) == "SELECT 1")
        #expect(at(8) == "SELECT 1")          // end of the text, before the semicolon
        #expect(at(9) == "SELECT 1")          // right after the semicolon
        #expect(at(10) == "SELECT 1")         // blank line
        #expect(at(second) == "SELECT 2")
        #expect(at(second + 8) == "SELECT 2")
        #expect(at(ns.range(of: "-- note").location + 3) == "SELECT 2")  // inside a comment
        #expect(at(third + 1) == "SELECT 3")
        #expect(at(ns.length) == "SELECT 3")
        #expect(at(ns.length + 50) == "SELECT 3")
    }

    @Test func statementAtCursorBeforeFirstStatement() {
        let script = "-- header\n\n   SELECT 1; SELECT 2"
        #expect(SQLSplitter.statement(at: 0, in: script, kind: .mysql)?.text == "SELECT 1")
        #expect(SQLSplitter.statement(at: 12, in: script, kind: .mysql)?.text == "SELECT 1")
        #expect(SQLSplitter.statement(at: -5, in: script, kind: .mysql)?.text == "SELECT 1")
    }

    @Test func statementAtCursorWithoutStatements() {
        #expect(SQLSplitter.statement(at: 0, in: "", kind: .sqlite) == nil)
        #expect(SQLSplitter.statement(at: 3, in: "-- only a comment", kind: .sqlite) == nil)
    }

    @Test func statementAtCursorUsesUTF16Offsets() {
        let script = "SELECT '😀😀'; SELECT 2"
        let ns = script as NSString
        let second = ns.range(of: "SELECT 2")
        // "SELECT '😀😀'" is 13 UTF-16 units (each emoji is a surrogate pair); 12 is before its closing quote.
        #expect(SQLSplitter.split(script, kind: .postgres).first?.range == NSRange(location: 0, length: 13))
        #expect(SQLSplitter.statement(at: 12, in: script, kind: .postgres)?.text == "SELECT '😀😀'")
        #expect(SQLSplitter.statement(at: second.location, in: script, kind: .postgres)?.range == second)
    }

    // MARK: Scale and robustness

    @Test func largeScriptSplitsInOnePass() {
        var script = ""
        let chunk = """
        INSERT INTO items (name, note) VALUES ('café 😀', 'it''s; fine'); -- comment; here
        /* block; */ UPDATE items SET note = E'x\\';y' WHERE id = 1;
        CREATE FUNCTION f() RETURNS int AS $f$ SELECT 1; $f$ LANGUAGE sql;

        """
        while script.utf8.count < 1_200_000 { script += chunk }
        let repeats = script.components(separatedBy: "INSERT INTO").count - 1
        let clock = ContinuousClock()
        var statements: [SQLSplitter.Statement] = []
        let elapsed = clock.measure { statements = SQLSplitter.split(script, kind: .postgres) }
        #expect(statements.count == repeats * 3)
        #expect(statements.last?.text == "CREATE FUNCTION f() RETURNS int AS $f$ SELECT 1; $f$ LANGUAGE sql")
        #expect(elapsed < .seconds(5))
        // Spot-check exact ranges near the end of the script.
        let ns = script as NSString
        for statement in statements.suffix(3) {
            #expect(ns.substring(with: statement.range) == statement.text)
        }
    }

    @Test func unterminatedDollarQuoteInLargeScriptIsLinear() {
        let script = "SELECT $$" + String(repeating: "x; $a ", count: 200_000)
        let clock = ContinuousClock()
        var statements: [SQLSplitter.Statement] = []
        let elapsed = clock.measure { statements = SQLSplitter.split(script, kind: .postgres) }
        #expect(statements.count == 1)
        #expect(elapsed < .seconds(5))
    }

    @Test(arguments: DatabaseKind.allCases)
    func randomScriptsKeepRangeInvariants(kind: DatabaseKind) {
        let fragments = [
            "SELECT 1", ";", " ", "\n", "'a;b'", "'it''s'", "\"q;\"", "`b;`", "-- c;\n", "# h;\n", "/* x; */",
            "/*", "*/", "$$", "$t$", "E'\\';'", "'\\'", "😀", "é", "e\u{301}", "世界", "BEGIN", "END", "CASE",
            "CREATE TRIGGER x ", "CREATE PROCEDURE p ", "(", ")", "[", "]", "--", "\r\n", "DELIMITER // \n", "//",
        ]
        var rng = SplitterTestRNG(seed: 0xDBEE + UInt64(kind.rawValue.count))
        for _ in 0..<300 {
            var script = ""
            for _ in 0..<Int.random(in: 0...40, using: &rng) {
                script += fragments.randomElement(using: &rng)!
            }
            let statements = SQLSplitter.split(script, kind: kind)
            assertRangesMatch(statements, in: script)
            for statement in statements {
                let middle = statement.range.location + statement.range.length / 2
                #expect(SQLSplitter.statement(at: middle, in: script, kind: kind) == statement)
            }
        }
    }
}

/// Deterministic SplitMix64 generator so random-script failures are reproducible.
private struct SplitterTestRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
