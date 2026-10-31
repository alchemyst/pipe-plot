import XCTest
@testable import PipePlotCore

final class PeakFinderTests: XCTestCase {
    func testReturnsObservedProminentPeaksAndTroughsOnly() {
        let start = Date(timeIntervalSince1970: 0)
        let values = [0.0, 1, 3, 1, 0, -2, 0, 1]
        let samples = values.enumerated().map { StoredSample(timestamp: start.addingTimeInterval(Double($0.offset) * 10), sequence: UInt64($0.offset), value: $0.element) }
        let found = PeakFinder.extrema(samples: samples, visibleRange: start...start.addingTimeInterval(70), plotWidth: 700, valueRange: -3...4)
        XCTAssertEqual(found.map(\.sampleIndex), [2, 5])
        XCTAssertEqual(found.map(\.kind), [.peak, .trough])
    }

    func testHonorsCountAndReturnsNoInventedPoints() {
        let start = Date(timeIntervalSince1970: 0)
        let values = [0.0, 5, 0, 4, 0, 3, 0, 2, 0]
        let samples = values.enumerated().map { StoredSample(timestamp: start.addingTimeInterval(Double($0.offset)), sequence: UInt64($0.offset), value: $0.element) }
        let found = PeakFinder.extrema(samples: samples, visibleRange: start...start.addingTimeInterval(8), plotWidth: 800, valueRange: -1...6, maximumCount: 2)
        XCTAssertLessThanOrEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { samples.indices.contains($0.sampleIndex) })
    }
    func testSmoothCyclesAndGuideIndependentProminence() {
        let start = Date(timeIntervalSince1970: 0)
        for cycles in [1.0, 2.0] {
            let samples = (0...2000).map { i in
                StoredSample(timestamp: start.addingTimeInterval(Double(i) / 2), sequence: UInt64(i),
                             value: sin(Double(i) / 2000 * cycles * 2 * .pi))
            }
            let found = PeakFinder.extrema(samples: samples, visibleRange: start...start.addingTimeInterval(1000), plotWidth: 800, valueRange: -1000...1000)
            XCTAssertTrue(found.contains { $0.kind == .peak })
            XCTAssertTrue(found.contains { $0.kind == .trough })
        }
    }

    func testNoExtremaAcrossSegmentsOrOnMonotonicData() {
        let start = Date(timeIntervalSince1970: 0)
        let values = [0.0, 1, 2, 1, 0, -1]
        let samples = values.enumerated().map { i, value in
            StoredSample(timestamp: start.addingTimeInterval(Double(i)), sequence: UInt64(i), value: value, segmentID: i < 3 ? "a" : "b")
        }
        XCTAssertTrue(PeakFinder.extrema(samples: samples, visibleRange: start...start.addingTimeInterval(5), plotWidth: 800, valueRange: -1...2).isEmpty)
    }

    func testFlatPlateauProducesOneObservedPeak() {
        let start = Date(timeIntervalSince1970: 0)
        let samples = [0.0, 2, 2, 2, 0].enumerated().map { i, value in
            StoredSample(timestamp: start.addingTimeInterval(Double(i)), sequence: UInt64(i), value: value)
        }
        let found = PeakFinder.extrema(samples: samples, visibleRange: start...start.addingTimeInterval(4), plotWidth: 800, valueRange: 0...2)
        XCTAssertEqual(found.map(\.sampleIndex), [2])
    }

}
