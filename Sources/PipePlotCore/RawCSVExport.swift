import CSQLite
import Darwin
import Foundation

extension SampleStore {
    /// Exports an independent WAL snapshot. Rows are ordered by stream UUID, then
    /// by receipt timestamp and sequence. Timestamps are Unix seconds and optional
    /// bounds are inclusive, as in selection statistics.
    public func exportRawCSV(
        streams: [StreamDescriptor], bounds: ClosedRange<Date>? = nil, to destination: URL
    ) throws {
        try Task.checkCancellation()
        try validateExportDestination(destination)
        let files = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".pipeplot-export-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let temporary = staging.appendingPathComponent("export.csv")
        guard files.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }

        let reader = try SampleStore(readOnlyDatabaseURL: databaseURL)
        var buffer = Data()
        try reader.writeRawCSV(streams: streams, bounds: bounds) { row in
            buffer.append(contentsOf: row.utf8)
            if buffer.count >= 65_536 {
                try file.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try file.write(contentsOf: buffer)
        try file.synchronize()
        try file.close()
        try Task.checkCancellation()

        // Staging beside the destination keeps the final rename on the same volume.
        if rename(temporary.path, destination.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func validateExportDestination(_ destination: URL) throws {
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        let identifierKey: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let destinationID = try? resolved.resourceValues(forKeys: identifierKey).fileResourceIdentifier as? NSObject
        let protected = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            databaseURL.appendingPathExtension("metadata.json"),
        ]
        for file in protected {
            let existing = file.resolvingSymlinksInPath().standardizedFileURL
            let existingID = try? existing.resourceValues(forKeys: identifierKey).fileResourceIdentifier as? NSObject
            if resolved.path == existing.path || (destinationID != nil && destinationID == existingID) {
                throw CocoaError(
                    .fileWriteInvalidFileName,
                    userInfo: [NSLocalizedDescriptionKey: "Choose a CSV destination outside the active capture files."])
            }
        }
    }

    /// The caller supplies a sink so the history can be streamed without a result array.
    func writeRawCSV(
        streams: [StreamDescriptor], bounds: ClosedRange<Date>?, write: (String) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN")
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? execute("ROLLBACK") }
        }

        try write("receipt_timestamp,stream_id,name,value\r\n")
        let predicate = bounds == nil ? "" : "AND timestamp>=? AND timestamp<=?"
        var seen: Set<StreamID> = []
        for stream in streams.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard seen.insert(stream.id).inserted else { continue }
            try Task.checkCancellation()
            let statement = try self.statement(
                "SELECT timestamp,value FROM samples WHERE stream_id=? \(predicate) ORDER BY timestamp,sequence"
            )
            defer { statement.close() }
            let id = stream.id.uuidString.lowercased()
            try statement.text(id, at: 1)
            if let bounds {
                try statement.double(bounds.lowerBound.timeIntervalSince1970, at: 2)
                try statement.double(bounds.upperBound.timeIntervalSince1970, at: 3)
            }
            let quotedName = "\"" + stream.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            while try statement.step() == .row {
                try Task.checkCancellation()
                let timestamp = sqlite3_column_double(statement.raw, 0)
                let value = sqlite3_column_double(statement.raw, 1)
                try write("\(timestamp),\(id),\(quotedName),\(value)\r\n")
            }
        }
        try execute("COMMIT")
    }
}
