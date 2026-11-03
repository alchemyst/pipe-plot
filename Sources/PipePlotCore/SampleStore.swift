import Foundation
import CSQLite

public enum SampleStoreError: Error, LocalizedError {
    case open(String), sql(String), invalidLimit
    public var errorDescription: String? {
        switch self {
        case .open(let s), .sql(let s): return s
        case .invalidLimit: return "limit must be between 1 and 50000"
        }
    }
}

/// SQLite-backed raw observations. Queries are always bounded; sample histories are never cached here.
// All access to the SQLite handle is serialized by lock (including extension queries).
public final class SampleStore: @unchecked Sendable {
    public static let maximumQueryRows = 50_000
    var db: OpaquePointer?
    let lock = NSRecursiveLock()
    public init(databaseURL: URL) throws {
        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard
            sqlite3_open_v2(
                databaseURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK
        else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let db { sqlite3_close(db) }
            db = nil
            throw SampleStoreError.open(msg)
        }
        do {
            try execute(
                "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS samples(stream_id TEXT NOT NULL, timestamp REAL NOT NULL, sequence INTEGER NOT NULL, value REAL NOT NULL, PRIMARY KEY(stream_id, sequence)); CREATE INDEX IF NOT EXISTS samples_by_time ON samples(stream_id,timestamp,sequence);"
            )
            let columns = try self.statement("PRAGMA table_info(samples)")
            defer { columns.close() }
            var hasSegmentID = false
            while try columns.step() == .row {
                if let name = sqlite3_column_text(columns.raw, 1), String(cString: name) == "segment_id" {
                    hasSegmentID = true
                }
            }
            columns.close()
            if !hasSegmentID { try execute("ALTER TABLE samples ADD COLUMN segment_id TEXT") }
            try execute(
                "CREATE TABLE IF NOT EXISTS stream_meta(stream_id TEXT PRIMARY KEY, sample_count INTEGER NOT NULL DEFAULT 0, first_time REAL, last_time REAL, next_sequence INTEGER NOT NULL DEFAULT 0);"
            )
            // Separate append and mutation revisions let a reader reuse unchanged
            // membership after out-of-range arrivals, while remaps always invalidate.
            try execute(
                """
                CREATE TABLE IF NOT EXISTS fit_versions(stream_id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0, mutation INTEGER NOT NULL DEFAULT 0);
                CREATE TRIGGER IF NOT EXISTS fit_insert AFTER INSERT ON samples BEGIN
                    INSERT INTO fit_versions(stream_id,revision) VALUES(NEW.stream_id,1)
                    ON CONFLICT(stream_id) DO UPDATE SET revision=revision+1;
                END;
                CREATE TRIGGER IF NOT EXISTS fit_delete AFTER DELETE ON samples BEGIN
                    INSERT INTO fit_versions(stream_id,revision,mutation) VALUES(OLD.stream_id,1,1)
                    ON CONFLICT(stream_id) DO UPDATE SET revision=revision+1,mutation=mutation+1;
                END;
                CREATE TRIGGER IF NOT EXISTS fit_update AFTER UPDATE ON samples BEGIN
                    INSERT INTO fit_versions(stream_id,revision,mutation) VALUES(OLD.stream_id,1,1)
                    ON CONFLICT(stream_id) DO UPDATE SET revision=revision+1,mutation=mutation+1;
                    INSERT INTO fit_versions(stream_id,revision,mutation) VALUES(NEW.stream_id,1,1)
                    ON CONFLICT(stream_id) DO UPDATE SET revision=revision+1,mutation=mutation+1;
                END;
                """)
        } catch {
            if let db { sqlite3_close(db) }
            db = nil
            throw error
        }
    }
    /// Independent WAL reader for UI analysis. It cannot write and does not hold
    /// the ingestion connection's lock while scanning a long historical range.
    public init(readOnlyDatabaseURL: URL) throws {
        guard
            sqlite3_open_v2(readOnlyDatabaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK
        else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open history reader"
            if let db { sqlite3_close(db) }
            db = nil
            throw SampleStoreError.open(message)
        }
        do {
            try execute("PRAGMA query_only=ON;")
        } catch {
            if let db { sqlite3_close(db) }
            db = nil
            throw error
        }
    }
    deinit { if let db { sqlite3_close(db) } }

