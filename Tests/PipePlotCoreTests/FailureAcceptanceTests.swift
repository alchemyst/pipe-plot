import Foundation
import XCTest
import CSQLite
@testable import PipePlotCore

final class FailureAcceptanceTests: XCTestCase {
    func testSQLiteFullRetainsAcknowledgedRowsAndRejectsWholeRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("full.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 2))
        for i in 0..<10 { try store.append(SampleRow(values: [Double(i), Double(i)]), to: ready.attachmentID) }
        // Cap only this isolated SQLite database's page budget, never fill the host disk.
        guard
            sqlite3_exec(store.samples.db, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA max_page_count=32", nil, nil, nil)
                == SQLITE_OK
        else { return XCTFail("Could not set isolated database page limit") }
        var accepted = 10, failure: Error?
        for i in 10..<10000 {
            do {
                try store.append(SampleRow(values: [Double(i), Double(i)]), to: ready.attachmentID)
                accepted += 1
            } catch {
                failure = error
                break
            }
        }
        let error = try XCTUnwrap(failure)
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("full"), error.localizedDescription)
        let snapshot = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        for stream in snapshot.charts[0].streams {
            XCTAssertEqual(stream.sampleCount, Int64(accepted))
            XCTAssertEqual(try store.samples.count(streamID: stream.id), Int64(accepted))
        }
        XCTAssertEqual(
            try store.samples.query(streamID: ready.streams[0].id).map(\.value),
            try store.samples.query(streamID: ready.streams[1].id).map(\.value))
        let reopened = try PipePlotStore(databaseURL: database)
        XCTAssertEqual(
            try reopened.snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].sampleCount, Int64(accepted))
        print(
            "FAILURE_ACCEPTANCE SQLITE_FULL acknowledgedRows=\(accepted) retainedPerStream=\(accepted) error=\(error.localizedDescription)"
        )
    }

    func testInterruptedEmptyTrashRetriesSampleRemovalOnRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("trash.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        let trashed = try store.registerSampler(intent: .newSession, sampler: SamplerIntent(columnCount: 1))
        let kept = try store.registerSampler(intent: .newSession, sampler: SamplerIntent(columnCount: 1))
        try store.append(SampleRow(values: [1]), to: trashed.attachmentID)
        try store.append(SampleRow(values: [2]), to: kept.attachmentID)
        try store.deleteSession(sessionID: trashed.sessionID)

        let rejectDelete =
            "CREATE TRIGGER reject_delete BEFORE DELETE ON samples BEGIN SELECT RAISE(ABORT, 'test'); END"
        XCTAssertEqual(sqlite3_exec(store.samples.db, rejectDelete, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.emptyTrash(sessionIDs: [trashed.sessionID, kept.sessionID]))
        XCTAssertNil(try store.snapshot(sessionID: trashed.sessionID))
        XCTAssertThrowsError(try store.restoreSession(sessionID: trashed.sessionID))
        XCTAssertTrue(store.hasPendingTrashCleanup)
        XCTAssertEqual(try store.samples.query(streamID: trashed.streams[0].id).map(\.value), [1])

        XCTAssertEqual(sqlite3_exec(store.samples.db, "DROP TRIGGER reject_delete", nil, nil, nil), SQLITE_OK)
        let reopened = try PipePlotStore(databaseURL: database)
        XCTAssertFalse(reopened.hasPendingTrashCleanup)
        XCTAssertNil(try reopened.snapshot(sessionID: trashed.sessionID))
        XCTAssertTrue(try reopened.samples.query(streamID: trashed.streams[0].id).isEmpty)
        XCTAssertEqual(try reopened.samples.count(streamID: trashed.streams[0].id), 0)
        XCTAssertEqual(try reopened.listSessions().map(\.id), [kept.sessionID])
        XCTAssertEqual(try reopened.samples.query(streamID: kept.streams[0].id).map(\.value), [2])
    }

    func testMetadataWriteFailurePreservesAcknowledgedDataAndRecoversRawCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        try store.append(SampleRow(values: [1]), to: ready.attachmentID)
        let metadata = database.appendingPathExtension("metadata.json"),
            backup = directory.appendingPathComponent("acknowledged.json")
        try FileManager.default.moveItem(at: metadata, to: backup)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.append(SampleRow(values: [2]), to: ready.attachmentID))
        XCTAssertEqual(try store.snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].sampleCount, 2)
        // The second raw row committed before metadata failed; it was not
        // acknowledged. Reopening reconciles counts without discarding either row.
        XCTAssertEqual(try store.samples.count(streamID: ready.streams[0].id), 2)
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.moveItem(at: backup, to: metadata)
        let reopened = try PipePlotStore(databaseURL: database)
        XCTAssertEqual(try reopened.snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].sampleCount, 2)
        XCTAssertEqual(try reopened.samples.query(streamID: ready.streams[0].id).map(\.value), [1, 2])
        print("FAILURE_ACCEPTANCE METADATA_WRITE acknowledged=1 retainedRaw=2 recovered=2")
    }
}
