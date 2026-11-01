import Foundation
import CSQLite

/// A fit and the indexed time boundaries within which its membership is unchanged.
/// Nil fits are cached too (empty or insufficiently distinct observations).
public struct ReusableLinearFit: Sendable {
    public let fit: LinearFit?
    public let didRefit: Bool
    public let streamID: StreamID
    fileprivate let revision: Int64
    fileprivate let mutation: Int64
    fileprivate let count: Int64
    fileprivate let newestSequence: Int64
    fileprivate let first: Date?
    fileprivate let last: Date?
    fileprivate let before: Date?
    fileprivate let after: Date?

    /// Caller must separately establish that the stream data has not changed.
    public func contains(from: Date, to: Date) -> Bool {
        // Compare in SQLite's timestamp representation: Date's reference epoch
        // can otherwise differ by a fraction of a microsecond at exact edges.
        let lower = from.timeIntervalSince1970, upper = to.timeIntervalSince1970
        return (before.map { lower > $0.timeIntervalSince1970 } ?? true)
            && (after.map { upper < $0.timeIntervalSince1970 } ?? true)
            && (first.map { lower <= $0.timeIntervalSince1970 } ?? true)
            && (last.map { upper >= $0.timeIntervalSince1970 } ?? true)
    }
}

extension SampleStore {
    /// Reads revision, membership and fit in one WAL snapshot. Silent ticks need
    /// only a revision lookup; crossing a boundary requires indexed endpoint seeks.
    /// Append-only membership uses count + maximum allocated sequence; updates,
    /// deletes and segment remaps additionally advance the mutation generation.
    public func reusableLinearFit(streamID: StreamID, from: Date, to: Date,
                                  reusing previous: ReusableLinearFit? = nil) throws -> ReusableLinearFit {
        lock.lock(); defer { lock.unlock() }
        func sql(_ text: String) throws {
            guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
                throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
        try sql("BEGIN DEFERRED")
        defer { try? sql("ROLLBACK") }
        var version: OpaquePointer?
        try prepare("SELECT revision,mutation FROM fit_versions WHERE stream_id=?", &version)
        defer { sqlite3_finalize(version) }
        bindText(version, 1, streamID.uuidString.lowercased())
        let code = sqlite3_step(version)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw SampleStoreError.sql("Could not read fit revision") }
        let revision = code == SQLITE_ROW ? sqlite3_column_int64(version, 0) : 0
        let mutation = code == SQLITE_ROW ? sqlite3_column_int64(version, 1) : 0
        let old = previous.flatMap { $0.streamID == streamID ? $0 : nil }
        if let old, old.revision == revision, old.contains(from: from, to: to) {
            return ReusableLinearFit(fit: old.fit, didRefit: false, streamID: streamID, revision: revision,
                mutation: mutation, count: old.count, newestSequence: old.newestSequence,
                first: old.first, last: old.last, before: old.before, after: old.after)
        }
        func endpoint(_ comparison: String, _ date: Date, _ order: String) throws -> Date? {
            var statement: OpaquePointer?
            try prepare("SELECT timestamp FROM samples WHERE stream_id=? AND timestamp \(comparison) ? ORDER BY timestamp \(order),sequence \(order) LIMIT 1", &statement)
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, streamID.uuidString.lowercased())
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw SampleStoreError.sql("Could not read fit boundary") }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
        var membership: OpaquePointer?
        try prepare("SELECT COUNT(*),COALESCE(MAX(sequence),-1) FROM samples WHERE stream_id=? AND timestamp>=? AND timestamp<=?", &membership)
        defer { sqlite3_finalize(membership) }
        bindText(membership, 1, streamID.uuidString.lowercased())
        sqlite3_bind_double(membership, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(membership, 3, to.timeIntervalSince1970)
        guard sqlite3_step(membership) == SQLITE_ROW else { throw SampleStoreError.sql("Could not read fit membership") }
        let count = sqlite3_column_int64(membership, 0), newest = sqlite3_column_int64(membership, 1)
        let first = try count > 0 ? endpoint(">=", from, "ASC") : nil
        let last = try count > 0 ? endpoint("<=", to, "DESC") : nil
        let reuse = old.map {
            $0.mutation == mutation && $0.count == count && $0.newestSequence == newest
                && $0.first == first && $0.last == last
        } ?? false
        let fit = try reuse ? old?.fit : linearFit(streamID: streamID, from: from, to: to)
        return try ReusableLinearFit(fit: fit, didRefit: !reuse, streamID: streamID, revision: revision,
            mutation: mutation, count: count, newestSequence: newest,
            first: first, last: last,
            before: endpoint("<", from, "DESC"), after: endpoint(">", to, "ASC"))
    }
}
