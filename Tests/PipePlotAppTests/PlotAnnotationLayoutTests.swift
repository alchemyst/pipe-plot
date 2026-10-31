import XCTest
@testable import PipePlotApp

final class PlotAnnotationLayoutTests: XCTestCase {
    func testAutomaticRangePadsBothEndsAndRemainsFinite() {
        for values: [Double] in [[10, 20, 100], [-100, -20, -10], [0, 10], [-10, 0], [5], [0], [-5, 5], [1e308], [-1e308, 1e308]] {
            let range = PlotValueRange.automatic(values)
            XCTAssertTrue(range.lowerBound.isFinite && range.upperBound.isFinite)
            XCTAssertLessThan(range.lowerBound, values.min()!)
            XCTAssertGreaterThan(range.upperBound, values.max()!)
        }
        XCTAssertEqual(PlotValueRange.automatic([]), 0...1)
        let largest = Double.greatestFiniteMagnitude
        XCTAssertEqual(PlotValueRange.automatic([-largest, largest]), -largest...largest)
    }
    func testBadgesStayInsideAllEdgesIncludingOversizedText() {
        let plot = CGRect(x: 56, y: 4, width: 400, height: 200)
        for point in [CGPoint(x: 0, y: -10), CGPoint(x: 500, y: 210)] {
            for size in [CGSize(width: 70, height: 12), CGSize(width: 800, height: 300)] {
                let badge = PlotAnnotationLayout.badge(size: size, preferredOrigin: point, plot: plot)
                XCTAssertGreaterThanOrEqual(badge.minX, plot.minX)
                XCTAssertGreaterThanOrEqual(badge.minY, plot.minY)
                XCTAssertLessThanOrEqual(badge.maxX, plot.maxX)
                XCTAssertLessThanOrEqual(badge.maxY, plot.maxY)
            }
        }
    }
}
