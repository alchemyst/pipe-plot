import XCTest
@testable import PipePlotCore

final class MetadataContinuationTests: XCTestCase {
    func testChangedUnitHintDoesNotReuseAnImplicitGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PipePlotStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let first = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1, unitHint: "MiB"))
        try store.finishAttachment(first.attachmentID, reason: .eof)
        let second = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1, unitHint: "seconds"))
        XCTAssertFalse(second.continued)
        XCTAssertNotEqual(first.streams[0].id, second.streams[0].id)
        XCTAssertEqual(try store.snapshot(sessionID: first.sessionID)?.charts[0].settings.unit, "MiB")
    }
}
