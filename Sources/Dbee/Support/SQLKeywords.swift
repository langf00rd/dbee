import Foundation

/// Reserved words, data types and built-in functions used by the highlighter and completion.
/// All entries are upper case; lookups are ASCII case-insensitive.
enum SQLKeywords {
    /// Clause and statement keywords shared by every supported engine.
    static let common: Set<String> = [
        "ADD", "ALL", "ALTER", "ALWAYS", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY",
        "CASCADE", "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT",
        "CREATE", "CROSS", "CURRENT", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER",
        "DATABASE", "DEFAULT", "DEFERRABLE", "DEFERRED", "DELETE", "DESC", "DISTINCT", "DO", "DROP", "EACH",
        "ELSE", "END", "ESCAPE", "EXCEPT", "EXCLUSIVE", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FILTER",
        "FIRST", "FOLLOWING", "FOR", "FOREIGN", "FROM", "FULL", "GENERATED", "GRANT", "GROUP", "GROUPS",
        "HAVING", "IF", "IMMEDIATE", "IN", "INDEX", "INITIALLY", "INNER", "INSERT", "INSTEAD", "INTERSECT",
        "INTO", "IS", "JOIN", "KEY", "LAST", "LATERAL", "LEFT", "LIKE", "LIMIT", "LOCAL", "MATCH",
        "MATERIALIZED", "NATURAL", "NEXT", "NO", "NOT", "NOTHING", "NULL", "NULLS", "OF", "OFFSET", "ON",
        "ONLY", "OR", "ORDER", "OTHERS", "OUTER", "OVER", "PARTITION", "PRECEDING", "PRIMARY", "PROCEDURE",
        "RANGE", "RECURSIVE", "REFERENCES", "RELEASE", "RENAME", "REPLACE", "RESTRICT", "RETURNING",
        "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVEPOINT", "SCHEMA", "SELECT", "SET", "SOME",
        "STORED", "TABLE", "TEMP", "TEMPORARY", "THEN", "TIES", "TO", "TRANSACTION", "TRIGGER", "TRUE",
        "TRUNCATE", "UNBOUNDED", "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "VIEW", "VIRTUAL", "WHEN",
        "WHERE", "WINDOW", "WITH", "WITHOUT", "AFTER", "BEFORE", "ACTION", "DEFINER", "INTERVAL", "ZONE",
        "AT", "SEQUENCE", "FUNCTION", "RETURNS", "RETURN", "DECLARE", "CALL", "EXECUTE", "PREPARE",
        "DEALLOCATE", "CURSOR", "CLOSE", "LOCK", "ROLE", "USER", "PRIVILEGES", "CHARACTER", "COMMENT",
    ]

    static let postgres: Set<String> = [
        "ILIKE", "SIMILAR", "ARRAY", "CONCURRENTLY", "REFRESH", "VACUUM", "REINDEX", "CLUSTER", "COPY",
        "STDIN", "STDOUT", "LISTEN", "NOTIFY", "UNLISTEN", "DISCARD", "RESET", "SHOW", "EXTENSION",
        "DOMAIN", "OWNER", "OWNED", "INHERITS", "UNLOGGED", "TABLESPACE", "LANGUAGE", "SETOF", "VARIADIC",
        "OUT", "INOUT", "STABLE", "IMMUTABLE", "VOLATILE", "STRICT", "SECURITY", "INVOKER", "LEAKPROOF",
        "PARALLEL", "POLICY", "SESSION_USER", "LOCALTIME", "LOCALTIMESTAMP", "ORDINALITY", "TABLESAMPLE",
        "OVERRIDING", "IDENTITY", "SYSTEM", "NOWAIT", "SKIP", "LOCKED", "SHARE", "EXCLUDE", "ANALYSE",
        "VERBOSE", "ISNULL", "NOTNULL", "SYMMETRIC", "ASYMMETRIC", "PUBLICATION", "SUBSCRIPTION",
        "PERFORM", "RAISE", "NOTICE", "EXCEPTION", "LOOP", "WHILE", "ELSIF", "FOREACH", "EXIT", "CONTINUE",
        "TYPE", "ENUM", "ATTACH", "DETACH", "CONVERSION", "COLLATION", "OPERATOR", "AGGREGATE",
    ]

