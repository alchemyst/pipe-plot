import Foundation
import CSQLite

/// A centered least-squares fit. The same fit can be retained for a fixed selection.
public struct LinearFit: Equatable, Sendable {
    public let count: Int
    public let origin: Date
    public let meanTime: Double
    public let meanValue: Double
    public let slope: Double
    public func value(at date: Date) -> Double {
        meanValue + slope * (date.timeIntervalSince(origin) - meanTime)
    }
    public func crossing(value: Double) -> Date? {
        guard slope.isFinite, abs(slope) > 1e-15 else { return nil }
        let time = origin.timeIntervalSince1970 + meanTime + (value - meanValue) / slope
        guard time.isFinite, abs(time) < 8.64e12 else { return nil }
        return Date(timeIntervalSince1970: time)
    }
}

extension SampleStore {
    /// Enumerates raw rows with constant client memory and checks SQLite read failures.
    private func scan(streamID: StreamID, from: Date, to: Date, visit: (StoredSample) -> Void) throws {
        var statement: OpaquePointer?
        try prepare("SELECT timestamp,sequence,value,segment_id FROM samples WHERE stream_id=? AND timestamp>=? AND timestamp<=? ORDER BY timestamp,sequence", &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, streamID.uuidString.lowercased())
        sqlite3_bind_double(statement, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, to.timeIntervalSince1970)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            visit(StoredSample(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                sequence: UInt64(sqlite3_column_int64(statement, 1)), value: sqlite3_column_double(statement, 2),
                segmentID: sqlite3_column_text(statement, 3).map { String(cString: $0) }))
        }
    }

    /// Exact nearest observation for hover; display reduction never supplies readout values.
    public func nearestSample(streamID: StreamID, at time: Date) throws -> StoredSample? {
        lock.lock(); defer { lock.unlock() }
        var choices: [StoredSample] = []
        for (comparison, order) in [("<=", "DESC"), (">=", "ASC")] {
            var statement: OpaquePointer?
            try prepare("SELECT timestamp,sequence,value,segment_id FROM samples WHERE stream_id=? AND timestamp \(comparison) ? ORDER BY timestamp \(order),sequence \(order) LIMIT 1", &statement)
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, streamID.uuidString.lowercased()); sqlite3_bind_double(statement, 2, time.timeIntervalSince1970)
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                choices.append(StoredSample(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    sequence: UInt64(sqlite3_column_int64(statement, 1)), value: sqlite3_column_double(statement, 2),
                    segmentID: sqlite3_column_text(statement, 3).map { String(cString: $0) }))
            } else if code != SQLITE_DONE { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
        }
        return choices.min { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }
    }

    public func statistics(streamID: StreamID, from: Date, to: Date) throws -> SelectionStatistics? {
        lock.lock(); defer { lock.unlock() }
        var moments = SampleMoments()
        var first: StoredSample?, last: StoredSample?
        try scan(streamID: streamID, from: from, to: to) { row in
            moments.append(time: 0, value: row.value)
            if first == nil { first = row }; last = row
        }
        moments.flush()
        guard let first, let last else { return nil }
        let n = moments.count
        // SQLite performs the sort; no unbounded Swift array is materialized.
        var statement: OpaquePointer?
        try prepare("SELECT AVG(value) FROM (SELECT value FROM samples WHERE stream_id=? AND timestamp>=? AND timestamp<=? ORDER BY value LIMIT ? OFFSET ?)", &statement)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, streamID.uuidString.lowercased())
        sqlite3_bind_double(statement, 2, from.timeIntervalSince1970); sqlite3_bind_double(statement, 3, to.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, n.isMultiple(of: 2) ? 2 : 1)
        sqlite3_bind_int64(statement, 5, Int64((n - 1) / 2))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SampleStoreError.sql("Could not calculate median") }
        return SelectionStatistics(count: n, minimum: moments.minimum, maximum: moments.maximum, mean: moments.meanValue,
            populationStandardDeviation: sqrt(max(0, moments.valueSquares / Double(n))), median: sqlite3_column_double(statement, 0),
            firstSampleAt: first.timestamp, lastSampleAt: last.timestamp, firstValue: first.value, lastValue: last.value)
    }

    public func linearFit(streamID: StreamID, from: Date, to: Date) throws -> LinearFit? {
        lock.lock(); defer { lock.unlock() }
        var moments = SampleMoments()
        try scan(streamID: streamID, from: from, to: to) { row in
            moments.append(time: row.timestamp.timeIntervalSince(from), value: row.value)
        }
        moments.flush()
        guard let slope = moments.slope else { return nil }
        return LinearFit(count: moments.count, origin: from, meanTime: moments.meanTime,
                         meanValue: moments.meanValue, slope: slope)
    }

    /// Keeps first/last/min/max per time bucket. The returned working set is bounded
    /// independently of raw history and preserves reconnect discontinuities conservatively.
    public func displaySamples(streamID: StreamID, from: Date, to: Date, bucketCount: Int = 800) throws -> [StoredSample] {
        lock.lock(); defer { lock.unlock() }
        let buckets = max(1, min(4096, bucketCount)), span = max(0.001, to.timeIntervalSince(from))
        var output: [StoredSample] = [], candidates: [StoredSample] = []
        var current = -1, mixed = false, segment: String?
        func flush() {
            var unique: [UInt64: StoredSample] = [:]
            for sample in candidates { unique[sample.sequence] = sample }
            var rows = unique.values.sorted { ($0.timestamp, $0.sequence) < ($1.timestamp, $1.sequence) }
            if mixed {
                // Avoid drawing invented continuity through collapsed reconnects.
                for i in rows.indices { rows[i].segmentID = "reduced-\(rows[i].sequence)" }
            }
            output.append(contentsOf: rows)
        }
        try scan(streamID: streamID, from: from, to: to) { sample in
            let index = min(buckets - 1, max(0, Int(sample.timestamp.timeIntervalSince(from) / span * Double(buckets))))
            if index != current {
                flush(); current = index; candidates = [sample, sample, sample, sample]
                segment = sample.segmentID; mixed = false
            } else {
                candidates[1] = sample
                if sample.value < candidates[2].value { candidates[2] = sample }
                if sample.value > candidates[3].value { candidates[3] = sample }
                if sample.segmentID != segment { mixed = true }
            }
        }
        flush()
        return output
    }
}
