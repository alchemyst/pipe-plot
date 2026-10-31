import XCTest
@testable import PipePlotCore

final class StreamLayoutTests: XCTestCase {
    func testHiddenLastStreamKeepsCaptureStylePersistenceAndReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("test.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let stream = try XCTUnwrap(ready.streams.first?.id)
        try store.updateStreamStyle(stream, colorHex: "#abcdef", dotsVisible: true, linesVisible: false)
        try store.setStreamLayoutHidden(true, streamID: stream)
        try store.append(SampleRow(timestamp: Date(), values: [42], sequence: 1), to: ready.attachmentID)
        func chart() throws -> ChartSnapshot { try XCTUnwrap(store.snapshot(sessionID: ready.sessionID)?.charts.first) }
        XCTAssertEqual(try chart().streams[0].isLayoutHidden, true)
        XCTAssertEqual(try chart().streams[0].sampleCount, 1)
        XCTAssertTrue(try chart().isVisible)
        XCTAssertTrue(try chart().isTarget)
        XCTAssertEqual(try PipePlotStore(databaseURL: database).snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].isLayoutHidden, true)
        XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
        XCTAssertEqual(try chart().streams[0].isLayoutHidden, false)
        XCTAssertEqual(try chart().streams[0].colorHex, "#abcdef")
        XCTAssertEqual(try chart().streams[0].dotsVisible, true)
        XCTAssertEqual(try chart().streams[0].linesVisible, false)
        XCTAssertEqual(try chart().streams[0].sampleCount, 1)
        XCTAssertTrue(try store.redo(sessionID: ready.sessionID))
        try store.setStreamLayoutHidden(false, streamID: stream)
        XCTAssertEqual(try chart().streams[0].isLayoutHidden, false)
        XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
        XCTAssertEqual(try chart().streams[0].isLayoutHidden, true)
        // Older IPC payloads have no presentation flag.
        let legacy = Data("{\"id\":\"\(stream.uuidString)\",\"name\":\"legacy\",\"state\":\"ended\",\"sampleCount\":0}".utf8)
        XCTAssertNil(try JSONDecoder().decode(StreamDescriptor.self, from: legacy).isLayoutHidden)
    }
}
