import XCTest
@testable import PipePlotApp

final class LatestLabelLayoutTests: XCTestCase {
    func testMeasuredWidthAndBoundaries() {
        let plot = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertNotNil(LatestLabelLayout.place(point: CGPoint(x: 65, y: 0), size: CGSize(width: 29, height: 10), plot: plot, occupied: []))
        XCTAssertNil(LatestLabelLayout.place(point: CGPoint(x: 65, y: 25), size: CGSize(width: 30, height: 10), plot: plot, occupied: []))
        let top = LatestLabelLayout.place(point: CGPoint(x: 10, y: 0), size: CGSize(width: 20, height: 10), plot: plot, occupied: [])!
        let bottom = LatestLabelLayout.place(point: CGPoint(x: 10, y: 50), size: CGSize(width: 20, height: 10), plot: plot, occupied: [])!
        XCTAssertEqual(top.minY, 0)
        XCTAssertEqual(bottom.maxY, 50)
    }

    func testOverlappingLabelsMoveOrAreOmitted() {
        let plot = CGRect(x: 0, y: 0, width: 100, height: 34)
        let point = CGPoint(x: 10, y: 17)
        let size = CGSize(width: 30, height: 10)
        let first = LatestLabelLayout.place(point: point, size: size, plot: plot, occupied: [])!
        let second = LatestLabelLayout.place(point: point, size: size, plot: plot, occupied: [first])!
        XCTAssertFalse(first.intersects(second))
        let third = LatestLabelLayout.place(point: point, size: size, plot: plot, occupied: [first, second])!
        XCTAssertNil(LatestLabelLayout.place(point: point, size: size, plot: plot, occupied: [first, second, third]))
    }
}
