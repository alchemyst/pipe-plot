import XCTest
@testable import PipePlotCore

final class NumericTextTests: XCTestCase {
    func testBinaryPrefixParsingIsExact() {
        XCTAssertEqual(NumericText.parse("10 Gi"), 10 * 1_073_741_824)
        XCTAssertEqual(NumericText.parse("10GiB"), 10 * 1_073_741_824)
        XCTAssertEqual(NumericText.parse("1.5 MiB"), 1.5 * 1_048_576)
        XCTAssertEqual(NumericText.parse("2kB"), 2_000)
        XCTAssertEqual(NumericText.parse("1e3"), 1_000)
        XCTAssertEqual(NumericText.parse("10 B"), 10)
        XCTAssertEqual(NumericText.parse("10 m", unit: "m"), 10)
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
        XCTAssertEqual(TimeText.format(origin, zone: .utc), "00:00:00 UTC")
        XCTAssertEqual(TimeText.format(origin, zone: .utc, includeDate: true), "1970-01-01 00:00:00 UTC")
        XCTAssertEqual(TimeText.format(origin.addingTimeInterval(65), zone: .local, reference: origin), "+1:05")
        XCTAssertEqual(TimeText.format(origin.addingTimeInterval(-5), zone: .utc, reference: origin), "−5s")
        XCTAssertEqual(TimeText.format(origin.addingTimeInterval(3661), zone: .utc, reference: origin), "+1:01:01")
        XCTAssertEqual(TimeText.format(origin.addingTimeInterval(0.6), zone: .utc, reference: origin), "+1s")
    }

    func testLocalAbsoluteFormattingUsesCurrentZoneWithSecondPrecision() throws {
        let date = Date(timeIntervalSince1970: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = try XCTUnwrap(parts.year), month = try XCTUnwrap(parts.month), day = try XCTUnwrap(parts.day)
        let hour = try XCTUnwrap(parts.hour), minute = try XCTUnwrap(parts.minute), second = try XCTUnwrap(parts.second)
        let clock = String(format: "%02d:%02d:%02d", hour, minute, second)
        let dated = String(format: "%04d-%02d-%02d %@", year, month, day, clock)
        XCTAssertEqual(TimeText.format(date, zone: .local), clock)
        XCTAssertEqual(TimeText.format(date, zone: .local, includeDate: true), dated)
        XCTAssertFalse(TimeText.format(date, zone: .local).hasSuffix(" UTC"))
    }
}
