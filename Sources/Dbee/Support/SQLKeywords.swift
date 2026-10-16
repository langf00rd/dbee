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

    static let clickhouse: Set<String> = [
        "ALIAS", "ANTI", "APPEND", "ARRAY", "ASOF", "ASYNC", "ATTACH", "CLEAR", "CLUSTER", "CODEC", "CUBE",
        "DATABASES", "DEDUPLICATE", "DESCRIBE", "DETACH", "DICTIONARIES", "DICTIONARY", "EMPTY", "ENGINE",
        "EPHEMERAL", "EXCHANGE", "FILL", "FINAL", "FORMAT", "FREEZE", "GLOBAL", "GRANULARITY", "ILIKE",
        "INTERPOLATE", "KILL", "LAYOUT", "LIFETIME", "LIVE", "MATERIALIZE", "MODIFY", "MOVE", "MUTATION",
        "OPTIMIZE", "PASTE", "POPULATE", "PREWHERE", "PROCESSLIST", "PROJECTION", "QUALIFY", "QUERY", "REFRESH",
        "ROLLUP", "SAMPLE", "SEMI", "SETTINGS", "SHOW", "SOURCE", "STEP", "SYNC", "SYSTEM", "TABLES", "TOTALS",
        "TTL", "UNFREEZE", "USE",
    ]

    static let cql: Set<String> = [
        "AGGREGATE", "ALLOW", "APPLY", "AUTHORIZE", "BATCH", "CALLED", "CLUSTERING", "COMPACT", "CONSISTENCY",
        "CONTAINS", "COUNTER", "CUSTOM", "DESCRIBE", "DURABLE_WRITES", "EACH_QUORUM", "FILTERING", "FINALFUNC",
        "FROZEN", "INITCOND", "INPUT", "JSON", "KEYS", "KEYSPACE", "KEYSPACES", "LANGUAGE", "LIST", "LOCAL_ONE",
        "LOCAL_QUORUM", "LOCAL_SERIAL", "LOGIN", "MAP", "MODIFY", "NOSUPERUSER", "ONE", "PASSWORD", "PER",
        "PERMISSION", "PERMISSIONS", "QUORUM", "REPLICATION", "ROLES", "SERIAL", "SFUNC", "STATIC", "STORAGE",
        "STYPE", "SUPERUSER", "THREE", "TOKEN", "TTL", "TWO", "TYPE", "UNLOGGED", "USE", "USERS", "WRITETIME",
    ]

    /// ClickHouse type names, spelled as ClickHouse wants them (they are case-sensitive).
    static let clickhouseTypeNames: [String] = [
        "AggregateFunction", "Array", "Bool", "Date", "Date32", "DateTime", "DateTime64", "Decimal", "Decimal128",
        "Decimal256", "Decimal32", "Decimal64", "Dynamic", "Enum16", "Enum8", "FixedString", "Float32", "Float64",
        "IPv4", "IPv6", "Int128", "Int16", "Int256", "Int32", "Int64", "Int8", "JSON", "LowCardinality", "Map",
        "Nested", "Nothing", "Nullable", "SimpleAggregateFunction", "String", "Tuple", "UInt128", "UInt16",
        "UInt256", "UInt32", "UInt64", "UInt8", "UUID", "Variant",
    ]

    /// Common ClickHouse functions, spelled as ClickHouse wants them.
    static let clickhouseFunctionNames: [String] = [
        "any", "anyLast", "argMax", "argMin", "arrayFilter", "arrayJoin", "arrayMap", "avg", "coalesce", "concat",
        "count", "countIf", "currentDatabase", "dictGet", "formatDateTime", "formatReadableSize", "generateUUIDv4",
        "groupArray", "groupUniqArray", "has", "if", "ifNull", "isNull", "JSONExtract", "JSONExtractString",
        "length", "lower", "max", "maxIf", "min", "minIf", "multiIf", "now", "now64", "numbers", "quantile",
        "quantiles", "replaceAll", "round", "splitByChar", "sum", "sumIf", "throwIf", "toDate", "toDateTime",
        "toDecimal64", "toFloat64", "toInt64", "toStartOfDay", "toStartOfHour", "toStartOfMonth", "toStartOfWeek",
        "toString", "toUInt64", "toYYYYMM", "today", "topK", "uniq", "uniqExact", "upper", "version", "yesterday",
    ]

    static let cqlTypes: Set<String> = [
        "ASCII", "BIGINT", "BLOB", "BOOLEAN", "COUNTER", "DATE", "DECIMAL", "DOUBLE", "DURATION", "FLOAT", "INET",
        "INT", "SMALLINT", "TEXT", "TIME", "TIMESTAMP", "TIMEUUID", "TINYINT", "TUPLE", "UUID", "VARCHAR", "VARINT",
    ]

    static let cqlFunctions: Set<String> = [
        "AVG", "BLOBASTEXT", "CAST", "COUNT", "CURRENTDATE", "CURRENTTIME", "CURRENTTIMESTAMP", "CURRENTTIMEUUID",
        "FROMJSON", "MAX", "MAXTIMEUUID", "MIN", "MINTIMEUUID", "NOW", "SUM", "TEXTASBLOB", "TODATE", "TOJSON",
        "TOKEN", "TOTIMESTAMP", "TOUNIXTIMESTAMP", "TTL", "UUID", "WRITETIME",
    ]

    /// Meilisearch requests: the HTTP methods, and JSON's literals.
    static let httpWords: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "TRUE", "FALSE", "NULL"]

    /// Type names the highlighter colours for `kind`.
    static func types(for kind: DatabaseKind) -> Set<String> {
        switch kind {
        case .clickhouse: clickhouseTypes
        case .scylla: cqlTypes
        default: types
        }
    }

    /// Function names the highlighter colours (before "(") for `kind`.
    static func functions(for kind: DatabaseKind) -> Set<String> {
        switch kind {
        case .clickhouse: clickhouseFunctions
        case .scylla: cqlFunctions
        default: functions
        }
    }

    private static let clickhouseTypes = Set(clickhouseTypeNames.map { $0.uppercased() })
    private static let clickhouseFunctions = Set(clickhouseFunctionNames.map { $0.uppercased() }).union(functions)

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
        case .clickhouse: clickhouseAll
        case .scylla: cqlAll
        case .redis: redisCommands
        case .mongodb: mongoWords
        case .meilisearch: httpWords
        }
    }

    /// Words offered by completion for the given engine, sorted, upper case.
    static func completionWords(for kind: DatabaseKind) -> [String] {
        switch kind {
        case .postgres: postgresCompletion
        case .mysql: mysqlCompletion
        case .sqlite: sqliteCompletion
        case .clickhouse: clickhouseCompletion
        case .scylla: cqlCompletion
        case .redis: redisCompletion
        case .mongodb: mongoCompletion
        case .meilisearch: httpCompletion
        }
    }

    /// Redis command names (first words of commands, and the common subcommands and options).
    static let redisCommands: Set<String> = [
        "APPEND", "AUTH", "BITCOUNT", "BITFIELD", "BITOP", "BITPOS", "BLMOVE", "BLMPOP", "BLPOP", "BRPOP",
        "BZMPOP", "BZPOPMAX", "BZPOPMIN", "CLIENT", "CLUSTER", "COMMAND", "CONFIG", "COPY", "DBSIZE", "DECR",
        "DECRBY", "DEL", "DISCARD", "DUMP", "ECHO", "EVAL", "EVALSHA", "EXEC", "EXISTS", "EXPIRE", "EXPIREAT",
        "EXPIRETIME", "FCALL", "FLUSHALL", "FLUSHDB", "FUNCTION", "GEOADD", "GEODIST", "GEOHASH", "GEOPOS",
        "GEOSEARCH", "GET", "GETBIT", "GETDEL", "GETEX", "GETRANGE", "GETSET", "HDEL", "HEXISTS", "HGET",
        "HGETALL", "HINCRBY", "HINCRBYFLOAT", "HKEYS", "HLEN", "HMGET", "HMSET", "HRANDFIELD", "HSCAN", "HSET",
        "HSETNX", "HSTRLEN", "HVALS", "INCR", "INCRBY", "INCRBYFLOAT", "INFO", "KEYS", "LASTSAVE", "LCS",
        "LINDEX", "LINSERT", "LLEN", "LMOVE", "LMPOP", "LPOP", "LPOS", "LPUSH", "LPUSHX", "LRANGE", "LREM",
        "LSET", "LTRIM", "MEMORY", "MGET", "MOVE", "MSET", "MSETNX", "MULTI", "OBJECT", "PERSIST", "PEXPIRE",
        "PEXPIREAT", "PEXPIRETIME", "PFADD", "PFCOUNT", "PFMERGE", "PING", "PSETEX", "PTTL", "PUBLISH",
        "PUBSUB", "RANDOMKEY", "RENAME", "RENAMENX", "RESTORE", "ROLE", "RPOP", "RPOPLPUSH", "RPUSH", "RPUSHX",
        "SADD", "SAVE", "SCAN", "SCARD", "SCRIPT", "SDIFF", "SDIFFSTORE", "SELECT", "SET", "SETBIT", "SETEX",
        "SETNX", "SETRANGE", "SINTER", "SINTERCARD", "SINTERSTORE", "SISMEMBER", "SLOWLOG", "SMEMBERS",
        "SMISMEMBER", "SMOVE", "SORT", "SPOP", "SRANDMEMBER", "SREM", "SSCAN", "STRLEN", "SUNION",
        "SUNIONSTORE", "SWAPDB", "TIME", "TOUCH", "TTL", "TYPE", "UNLINK", "UNWATCH", "WAIT", "WATCH", "XACK",
        "XADD", "XAUTOCLAIM", "XCLAIM", "XDEL", "XGROUP", "XINFO", "XLEN", "XPENDING", "XRANGE", "XREAD",
        "XREADGROUP", "XREVRANGE", "XTRIM", "ZADD", "ZCARD", "ZCOUNT", "ZDIFF", "ZINCRBY", "ZINTER",
        "ZINTERCARD", "ZLEXCOUNT", "ZMPOP", "ZMSCORE", "ZPOPMAX", "ZPOPMIN", "ZRANDMEMBER", "ZRANGE",
        "ZRANGEBYLEX", "ZRANGEBYSCORE", "ZRANGESTORE", "ZRANK", "ZREM", "ZREMRANGEBYLEX", "ZREMRANGEBYRANK",
        "ZREMRANGEBYSCORE", "ZREVRANGE", "ZREVRANGEBYSCORE", "ZREVRANK", "ZSCAN", "ZSCORE", "ZUNION",
        "ZUNIONSTORE", "JSON.GET", "JSON.SET", "JSON.DEL", "FT.SEARCH", "FT.INFO",
        "MATCH", "COUNT", "WITHSCORES", "WITHVALUES", "LIMIT", "EX", "PX", "NX", "XX", "KEEPTTL", "LIST",
    ]

    /// mongosh words: shell commands, db and collection methods, cursor methods and constructors.
    static let mongoWords: Set<String> = [
        "DB", "SHOW", "USE", "DBS", "COLLECTIONS",
        "FIND", "FINDONE", "AGGREGATE", "COUNTDOCUMENTS", "ESTIMATEDDOCUMENTCOUNT", "DISTINCT",
        "INSERTONE", "INSERTMANY", "UPDATEONE", "UPDATEMANY", "REPLACEONE", "DELETEONE", "DELETEMANY",
        "FINDONEANDUPDATE", "FINDONEANDREPLACE", "FINDONEANDDELETE", "DROP", "RENAMECOLLECTION",
        "GETINDEXES", "CREATEINDEX", "DROPINDEX", "STATS", "GETCOLLECTION", "RUNCOMMAND", "ADMINCOMMAND",
        "GETCOLLECTIONNAMES", "GETCOLLECTIONINFOS", "CREATECOLLECTION", "CREATEVIEW", "DROPDATABASE",
        "SERVERSTATUS", "VERSION", "GETNAME", "CURRENTOP", "KILLOP", "HOSTINFO",
        "SORT", "LIMIT", "SKIP", "PROJECTION", "HINT", "MAXTIMEMS", "COLLATION", "COMMENT", "COUNT",
        "EXPLAIN", "TOARRAY", "PRETTY",
        "OBJECTID", "ISODATE", "DATE", "NUMBERLONG", "NUMBERINT", "NUMBERDECIMAL", "TIMESTAMP", "BINDATA",
        "UUID", "MINKEY", "MAXKEY", "TRUE", "FALSE", "NULL", "NEW",
    ]

    /// Spellings used for completion, since mongosh names are case-sensitive.
    private static let mongoCompletion: [String] = [
        "db", "show", "use", "dbs", "collections",
        "find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount", "distinct",
        "insertOne", "insertMany", "updateOne", "updateMany", "replaceOne", "deleteOne", "deleteMany",
        "findOneAndUpdate", "findOneAndReplace", "findOneAndDelete", "drop", "renameCollection",
        "getIndexes", "createIndex", "dropIndex", "stats", "getCollection", "runCommand", "adminCommand",
        "getCollectionNames", "getCollectionInfos", "createCollection", "createView", "dropDatabase",
        "serverStatus", "version", "getName", "currentOp", "killOp", "hostInfo",
        "sort", "limit", "skip", "projection", "hint", "maxTimeMS", "collation", "comment", "count", "explain",
        "ObjectId", "ISODate", "NumberLong", "NumberInt", "NumberDecimal", "Timestamp", "BinData", "UUID",
        "MinKey", "MaxKey", "true", "false", "null",
        "$match", "$group", "$project", "$sort", "$limit", "$skip", "$unwind", "$lookup", "$addFields", "$set",
        "$unset", "$count", "$facet", "$replaceRoot", "$sample", "$out", "$merge",
        "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$and", "$or", "$not", "$nor", "$exists",
        "$type", "$regex", "$elemMatch", "$size", "$all", "$expr", "$text", "$inc", "$push", "$pull",
        "$addToSet", "$pop", "$rename", "$sum", "$avg", "$min", "$max", "$first", "$last",
    ].sorted { $0.lowercased() < $1.lowercased() }

    private static let redisCompletion = redisCommands.sorted()

    private static let postgresAll = common.union(postgres)
    private static let mysqlAll = common.union(mysql)
    private static let sqliteAll = common.union(sqlite)
    private static let clickhouseAll = common.union(clickhouse)
    private static let cqlAll = common.union(cql)

    private static let postgresCompletion = postgresAll.union(types).union(functions).sorted()
    private static let mysqlCompletion = mysqlAll.union(types).union(functions).sorted()
    private static let sqliteCompletion = sqliteAll.union(types).union(functions).sorted()
    /// ClickHouse's own names keep their spelling, since it matches them case-sensitively. A name spelled like a
    /// keyword (if, any) is left to the keyword.
    private static let clickhouseCompletion = (Array(clickhouseAll) + (clickhouseTypeNames + clickhouseFunctionNames)
        .filter { !clickhouseAll.contains($0.uppercased()) }).sorted()
    private static let cqlCompletion = cqlAll.union(cqlTypes).union(cqlFunctions).sorted()
    private static let httpCompletion = ["DELETE", "GET", "PATCH", "POST", "PUT"]
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
            // Mixed-case names (mongosh methods, ClickHouse functions and types) are case-sensitive, so they keep
            // their own spelling.
            let shown = wantsLowercase && word == word.uppercased() ? word.lowercased() : word
            if shown != prefix, seen.insert(word.lowercased()).inserted { keywords.append(shown) }
        }
        return Array((objects + keywords).prefix(limit))
    }
}
