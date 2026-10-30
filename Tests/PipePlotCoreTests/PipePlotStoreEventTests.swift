import XCTest
@testable import PipePlotCore

final class PipePlotStoreEventTests: XCTestCase {
    private func makeStore() throws -> (PipePlotStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try PipePlotStore(databaseURL: directory.appendingPathComponent("state.sqlite")), directory)
    }

    func testEventConnectionAddsOnlyTimestampedGuidesAndFinalAttachmentFreezesClock() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ready = try store.registerEventConnection(intent: .newSession)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000.25)
        try store.appendEvent("pump started", at: timestamp, to: ready.attachmentID)

        var session = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        XCTAssertTrue(session.charts.flatMap(\.streams).isEmpty)
        XCTAssertNil(session.timeline.clockStoppedAt)
        XCTAssertEqual(session.timeGuides.count, 1)
        XCTAssertEqual(session.timeGuides[0].value, timestamp.timeIntervalSince1970)
        XCTAssertEqual(session.timeGuides[0].label, "pump started")

        try store.finishAttachment(ready.attachmentID, reason: .eof)
        session = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        XCTAssertNotNil(session.timeline.clockStoppedAt)
        XCTAssertEqual(session.timeGuides.count, 1)
    }

    func testExplicitSessionWithHiddenChartsDoesNotChangeGlobalTargetOrCreateChart() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try store.createSession()
        let extra = try store.createChart(in: session.id)
        try store.deleteChart(extra.id)
        try store.deleteChart(session.charts[0].id)
        XCTAssertNil(store.currentTarget())
        let countBefore = try XCTUnwrap(store.snapshot(sessionID: session.id)).charts.count

        let ready = try store.registerEventConnection(intent: .session(sessionID: session.id, lineNames: []))
        XCTAssertEqual(ready.sessionID, session.id)
        XCTAssertNil(store.currentTarget())
        XCTAssertEqual(try XCTUnwrap(store.snapshot(sessionID: session.id)).charts.count, countBefore)
    }

    func testFailedRegistrationRollsBackInMemoryAndMetadataState() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataDirectory = directory.appendingPathComponent("state.sqlite.metadata.json", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.registerEventConnection(intent: .newSession))
        XCTAssertTrue(try store.listSessions().isEmpty)
        XCTAssertNil(store.currentTarget())
        try FileManager.default.removeItem(at: metadataDirectory)

        let ready = try store.registerEventConnection(intent: .newSession)
        XCTAssertEqual(try store.listSessions().map(\.id), [ready.sessionID])
    }

    func testRejectsInvalidEventsEvenWhenCalledOutsideTheCLIParser() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try store.registerEventConnection(intent: .newSession)
        XCTAssertThrowsError(try store.appendEvent("bad\0event", to: ready.attachmentID))
        XCTAssertThrowsError(try store.appendEvent(String(repeating: "x", count: EventInputParser.maximumLineBytes + 1), to: ready.attachmentID))
        XCTAssertThrowsError(try store.appendEvent("   ", to: ready.attachmentID))

        let numeric = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        XCTAssertThrowsError(try store.appendEvent("wrong attachment", to: numeric.attachmentID))
    }
}
