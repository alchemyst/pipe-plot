import XCTest
@testable import PipePlotCore

final class ForecastTargetTests: XCTestCase {
    func testLegacySingleForecastSetterRestoresPluralListOnUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("test.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let firstGuide = Guide(orientation: .horizontalValue, value: 10)
        let secondGuide = Guide(orientation: .horizontalValue, value: 20)
        try store.upsertGuide(firstGuide, chartID: ready.chartID)
        try store.upsertGuide(secondGuide, chartID: ready.chartID)
        let selection = TimeSelection(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20))
        let first = ForecastConfiguration(streamID: ready.streams[0].id, guideID: firstGuide.id, selection: selection)
        let second = ForecastConfiguration(streamID: ready.streams[0].id, guideID: secondGuide.id, selection: selection)
        try store.setForecasts([first, second], sessionID: ready.sessionID)
        XCTAssertEqual(try store.snapshot(sessionID: ready.sessionID)?.timeline.forecasts, [first, second])
        try store.setForecast(second, sessionID: ready.sessionID)
        XCTAssertEqual(try store.snapshot(sessionID: ready.sessionID)?.timeline.forecasts, [second])
        XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
        XCTAssertEqual(try store.snapshot(sessionID: ready.sessionID)?.timeline.forecasts, [first, second])
        XCTAssertEqual(
            try PipePlotStore(databaseURL: database).snapshot(sessionID: ready.sessionID)?.timeline.forecasts,
            [first, second])
        XCTAssertTrue(try store.redo(sessionID: ready.sessionID))
        XCTAssertEqual(try store.snapshot(sessionID: ready.sessionID)?.timeline.forecast, second)
    }

    func testAtomicTargetValidationUndoAndCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("test.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let stream = try XCTUnwrap(ready.streams.first?.id)
        let selection = TimeSelection(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20))
        let before = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        XCTAssertThrowsError(try store.createForecastTarget(value: .infinity, streamID: stream, selection: selection))
        XCTAssertEqual(try store.snapshot(sessionID: ready.sessionID), before)
        let guide = try store.createForecastTarget(
            value: 10 * pow(1024, 3), label: "target", streamID: stream, selection: selection)
        let added = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        XCTAssertEqual(added.charts.first?.guides, [guide])
        XCTAssertEqual(added.timeline.forecasts.first?.selection, selection)
        XCTAssertEqual(added.timeline.forecasts.first?.streamID, stream)
        XCTAssertEqual(added.timeline.forecasts.first?.guideID, guide.id)
        XCTAssertEqual(
            try PipePlotStore(databaseURL: database).snapshot(sessionID: ready.sessionID)?.charts.first?.guides, [guide]
        )
        try store.append(SampleRow(timestamp: selection.end, values: [3], sequence: 1), to: ready.attachmentID)
        XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
        let undone = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        XCTAssertTrue(undone.charts[0].guides.isEmpty)
        XCTAssertEqual(undone.timeline.forecasts, [])
        XCTAssertEqual(undone.charts[0].streams[0].sampleCount, 1)
        XCTAssertTrue(try store.redo(sessionID: ready.sessionID))
        let redone = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        XCTAssertEqual(redone.charts[0].guides, [guide])
        XCTAssertEqual(redone.timeline.forecasts, added.timeline.forecasts)
        XCTAssertEqual(redone.charts[0].streams[0].sampleCount, 1)
    }
}
