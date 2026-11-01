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
        guard sqlite3_exec(store.samples.db, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA max_page_count=32", nil, nil, nil) == SQLITE_OK else { return XCTFail("Could not set isolated database page limit") }
        var accepted = 10, failure: Error?
        for i in 10..<10000 {
            do { try store.append(SampleRow(values: [Double(i), Double(i)]), to: ready.attachmentID); accepted += 1 }
            catch { failure = error; break }
        }
        let error = try XCTUnwrap(failure)
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("full"), error.localizedDescription)
        let snapshot = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
        for stream in snapshot.charts[0].streams {
            XCTAssertEqual(stream.sampleCount, Int64(accepted))
            XCTAssertEqual(try store.samples.count(streamID: stream.id), Int64(accepted))
        }
        XCTAssertEqual(try store.samples.query(streamID: ready.streams[0].id).map(\.value), try store.samples.query(streamID: ready.streams[1].id).map(\.value))
        let reopened = try PipePlotStore(databaseURL: database)
        XCTAssertEqual(try reopened.snapshot(sessionID: ready.sessionID)?.charts[0].streams[0].sampleCount, Int64(accepted))
        print("FAILURE_ACCEPTANCE SQLITE_FULL acknowledgedRows=\(accepted) retainedPerStream=\(accepted) error=\(error.localizedDescription)")
    }

    func testMetadataWriteFailurePreservesAcknowledgedDataAndRecoversRawCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        try store.append(SampleRow(values: [1]), to: ready.attachmentID)
        let metadata = database.appendingPathExtension("metadata.json"), backup = directory.appendingPathComponent("acknowledged.json")
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
        XCTAssertEqual(try reopened.samples.query(streamID: ready.streams[0].id).map(\.value), [1,2])
        print("FAILURE_ACCEPTANCE METADATA_WRITE acknowledged=1 retainedRaw=2 recovered=2")
    }
}
