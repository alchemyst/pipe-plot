import Foundation
import XCTest
@testable import PipePlotCore

final class DomainCompatibilityTests: XCTestCase {
    func testLegacyAxisSettingsDecodeConcreteDefaultsAndKeepReferenceOptional() throws {
        let decoder = JSONDecoder()
        let settings = try decoder.decode(AxisSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, AxisSettings())
        XCTAssertEqual(settings.yScale, .automatic)
        XCTAssertFalse(settings.dotsVisible)
        XCTAssertTrue(settings.linesVisible)
        XCTAssertEqual(settings.numericScale, .decimal)
        XCTAssertFalse(settings.includeZero)
        XCTAssertTrue(settings.showExtrema)
        XCTAssertNil(settings.referenceGuideID)

        let explicit = try decoder.decode(
            AxisSettings.self,
            from: Data("{\"numericScale\":\"binary\",\"includeZero\":true,\"showExtrema\":false}".utf8))
        XCTAssertEqual(explicit.numericScale, .binary)
        XCTAssertTrue(explicit.includeZero)
        XCTAssertFalse(explicit.showExtrema)
        XCTAssertEqual(try decoder.decode(AxisSettings.self, from: JSONEncoder().encode(settings)), settings)

        let stream = try decoder.decode(
            StreamDescriptor.self,
            from: Data("{\"id\":\"\(UUID())\",\"name\":\"legacy\",\"state\":\"ended\",\"sampleCount\":0}".utf8))
        XCTAssertNil(stream.colorHex)
        XCTAssertNil(stream.dotsVisible)
        XCTAssertNil(stream.linesVisible)
    }

    func testForecastDecodingPrecedenceAndRoundTrip() throws {
        let first = ForecastConfiguration(
            streamID: UUID(), guideID: UUID(),
            selection: TimeSelection(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20)))
        let second = ForecastConfiguration(
            streamID: UUID(), guideID: UUID(),
            selection: TimeSelection(start: Date(timeIntervalSince1970: 30), end: Date(timeIntervalSince1970: 40)))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let firstJSON = try JSONSerialization.jsonObject(with: encoder.encode(first))
        let secondJSON = try JSONSerialization.jsonObject(with: encoder.encode(second))
        func decode(_ object: [String: Any]) throws -> TimelineState {
            try decoder.decode(TimelineState.self, from: JSONSerialization.data(withJSONObject: object))
        }

        let singular = try decode(["forecast": firstJSON])
        XCTAssertEqual(singular.forecasts, [first])
        XCTAssertEqual(singular.forecast, first)
        XCTAssertEqual(singular.timeZone, .local)
        XCTAssertTrue(singular.followNow)
        XCTAssertEqual(try decoder.decode(TimelineState.self, from: encoder.encode(singular)).forecasts, [first])

        let plural = try decode(["forecast": firstJSON, "forecasts": [secondJSON, firstJSON]])
        XCTAssertEqual(plural.forecasts, [second, first])
        XCTAssertEqual(plural.forecast, second)
        XCTAssertEqual(try decoder.decode(TimelineState.self, from: encoder.encode(plural)), plural)
        XCTAssertEqual(try decode(["forecast": firstJSON, "forecasts": []]).forecasts, [])
        XCTAssertEqual(try decode(["forecast": firstJSON, "forecasts": NSNull()]).forecasts, [first])
        XCTAssertEqual(try decode([:]).forecasts, [])

        var legacySetter = plural
        legacySetter.forecast = first
        XCTAssertEqual(legacySetter.forecasts, [first])
        legacySetter.forecast = nil
        XCTAssertTrue(legacySetter.forecasts.isEmpty)
    }
}
