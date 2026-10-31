import XCTest
import SwiftUI
import AppKit
import PipePlotCore
@testable import PipePlotApp

@MainActor
final class AnnotationRenderTests: XCTestCase {
    /// Set PIPEPLOT_REVIEW_DIR to export the actual Canvas for visual inspection.
    func testAnnotationReviewFixtures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PipePlotStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let stream = ready.streams[0].id
        let start = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 100)
        for scenario in ["upper-guide", "lower-guide", "unnamed-drag", "named-time-drag", "forecast-selection-cleared", "forecast-selection-changed"] {
            var session = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID))
            var chart = session.charts[0]
            chart.settings.unit = "B"
            chart.guides = [Guide(orientation: .horizontalValue, value: scenario == "lower-guide" ? -100 : 100, label: scenario == "unnamed-drag" ? nil : "limit")]
            session.timeline.timeZone = .utc
            session.timeGuides = [Guide(orientation: .verticalTime, value: 98, label: "deploy")]
            let samples = (0...20).map { StoredSample(timestamp: start.addingTimeInterval(Double($0) * 4), sequence: UInt64($0), value: Double($0) / 2 + 10) }
            let training = scenario.hasPrefix("forecast") ? [
                ForecastTrainingRange(id: UUID(), streamID: stream, label: "line 1 → limit · training", range: start.addingTimeInterval(10)...start.addingTimeInterval(50), linked: false),
                ForecastTrainingRange(id: UUID(), streamID: stream, label: "line 1 → target 2 · training", range: start.addingTimeInterval(30)...start.addingTimeInterval(80), linked: true)
            ] : []
            let selection: TimeSelection? = scenario == "forecast-selection-changed" ? TimeSelection(start: start.addingTimeInterval(60), end: start.addingTimeInterval(90)) : nil
            let canvas = PlotCanvas(chart: chart, session: session, samples: [stream: samples], currentDisplays: [], domain: start...end, now: end,
                hoverDate: .constant(nil), selectionStart: .constant(nil), selectionPreview: .constant(nil), selectionLinkedPreview: .constant(false),
                selection: selection, forecasts: [],
                draggingGuideID: scenario == "unnamed-drag" ? chart.guides[0].id : (scenario == "named-time-drag" ? session.timeGuides[0].id : nil),
                trainingRanges: training, onSelectionCommit: { _,_,_ in }, onGuide: { _,_ in }, onPan: { _,_,_ in }, onZoom: { _,_,_ in })
                .drawingCanvas.frame(width: 800, height: 260).background(Color.black).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            let cgImage = try XCTUnwrap(renderer.cgImage)
            if let output = ProcessInfo.processInfo.environment["PIPEPLOT_REVIEW_DIR"] {
                let url = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
                try data.write(to: url.appendingPathComponent(scenario + ".png"))
            }
        }
    }
}
