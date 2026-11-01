import XCTest
@testable import PipePlotCore

final class DerivedSeriesTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1000)
    private func configuration(_ kernel: SmoothingKernel = .weightedSavitzkyGolay, dt: Double = 1, window: Double = 10, gap: Double = 3) -> DerivedSeriesConfiguration {
        .init(interval: dt, window: window, maximumGap: gap, kernel: kernel, referenceCadence: dt)
    }
    private func rows(_ count: Int, dt: Double = 1, value: (Double) -> Double) -> [StoredSample] {
        (0..<count).map { i in .init(timestamp: origin.addingTimeInterval(Double(i) * dt), sequence: UInt64(i), value: value(Double(i) * dt), segmentID: "a") }
    }
    private func filter(_ rows: [StoredSample], _ c: DerivedSeriesConfiguration, chunkSize: Int = 100000) throws -> [DerivedPoint] {
        var processor = try DerivedSeriesProcessor(configuration: c, origin: origin), result: [DerivedPoint] = []
        for chunk in stride(from: 0, to: rows.count, by: chunkSize) {
            for row in rows[chunk..<min(rows.count, chunk + chunkSize)] { try processor.append(row) { result.append($0) } }
        }
        processor.finish { result.append($0) }; return result
    }
    func testAnalyticSignalsAndDerivativeSignUnitsAlignment() throws {
        for kernel in SmoothingKernel.allCases {
            for degree in 0...3 {
                let c = configuration(kernel, dt: 0.25, window: 3, gap: 1)
                let points = try filter(rows(100, dt: 0.25) { pow($0, Double(degree)) }, c)
                XCTAssertEqual(points.count, 100 - 2 * c.radius)
                XCTAssertEqual(points.first!.timestamp, origin.addingTimeInterval(c.delay))
                XCTAssertEqual(points.last!.timestamp, origin.addingTimeInterval(24.75 - c.delay))
                for point in points {
                    let t = point.timestamp.timeIntervalSince(origin)
                    XCTAssertEqual(point.smoothed, pow(t, Double(degree)), accuracy: 1e-7)
                    XCTAssertEqual(point.derivative, degree == 0 ? 0 : Double(degree) * pow(t, Double(degree - 1)), accuracy: 1e-7)
                    XCTAssertEqual(point.interpolatedCount, 0)
                }
            }
            let sine = try filter(rows(1001, dt: 0.1) { sin($0 * 0.4) }, configuration(kernel, dt: 0.1, window: 2, gap: 0.3))
            for point in sine {
                let t = point.timestamp.timeIntervalSince(origin)
                XCTAssertEqual(point.smoothed, sin(t * 0.4), accuracy: 0.001)
                XCTAssertEqual(point.derivative, 0.4 * cos(t * 0.4), accuracy: 0.0001)
            }
        }
    }
    func testJitterDriftShortMissingAndDuplicateLastWins() throws {
        var source: [StoredSample] = []
        for i in 0..<300 where i != 100 && i != 101 {
            let t = Double(i) * 1.007 + 0.04 * sin(Double(i) * 1.7)
            source.append(.init(timestamp: origin.addingTimeInterval(t), sequence: UInt64(i * 2), value: 4 - 2 * t, segmentID: "a"))
            if i == 80 {
                // Duplicate's final value wins, even across a caller chunk boundary.
                source[source.count - 1].value = 9999
                source.append(.init(timestamp: origin.addingTimeInterval(t), sequence: UInt64(i * 2 + 1), value: 4 - 2 * t, segmentID: "a"))
            }
        }
        let c = configuration(dt: 1, window: 10, gap: 3.2)
        let batch = try filter(source, c), incremental = try filter(source, c, chunkSize: 7)
        XCTAssertEqual(batch, incremental)
        XCTAssertGreaterThan(batch.count, 280)
        XCTAssertTrue(batch.contains { $0.interpolatedCount > 0 })
        for point in batch {
            XCTAssertEqual(point.smoothed, 4 - 2 * point.timestamp.timeIntervalSince(origin), accuracy: 1e-6)
            XCTAssertEqual(point.derivative, -2, accuracy: 1e-6)
        }
    }
    func testLongGapReconnectNoPaddingAndObservedOnly() throws {
        let c = configuration()
        var source = rows(30) { $0 }
        source += (50..<80).map { .init(timestamp: origin.addingTimeInterval(Double($0)), sequence: UInt64($0), value: Double($0), segmentID: "a") }
        source += (80..<110).map { .init(timestamp: origin.addingTimeInterval(Double($0)), sequence: UInt64($0), value: Double($0), segmentID: "b") }
        let points = try filter(source, c)
        XCTAssertEqual(points.count, 60)
        XCTAssertEqual(Set(points.map(\.run)).count, 3)
        XCTAssertFalse(points.contains { (25..<55).contains($0.timestamp.timeIntervalSince(origin)) })
        XCTAssertFalse(points.contains { (75..<85).contains($0.timestamp.timeIntervalSince(origin)) })
        XCTAssertTrue(try filter(Array(source.prefix(8)), c).isEmpty)
        var exact = c; exact.resampling = .observedOnly
        let jittered = rows(100, dt: 1.01) { $0 }
        XCTAssertTrue(try filter(jittered, exact).isEmpty)
        var p = try DerivedSeriesProcessor(configuration: c, origin: origin)
        try p.append(source[1]) { _ in }
        XCTAssertThrowsError(try p.append(source[0]) { _ in })
    }
    func testStoreQueryCadencePersistenceUndoAndRawStatistics() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.sqlite")
        let store = try PipePlotStore(databaseURL: url)
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let id = ready.streams[0].id
        for row in rows(200, value: { $0 }) { _ = try store.append(.init(timestamp: row.timestamp, values: [row.value]), to: ready.attachmentID) }
        XCTAssertEqual(try store.samples.suggestedDerivedInterval(streamID: id), 1)
        XCTAssertThrowsError(try store.setDerivedSeries(configuration(dt: 2), streamID: id))
        let c = configuration()
        try store.setDerivedSeries(c, streamID: id)
        let result = try store.samples.derivedSeries(streamID: id, configuration: c, from: origin.addingTimeInterval(50), to: origin.addingTimeInterval(100), bucketCount: 800)
        let expected = try filter(rows(200, value: { $0 }), c).filter { $0.timestamp >= origin.addingTimeInterval(50) && $0.timestamp <= origin.addingTimeInterval(100) }
        XCTAssertEqual(result.points.map(\.timestamp), expected.map(\.timestamp))
        for (actual, expected) in zip(result.points, expected) { XCTAssertEqual(actual.derivative, expected.derivative, accuracy: 1e-10) }
        XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
        XCTAssertNil(try store.snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].derivedSeries)
        _ = try store.append(.init(timestamp: origin.addingTimeInterval(200), values: [200]), to: ready.attachmentID)
        XCTAssertTrue(try store.redo(sessionID: ready.sessionID))
        let restored = try PipePlotStore(databaseURL: url)
        XCTAssertEqual(try restored.snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].derivedSeries, c)
        XCTAssertEqual(try restored.samples.count(streamID: id), 201)
        XCTAssertEqual(try restored.samples.statistics(streamID: id, from: origin, to: origin.addingTimeInterval(200))?.mean, 100)
        let reduced = try store.samples.derivedSeries(streamID: id, configuration: c, from: origin, to: origin.addingTimeInterval(200), bucketCount: 3)
        XCTAssertLessThanOrEqual(reduced.points.count, 18)
    }
    func testKernelComparisonAtMatchedBandwidth() throws {
        let ordinary = configuration(.savitzkyGolay, window: 20)
        func cutoff(_ c: DerivedSeriesConfiguration) throws -> Double {
            let k = try PolynomialKernel(configuration: c).smoothing
            for step in 1...5000 {
                let f = Double(step) / 10000
                let amplitude = zip(k.indices, k).reduce(0.0) { $0 + $1.1 * cos(2 * .pi * f * Double($1.0 - c.radius)) }
                if amplitude < 1 / sqrt(2) { return f }
            }
            return 0.5
        }
        let target = try cutoff(ordinary)
        let alternatives = try (10...25).map { radius -> (DerivedSeriesConfiguration, Double) in
            let c = configuration(window: Double(2 * radius)); return (c, try cutoff(c))
        }
        let (weighted, weightedCutoff) = alternatives.min { abs($0.1 - target) < abs($1.1 - target) }!
        XCTAssertLessThan(abs(weightedCutoff - target) / target, 0.06)
        var seed: UInt64 = 190019
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 11) / Double(UInt64.max >> 11) - 0.5 }
        let input = rows(20000) { t in sin(2 * .pi * 0.01 * t) + 0.5 * sin(2 * .pi * 0.31 * t) + 0.3 * sin(2 * .pi * 0.43 * t) + 0.1 * noise() }
        func errors(_ c: DerivedSeriesConfiguration) throws -> (Double, Double) {
            let output = try filter(input, c).filter { $0.timestamp > origin.addingTimeInterval(100) && $0.timestamp < origin.addingTimeInterval(19900) }
            let smooth = output.reduce(0) { $0 + pow($1.smoothed - sin(2 * .pi * 0.01 * $1.timestamp.timeIntervalSince(origin)), 2) }
            let derivative = output.reduce(0) { $0 + pow($1.derivative - 2 * .pi * 0.01 * cos(2 * .pi * 0.01 * $1.timestamp.timeIntervalSince(origin)), 2) }
            return (sqrt(smooth / Double(output.count)), sqrt(derivative / Double(output.count)))
        }
        let sg = try errors(ordinary), w = try errors(weighted)
        print("DERIVED_COMPARISON seed=190019 SG_radius=\(ordinary.radius) WSG_radius=\(weighted.radius) cutoff=\(target),\(weightedCutoff) smooth_RMSE=\(sg.0),\(w.0) derivative_RMSE=\(sg.1),\(w.1)")
        XCTAssertLessThan(w.0, sg.0); XCTAssertLessThan(w.1, sg.1)
        // Neither kernel invents estimates at start/end: compared windows differ
        // only by their explicitly reported centered latency.
        XCTAssertEqual(try filter(input, weighted).first?.timestamp, origin.addingTimeInterval(weighted.delay))
    }
    func testLiveDuplicateClosureAndCadenceSpeedup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("test.sqlite")), id = UUID()
        let c = configuration()
        for i in 0..<30 { try store.append(values: [Double(i)], timestamp: origin.addingTimeInterval(Double(i)), to: [id], segmentID: "a") }
        func query(live: Bool) throws -> DerivedSeriesResult {
            try store.derivedSeries(streamID: id, configuration: c, from: origin, to: origin.addingTimeInterval(100), live: live)
        }
        let before = try query(live: true)
        XCTAssertEqual(before.points.count, 19)
        try store.append(values: [999], timestamp: origin.addingTimeInterval(29), to: [id], segmentID: "a")
        XCTAssertEqual(try query(live: true).points, before.points) // pending group is not published
        try store.append(values: [29], timestamp: origin.addingTimeInterval(29), to: [id], segmentID: "a")
        XCTAssertEqual(try query(live: false).points.count, 20) // EOF flushes the final last-wins group
        // Small cadence changes do not silently replace the saved reference cadence.
        for i in 1...150 {
            try store.append(values: [Double(i)], timestamp: origin.addingTimeInterval(29 + Double(i) * 0.99), to: [id], segmentID: "a")
        }
        XCTAssertFalse(try query(live: false).points.isEmpty)
        for i in 1...150 {
            try store.append(values: [Double(i)], timestamp: origin.addingTimeInterval(178 + Double(i) * 0.1), to: [id], segmentID: "a")
        }
        XCTAssertThrowsError(try query(live: false)) // no silent decimation after a material speedup
    }

    func testInterpolationBiasAndLargeConstant() throws {
        let constant = try filter(rows(40) { _ in 1e200 }, configuration())
        XCTAssertTrue(constant.allSatisfy { $0.smoothed == 1e200 && $0.derivative == 0 })
        let source = (0..<1000).filter { $0 % 37 != 12 }.map { i -> StoredSample in
            let t = Double(i) * 1.003 + 0.06 * sin(Double(i) * 1.7)
            return .init(timestamp: origin.addingTimeInterval(t), sequence: UInt64(i), value: sin(t * 0.08), segmentID: "a")
        }
        let points = try filter(source, configuration())
        let smoothingRMSE = sqrt(points.reduce(0) { $0 + pow($1.smoothed - sin($1.timestamp.timeIntervalSince(origin) * 0.08), 2) } / Double(points.count))
        let derivativeRMSE = sqrt(points.reduce(0) { $0 + pow($1.derivative - 0.08 * cos($1.timestamp.timeIntervalSince(origin) * 0.08), 2) } / Double(points.count))
        print("DERIVED_RESAMPLING sine_frequency_rad_s=0.08 cadence=1.003 jitter=0.06 missing_every=37 smoothing_RMSE=\(smoothingRMSE) derivative_RMSE=\(derivativeRMSE)")
        XCTAssertLessThan(smoothingRMSE, 0.002); XCTAssertLessThan(derivativeRMSE, 0.0005)
        XCTAssertGreaterThan(smoothingRMSE, 0) // interpolation is not exact for curved signals
    }

    func testBoundedWorkingMemoryAndInvalidConfiguration() throws {
        for c in [configuration(dt: 0), configuration(window: .infinity), configuration(gap: -1)] {
            XCTAssertThrowsError(try DerivedSeriesProcessor(configuration: c, origin: origin))
        }
        var processor = try DerivedSeriesProcessor(configuration: configuration(window: 100), origin: origin)
        let capacity = processor.workingCapacity
        var count = 0
        let start = Date()
        for i in 0..<100000 {
            try processor.append(.init(timestamp: origin.addingTimeInterval(Double(i)), sequence: UInt64(i), value: sin(Double(i)), segmentID: "a")) { _ in count += 1 }
        }
        processor.finish { _ in count += 1 }
        XCTAssertEqual(processor.workingCapacity, capacity)
        XCTAssertEqual(count, 99900)
        print("DERIVED_SUSTAINED samples=100000 window=101 capacity=\(capacity) elapsed=\(Date().timeIntervalSince(start))")
    }
}
