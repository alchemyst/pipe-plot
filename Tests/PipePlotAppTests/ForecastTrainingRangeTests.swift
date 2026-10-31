import XCTest
import PipePlotCore
@testable import PipePlotApp

@MainActor
final class ForecastTrainingRangeTests: XCTestCase {
    func testSavedTrainingRangesSurviveSelectionChangesAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let guide = Guide(orientation: .horizontalValue, value: 100)
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        let selection = TimeSelection(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20))
        let fixed = ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id, selection: selection)
        var moving = selection; moving.mode = .bothFollowNow(duration: 5)
        let linked = ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id, selection: moving)
        try model.store.setForecasts([fixed, linked], sessionID: ready.sessionID)
        model.refreshAll()
        func ranges() throws -> [ForecastTrainingRange] {
            let session = try XCTUnwrap(model.sessions[ready.sessionID])
            return model.forecastTrainingRanges(for: session.charts[0], session: session)
        }
        for active in [selection, moving, nil] {
            try model.store.setSelection(active, sessionID: ready.sessionID)
            model.refreshAll()
            let result = try ranges()
            XCTAssertEqual(result.map(\.id), [fixed.id, linked.id])
            XCTAssertEqual(result[0].range, selection.start...selection.end)
            XCTAssertFalse(result[0].linked)
            XCTAssertTrue(result[1].linked)
            XCTAssertEqual(result[1].range.upperBound.timeIntervalSince(result[1].range.lowerBound), 5)
        }
        model.undo(ready.sessionID)
        XCTAssertEqual(try ranges()[0].range, selection.start...selection.end)
    }
}
