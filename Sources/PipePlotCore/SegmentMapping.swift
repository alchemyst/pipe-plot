import Foundation
import CSQLite

extension SampleStore {
    /// Remaps whole acquisition segments without copying observations into undo history.
    /// Undo calls the same operation with reversed endpoints; rows arriving after the
    /// edit carry the same segment ID, so they move back with their original producer.
    public func reassignSegments(_ segmentIDs: [String], from source: StreamID, to destination: StreamID) throws {
        guard source != destination, !segmentIDs.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try sql("BEGIN IMMEDIATE")
        do {
            var offsetStatement: OpaquePointer?
            try prepare("SELECT COALESCE(MAX(sequence)+1,0) FROM samples WHERE stream_id=?", &offsetStatement)
            bindText(offsetStatement, 1, destination.uuidString.lowercased())
            guard sqlite3_step(offsetStatement) == SQLITE_ROW else { sqlite3_finalize(offsetStatement); throw SampleStoreError.sql("Could not allocate remapped sequences") }
            let offset = sqlite3_column_int64(offsetStatement, 0)
            sqlite3_finalize(offsetStatement)
            let placeholders = Array(repeating: "?", count: segmentIDs.count).joined(separator: ",")
            var statement: OpaquePointer?
            try prepare("UPDATE samples SET stream_id=?, sequence=sequence+? WHERE stream_id=? AND segment_id IN (\(placeholders))", &statement)
            bindText(statement, 1, destination.uuidString.lowercased()); sqlite3_bind_int64(statement, 2, offset)
            bindText(statement, 3, source.uuidString.lowercased())
            for (index, id) in segmentIDs.enumerated() { bindText(statement, Int32(index + 4), id) }
            let code = sqlite3_step(statement); sqlite3_finalize(statement)
            guard code == SQLITE_DONE else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            for stream in [source, destination] {
                var refresh: OpaquePointer?
                try prepare("INSERT INTO stream_meta(stream_id,sample_count,first_time,last_time,next_sequence) SELECT ?,COUNT(*),MIN(timestamp),MAX(timestamp),COALESCE(MAX(sequence)+1,0) FROM samples WHERE stream_id=? ON CONFLICT(stream_id) DO UPDATE SET sample_count=excluded.sample_count,first_time=excluded.first_time,last_time=excluded.last_time,next_sequence=excluded.next_sequence", &refresh)
                bindText(refresh, 1, stream.uuidString.lowercased()); bindText(refresh, 2, stream.uuidString.lowercased())
                let result = sqlite3_step(refresh); sqlite3_finalize(refresh)
                guard result == SQLITE_DONE else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            }
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }

    public func segmentIDs(streamID: StreamID) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        try prepare("SELECT DISTINCT segment_id FROM samples WHERE stream_id=? AND segment_id IS NOT NULL", &statement)
        defer { sqlite3_finalize(statement) }; bindText(statement, 1, streamID.uuidString.lowercased())
        var result: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            result.append(String(cString: sqlite3_column_text(statement, 0)))
        }
    }

    private func sql(_ command: String) throws {
        guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
    }
}
