import CSQLite
import Foundation
import XCTest
@testable import PipePlotCore

final class SQLiteStatementTests: XCTestCase {
    private func store() throws -> (SampleStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try SampleStore(databaseURL: directory.appendingPathComponent("samples.sqlite")), directory)
    }

    func testPrepareAndBindingErrorsLeaveNoOpenStatement() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try XCTUnwrap(store.db)
        XCTAssertThrowsError(try store.statement("SELECT missing_column FROM samples"))
        XCTAssertNil(sqlite3_next_stmt(db, nil))

        let statement = try store.statement("SELECT ?")
        XCTAssertThrowsError(try statement.text("out of range", at: 2))
        statement.close()
        statement.close()
        XCTAssertNil(sqlite3_next_stmt(db, nil))
    }

    func testStepErrorAfterRowAndCleanup() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try XCTUnwrap(store.db)
        let statement = try store.statement("SELECT 1 UNION ALL SELECT abs(-9223372036854775808)")
        XCTAssertEqual(try statement.step(), .row)
        XCTAssertEqual(sqlite3_column_int(statement.raw, 0), 1)
        XCTAssertThrowsError(try statement.step())
        statement.close()
        XCTAssertNil(sqlite3_next_stmt(db, nil))
    }

    func testStoreQueryThrowsRatherThanReturningPartialRows() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try store.append(StoredSample(timestamp: Date(timeIntervalSince1970: 1), sequence: 0, value: 1), to: id)
        try store.append(StoredSample(timestamp: Date(timeIntervalSince1970: 2), sequence: 1, value: 2), to: id)
        let db = try XCTUnwrap(store.db)
        let sql = """
            ALTER TABLE samples RENAME TO source_samples;
            CREATE VIEW samples AS SELECT stream_id,timestamp,sequence,
                CASE WHEN sequence=1 THEN abs(-9223372036854775808) ELSE value END AS value,
                segment_id FROM source_samples;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.query(streamID: id))
        XCTAssertNil(sqlite3_next_stmt(db, nil))
    }

    func testLegacySegmentColumnMigrationIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let legacy =
            "CREATE TABLE samples(stream_id TEXT NOT NULL,timestamp REAL NOT NULL,sequence INTEGER NOT NULL,value REAL NOT NULL,PRIMARY KEY(stream_id,sequence))"
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let id = UUID()
        let first = try SampleStore(databaseURL: url)
        try first.append(
            StoredSample(timestamp: Date(timeIntervalSince1970: 1), sequence: 0, value: 2, segmentID: "segment"),
            to: id)
        let second = try SampleStore(databaseURL: url)
        XCTAssertEqual(try second.query(streamID: id).first?.segmentID, "segment")
    }

    func testBusyReadThrowsAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("locked.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        let schema = "CREATE TABLE samples(stream_id TEXT,timestamp REAL,sequence INTEGER,value REAL,segment_id TEXT)"
        XCTAssertEqual(sqlite3_exec(writer, schema, nil, nil, nil), SQLITE_OK)
        let reader = try SampleStore(readOnlyDatabaseURL: url)
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }
        let id = UUID()
        XCTAssertThrowsError(try reader.query(streamID: id)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("locked"), "\(error)")
        }
        XCTAssertNil(sqlite3_next_stmt(reader.db, nil))
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try reader.query(streamID: id), [])
    }
}
