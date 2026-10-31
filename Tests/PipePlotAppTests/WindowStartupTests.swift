import XCTest
@testable import PipePlotApp
import PipePlotCore

@MainActor
final class WindowStartupTests: XCTestCase {
    func testBackgroundRegistrationKeepsDataAndDeduplicatesDeferredWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        model.refreshAll()
        model.requestSessionWindow(ready.sessionID)
        model.requestSessionWindow(ready.sessionID)
        try model.store.append(SampleRow(values: [3]), to: ready.attachmentID)
        try model.store.finishAttachment(ready.attachmentID, reason: .eof)
        var windows: [SessionID] = []
        model.installOpenWindow { windows.append($0) }
        XCTAssertEqual(windows, [ready.sessionID])
        model.requestSessionWindow(ready.sessionID)
        model.installOpenWindow { windows.append($0) }
        XCTAssertEqual(windows, [ready.sessionID])
        XCTAssertTrue(model.openedSessionIDs.contains(ready.sessionID))
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].sampleCount, 1)
        model.windowClosed(ready.sessionID)
        model.requestSessionWindow(ready.sessionID)
        XCTAssertEqual(windows, [ready.sessionID, ready.sessionID])
    }
}