    static let mysql: Set<String> = [
        "AUTO_INCREMENT", "CHANGE", "CHARSET", "DATABASES", "DELAYED", "DESCRIBE", "DIV", "DUPLICATE",
        "ENGINE", "FORCE", "FULLTEXT", "HIGH_PRIORITY", "IGNORE", "INTERVAL", "KILL", "LOW_PRIORITY",
        "MODIFY", "MOD", "PROCESSLIST", "REGEXP", "RLIKE", "SCHEMAS", "SHOW", "SPATIAL", "SQL_CALC_FOUND_ROWS",
        "STATUS", "STRAIGHT_JOIN", "TABLES", "UNLOCK", "UNSIGNED", "USE", "VARIABLES", "XOR", "ZEROFILL",
        "GLOBAL", "SESSION", "DELIMITER", "LEAVE", "ITERATE", "REPEAT", "UNTIL", "LOOP", "WHILE", "HANDLER",
        "SIGNAL", "COLUMNS", "FIELDS", "OPTIMIZE", "REPAIR", "PURGE", "GRANTS", "ALGORITHM", "SQL",
        "SECURITY", "INVOKER", "DETERMINISTIC", "READS", "MODIFIES", "CONTAINS", "EVENT", "SCHEDULE",
        "EVERY", "ENUM", "TRIGGERS", "LINES", "TERMINATED", "ENCLOSED", "OUTFILE", "INFILE", "LOAD", "DATA",
    ]

    static let sqlite: Set<String> = [
        "ABORT", "ATTACH", "AUTOINCREMENT", "CONFLICT", "DETACH", "FAIL", "GLOB", "IGNORE", "INDEXED",
        "ISNULL", "NOTNULL", "PLAN", "PRAGMA", "QUERY", "RAISE", "REGEXP", "REINDEX", "ROWID", "STRICT",
        "VACUUM", "UPSERT",
    ]

    /// Built-in type names (highlighted separately from keywords).
    static let types: Set<String> = [
        "BIGINT", "BIGSERIAL", "BINARY", "BIT", "BLOB", "BOOL", "BOOLEAN", "BYTEA", "CHAR", "CIDR",
        "DATE", "DATETIME", "DECIMAL", "DOUBLE", "FLOAT", "FLOAT4", "FLOAT8", "INET", "INT", "INT2",
        "INT4", "INT8", "INTEGER", "JSON", "JSONB", "LONGBLOB", "LONGTEXT", "MACADDR", "MEDIUMBLOB",
        "MEDIUMINT", "MEDIUMTEXT", "MONEY", "NCHAR", "NUMERIC", "NVARCHAR", "OID", "PRECISION", "REAL",
        "REGCLASS", "SERIAL", "SMALLINT", "SMALLSERIAL", "TEXT", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
        "TIMETZ", "TINYBLOB", "TINYINT", "TINYTEXT", "TSQUERY", "TSVECTOR", "UUID", "VARBINARY",
        "VARCHAR", "VARYING", "XML", "YEAR", "INT4RANGE", "INT8RANGE", "NUMRANGE", "TSRANGE", "TSTZRANGE",
        "DATERANGE", "HSTORE", "CITEXT", "GEOMETRY", "POINT",
    ]

