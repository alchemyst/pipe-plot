import Foundation
import CSQLite

public struct DerivedSeriesResult: Sendable {
    public var points: [DerivedPoint]
    public var message: String
    public var processedSamples: Int
    public init(points: [DerivedPoint], message: String, processedSamples: Int) {
        self.points = points
        self.message = message
        self.processedSamples = processedSamples
    }
}

extension SampleStore {
    /// Robust initial cadence: first 129 observations, positive within-segment
    /// spacings only. Fixed suggestion; never recalculated by the live clock.
    public func suggestedDerivedInterval(streamID: StreamID) throws -> TimeInterval? {
        let rows = try query(streamID: streamID, limit: 129)
        return Self.cadence(rows)
    }
    private static func cadence(_ rows: [StoredSample]) -> Double? {
        let spacings = zip(rows, rows.dropFirst()).compactMap { a, b -> Double? in
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            return a.segmentID == b.segmentID && dt > 0 ? dt : nil
        }.sorted()
        guard !spacings.isEmpty else { return nil }
        let middle = spacings.count / 2
        return spacings.count % 2 == 0 ? (spacings[middle - 1] + spacings[middle]) / 2 : spacings[middle]
    }

    /// Scans raw input through one bounded FIR, retaining at most six extrema per
    /// display bucket. Never filters display-reduced points or caches full history.
    public func derivedSeries(
        streamID: StreamID, configuration c: DerivedSeriesConfiguration,
        from start: Date, to end: Date, bucketCount: Int = 400, live: Bool = false
    ) throws -> DerivedSeriesResult {
        try c.validate(cadence: c.referenceCadence ?? suggestedDerivedInterval(streamID: streamID))
        guard start <= end, (1...800).contains(bucketCount) else { throw DerivedSeriesError.invalidSettings }
        lock.lock()
        defer { lock.unlock() }
        // Receipt jitter needs interpolation; a sustained material cadence speedup
        // instead requires a finer grid. Do not silently decimate that new regime.
        let recentStatement = try self.statement(
            "SELECT timestamp,sequence,value,segment_id FROM samples WHERE stream_id=? ORDER BY timestamp DESC,sequence DESC LIMIT 129"
        )
        defer { recentStatement.close() }

        try recentStatement.text(streamID.uuidString.lowercased(), at: 1)
        var recent: [StoredSample] = []
        var recentRC = try recentStatement.step()
        while recentRC == .row {
            recent.append(
                StoredSample(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(recentStatement.raw, 0)),
                    sequence: UInt64(sqlite3_column_int64(recentStatement.raw, 1)),
                    value: sqlite3_column_double(recentStatement.raw, 2),
                    segmentID: sqlite3_column_text(recentStatement.raw, 3).map { String(cString: $0) }))
            recentRC = try recentStatement.step()
        }
        guard recentRC == .done else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
        if let cadence = Self.cadence(Array(recent.reversed())), cadence < c.interval * 0.8 {
            throw DerivedSeriesError.downsampling
        }
        guard let origin = try bounds(streamID: streamID).first else {
            return DerivedSeriesResult(points: [], message: "Waiting for observations", processedSamples: 0)
        }
        let padding = c.delay + c.maximumGap + c.interval
        let stmt = try self.statement(
            "SELECT timestamp,sequence,value,segment_id FROM samples WHERE stream_id=? AND timestamp>=? AND timestamp<=? ORDER BY timestamp,sequence"
        )
        defer { stmt.close() }

        try stmt.text(streamID.uuidString.lowercased(), at: 1)
        try stmt.double(start.addingTimeInterval(-padding).timeIntervalSince1970, at: 2)
        try stmt.double(end.addingTimeInterval(padding).timeIntervalSince1970, at: 3)
        var processor = try DerivedSeriesProcessor(configuration: c, origin: origin)
        var buckets = [[DerivedPoint]](repeating: [], count: bucketCount), processed = 0
        let span = max(c.interval, end.timeIntervalSince(start))
        func collect(_ p: DerivedPoint) {
            guard p.timestamp >= start, p.timestamp <= end else { return }
            let index = min(
                bucketCount - 1, max(0, Int(p.timestamp.timeIntervalSince(start) / span * Double(bucketCount))))
            // First, last, smooth min/max, derivative min/max. Stable ordering and
            // separate runs avoid connecting through any removed gap.
            let old = buckets[index]
            if old.isEmpty {
                buckets[index] = [p]
                return
            }
            let candidates = old + [p]
            let chosen = [
                candidates.first!, p,
                candidates.min { $0.smoothed < $1.smoothed }!, candidates.max { $0.smoothed < $1.smoothed }!,
                candidates.min { $0.derivative < $1.derivative }!, candidates.max { $0.derivative < $1.derivative }!,
            ]
            buckets[index] = chosen.sorted { $0.timestamp < $1.timestamp }.reduce(into: []) { result, item in
                if result.last?.timestamp != item.timestamp { result.append(item) }
            }
        }
        var rc = try stmt.step()
        while rc == .row {
            let sample = StoredSample(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt.raw, 0)),
                sequence: UInt64(sqlite3_column_int64(stmt.raw, 1)), value: sqlite3_column_double(stmt.raw, 2),
                segmentID: sqlite3_column_text(stmt.raw, 3).map { String(cString: $0) })
            try processor.append(sample, emit: collect)
            processed += 1
            rc = try stmt.step()
        }
        guard rc == .done else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
        if !live { processor.finish(emit: collect) }
        let points = buckets.flatMap { $0 }
        let message =
            points.isEmpty
            ? "Insufficient contiguous data for the centered window"
            : "Delayed centered estimate · \(String(format: "%g", c.delay)) s delay · \(points.filter { $0.interpolatedCount > 0 }.count)/\(points.count) displayed estimates use interpolation"
        return DerivedSeriesResult(points: points, message: message, processedSamples: processed)
    }
}
