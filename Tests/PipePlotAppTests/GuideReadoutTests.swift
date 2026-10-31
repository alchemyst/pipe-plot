import XCTest
import PipePlotCore
@testable import PipePlotApp

final class GuideReadoutTests: XCTestCase {
    func testDragReadoutsIncludeUnnamedValuesAndNamedCoordinates() {
        var settings = AxisSettings(unit: "B")
        settings.numericScale = .binary
        let guide = Guide(orientation: .horizontalValue, value: 10 * 1_073_741_824)
        XCTAssertEqual(GuideReadout.horizontal(guide, settings: settings, dragging: true), "10 GiB")
        let time = Guide(orientation: .verticalTime, value: 100, label: "deploy")
        let timeline = TimelineState(timeZone: .utc)
        XCTAssertEqual(GuideReadout.vertical(time, timeline: timeline, reference: nil, dragging: true, includeDate: false), "deploy  00:01:40 UTC")
        XCTAssertEqual(GuideReadout.vertical(time, timeline: timeline, reference: Date(timeIntervalSince1970: 90), dragging: true, includeDate: false), "deploy  +10s")
        XCTAssertEqual(GuideReadout.vertical(time, timeline: timeline, reference: nil, dragging: false, includeDate: false), "deploy")
    }
}
