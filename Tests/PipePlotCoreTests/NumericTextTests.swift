import XCTest
@testable import PipePlotCore

final class NumericTextTests: XCTestCase {
    func testBinaryPrefixParsingIsExact() {
        XCTAssertEqual(NumericText.parse("10 Gi"), 10 * 1_073_741_824)
        XCTAssertEqual(NumericText.parse("10GiB"), 10 * 1_073_741_824)
        XCTAssertEqual(NumericText.parse("1.5 MiB"), 1.5 * 1_048_576)
        XCTAssertEqual(NumericText.parse("2kB"), 2_000)
        XCTAssertEqual(NumericText.parse("1e3"), 1_000)
    }

    func testPrefixParsingRejectsMalformedAndNonFiniteInput() {
        XCTAssertNil(NumericText.parse(""))
        XCTAssertNil(NumericText.parse("10 Gi!"))
        XCTAssertNil(NumericText.parse("10 meters"))
        XCTAssertNil(NumericText.parse("NaN"))
        XCTAssertNil(NumericText.parse("1e999"))
    }

    func testFormatsDecimalAndBinaryPrefixes() {
        XCTAssertEqual(NumericText.format(1_500, scale: .decimal), "1.5 k")
        XCTAssertEqual(NumericText.format(0, scale: .decimal), "0")
        XCTAssertEqual(NumericText.format(1_572_864, scale: .binary, unit: "B"), "1.5 MiB")
        XCTAssertEqual(NumericText.ticks(in: 0...1_073_741_824, scale: .binary, targetCount: 4).count, 5)
    }
}

final class TimeTextTests: XCTestCase {
    func testUTCAbsoluteAndRelativeTimeFormatting() {
        let origin = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(TimeText.format(origin, zone: .utc).hasSuffix("UTC"))
        XCTAssertEqual(TimeText.format(origin.addingTimeInterval(65), zone: .local, reference: origin), "+1:05")
        XCTAssertEqual(TimeText.format(origin.addingTimeInterval(-5), zone: .utc, reference: origin), "−5s")
    }
}
