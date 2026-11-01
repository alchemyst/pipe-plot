import XCTest
@testable import PipePlotCore

final class ReusableLinearFitTests: XCTestCase {
    func testMembershipBoundariesArrivalsAndMappingOnWALReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let writer = try SampleStore(databaseURL: url)
        let reader = try SampleStore(readOnlyDatabaseURL: url)
        let id = UUID(), other = UUID(), start = Date(timeIntervalSince1970: 1000)
        for (time, value) in [(0.0, 0.0), (10, 10), (20, 40), (30, 90)] {
            try writer.append(values: [value], timestamp: start.addingTimeInterval(time), to: [id], segmentID: "a")
        }
        func query(_ from: Double, _ to: Double, _ old: ReusableLinearFit? = nil) throws -> ReusableLinearFit {
            try reader.reusableLinearFit(streamID: id, from: start.addingTimeInterval(from), to: start.addingTimeInterval(to), reusing: old)
        }
        var result = try query(0, 20)
        XCTAssertTrue(result.didRefit)
        for i in 1...90 {
            result = try query(0, 20 + Double(i) / 10, result)
            XCTAssertFalse(result.didRefit)
        }
        result = try query(0, 30, result) // inclusive upper boundary
        XCTAssertTrue(result.didRefit)
        XCTAssertEqual(result.fit?.count, 4)
        result = try query(0.001, 30, result) // lower boundary leaves
        XCTAssertTrue(result.didRefit)
        XCTAssertEqual(result.fit?.count, 3)
        XCTAssertEqual(try XCTUnwrap(result.fit).slope, 4, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(result.fit?.crossing(value: 100)).timeIntervalSince(start), 33.333333333, accuracy: 1e-6)
        try writer.append(values: [999], timestamp: start.addingTimeInterval(100), to: [id])
        result = try query(0.001, 30, result)
        XCTAssertFalse(result.didRefit) // arrival outside selection
        try writer.append(values: [20], timestamp: start.addingTimeInterval(15), to: [id])
        result = try query(0.001, 30, result)
        XCTAssertTrue(result.didRefit) // interior arrival, unchanged first/last
        XCTAssertEqual(result.fit?.count, 4)
        try writer.reassignSegments(["a"], from: id, to: other)
        result = try query(0.001, 30, result)
        XCTAssertTrue(result.didRefit)
        XCTAssertNil(result.fit)
        try writer.reassignSegments(["a"], from: other, to: id)
        result = try query(0.001, 30, result)
        XCTAssertTrue(result.didRefit)
        XCTAssertEqual(result.fit?.count, 4)
        // A mapping round trip preserves count and time bounds, but advances
        // sequence identities and must not pass the descriptor-only fast path.
        try writer.reassignSegments(["a"], from: id, to: other)
        try writer.reassignSegments(["a"], from: other, to: id)
        result = try query(0.001, 30, result)
        XCTAssertTrue(result.didRefit)
        XCTAssertEqual(result.fit?.count, 4)
    }

    func testFractionalTimestampBoundsUseSQLitePrecision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let id = UUID(), start = Date(timeIntervalSinceReferenceDate: 815123456.1234567)
        try store.append(values: [0], timestamp: start, to: [id])
        try store.append(values: [1], timestamp: start.addingTimeInterval(1), to: [id])
        let first = try store.reusableLinearFit(streamID: id, from: start, to: start.addingTimeInterval(1))
        XCTAssertTrue(first.contains(from: start, to: start.addingTimeInterval(1)))
        let second = try store.reusableLinearFit(streamID: id, from: start, to: start.addingTimeInterval(1), reusing: first)
        XCTAssertFalse(second.didRefit)
        XCTAssertEqual(second.fit, first.fit)
    }

    func testEqualCountAndMaximumSequenceDoNotHideRollingMembershipChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let id = UUID(), start = Date(timeIntervalSince1970: 1000)
        // Non-monotonic insertion order puts the largest sequence in both ranges.
        for time in [0.0, 20, 30, 10] {
            try store.append(values: [time * time], timestamp: start.addingTimeInterval(time), to: [id])
        }
        let first = try store.reusableLinearFit(streamID: id, from: start, to: start.addingTimeInterval(20))
        let second = try store.reusableLinearFit(streamID: id, from: start.addingTimeInterval(10),
                                                 to: start.addingTimeInterval(30), reusing: first)
        XCTAssertTrue(second.didRefit)
        XCTAssertEqual(first.fit?.count, second.fit?.count)
        XCTAssertEqual(try XCTUnwrap(first.fit).slope, 20, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(second.fit).slope, 40, accuracy: 1e-10)
    }

    func testEmptyGapAndDuplicateTimes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let id = UUID()
        for time in [0.0, 10, 10, 20] {
            try store.append(values: [time], timestamp: Date(timeIntervalSince1970: time), to: [id])
        }
        func query(_ from: Double, _ to: Double, _ old: ReusableLinearFit? = nil) throws -> ReusableLinearFit {
            try store.reusableLinearFit(streamID: id, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to), reusing: old)
        }
        var result = try query(1, 5)
        XCTAssertNil(result.fit)
        result = try query(2, 9, result)
        XCTAssertFalse(result.didRefit)
        result = try query(2, 10, result)
        XCTAssertTrue(result.didRefit)
        XCTAssertNil(result.fit) // two equal timestamps
        result = try query(2, 20, result)
        XCTAssertTrue(result.didRefit)
        XCTAssertEqual(result.fit?.count, 3)
        result = try query(10, 20, result)
        XCTAssertFalse(result.didRefit)
        result = try query(10.001, 20, result)
        XCTAssertTrue(result.didRefit)
        XCTAssertNil(result.fit)
    }
}
