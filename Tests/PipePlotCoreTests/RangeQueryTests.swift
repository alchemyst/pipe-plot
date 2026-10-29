import XCTest
@testable import PipePlotCore

final class RangeQueryTests: XCTestCase {
    func testLongRangeUsesAllRawSamplesAndRetainsExtrema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let stream = UUID(), origin = Date(timeIntervalSince1970: 1_000)
        for index in 0..<50_010 {
            try store.append(StoredSample(timestamp: origin.addingTimeInterval(Double(index)), sequence: UInt64(index), value: Double(index), segmentID: index < 25_000 ? "one" : "two"), to: stream)
        }
        let end = origin.addingTimeInterval(50_009)
        let statistics = try XCTUnwrap(store.statistics(streamID: stream, from: origin, to: end))
        XCTAssertEqual(statistics.count, 50_010)
        XCTAssertEqual(statistics.mean, 25_004.5, accuracy: 1e-8)
        XCTAssertEqual(statistics.median, 25_004.5, accuracy: 1e-8)
        XCTAssertEqual(statistics.change, 50_009)
        let fit = try XCTUnwrap(store.linearFit(streamID: stream, from: origin, to: end))
        XCTAssertEqual(fit.slope, 1, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(fit.crossing(value: 60_000)).timeIntervalSince(origin), 60_000, accuracy: 1e-6)
        let display = try store.displaySamples(streamID: stream, from: origin, to: end, bucketCount: 100)
        XCTAssertLessThanOrEqual(display.count, 400)
        XCTAssertEqual(display.first?.value, 0)
        XCTAssertEqual(display.last?.value, 50_009)
        XCTAssertEqual(try store.query(streamID: stream, from: origin, to: origin, limit: 1).first?.segmentID, "one")
    }

    func testFlatFitAndEmptyRange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let stream = UUID(), start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 200)
        XCTAssertNil(try store.statistics(streamID: stream, from: start, to: end))
        XCTAssertNil(try store.linearFit(streamID: stream, from: start, to: end))
        try store.append(values: [-2], timestamp: start, to: [stream], segmentID: "a")
        try store.append(values: [-2], timestamp: end, to: [stream], segmentID: "b")
        let fit = try XCTUnwrap(store.linearFit(streamID: stream, from: start, to: end))
        XCTAssertNil(fit.crossing(value: 10))
        XCTAssertEqual(try store.statistics(streamID: stream, from: start, to: end)?.mean, -2)
    }
}
