import XCTest
@testable import PipePlotCore

final class StreamInsertionTests: XCTestCase {
    func testInsertBeforeSourceAndUndoAsSingleActionWithLaterCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PipePlotStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let id = try XCTUnwrap(ready.streams.first?.id)
        var settings = AxisSettings(); settings.unit = "K"
        try store.updateSettings(settings, chartID: ready.chartID)
        let guide = Guide(orientation: .horizontalValue, value: 20)
        try store.upsertGuide(guide, chartID: ready.chartID)
        try store.updateStreamStyle(id, colorHex: "#abcdef", dotsVisible: true, linesVisible: false)
        let destination = try store.moveStreamToNewChart(id, before: ready.chartID)
        try store.append(SampleRow(timestamp: Date(), values: [4], sequence: 1), to: ready.attachmentID)
        func session() throws -> SessionSnapshot { try XCTUnwrap(store.snapshot(sessionID: ready.sessionID)) }
        XCTAssertEqual(try session().charts.map(\.id), [destination.id, ready.chartID])
        XCTAssertTrue(try session().charts[0].isVisible)
        XCTAssertFalse(try session().charts[1].isVisible)
        XCTAssertEqual(try session().charts[1].guides, [guide])
        XCTAssertEqual(try session().charts[1].settings.unit, "K")
        XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
        XCTAssertEqual(try session().charts.map(\.id), [ready.chartID])
        XCTAssertEqual(try session().charts[0].streams[0].sampleCount, 1)
        XCTAssertEqual(try session().charts[0].streams[0].colorHex, "#abcdef")
        XCTAssertTrue(try store.redo(sessionID: ready.sessionID))
        XCTAssertEqual(try session().charts[0].id, destination.id)
        XCTAssertEqual(try session().charts[0].streams[0].id, id)
        XCTAssertEqual(try session().charts[0].streams[0].sampleCount, 1)
        XCTAssertEqual(try session().charts[0].streams[0].dotsVisible, true)
        XCTAssertEqual(try session().charts[0].streams[0].linesVisible, false)
    }
}
