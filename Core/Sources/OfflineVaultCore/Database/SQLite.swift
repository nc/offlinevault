import Foundation
import SQLite3

/// Minimal, thread-safe SQLite wrapper (serial queue) with FTS5 support via the system library.
public final class SQLiteDatabase: @unchecked Sendable {
    public enum SQLiteError: LocalizedError {
        case open(String), prepare(String, String), step(String, String), bind(String)
        public var errorDescription: String? {
            switch self {
            case .open(let m): return "Could not open database: \(m)"
            case .prepare(let m, let sql): return "SQL prepare failed: \(m) — \(sql)"
            case .step(let m, let sql): return "SQL failed: \(m) — \(sql)"
            case .bind(let m): return "SQL bind failed: \(m)"
            }
        }
    }

    public enum Value: Equatable, Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    public struct Row {
        public let columns: [String: Value]
        public subscript(_ name: String) -> Value { columns[name] ?? .null }
        public func string(_ name: String) -> String? {
            switch self[name] {
            case .text(let s): return s
            case .integer(let i): return String(i)
            case .real(let d): return String(d)
            default: return nil
            }
        }
        public func int(_ name: String) -> Int64? {
            switch self[name] {
            case .integer(let i): return i
            case .real(let d): return Int64(d)
            case .text(let s): return Int64(s)
            default: return nil
            }
        }
        public func double(_ name: String) -> Double? {
            switch self[name] {
            case .integer(let i): return Double(i)
            case .real(let d): return d
            case .text(let s): return Double(s)
            default: return nil
            }
        }
        public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
        public func date(_ name: String) -> Date? { double(name).map { Date(timeIntervalSince1970: $0) } }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.offlinevault.sqlite")
    private let queueKey = DispatchSpecificKey<Bool>()
    public let path: String

    /// Runs on the serial queue; re-entrant so `transaction { execute(...) }` works.
    private func sync<T>(_ body: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.open(msg)
        }
        db = handle
        queue.setSpecific(key: queueKey, value: true)
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    public static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit { if let db { sqlite3_close_v2(db) } }

    private var lastMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    // MARK: Execution

    @discardableResult
    public func execute(_ sql: String, _ params: [Value] = []) throws -> Int {
        try sync { try executeUnlocked(sql, params) }
    }

    public func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        try sync { try queryUnlocked(sql, params) }
    }

    public func scalar(_ sql: String, _ params: [Value] = []) throws -> Value {
        let rows = try query(sql, params)
        guard let first = rows.first, let v = first.columns.values.first else { return .null }
        return v
    }

    public func lastInsertRowID() -> Int64 { (try? sync { sqlite3_last_insert_rowid(db) }) ?? 0 }

    /// Runs `body` inside a transaction; rolls back on throw.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try sync {
            try executeUnlocked("BEGIN IMMEDIATE", [])
            do {
                let result = try body()
                try executeUnlocked("COMMIT", [])
                return result
            } catch {
                _ = try? executeUnlocked("ROLLBACK", [])
                throw error
            }
        }
    }

    // MARK: Unlocked primitives (call on queue)

    private func executeUnlocked(_ sql: String, _ params: [Value]) throws -> Int {
        if params.isEmpty, sql.contains(";") {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw SQLiteError.step(lastMessage, sql) }
            return Int(sqlite3_changes(db))
        }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError.step(lastMessage, sql) }
        return Int(sqlite3_changes(db))
    }

    private func queryUnlocked(_ sql: String, _ params: [Value]) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let count = Int(sqlite3_column_count(stmt))
        let names = (0..<count).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(lastMessage, sql) }
            var cols: [String: Value] = [:]
            for i in 0..<count {
                let idx = Int32(i)
                switch sqlite3_column_type(stmt, idx) {
                case SQLITE_INTEGER: cols[names[i]] = .integer(sqlite3_column_int64(stmt, idx))
                case SQLITE_FLOAT: cols[names[i]] = .real(sqlite3_column_double(stmt, idx))
                case SQLITE_TEXT: cols[names[i]] = .text(String(cString: sqlite3_column_text(stmt, idx)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, idx))
                    if let p = sqlite3_column_blob(stmt, idx) { cols[names[i]] = .blob(Data(bytes: p, count: n)) } else { cols[names[i]] = .blob(Data()) }
                default: cols[names[i]] = .null
                }
            }
            rows.append(Row(columns: cols))
        }
        return rows
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(lastMessage, sql)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let d): rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
            }
            if rc != SQLITE_OK { sqlite3_finalize(stmt); throw SQLiteError.bind(lastMessage) }
        }
        return stmt
    }
}

// Convenience conversions
extension SQLiteDatabase.Value {
    public static func from(_ s: String?) -> SQLiteDatabase.Value { s.map { .text($0) } ?? .null }
    public static func from(_ i: Int64?) -> SQLiteDatabase.Value { i.map { .integer($0) } ?? .null }
    public static func from(_ i: Int?) -> SQLiteDatabase.Value { i.map { .integer(Int64($0)) } ?? .null }
    public static func from(_ d: Double?) -> SQLiteDatabase.Value { d.map { .real($0) } ?? .null }
    public static func from(_ d: Date?) -> SQLiteDatabase.Value { d.map { .real($0.timeIntervalSince1970) } ?? .null }
    public static func from(_ b: Bool) -> SQLiteDatabase.Value { .integer(b ? 1 : 0) }
}

/// Escapes user input for an FTS5 MATCH expression: every token becomes a quoted phrase-free term joined with implicit AND,
/// and a trailing prefix match is added to the last token so partially typed words still hit.
public enum FTSQuery {
    public static func build(_ raw: String, prefixLast: Bool = true, orTerms: Bool = false) -> String? {
        let tokens = raw
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var parts: [String] = []
        for (i, t) in tokens.enumerated() {
            let quoted = "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if prefixLast && i == tokens.count - 1 && t.count >= 3 { parts.append(quoted + "*") } else { parts.append(quoted) }
        }
        return parts.joined(separator: orTerms ? " OR " : " ")
    }
}