    /// Built-in functions. Highlighted as functions only when followed by "(".
    static let functions: Set<String> = [
        "ABS", "AGE", "ARRAY_AGG", "ARRAY_LENGTH", "AVG", "BOOL_AND", "BOOL_OR", "CEIL", "CEILING",
        "CHAR_LENGTH", "CHARACTER_LENGTH", "COALESCE", "CONCAT", "CONCAT_WS", "COUNT", "CURDATE", "CURTIME",
        "DATE", "DATE_ADD", "DATE_FORMAT", "DATE_PART", "DATE_SUB", "DATE_TRUNC", "DATEDIFF", "DATETIME",
        "DENSE_RANK", "EXTRACT", "FIRST_VALUE", "FLOOR", "FORMAT", "FROM_UNIXTIME", "GEN_RANDOM_UUID",
        "GENERATE_SERIES", "GREATEST", "GROUP_CONCAT", "HEX", "IF", "IFNULL", "IIF", "INSTR", "ISNULL",
        "JSON_AGG", "JSON_ARRAY", "JSON_BUILD_ARRAY", "JSON_BUILD_OBJECT", "JSON_EXTRACT", "JSON_OBJECT",
        "JSON_OBJECT_AGG", "JSONB_AGG", "JSONB_BUILD_OBJECT", "JSONB_SET", "JULIANDAY", "LAG", "LAST_INSERT_ID",
        "LAST_INSERT_ROWID", "LAST_VALUE", "LEAD", "LEAST", "LEFT", "LENGTH", "LOWER", "LPAD", "LTRIM", "MAX",
        "MD5", "MIN", "MOD", "NOW", "NTILE", "NULLIF", "POSITION", "POWER", "PRINTF", "QUOTE", "RANDOM",
        "RAND", "RANK", "REGEXP_REPLACE", "REPLACE", "RIGHT", "ROUND", "ROW_NUMBER", "RPAD", "RTRIM", "SHA1",
        "SHA2", "SPLIT_PART", "SQRT", "STR_TO_DATE", "STRFTIME", "STRING_AGG", "SUBSTR", "SUBSTRING", "SUM",
        "TIME", "TO_CHAR", "TO_DATE", "TO_JSON", "TO_JSONB", "TO_NUMBER", "TO_TIMESTAMP", "TOTAL", "TRIM",
        "TYPEOF", "UNHEX", "UNIX_TIMESTAMP", "UNNEST", "UPPER", "UUID", "CHANGES", "ZEROBLOB",
        "CURRENT_SETTING", "PG_SIZE_PRETTY", "PG_TOTAL_RELATION_SIZE", "PG_SLEEP", "SLEEP", "VERSION",
        "DATABASE", "SCHEMA", "CONVERT", "CAST", "TRY_CAST", "STDDEV", "VARIANCE", "PERCENTILE_CONT",
    ]

    /// Keywords recognised for the given engine (common set plus engine-specific words).
    static func keywords(for kind: DatabaseKind) -> Set<String> {
        switch kind {
        case .postgres: postgresAll
        case .mysql: mysqlAll
        case .sqlite: sqliteAll
        }
    }

    /// Words offered by completion for the given engine, sorted, upper case.
    static func completionWords(for kind: DatabaseKind) -> [String] {
        switch kind {
        case .postgres: postgresCompletion
        case .mysql: mysqlCompletion
        case .sqlite: sqliteCompletion
        }
    }

    private static let postgresAll = common.union(postgres)
    private static let mysqlAll = common.union(mysql)
    private static let sqliteAll = common.union(sqlite)

    private static let postgresCompletion = postgresAll.union(types).union(functions).sorted()
    private static let mysqlCompletion = mysqlAll.union(types).union(functions).sorted()
    private static let sqliteCompletion = sqliteAll.union(types).union(functions).sorted()
}

/// Builds the completion list for a partial word.
enum SQLCompletion {
    /// Candidates starting with `prefix` (case-insensitive): schema objects first, then keywords.
    /// Keywords follow the case of the prefix (all-lowercase prefix → lowercase keywords).
    /// An entry identical to the prefix is dropped, since accepting it would change nothing.
    /// An empty prefix (completion requested after whitespace) offers schema objects only.
    static func candidates(for prefix: String, words: [String], kind: DatabaseKind, limit: Int = 200) -> [String] {
        guard !prefix.isEmpty else {
            var seen = Set<String>()
            let objects = words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            return Array(objects.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(limit))
        }
        let lowerPrefix = prefix.lowercased()
        let wantsLowercase = prefix == lowerPrefix && prefix.contains(where: \.isLetter)
        var seen = Set<String>()
        var objects: [String] = []
        for word in words where word.count > 0 && word.lowercased().hasPrefix(lowerPrefix) {
            if word != prefix, seen.insert(word.lowercased()).inserted { objects.append(word) }
        }
        objects.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        var keywords: [String] = []
        for word in SQLKeywords.completionWords(for: kind) where word.lowercased().hasPrefix(lowerPrefix) {
            let shown = wantsLowercase ? word.lowercased() : word
            if shown != prefix, seen.insert(word.lowercased()).inserted { keywords.append(shown) }
        }
        return Array((objects + keywords).prefix(limit))
    }
}
