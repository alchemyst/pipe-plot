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
        let statement = try self.statement(
            "SELECT timestamp,sequence,value,segment_id FROM samples WHERE stream_id=? AND timestamp>=? AND timestamp<=? ORDER BY timestamp,sequence"
        )
        defer { statement.close() }

        try statement.text(streamID.uuidString.lowercased(), at: 1)
        try statement.double(from.timeIntervalSince1970, at: 2)
        try statement.double(to.timeIntervalSince1970, at: 3)
        while true {
            let result = try statement.step()
            if result == .done { break }
            guard result == .row else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            visit(
                StoredSample(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement.raw, 0)),
                    sequence: UInt64(sqlite3_column_int64(statement.raw, 1)),
                    value: sqlite3_column_double(statement.raw, 2),
                    segmentID: sqlite3_column_text(statement.raw, 3).map { String(cString: $0) }))
        }
    }

    /// Exact nearest observation for hover; display reduction never supplies readout values.
    public func nearestSample(streamID: StreamID, at time: Date) throws -> StoredSample? {
        lock.lock()
        defer { lock.unlock() }
        var choices: [StoredSample] = []
        for (comparison, order) in [("<=", "DESC"), (">=", "ASC")] {
            let statement = try self.statement(
                "SELECT timestamp,sequence,value,segment_id FROM samples WHERE stream_id=? AND timestamp \(comparison) ? ORDER BY timestamp \(order),sequence \(order) LIMIT 1"
            )
            defer { statement.close() }

            try statement.text(streamID.uuidString.lowercased(), at: 1)
            try statement.double(time.timeIntervalSince1970, at: 2)
            let code = try statement.step()
            if code == .row {
                choices.append(
                    StoredSample(
                        timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement.raw, 0)),
                        sequence: UInt64(sqlite3_column_int64(statement.raw, 1)),
                        value: sqlite3_column_double(statement.raw, 2),
                        segmentID: sqlite3_column_text(statement.raw, 3).map { String(cString: $0) }))
            } else if code != .done {
                throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
        return choices.min { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }
    }

    public func statistics(streamID: StreamID, from: Date, to: Date) throws -> SelectionStatistics? {
        lock.lock()
        defer { lock.unlock() }
        var moments = SampleMoments()
        var first: StoredSample?, last: StoredSample?
        try scan(streamID: streamID, from: from, to: to) { row in
            moments.append(time: 0, value: row.value)
            if first == nil { first = row }
            last = row
        }
        moments.flush()
        guard let first, let last else { return nil }
        let n = moments.count
        // SQLite performs the sort; no unbounded Swift array is materialized.
        let statement = try self.statement(
            "SELECT AVG(value) FROM (SELECT value FROM samples WHERE stream_id=? AND timestamp>=? AND timestamp<=? ORDER BY value LIMIT ? OFFSET ?)"
        )
        defer { statement.close() }

        try statement.text(streamID.uuidString.lowercased(), at: 1)
        try statement.double(from.timeIntervalSince1970, at: 2)
        try statement.double(to.timeIntervalSince1970, at: 3)
        try statement.int(n.isMultiple(of: 2) ? 2 : 1, at: 4)
        try statement.int64(Int64((n - 1) / 2), at: 5)
        guard try statement.step() == .row else { throw SampleStoreError.sql("Could not calculate median") }
        return SelectionStatistics(
            count: n, minimum: moments.minimum, maximum: moments.maximum, mean: moments.meanValue,
            populationStandardDeviation: sqrt(max(0, moments.valueSquares / Double(n))),
            median: sqlite3_column_double(statement.raw, 0),
            firstSampleAt: first.timestamp, lastSampleAt: last.timestamp, firstValue: first.value, lastValue: last.value
        )
    }

    public func linearFit(streamID: StreamID, from: Date, to: Date) throws -> LinearFit? {
        lock.lock()
        defer { lock.unlock() }
        var moments = SampleMoments()
        try scan(streamID: streamID, from: from, to: to) { row in
            moments.append(time: row.timestamp.timeIntervalSince(from), value: row.value)
        }
        moments.flush()
        guard let slope = moments.slope else { return nil }
        return LinearFit(
            count: moments.count, origin: from, meanTime: moments.meanTime,
            meanValue: moments.meanValue, slope: slope)
    }

    /// Keeps first/last/min/max per time bucket. The returned working set is bounded
    /// independently of raw history and preserves reconnect discontinuities conservatively.
    public func displaySamples(streamID: StreamID, from: Date, to: Date, bucketCount: Int = 800) throws
        -> [StoredSample]
    {
        lock.lock()
        defer { lock.unlock() }
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
                flush()
                current = index
                candidates = [sample, sample, sample, sample]
                segment = sample.segmentID
                mixed = false
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
