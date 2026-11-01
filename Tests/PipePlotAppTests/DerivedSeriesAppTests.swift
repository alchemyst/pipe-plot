import XCTest
import AppKit
import SwiftUI
import PipePlotCore
@testable import PipePlotApp

@MainActor
final class DerivedSeriesAppTests: XCTestCase {
    func testDerivedQueriesRemainSeparateFromRawAnalysisAndSuspend() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = PipePlotAppModel(databaseURL: dir.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date(timeIntervalSince1970: 1000), id = ready.streams[0].id
        for i in 0..<100 { _ = try model.store.append(.init(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i * i)]), to: ready.attachmentID) }
        model.refreshAll()
        let c = DerivedSeriesConfiguration(interval: 1, window: 10, maximumGap: 3, referenceCadence: 1)
        XCTAssertTrue(model.setDerivedSeries(c, streamID: id))
        let range = start...start.addingTimeInterval(99)
        func stream() throws -> StreamDescriptor { try XCTUnwrap(model.sessions[ready.sessionID]?.charts[0].streams[0]) }
        var result: DerivedSeriesResult?
        for _ in 0..<100 {
            result = model.derivedSeries(try stream(), range: range, sessionID: ready.sessionID)
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(result?.points.count, 89)
        XCTAssertEqual(result?.points.first?.derivative ?? 0, 10, accuracy: 1e-8)
        XCTAssertEqual(try model.store.samples.count(streamID: id), 100)
        XCTAssertEqual(try model.store.samples.nearestSample(streamID: id, at: start.addingTimeInterval(10))?.value, 100)
        let queries = model.queries.submittedQueryCount
        model.setDisplayActive(false, for: ready.sessionID)
        XCTAssertNil(model.derivedSeries(try stream(), range: range, sessionID: ready.sessionID))
        XCTAssertEqual(model.queries.submittedQueryCount, queries)
        model.undo(ready.sessionID)
        XCTAssertNil(try stream().derivedSeries)
        model.redo(ready.sessionID)
        XCTAssertEqual(try stream().derivedSeries, c)
        XCTAssertEqual(try model.store.samples.count(streamID: id), 100)
    }

    func testRenderDerivedPanelPreview() async throws {
        _ = NSApplication.shared
        let origin = Date(timeIntervalSince1970: 1000)
        let c = DerivedSeriesConfiguration(interval: 1, window: 10, maximumGap: 3, referenceCadence: 1)
        var processor = try DerivedSeriesProcessor(configuration: c, origin: origin), points: [DerivedPoint] = []
        for i in 0..<90 {
            try processor.append(.init(timestamp: origin.addingTimeInterval(Double(i)), sequence: UInt64(i), value: sin(Double(i) / 10), segmentID: "preview")) { points.append($0) }
        }
        processor.finish { points.append($0) }
        let stream = StreamDescriptor(id: UUID(), name: "Memory", derivedSeries: c)
        let panel = DerivedSeriesPanel(stream: stream, unit: "MiB", domain: origin...origin.addingTimeInterval(90),
                                      result: DerivedSeriesResult(points: points, message: "Delayed centered estimate · 5 s delay · 0/80 displayed estimates use interpolation", processedSamples: 90),
                                      hoverDate: origin.addingTimeInterval(42), edit: {}, disable: {})
        let view = NSHostingView(rootView: panel.frame(width: 760).padding().background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 792, height: 310), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bounds = view.bounds
        XCTAssertGreaterThan(bounds.height, 200)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pipeplot-derived-preview.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        print("DERIVED_PREVIEW \(path.path)")
        window.close()
    }
}
