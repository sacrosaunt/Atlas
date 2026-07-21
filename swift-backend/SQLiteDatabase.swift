import Foundation
import SQLite3

enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var string: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value)
        default: return nil
        }
    }

    var data: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }
}

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message), .prepare(let message), .step(let message), .execute(let message):
            return message
        }
    }
}

final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()

    init(path: String, readOnly: Bool = false) throws {
        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw SQLiteError.open(message)
        }
        handle = database
        sqlite3_busy_timeout(handle, 5_000)
        sqlite3_create_function_v2(
            handle,
            "vec_length",
            1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            { context, count, values in
                guard count == 1, let values, let value = values[0] else {
                    sqlite3_result_null(context); return
                }
                let bytes = sqlite3_value_bytes(value)
                sqlite3_result_int(context, bytes / Int32(MemoryLayout<Float>.size))
            },
            nil,
            nil,
            nil
        )
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw SQLiteError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw SQLiteError.execute(message)
        }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [[String: SQLiteValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
            }
            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes = sqlite3_column_blob(statement, index), count > 0 {
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else { row[name] = .blob(Data()) }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
    }

    func scalar(_ sql: String, bindings: [SQLiteValue] = []) throws -> SQLiteValue? {
        try query(sql, bindings: bindings).first?.values.first
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
            case .real(let value): code = sqlite3_bind_double(statement, index, value)
            case .text(let value): code = sqlite3_bind_text(statement, index, value, -1, transient)
            case .blob(let value):
                code = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            }
            guard code == SQLITE_OK else {
                throw SQLiteError.execute(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
