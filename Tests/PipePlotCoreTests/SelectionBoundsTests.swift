import Foundation
import XCTest
@testable import PipePlotCore

final class SelectionBoundsTests: XCTestCase {
    func testAllModesResolveWithLiveAndFrozenClocksWithoutAnalyticalClamping() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let live = Date(timeIntervalSince1970: 300)
        let frozen = Date(timeIntervalSince1970: 250)
        XCTAssertEqual(TimeSelection(start: start, end: end).resolvedBounds(at: live), start...end)
        XCTAssertEqual(
            TimeSelection(start: start, end: end, mode: .endFollowsNow).resolvedBounds(at: live), start...live)
        XCTAssertEqual(
            TimeSelection(start: start, end: end, mode: .endFollowsNow).resolvedBounds(at: frozen), start...frozen)
        XCTAssertEqual(
            TimeSelection(start: start, end: end, mode: .bothFollowNow(duration: 60)).resolvedBounds(at: live),
            live.addingTimeInterval(-60)...live)
        XCTAssertEqual(
            TimeSelection(start: start, end: end, mode: .bothFollowNow(duration: 60)).resolvedBounds(at: frozen),
            frozen.addingTimeInterval(-60)...frozen)
        XCTAssertEqual(
            TimeSelection(start: start, end: end, mode: .startFollowsEnd(duration: 30)).resolvedBounds(at: live),
            end.addingTimeInterval(-30)...end)
        XCTAssertEqual(TimeSelection(start: end, end: start).resolvedBounds(at: live), start...end)

        let full = TimeSelection(start: start, end: end, mode: .endFollowsNow).resolvedBounds(at: live)
        let viewport = Date(timeIntervalSince1970: 150)...Date(timeIntervalSince1970: 220)
        XCTAssertEqual(TimeSelection.clippedForDisplay(full, to: viewport), viewport)
        XCTAssertNil(
            TimeSelection.clippedForDisplay(full, to: Date(timeIntervalSince1970: 301)...live.addingTimeInterval(60)))
        XCTAssertEqual(full, start...live)
    }
}
