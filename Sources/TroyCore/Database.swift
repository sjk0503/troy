import Foundation
import SQLite3

/// A value bound to a `?` placeholder.
enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    static func opt(_ value: Int64?) -> SQLValue { value.map { .int($0) } ?? .null }
    static func opt(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
}

extension SQLValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    init(integerLiteral value: Int64) { self = .int(value) }
    init(stringLiteral value: String) { self = .text(value) }
    init(nilLiteral: ()) { self = .null }
    init(floatLiteral value: Double) { self = .double(value) }
}

/// Reads the columns of the current result row, left to right. The cursor moves on with every call,
/// so the order of the calls must match the order of the selected columns.
final class Row {
    let statement: OpaquePointer
    private var column: Int32 = 0

    init(_ statement: OpaquePointer) { self.statement = statement }

    func rewind() { column = 0 }

    func int() -> Int64 {
        defer { column += 1 }
        return sqlite3_column_int64(statement, column)
    }

    func optInt() -> Int64? {
        defer { column += 1 }
        return sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    func double() -> Double {
        defer { column += 1 }
        return sqlite3_column_double(statement, column)
    }

    func text() -> String {
        defer { column += 1 }
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    func optText() -> String? {
        defer { column += 1 }
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func skip(_ count: Int32 = 1) { column += count }
}

/// A thin wrapper over one SQLite connection. Not thread-safe: `Store` serializes access.
final class Database {
    private var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    private var depth = 0
    private static let cacheLimit = 400

    /// SQLite copies the bytes before `sqlite3_bind_text` returns.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// - Parameter create: false opens only a file that exists already, so a reader that merely
    ///   looks never leaves an empty database behind.
    init(path: String, create: Bool = true) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
            if let opened { sqlite3_close(opened) }
            throw TroyError.database("Cannot open \(path): \(message)")
        }
        handle = opened
    }

    deinit { close() }

    var isOpen: Bool { handle != nil }

    func close() {
        for statement in cache.values { sqlite3_finalize(statement) }
        cache.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    // MARK: Errors

    /// The primary result code of the most recent failure on this connection.
    private var failure: Int32 = SQLITE_OK

    /// Whether the most recent failure was SQLite giving up on a lock another connection holds.
    var lastFailureWasBusy: Bool { failure == SQLITE_BUSY }

    private func lastError() -> TroyError {
        guard let handle else { return .database("The database is closed.") }
        failure = sqlite3_errcode(handle) & 0xFF
        return .database(String(cString: sqlite3_errmsg(handle)))
    }

    private func connection() throws -> OpaquePointer {
        guard let handle else { throw TroyError.database("The database is closed.") }
        return handle
    }

    // MARK: Statements

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = cache[sql] { return cached }
        let handle = try connection()
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil) == SQLITE_OK, let prepared else {
            throw lastError()
        }
        if cache.count >= Self.cacheLimit {
            for statement in cache.values { sqlite3_finalize(statement) }
            cache.removeAll()
        }
        cache[sql] = prepared
        return prepared
    }

    private func bind(_ statement: OpaquePointer, _ values: [SQLValue]) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == values.count else {
            throw TroyError.database("Internal error: \(expected) placeholders but \(values.count) values.")
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .int(let number): code = sqlite3_bind_int64(statement, index, number)
            case .double(let number): code = sqlite3_bind_double(statement, index, number)
            case .null: code = sqlite3_bind_null(statement, index)
            case .text(let string):
                let length = string.utf8.count
                code = string.withCString { sqlite3_bind_text(statement, index, $0, Int32(length), Self.transient) }
            }
            if code != SQLITE_OK { throw lastError() }
        }
    }

    // MARK: Running SQL

    /// Runs one or more statements without parameters.
    func execute(_ sql: String) throws {
        let handle = try connection()
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        if code != SQLITE_OK {
            failure = code & 0xFF
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
            sqlite3_free(message)
            throw TroyError.database(text)
        }
    }

    /// Runs one statement and returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try statement(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(statement, values)
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw lastError() }
        return changes
    }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE (triggers excluded).
    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// Runs a query and maps every row. `map` must not run other statements.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        let statement = try statement(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(statement, values)
        let row = Row(statement)
        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                row.rewind()
                result.append(try map(row))
            } else if code == SQLITE_DONE {
                return result
            } else {
                throw lastError()
            }
        }
    }

    func first<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (Row) throws -> T) throws -> T? {
        try query(sql, values, map).first
    }

    /// The first column of the first row as an integer, or nil when there is no row or the value is NULL.
    func int(_ sql: String, _ values: [SQLValue] = []) throws -> Int64? {
        try query(sql, values) { $0.optInt() }.first ?? nil
    }

    func exists(_ sql: String, _ values: [SQLValue] = []) throws -> Bool {
        try query(sql, values) { _ in true }.first ?? false
    }

    // MARK: Transactions

    /// Runs `body` in one read transaction, so every query in it sees the same committed state
    /// even while another process writes. Readers never block writers in WAL mode.
    func snapshot<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        try execute("BEGIN")
        depth = 1
        defer { depth = 0 }
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs `body` in one `BEGIN IMMEDIATE` transaction; rolls back when it throws.
    /// A call made while a transaction is open joins it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        try execute("BEGIN IMMEDIATE")
        depth = 1
        defer { depth = 0 }
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
