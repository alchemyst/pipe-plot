import CSQLite
import Foundation

/// A single prepared statement. Its lifetime is confined to the caller's locked database access.
final class SQLiteStatement {
    enum Step { case row, done }

    private let db: OpaquePointer
    private var pointer: OpaquePointer?
    var raw: OpaquePointer { pointer! }

    init(_ db: OpaquePointer, _ sql: String) throws {
        self.db = db
        var pointer: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &pointer, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(pointer)
            throw SampleStoreError.sql(message)
        }
        self.pointer = pointer
    }

    deinit { close() }

    func close() {
        if let pointer {
            self.pointer = nil
            sqlite3_finalize(pointer)
        }
    }

    private func checked(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    func text(_ value: String, at index: Int32) throws {
        try checked(sqlite3_bind_text(raw, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
    }

    func double(_ value: Double, at index: Int32) throws { try checked(sqlite3_bind_double(raw, index, value)) }
    func int(_ value: Int32, at index: Int32) throws { try checked(sqlite3_bind_int(raw, index, value)) }
    func int64(_ value: Int64, at index: Int32) throws { try checked(sqlite3_bind_int64(raw, index, value)) }
    func null(at index: Int32) throws { try checked(sqlite3_bind_null(raw, index)) }
    func optionalDouble(_ value: Double?, at index: Int32) throws {
        if let value { try double(value, at: index) } else { try null(at: index) }
    }

    func step() throws -> Step {
        switch sqlite3_step(raw) {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default: throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }
}
