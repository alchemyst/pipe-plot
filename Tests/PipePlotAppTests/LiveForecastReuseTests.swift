import XCTest
import PipePlotCore
@testable import PipePlotApp

@MainActor
final class LiveForecastReuseTests: XCTestCase {
    func testSilentConnectedClockAndRollingBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date(timeIntervalSince1970: 1000)
        for (time, value) in [(0.0, 0.0), (10, 10), (20, 40)] {
            _ = try model.store.append(SampleRow(timestamp: start.addingTimeInterval(time), values: [value]), to: ready.attachmentID)
        }
        let guide = Guide(orientation: .horizontalValue, value: 100)
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        model.tick(ready.sessionID, now: start.addingTimeInterval(20))
        let selection = TimeSelection(start: start, end: start.addingTimeInterval(20), mode: .bothFollowNow(duration: 25))
        model.setForecast(ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id, selection: selection),
                          session: try XCTUnwrap(model.sessions[ready.sessionID]))
        func waitForFit() async throws -> ForecastStatus {
            for _ in 0..<100 {
                if let status = model.allForecastStatuses[ready.sessionID]?.first, status.fit != nil { return status }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw XCTUnwrapError()
        }
        let first = try await waitForFit()
        XCTAssertEqual(first.fit?.count, 3)
        let queries = model.queries.submittedQueryCount, fits = model.queries.rawFitCount
        for i in 1...40 {
            model.tick(ready.sessionID, now: start.addingTimeInterval(20 + Double(i) / 10))
            XCTAssertEqual(model.allForecastStatuses[ready.sessionID]?.first?.fit, first.fit)
        }
        let silent = try XCTUnwrap(model.allForecastStatuses[ready.sessionID]?.first)
        XCTAssertEqual(model.queries.submittedQueryCount, queries)
        XCTAssertEqual(model.queries.rawFitCount, fits)
        XCTAssertEqual(silent.crossing, first.crossing)
        XCTAssertNotEqual(silent.message, first.message)
        XCTAssertEqual(silent.fitRange?.upperBound, start.addingTimeInterval(24))
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].streams[0].state, .live)
        model.tick(ready.sessionID, now: start.addingTimeInterval(25))
        XCTAssertEqual(model.queries.rawFitCount, fits) // inclusive left endpoint
        model.tick(ready.sessionID, now: start.addingTimeInterval(25.001))
        let rolled = try await waitForFit()
        XCTAssertEqual(rolled.fit?.count, 2)
        XCTAssertEqual(try XCTUnwrap(rolled.fit).slope, 3, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(rolled.crossing).timeIntervalSince(start), 40, accuracy: 1e-6)
        XCTAssertEqual(model.queries.rawFitCount, fits + 1)
        XCTAssertEqual(model.queries.submittedQueryCount, queries + 1)
        print("FORECAST_REUSE silentTicks=40 queries=0 rawFits=0 boundaryQueries=1 boundaryFits=1 crossing=40s")

        _ = try model.store.append(SampleRow(timestamp: start.addingTimeInterval(26), values: [80]), to: ready.attachmentID)
        model.tick(ready.sessionID, now: start.addingTimeInterval(26))
        let arrival = try await waitForFit()
        XCTAssertEqual(arrival.fit?.count, 3)
        XCTAssertEqual(model.queries.rawFitCount, fits + 2)
        XCTAssertNotEqual(arrival.crossing, rolled.crossing)

        var changed = arrival.configuration
        changed.selection.mode = .bothFollowNow(duration: 12)
        model.setForecast(changed, session: try XCTUnwrap(model.sessions[ready.sessionID]))
        let settings = try await waitForFit()
        XCTAssertEqual(settings.fit?.count, 2)
        XCTAssertEqual(model.queries.rawFitCount, fits + 3)
    }
}

private struct XCTUnwrapError: Error {}
