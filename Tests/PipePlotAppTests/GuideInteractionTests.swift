import XCTest
@testable import PipePlotApp
import PipePlotCore

@MainActor
final class GuideInteractionTests: XCTestCase {
    func testTimeGuideEditsInvalidateCommandsAndUndoRedo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let session = try model.store.createSession()
        model.becameActive(session.id)
        let revision = model.editRevision
        model.addTimeGuide(at: Date(timeIntervalSince1970: 100), sessionID: session.id)
        XCTAssertGreaterThan(model.editRevision, revision)
        XCTAssertNotNil(model.store.undoActionName(sessionID: session.id))
        let guide = try XCTUnwrap(model.sessions[session.id]?.timeGuides.first)
        model.undo(session.id)
        XCTAssertTrue(try XCTUnwrap(model.sessions[session.id]).timeGuides.isEmpty)
        model.redo(session.id)
        XCTAssertEqual(model.sessions[session.id]?.timeGuides.first, guide)
        model.removeTimeGuide(guide, sessionID: session.id)
        XCTAssertTrue(try XCTUnwrap(model.sessions[session.id]).timeGuides.isEmpty)
        model.undo(session.id)
        XCTAssertEqual(model.sessions[session.id]?.timeGuides.first, guide)
    }

    func testEventOnlyHistoryAndDisplayPreferencesPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("test.sqlite")
        let model = PipePlotAppModel(databaseURL: database)
        let ready = try model.store.registerEventConnection(intent: .target)
        let start = Date().addingTimeInterval(-3600)
        try model.store.appendEvent("restart", at: start, to: ready.attachmentID)
        try model.store.finishEventConnection(ready.attachmentID, reason: .eof)
        model.refreshAll()
        var session = try XCTUnwrap(model.sessions[ready.sessionID])
        model.showAllHistory(session)
        session = try XCTUnwrap(model.sessions[ready.sessionID])
        let visibleStart = try XCTUnwrap(session.timeline.visibleStart)
        XCTAssertEqual(visibleStart.timeIntervalSince(start), 0, accuracy: 0.000_001)
        model.setTimeZone(.utc, session: session)
        session = try XCTUnwrap(model.sessions[ready.sessionID])
        let guide = try XCTUnwrap(session.timeGuides.first)
        model.setTimeReference(guide.id, session: session)
        let reopened = try PipePlotStore(databaseURL: database)
        let saved = try XCTUnwrap(reopened.snapshot(sessionID: ready.sessionID))
        XCTAssertEqual(saved.timeline.timeZone, .utc)
        XCTAssertEqual(saved.timeline.referenceTimeGuideID, guide.id)
        XCTAssertNotNil(saved.timeline.clockStoppedAt)
    }
}
