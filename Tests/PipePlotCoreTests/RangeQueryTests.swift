import XCTest
@testable import PipePlotCore

final class RangeQueryTests: XCTestCase {
    func testSparseSignedSelectionStatisticsSurviveViewportChangesAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("history.sqlite")
        let first = UUID(), second = UUID(), emptyInSelection = UUID()
        func time(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_000 + offset) }
        let selection = TimeSelection(start: time(1), end: time(10))
        let bounds = selection.resolvedBounds(at: time(40))
        let initialViewport = time(1)...time(10)
        let widerViewport = time(-10)...time(40)

        func check(_ store: SampleStore, viewport: ClosedRange<Date>) throws {
            let display = try store.displaySamples(
                streamID: first, from: viewport.lowerBound, to: viewport.upperBound, bucketCount: 1)
            XCTAssertLessThan(display.count, 5)
            let a = try XCTUnwrap(
                store.statistics(streamID: first, from: bounds.lowerBound, to: bounds.upperBound))
            XCTAssertEqual(a.count, 5)
            XCTAssertEqual(a.minimum, -8)
            XCTAssertEqual(a.maximum, 11)
            XCTAssertEqual(a.mean, 1.2, accuracy: 1e-12)
            let b = try XCTUnwrap(
                store.statistics(streamID: second, from: bounds.lowerBound, to: bounds.upperBound))
            XCTAssertEqual(b.count, 2)
            XCTAssertEqual(b.minimum, -3)
            XCTAssertEqual(b.maximum, 0)
            XCTAssertEqual(b.mean, -1.5, accuracy: 1e-12)
            XCTAssertNil(
                try store.statistics(streamID: emptyInSelection, from: bounds.lowerBound, to: bounds.upperBound))
        }

        do {
            let store = try SampleStore(databaseURL: database)
            for (offset, value) in [(0.5, 100.0), (1, -8), (2.25, 0), (5, 4), (8.75, -1), (10, 11), (18, -70)] {
                try store.append(values: [value], timestamp: time(offset), to: [first])
            }
            try store.append(values: [-3], timestamp: time(3.5), to: [second])
            try store.append(values: [0], timestamp: time(9), to: [second])
            try store.append(values: [90], timestamp: time(22), to: [emptyInSelection])
            try check(store, viewport: initialViewport)
            try check(store, viewport: widerViewport)
        }

        let reopened = try SampleStore(databaseURL: database)
        try check(reopened, viewport: initialViewport)
        try check(reopened, viewport: widerViewport)
    }

    func testLongRangeUsesAllRawSamplesAndRetainsExtrema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let stream = UUID(), origin = Date(timeIntervalSince1970: 1_000)
        for index in 0..<50_010 {
            try store.append(
                StoredSample(
                    timestamp: origin.addingTimeInterval(Double(index)), sequence: UInt64(index), value: Double(index),
                    segmentID: index < 25_000 ? "one" : "two"), to: stream)
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

extension RangeQueryTests {
    func testSegmentRemapUndoIncludesLaterArrivals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let old = UUID(), new = UUID(), now = Date()
        try store.append(values: [1], timestamp: now, to: [old], segmentID: "original")
        try store.append(values: [2], timestamp: now, to: [new], segmentID: "resumed")
        try store.reassignSegments(["resumed"], from: new, to: old)
        try store.append(values: [3], timestamp: now, to: [old], segmentID: "resumed")
        try store.append(values: [9], timestamp: now, to: [old], segmentID: "unrelated")
        try store.reassignSegments(["resumed"], from: old, to: new)
        XCTAssertEqual(try store.query(streamID: old).map(\.value), [1, 9])
        XCTAssertEqual(try store.query(streamID: new).map(\.value), [2, 3])
        try store.reassignSegments(["resumed"], from: new, to: old)
        XCTAssertEqual(try store.count(streamID: old), 4)
        XCTAssertEqual(try store.count(streamID: new), 0)
    }
}
