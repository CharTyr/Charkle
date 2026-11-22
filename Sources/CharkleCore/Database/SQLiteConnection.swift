import Foundation
import SQLite3

public nonisolated struct LibraryDatabaseError: Error, LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

nonisolated enum SQLValue {
    case null, integer(Int64), real(Double), text(String), blob(Data)

    init(_ value: String?) { self = value.map(Self.text) ?? .null }
    init(_ value: Data?) { self = value.map(Self.blob) ?? .null }

    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch self {
        case .null: return sqlite3_bind_null(statement, index)
        case .integer(let value): return sqlite3_bind_int64(statement, index, value)
        case .real(let value): return sqlite3_bind_double(statement, index, value)
        case .text(let value): return sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), transient)
        case .blob(let value):
            if value.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
            return value.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
            }
        }
    }
}

nonisolated struct SQLRow {
    fileprivate let statement: OpaquePointer
    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func text(_ index: Int32) -> String {
        sqlite3_column_text(statement, index).map {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
        } ?? ""
    }
    func blob(_ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

// Owned exclusively by LibraryDatabase after initialization.
nonisolated final class SQLiteConnection {
    private let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard let db, result == SQLITE_OK else {
            if let db { sqlite3_close_v2(db) }
            throw LibraryDatabaseError("Could not open SQLite library (\(result)).")
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    private var error: LibraryDatabaseError { LibraryDatabaseError(String(cString: sqlite3_errmsg(handle))) }

    func script(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], read: (SQLRow) throws -> T) throws -> [T] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw error
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard value.bind(to: statement, at: Int32(index + 1)) == SQLITE_OK else { throw error }
        }
        var rows: [T] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(try read(SQLRow(statement: statement)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw error }
        return rows
    }
}
