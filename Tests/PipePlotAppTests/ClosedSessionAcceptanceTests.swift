import Foundation
import XCTest
import PipePlotCore
@testable import PipePlotApp

@MainActor final class ClosedSessionAcceptanceTests: XCTestCase {
    func testRestartSkipsClosedForecastUntilExplicitReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("closed.sqlite")
        let model = PipePlotAppModel(databaseURL: database)
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date(timeIntervalSince1970: 1000)
        for i in 0..<10 { try model.store.append(SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID) }
        let guide = Guide(orientation: .horizontalValue, value: 100)
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        let configuration = ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id, selection: TimeSelection(start: start, end: start.addingTimeInterval(9)))
        try model.store.setForecasts([configuration], sessionID: ready.sessionID)
        model.windowClosed(ready.sessionID)
        let restarted = PipePlotAppModel(databaseURL: database)
        XCTAssertFalse(try XCTUnwrap(restarted.store.snapshot(sessionID: ready.sessionID)).isOpen)
        XCTAssertEqual(restarted.queries.submittedQueryCount, 0, "Closed saved sessions must not compete with first-chart queries on startup")
        XCTAssertNil(restarted.forecastStatuses[ready.sessionID])
        restarted.openSession(ready.sessionID)
        for _ in 0..<100 {
            if restarted.forecastStatuses[ready.sessionID]?.fit != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(restarted.forecastStatuses[ready.sessionID]?.fit)
        XCTAssertEqual(restarted.sessions[ready.sessionID]?.timeline.forecasts, [configuration])
        XCTAssertEqual(try restarted.store.samples.count(streamID: ready.streams[0].id), 10)
    }
}
