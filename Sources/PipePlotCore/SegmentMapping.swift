import Foundation
import CSQLite

public struct SegmentTransfer {
    public let segmentIDs: [String]
    public let from: StreamID
    public let to: StreamID
    public init(segmentIDs: [String], from: StreamID, to: StreamID) {
        self.segmentIDs = segmentIDs
        self.from = from
        self.to = to
    }
}

extension SampleStore {
    /// Remaps whole acquisition segments without copying observations into undo history.
    /// Undo calls the same operation with reversed endpoints; rows arriving after the
    /// edit carry the same segment ID, so they move back with their original producer.
    public func reassignSegments(_ segmentIDs: [String], from source: StreamID, to destination: StreamID) throws {
        try reassignSegments([SegmentTransfer(segmentIDs: segmentIDs, from: source, to: destination)])
    }

    public func reassignSegments(_ mappings: [SegmentTransfer]) throws {
        lock.lock()
        defer { lock.unlock() }
        try sql("BEGIN IMMEDIATE")
        do {
            for mapping in mappings { try transfer(mapping) }
            try sql("COMMIT")
        } catch {
            try? sql("ROLLBACK")
            throw error
        }
    }

    private func transfer(_ mapping: SegmentTransfer) throws {
        let source = mapping.from, destination = mapping.to, segmentIDs = mapping.segmentIDs
        guard source != destination, !segmentIDs.isEmpty else { return }
        let offsetStatement = try self.statement("SELECT COALESCE(MAX(sequence)+1,0) FROM samples WHERE stream_id=?")
        defer { offsetStatement.close() }
        try offsetStatement.text(destination.uuidString.lowercased(), at: 1)
        guard try offsetStatement.step() == .row else {

            throw SampleStoreError.sql("Could not allocate remapped sequences")
        }
        let offset = sqlite3_column_int64(offsetStatement.raw, 0)
        offsetStatement.close()

        let placeholders = Array(repeating: "?", count: segmentIDs.count).joined(separator: ",")
        let statement = try self.statement(
            "UPDATE samples SET stream_id=?, sequence=sequence+? WHERE stream_id=? AND segment_id IN (\(placeholders))")
        defer { statement.close() }
        try statement.text(destination.uuidString.lowercased(), at: 1)
        try statement.int64(offset, at: 2)
        try statement.text(source.uuidString.lowercased(), at: 3)
        for (index, id) in segmentIDs.enumerated() { try statement.text(id, at: Int32(index + 4)) }
        let code = try statement.step()
        guard code == .done else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
        statement.close()
        for stream in [source, destination] {
            let refresh = try self.statement(
                "INSERT INTO stream_meta(stream_id,sample_count,first_time,last_time,next_sequence) SELECT ?,COUNT(*),MIN(timestamp),MAX(timestamp),COALESCE(MAX(sequence)+1,0) FROM samples WHERE stream_id=? ON CONFLICT(stream_id) DO UPDATE SET sample_count=excluded.sample_count,first_time=excluded.first_time,last_time=excluded.last_time,next_sequence=excluded.next_sequence"
            )
            defer { refresh.close() }
            try refresh.text(stream.uuidString.lowercased(), at: 1)
            try refresh.text(stream.uuidString.lowercased(), at: 2)
            let result = try refresh.step()
            guard result == .done else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            refresh.close()
        }
    }

    public func segmentIDs(streamID: StreamID) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try self.statement(
            "SELECT DISTINCT segment_id FROM samples WHERE stream_id=? AND segment_id IS NOT NULL")
        defer { statement.close() }

        try statement.text(streamID.uuidString.lowercased(), at: 1)
        var result: [String] = []
        while true {
            let code = try statement.step()
            if code == .done { return result }
            guard code == .row else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            result.append(String(cString: sqlite3_column_text(statement.raw, 0)))
        }
    }

    private func sql(_ command: String) throws {
        guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else {
            throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }
}
