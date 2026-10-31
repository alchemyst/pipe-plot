import XCTest
@testable import PipePlotCore

final class AccelerateAnalysisTests: XCTestCase {
    func testIrregularLargeOffsetSeriesAcrossBatches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let stream = UUID(), origin = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = 1e12
        // Alternating intervals, an incomplete final batch, and a large value offset.
        let samples = (0..<2053).map { index in
            let time = Double(index * 2 + index % 2)
            return StoredSample(timestamp: origin.addingTimeInterval(time), sequence: UInt64(index),
                                value: baseline - 0.25 * time)
        }
        for sample in samples { try store.append(sample, to: stream) }
        let end = try XCTUnwrap(samples.last).timestamp
        let fit = try XCTUnwrap(store.linearFit(streamID: stream, from: origin, to: end))
        XCTAssertEqual(fit.slope, -0.25, accuracy: 1e-8)
        XCTAssertEqual(fit.value(at: origin), baseline, accuracy: 0.001)
        let target = baseline - 1500
        let crossing = try XCTUnwrap(fit.crossing(value: target))
        XCTAssertEqual(crossing.timeIntervalSince(origin), 6000, accuracy: 0.001)
        guard case .crossing(let forecast) = Analysis.linearForecast(samples: samples, guideValue: target) else {
            return XCTFail("Expected a future crossing")
        }
        XCTAssertEqual(forecast.timeIntervalSince(crossing), 0, accuracy: 0.001)
        let memory = try XCTUnwrap(Analysis.statistics(samples: samples))
        let database = try XCTUnwrap(store.statistics(streamID: stream, from: origin, to: end))
        XCTAssertEqual(database, memory)
        let times = samples.map { $0.timestamp.timeIntervalSince(origin) }
        let meanTime = times.reduce(0, +) / Double(times.count)
        let variance = times.reduce(0) { $0 + ($1 - meanTime) * ($1 - meanTime) } / Double(times.count)
        XCTAssertEqual(database.mean, baseline - 0.25 * meanTime, accuracy: 0.001)
        XCTAssertEqual(database.populationStandardDeviation, 0.25 * sqrt(variance), accuracy: 1e-5)
    }

    func testRepeatedTimestampsCannotProduceFit() {
        let time = Date(timeIntervalSince1970: 100)
        let samples = (0..<1025).map {
            StoredSample(timestamp: time, sequence: UInt64($0), value: Double($0))
        }
        XCTAssertEqual(Analysis.linearForecast(samples: samples, guideValue: 2000), .insufficientData)
    }

    func testLargeConstantHasZeroVariance() throws {
        let samples = (0..<1025).map {
            StoredSample(timestamp: Date(timeIntervalSince1970: Double($0)), sequence: UInt64($0), value: 1e200)
        }
        let statistics = try XCTUnwrap(Analysis.statistics(samples: samples))
        XCTAssertEqual(statistics.mean, 1e200)
        XCTAssertEqual(statistics.populationStandardDeviation, 0)
        XCTAssertEqual(Analysis.linearForecast(samples: samples, guideValue: 2e200), .flatSlope)
    }
}