    /// Atomically persists all columns from one row. Returns the first sequence number assigned.
    @discardableResult public func append(
        values: [Double], timestamp: Date, to streamIDs: [StreamID], segmentID: String? = nil
    ) throws -> [UInt64] {
        guard values.count == streamIDs.count, values.allSatisfy(\.isFinite) else {
            throw SampleStoreError.sql("invalid sample row")
        }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var sequences: [UInt64] = []
            for (value, streamID) in zip(values, streamIDs) {
                let id = streamID.uuidString.lowercased()
                let seq = try nextSequence(for: id)
                try insert(
                    value: value, time: timestamp.timeIntervalSince1970, sequence: seq, streamID: id,
                    segmentID: segmentID)
                sequences.append(seq)
            }
            try execute("COMMIT")
            return sequences
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    public func append(_ sample: StoredSample, to streamID: StreamID) throws {
        lock.lock()
        defer { lock.unlock() }
        try insert(
            value: sample.value, time: sample.timestamp.timeIntervalSince1970, sequence: sample.sequence,
            streamID: streamID.uuidString.lowercased(), segmentID: sample.segmentID)
    }
    public func query(streamID: StreamID, from start: Date? = nil, to end: Date? = nil, limit: Int = 10_000) throws
        -> [StoredSample]
    {
        guard (1...Self.maximumQueryRows).contains(limit) else { throw SampleStoreError.invalidLimit }
        lock.lock()
        defer { lock.unlock() }
        let sql =
            "SELECT timestamp,sequence,value,segment_id FROM samples WHERE stream_id=? AND (? IS NULL OR timestamp>=?) AND (? IS NULL OR timestamp<=?) ORDER BY timestamp,sequence LIMIT ?"
        let stmt = try self.statement(sql)
        defer { stmt.close() }
        try stmt.text(streamID.uuidString.lowercased(), at: 1)
        try stmt.optionalDouble(start?.timeIntervalSince1970, at: 2)
        try stmt.optionalDouble(start?.timeIntervalSince1970, at: 3)
        try stmt.optionalDouble(end?.timeIntervalSince1970, at: 4)
        try stmt.optionalDouble(end?.timeIntervalSince1970, at: 5)
        try stmt.int64(Int64(limit), at: 6)
        var result: [StoredSample] = []
        result.reserveCapacity(min(limit, 4096))
        while try stmt.step() == .row {
            result.append(
                StoredSample(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt.raw, 0)),
                    sequence: UInt64(sqlite3_column_int64(stmt.raw, 1)), value: sqlite3_column_double(stmt.raw, 2),
                    segmentID: sqlite3_column_text(stmt.raw, 3).map { String(cString: $0) }))
        }
        return result
    }
    public func count(streamID: StreamID, from start: Date? = nil, to end: Date? = nil) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try self.statement(
            "SELECT COUNT(*) FROM samples WHERE stream_id=? AND (? IS NULL OR timestamp>=?) AND (? IS NULL OR timestamp<=?)",
        )
        defer { stmt.close() }
        try stmt.text(streamID.uuidString.lowercased(), at: 1)
        try stmt.optionalDouble(start?.timeIntervalSince1970, at: 2)
        try stmt.optionalDouble(start?.timeIntervalSince1970, at: 3)
        try stmt.optionalDouble(end?.timeIntervalSince1970, at: 4)
        try stmt.optionalDouble(end?.timeIntervalSince1970, at: 5)
        guard try stmt.step() == .row else { throw SampleStoreError.sql("Count query returned no row") }
        return sqlite3_column_int64(stmt.raw, 0)
    }
    public func bounds(streamID: StreamID) throws -> SampleBounds {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try self.statement("SELECT MIN(timestamp),MAX(timestamp) FROM samples WHERE stream_id=?")
        defer { stmt.close() }
        try stmt.text(streamID.uuidString.lowercased(), at: 1)
        guard try stmt.step() == .row else { throw SampleStoreError.sql("Bounds query returned no row") }
        let first =
            sqlite3_column_type(stmt.raw, 0) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt.raw, 0))
        let last =
            sqlite3_column_type(stmt.raw, 1) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt.raw, 1))
        return SampleBounds(first: first, last: last)
    }
    public func delete(streamID: StreamID) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute(
            "DELETE FROM samples WHERE stream_id='\(streamID.uuidString.lowercased())'; DELETE FROM stream_meta WHERE stream_id='\(streamID.uuidString.lowercased())'"
        )
    }

    private func nextSequence(for id: String) throws -> UInt64 {
        let insert = try self.statement("INSERT OR IGNORE INTO stream_meta(stream_id) VALUES(?)")
        defer { insert.close() }
        try insert.text(id, at: 1)
        guard try insert.step() == .done else { throw SampleStoreError.sql("Could not insert stream metadata") }
        insert.close()
        let stmt = try self.statement(
            "UPDATE stream_meta SET next_sequence=next_sequence+1 WHERE stream_id=? RETURNING next_sequence-1")
        defer { stmt.close() }
        try stmt.text(id, at: 1)
        guard try stmt.step() == .row else { throw SampleStoreError.sql("Could not allocate sequence") }
        let seq = UInt64(sqlite3_column_int64(stmt.raw, 0))
        return seq
    }
    private func insert(value: Double, time: Double, sequence: UInt64, streamID: String, segmentID: String? = nil)
        throws
    {
        let stmt = try self.statement(
            "INSERT INTO samples(stream_id,timestamp,sequence,value,segment_id) VALUES(?,?,?,?,?)")
        defer { stmt.close() }
        try stmt.text(streamID, at: 1)
        try stmt.double(time, at: 2)
        try stmt.int64(Int64(sequence), at: 3)
        try stmt.double(value, at: 4)
        if let segmentID { try stmt.text(segmentID, at: 5) }
        guard try stmt.step() == .done else { throw SampleStoreError.sql("Sample insert returned a row") }
        let meta = try self.statement(
            "INSERT INTO stream_meta(stream_id,sample_count,first_time,last_time,next_sequence) VALUES(?,1,?,?,?) ON CONFLICT(stream_id) DO UPDATE SET sample_count=sample_count+1, first_time=MIN(COALESCE(first_time,excluded.first_time),excluded.first_time),last_time=MAX(COALESCE(last_time,excluded.last_time),excluded.last_time),next_sequence=MAX(next_sequence,excluded.next_sequence)",
        )
        defer { meta.close() }
        try meta.text(streamID, at: 1)
        try meta.double(time, at: 2)
        try meta.double(time, at: 3)
        try meta.int64(Int64(sequence + 1), at: 4)
        guard try meta.step() == .done else { throw SampleStoreError.sql("Stream metadata update returned a row") }
    }
    private func execute(_ sql: String) throws {
        var errorText: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorText)
        if rc != SQLITE_OK {
            let msg = errorText.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorText)
            throw SampleStoreError.sql(msg)
        }
    }
    func statement(_ sql: String) throws -> SQLiteStatement {
        guard let db else { throw SampleStoreError.sql("Database connection is closed") }
        return try SQLiteStatement(db, sql)
    }
    private var errorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error" }
}

public struct StoredSample: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var sequence: UInt64
    public var value: Double
    public var segmentID: String?
    public init(timestamp: Date, sequence: UInt64, value: Double, segmentID: String? = nil) {
        self.timestamp = timestamp
        self.sequence = sequence
        self.value = value
        self.segmentID = segmentID
    }
}
