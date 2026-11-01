import XCTest
@testable import PipePlotApp
import PipePlotCore
import UniformTypeIdentifiers

@MainActor
final class StreamDropTests: XCTestCase {
    func testDragTypeCanBeResolvedByDropDestinations() throws {
        XCTAssertTrue(StreamDragState.contentType.conforms(to: .data))
        XCTAssertEqual(StreamDragState.pasteboardType, StreamDragState.contentType.identifier)
        XCTAssertEqual(UTType(StreamDragState.pasteboardType), StreamDragState.contentType)
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Config/Info.plist")), format: nil) as? [String: Any]
        let declarations = try XCTUnwrap(plist?["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == StreamDragState.pasteboardType })
        XCTAssertTrue((declaration["UTTypeConformsTo"] as? [String] ?? []).contains(UTType.data.identifier))
    }

    private func withModel(_ body: (PipePlotAppModel, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("test.sqlite")
        try body(PipePlotAppModel(databaseURL: database), database)
    }

    func testDestinationValidationAndPreviewLifecycle() throws {
        try withModel { model, _ in
            let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
            let stream = try XCTUnwrap(ready.streams.first?.id)
            let destination = try model.store.createChart(in: ready.sessionID)
            let other = try model.store.createSession()
            let target = StreamDropTarget(sessionID: ready.sessionID, onto: destination.id)
            let items = [stream.uuidString]
            let undoName = model.store.undoActionName(sessionID: ready.sessionID)
            for invalid in [[], ["text"], [UUID().uuidString], items + items] {
                XCTAssertFalse(model.canDropStream(invalid, sessionID: ready.sessionID, onto: destination.id))
                XCTAssertFalse(model.dropStream(invalid, sessionID: ready.sessionID, onto: destination.id))
            }
            XCTAssertFalse(model.canDropStream(items, sessionID: ready.sessionID, onto: ready.chartID))
            XCTAssertFalse(model.canDropStream(items, sessionID: other.id, onto: other.charts[0].id))
            XCTAssertFalse(model.canDropStream(items, sessionID: ready.sessionID, before: UUID()))
            XCTAssertFalse(model.canDropStream(items, sessionID: ready.sessionID, after: other.charts[0].id))
            XCTAssertFalse(model.canDropStream(items, sessionID: ready.sessionID, onto: destination.id, before: ready.chartID))
            XCTAssertFalse(model.canDropStream(items, sessionID: ready.sessionID, before: destination.id, after: ready.chartID))
            XCTAssertEqual(model.store.undoActionName(sessionID: ready.sessionID), undoName)
            XCTAssertFalse(target.accepts(model))
            model.streamDrag.begin(stream)
            model.streamDrag.target = target
            XCTAssertTrue(target.isTargeted(model))
            XCTAssertFalse(StreamDropTarget(sessionID: ready.sessionID, onto: ready.chartID).accepts(model))
            // A destination disappearing during a drag must immediately lose feedback.
            try model.store.deleteChart(destination.id)
            XCTAssertFalse(target.isTargeted(model))
            try model.store.restoreChart(destination.id)
            XCTAssertTrue(target.isTargeted(model))
            model.streamDrag.end() // Escape, outside drop and successful drop share this cleanup.
            XCTAssertNil(model.streamDrag.streamID)
            XCTAssertNil(model.streamDrag.target)
            XCTAssertFalse(target.isTargeted(model))
            model.streamDrag.begin(stream)
            XCTAssertNil(model.streamDrag.target)
            try model.store.setStreamLayoutHidden(true, streamID: stream)
            XCTAssertFalse(target.accepts(model))
            try model.store.setStreamLayoutHidden(false, streamID: stream)
            try model.store.deleteSession(sessionID: ready.sessionID)
            XCTAssertFalse(target.accepts(model))
        }
    }

    func testMergePreservesCaptureAnnotationsStyleAndSingleUndo() throws {
        try withModel { model, database in
            let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
            let stream = try XCTUnwrap(ready.streams.first?.id)
            let destination = try model.store.createChart(in: ready.sessionID)
            var sourceSettings = AxisSettings(); sourceSettings.unit = "K"; sourceSettings.dotsVisible = true; sourceSettings.linesVisible = false
            var destinationSettings = AxisSettings(); destinationSettings.unit = "Pa"
            try model.store.updateSettings(sourceSettings, chartID: ready.chartID)
            try model.store.updateSettings(destinationSettings, chartID: destination.id)
            let sourceGuide = Guide(orientation: .horizontalValue, value: 10)
            let destinationGuide = Guide(orientation: .horizontalValue, value: 20)
            try model.store.upsertGuide(sourceGuide, chartID: ready.chartID)
            try model.store.upsertGuide(destinationGuide, chartID: destination.id)
            try model.store.updateStreamStyle(stream, colorHex: "#abcdef", dotsVisible: nil, linesVisible: nil)
            XCTAssertTrue(model.dropStream([stream.uuidString], sessionID: ready.sessionID, onto: destination.id))
            try model.store.append(SampleRow(values: [42], sequence: 1), to: ready.attachmentID)
            @MainActor func session() throws -> SessionSnapshot { try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID)) }
            let moved = try session()
            XCTAssertFalse(moved.charts[0].isVisible)
            XCTAssertEqual(moved.charts[0].settings, sourceSettings)
            XCTAssertEqual(moved.charts[0].guides, [sourceGuide])
            XCTAssertEqual(moved.charts[1].settings, destinationSettings)
            XCTAssertEqual(moved.charts[1].guides, [destinationGuide])
            let line = try XCTUnwrap(moved.charts[1].streams.first)
            XCTAssertEqual(line.id, stream)
            XCTAssertEqual(line.sampleCount, 1)
            XCTAssertEqual(line.state, .live)
            XCTAssertEqual(line.colorHex, "#abcdef")
            XCTAssertEqual(line.dotsVisible, true)
            XCTAssertEqual(line.linesVisible, false)
            model.undo(ready.sessionID)
            XCTAssertTrue(try session().charts[0].isVisible)
            XCTAssertEqual(try session().charts[0].streams.first?.id, stream)
            XCTAssertTrue(try session().charts[1].streams.isEmpty)
            try model.store.append(SampleRow(values: [43], sequence: 2), to: ready.attachmentID)
            model.redo(ready.sessionID)
            XCTAssertFalse(try session().charts[0].isVisible)
            XCTAssertEqual(try session().charts[1].streams.first?.sampleCount, 2)
            let saved = try XCTUnwrap(PipePlotStore(databaseURL: database).snapshot(sessionID: ready.sessionID))
            XCTAssertEqual(saved.charts[1].streams.first?.id, stream)
            XCTAssertEqual(saved.charts[1].streams.first?.colorHex, "#abcdef")
            XCTAssertEqual(saved.charts[0].guides, [sourceGuide])
            XCTAssertEqual(saved.charts[1].guides, [destinationGuide])
        }
    }

    func testInsertionPositionsAndAtomicReplayDuringCapture() throws {
        for position in 0...2 {
            try withModel { model, _ in
                let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
                let stream = try XCTUnwrap(ready.streams.first?.id)
                let second = try model.store.createChart(in: ready.sessionID)
                let before: ChartID? = position == 0 ? ready.chartID : (position == 1 ? second.id : nil)
                let after: ChartID? = position == 2 ? second.id : nil
                XCTAssertTrue(model.dropStream([stream.uuidString], sessionID: ready.sessionID, before: before, after: after))
                let inserted = try XCTUnwrap(model.sessions[ready.sessionID]?.charts[position])
                XCTAssertEqual(inserted.streams.first?.id, stream)
                try model.store.append(SampleRow(values: [1], sequence: 1), to: ready.attachmentID)
                model.undo(ready.sessionID)
                XCTAssertEqual(model.sessions[ready.sessionID]?.charts.map(\.id), [ready.chartID, second.id])
                XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].streams.first?.sampleCount, 1)
                model.redo(ready.sessionID)
                XCTAssertEqual(model.sessions[ready.sessionID]?.charts[position].id, inserted.id)
                XCTAssertEqual(model.sessions[ready.sessionID]?.charts[position].streams.first?.sampleCount, 1)
            }
        }
    }
}
