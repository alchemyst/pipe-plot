import Foundation
import TabularData
import XCTest
@testable import PipePlotCore

final class RawCSVExportTests: XCTestCase {
    func testExportsRawSelectionWithInclusiveBoundsAndQuotedDuplicateNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("samples.sqlite"))
        let first = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let other = UUID()
        let streams = [second, first].map { StreamDescriptor(id: $0, name: "Level, \"A\"\nline 2") }
        func time(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }
        let samples: [(Double, Double, StreamID)] = [
            (9.5, -100, first), (10, -3, first), (10, 0, first), (13, 8, first),
            (11.25, 7, second), (13.5, 100, second), (11, 999, other),
        ]
        for (timestamp, value, stream) in samples {
            try store.append(values: [value], timestamp: time(timestamp), to: [stream])
        }
        let selection = TimeSelection(start: time(10), end: time(13))
        let bounds = selection.resolvedBounds(at: time(20))
        let destination = directory.appendingPathComponent("selected.csv")
        try Data("old contents".utf8).write(to: destination)
        try store.exportRawCSV(streams: streams, bounds: bounds, to: destination)

        let name = "\"Level, \"\"A\"\"\nline 2\""
        let firstID = first.uuidString.lowercased(), secondID = second.uuidString.lowercased()
        let header = "receipt_timestamp,stream_id,name,value\r\n"
        let firstRows = "10.0,\(firstID),\(name),-3.0\r\n10.0,\(firstID),\(name),0.0\r\n13.0,\(firstID),\(name),8.0\r\n"
        let secondRows = "11.25,\(secondID),\(name),7.0\r\n"
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), header + firstRows + secondRows)
        let imported = try DataFrame(
            csvData: Data(contentsOf: destination),
            types: ["receipt_timestamp": .double, "stream_id": .string, "name": .string, "value": .double])
        XCTAssertEqual(Array(imported["receipt_timestamp", Double.self]), [10, 10, 13, 11.25])
        XCTAssertEqual(Array(imported["stream_id", String.self]), [firstID, firstID, firstID, secondID])
        XCTAssertEqual(Array(imported["name", String.self]), Array(repeating: streams[0].name, count: 4))
        XCTAssertEqual(Array(imported["value", Double.self]), [-3, 0, 8, 7])
        XCTAssertEqual(try store.statistics(streamID: first, from: bounds.lowerBound, to: bounds.upperBound)?.count, 3)
        XCTAssertEqual(try store.statistics(streamID: second, from: bounds.lowerBound, to: bounds.upperBound)?.count, 1)

        try store.exportRawCSV(streams: streams, to: destination)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            header + "9.5,\(firstID),\(name),-100.0\r\n" + firstRows + secondRows + "13.5,\(secondID),\(name),100.0\r\n"
        )
    }

    func testStreamScanKeepsOneSnapshotWhileCaptureAppendsToLaterStream() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("samples.sqlite")
        let writer = try SampleStore(databaseURL: database)
        let reader = try SampleStore(readOnlyDatabaseURL: database)
        let first = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let streams = [first, second].map { StreamDescriptor(id: $0, name: "series") }
        let timestamp = Date(timeIntervalSince1970: 10)
        try writer.append(values: [1, 2], timestamp: timestamp, to: [first, second])

        var rows: [String] = []
        try reader.writeRawCSV(streams: streams, bounds: nil) { row in
            rows.append(row)
            if rows.count == 2 {
                try writer.append(values: [3], timestamp: timestamp, to: [second])
            }
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(try XCTUnwrap(rows.last).hasSuffix(",2.0\r\n"))
        XCTAssertEqual(try reader.count(streamID: second), 2)
    }

    func testCancelledExportPreservesExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("samples.sqlite"))
        let destination = directory.appendingPathComponent("existing.csv")
        let original = Data("original contents".utf8)
        try original.write(to: destination)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try store.exportRawCSV(streams: [], to: destination)
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testExportCannotReplaceCaptureFilesOrAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("samples.sqlite")
        let store = try PipePlotStore(databaseURL: database)
        _ = try store.createSession()
        let stream = StreamDescriptor(id: UUID(), name: "active")
        try store.samples.append(values: [42], timestamp: Date(), to: [stream.id])

        let protected = [
            database, directory.appendingPathComponent("samples.sqlite-wal"),
            directory.appendingPathComponent("samples.sqlite-shm"), database.appendingPathExtension("metadata.json"),
        ]
        let snapshots = try protected.map { try Data(contentsOf: $0) }
        let alias = directory.appendingPathComponent("alias.csv")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: database)
        let upperCase = directory.appendingPathComponent("SAMPLES.SQLITE")
        var destinations = protected + [alias]
        if FileManager.default.fileExists(atPath: upperCase.path) { destinations.append(upperCase) }

        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        for destination in destinations {
            XCTAssertThrowsError(try store.samples.exportRawCSV(streams: [stream], to: destination)) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteInvalidFileName)
            }
        }
        XCTAssertEqual(try protected.map { try Data(contentsOf: $0) }, snapshots)
        XCTAssertEqual(try Data(contentsOf: alias), snapshots.first)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), entries)
        XCTAssertEqual(try store.samples.query(streamID: stream.id).map(\.value), [42])
    }

    func testFailedExportPreservesExistingDestinationAndRemovesStaging() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("samples.sqlite")
        let store = try SampleStore(databaseURL: database)
        let destination = directory.appendingPathComponent("existing.csv")
        let original = Data("original contents".utf8)
        try original.write(to: destination)
        // The writer stays open, but a new read connection can no longer open its original path.
        try FileManager.default.moveItem(at: database, to: directory.appendingPathComponent("moved.sqlite"))
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))

        XCTAssertThrowsError(try store.exportRawCSV(streams: [], to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), entries)
    }
}
