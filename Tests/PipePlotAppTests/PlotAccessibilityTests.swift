import Accessibility
import PipePlotCore
import SwiftUI
import XCTest
@testable import PipePlotApp

@MainActor
final class PlotAccessibilityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func content(
        chart: ChartSnapshot, session: SessionSnapshot? = nil,
        samples: [StreamID: [StoredSample]] = [:], ready: Set<StreamID> = [], failed: Set<StreamID> = [],
        offset: TimeInterval = 0, valueRange: ClosedRange<Double> = 0...100,
        selection: TimeSelection? = nil
    ) -> PlotAccessibility {
        PlotAccessibility(
            chart: chart,
            session: session ?? SessionSnapshot(id: UUID(), number: 1, title: "Session", charts: [chart]),
            samples: samples, readyDisplays: ready, failedDisplays: failed,
            domain: start.addingTimeInterval(offset)...start.addingTimeInterval(offset + 300),
            now: start.addingTimeInterval(offset + 300), valueRange: valueRange, selection: selection, forecasts: [])
    }

    private func rows(_ values: [Double], segment: String = "first") -> [StoredSample] {
        values.enumerated().map { index, value in
            StoredSample(
                timestamp: start.addingTimeInterval(Double(index)), sequence: UInt64(index), value: value,
                segmentID: segment)
        }
    }

    func testDescriptorUpdatesVisibleRangeAndReferenceAxisDescriptions() throws {
        let stream = StreamDescriptor(id: UUID(), name: "Voltage")
        var chart = ChartSnapshot(id: UUID(), title: "Supply", streams: [stream])
        chart.settings.unit = "mV"
        var session = SessionSnapshot(id: UUID(), number: 1, title: "Session", charts: [chart])
        session.timeline.timeZone = .utc
        let initial = content(
            chart: chart, session: session, samples: [stream.id: rows([10, 11])], ready: [stream.id])
        let descriptor = initial.makeChartDescriptor()
        XCTAssertEqual(descriptor.title, "Supply")
        XCTAssertEqual(descriptor.series.map(\.name), ["Voltage"])
        XCTAssertTrue(descriptor.summary?.contains("latest visible raw observation: 11 mV") == true)
        XCTAssertEqual(
            try XCTUnwrap(descriptor.xAxis as? AXNumericDataAxisDescriptor).range.lowerBound,
            start.timeIntervalSince1970)
        XCTAssertEqual(descriptor.yAxis?.valueDescriptionProvider(10), "10 mV")

        let valueGuide = Guide(orientation: .horizontalValue, value: 10, label: "Baseline")
        let timeGuide = Guide(orientation: .verticalTime, value: start.timeIntervalSince1970 + 20, label: "Event")
        chart.title = "Changed"
        chart.guides = [valueGuide]
        chart.settings.referenceGuideID = valueGuide.id
        session.timeGuides = [timeGuide]
        session.timeline.referenceTimeGuideID = timeGuide.id
        let changedRows = rows([20, 25]).map { row in
            var changed = row
            changed.timestamp = row.timestamp.addingTimeInterval(10)
            return changed
        }
        let updated = content(
            chart: chart, session: session, samples: [stream.id: changedRows],
            ready: [stream.id], offset: 10, valueRange: 10...50)
        updated.updateChartDescriptor(descriptor)
        XCTAssertEqual(descriptor.title, "Changed")
        XCTAssertEqual(descriptor.yAxis?.range, 10...50)
        XCTAssertEqual(descriptor.yAxis?.valueDescriptionProvider(20), "10 mV")
        XCTAssertTrue((descriptor.xAxis as? AXNumericDataAxisDescriptor)?.title.contains("Elapsed time") == true)
        XCTAssertEqual(
            (descriptor.xAxis as? AXNumericDataAxisDescriptor)?.valueDescriptionProvider(timeGuide.value), "+0s")
        XCTAssertTrue(descriptor.summary?.contains("Baseline, raw guide value: 10 mV") == true)
        XCTAssertTrue(descriptor.summary?.contains("Event:") == true)
        XCTAssertTrue(descriptor.series.first?.dataPoints.last?.label?.contains("Raw observation 25 mV") == true)
        chart.streams[0].isLayoutHidden = true
        content(chart: chart, session: session, samples: [stream.id: changedRows], ready: [stream.id])
            .updateChartDescriptor(descriptor)
        XCTAssertTrue(descriptor.series.isEmpty)
        XCTAssertTrue(descriptor.summary?.contains("All streams are hidden") == true)
        chart.streams[0].isLayoutHidden = false
        content(
            chart: chart, session: session, samples: [stream.id: changedRows],
            ready: [stream.id], offset: 10, valueRange: 10...50
        )
        .updateChartDescriptor(descriptor)
        XCTAssertEqual(descriptor.series.map(\.name), ["Voltage"])
    }

    func testHiddenMarksOffAndQueryStatesStayDistinct() {
        var visible = StreamDescriptor(id: UUID(), name: "Visible")
        visible.linesVisible = false
        visible.dotsVisible = false
        var hidden = StreamDescriptor(id: UUID(), name: "Hidden")
        hidden.isLayoutHidden = true
        let chart = ChartSnapshot(id: UUID(), title: "Readings", streams: [visible, hidden])
        let pending = content(chart: chart).makeChartDescriptor()
        XCTAssertTrue(pending.series.isEmpty)
        XCTAssertTrue(pending.summary?.contains("Loading visible data for Visible") == true)
        XCTAssertTrue(pending.summary?.contains("1 hidden from layout") == true)
        XCTAssertTrue(pending.summary?.contains("Marks off for Visible") == true)

        let failed = content(chart: chart, failed: [visible.id]).makeChartDescriptor()
        XCTAssertTrue(failed.summary?.contains("Visible data refresh failed for Visible") == true)
        XCTAssertFalse(failed.summary?.contains("Loading visible data") == true)

        let updating = content(chart: chart, samples: [visible.id: rows([5])]).makeChartDescriptor()
        XCTAssertEqual(updating.series.map(\.name), ["Visible, marks off"])
        XCTAssertTrue(updating.summary?.contains("Updating visible data for Visible") == true)
        XCTAssertTrue(updating.summary?.contains("latest visible displayed raw observation") == true)
        let failedWithRows = content(chart: chart, samples: [visible.id: rows([5])], failed: [visible.id])
            .makeChartDescriptor()
        XCTAssertEqual(failedWithRows.series.count, 1)
        XCTAssertTrue(failedWithRows.summary?.contains("refresh failed") == true)

        let empty = content(chart: chart, ready: [visible.id]).makeChartDescriptor()
        XCTAssertTrue(empty.summary?.contains("No observations in range for Visible") == true)
        let ready = content(chart: chart, samples: [visible.id: rows([5])], ready: [visible.id])
            .makeChartDescriptor()
        XCTAssertEqual(ready.series.map(\.name), ["Visible, marks off"])
        XCTAssertEqual(ready.series.first?.isContinuous, false)
    }

    func testNavigationIsBoundedAndReconnectsAreSeparateSeries() {
        let stream = StreamDescriptor(id: UUID(), name: "Memory")
        let chart = ChartSnapshot(id: UUID(), title: "Memory", streams: [stream])
        var samples = rows((0..<300).map(Double.init))
        samples[50].value = -500
        samples[250].value = 500
        for index in 150..<300 { samples[index].segmentID = "second" }
        let descriptor = content(chart: chart, samples: [stream.id: samples], ready: [stream.id])
            .makeChartDescriptor()
        XCTAssertEqual(descriptor.series.count, 2)
        XCTAssertTrue(descriptor.series.allSatisfy(\.isContinuous))
        XCTAssertLessThanOrEqual(descriptor.series.flatMap(\.dataPoints).count, 122)
        XCTAssertTrue(descriptor.series[0].name?.contains("segment 1 of 2") == true)
        let labels = descriptor.series.flatMap(\.dataPoints).compactMap(\.label)
        XCTAssertTrue(labels.contains { $0.contains("Raw observation 0 at") })
        XCTAssertTrue(labels.contains { $0.contains("Raw observation 299 at") })
        XCTAssertTrue(labels.contains { $0.contains("Raw observation -500 at") })
        XCTAssertTrue(labels.contains { $0.contains("Raw observation 500 at") })
        XCTAssertTrue(descriptor.summary?.contains("at most 122") == true)
    }

    func testSelectionCreationUsesOnlyLayoutStreams() {
        let shown = StreamDescriptor(id: UUID(), name: "Shown")
        var hidden = StreamDescriptor(id: UUID(), name: "Hidden")
        hidden.isLayoutHidden = true
        let selection = TimeSelection.visibleRange(start...start.addingTimeInterval(30), streams: [shown, hidden])
        XCTAssertEqual(selection.selectedStreamIDs, [shown.id])
        XCTAssertEqual(selection.resolvedBounds(at: start).upperBound, start.addingTimeInterval(30))
        let chart = ChartSnapshot(id: UUID(), title: "Readings", streams: [shown, hidden])
        let descriptor = content(chart: chart, selection: selection).makeChartDescriptor()
        XCTAssertTrue(descriptor.summary?.contains("Selection") == true)
        XCTAssertTrue(descriptor.summary?.contains("fixed") == true)
    }

    func testCanvasAdapterRetainsHiddenStreamContextWhileRenderingOnlyVisibleStreams() {
        var hidden = StreamDescriptor(id: UUID(), name: "Hidden")
        hidden.isLayoutHidden = true
        let original = ChartSnapshot(id: UUID(), title: "Readings", streams: [hidden])
        var rendered = original
        rendered.streams = []
        let session = SessionSnapshot(id: UUID(), number: 1, title: "Session", charts: [original])
        let canvas = PlotCanvas(
            chart: rendered, accessibilityChart: original, session: session, samples: [:], currentDisplays: [],
            domain: start...start.addingTimeInterval(300), now: start,
            hoverDate: .constant(nil), selectionStart: .constant(nil), selectionPreview: .constant(nil),
            selectionLinkedPreview: .constant(false), selection: nil, forecasts: [],
            onSelectionCommit: { _, _, _ in }, onGuide: { _, _ in }, onPan: { _, _, _ in },
            onZoom: { _, _, _ in })
        let descriptor = canvas.chartAccessibility.makeChartDescriptor()
        XCTAssertTrue(descriptor.summary?.contains("All streams are hidden from layout") == true)
        XCTAssertFalse(descriptor.summary?.contains("Waiting for a pipeline") == true)
    }

    func testVisibleRangeSelectionUsesSemanticUndoPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("selection.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 2))
        let session = try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID))
        let chart = try XCTUnwrap(session.charts.first)
        let selection = TimeSelection.visibleRange(start...start.addingTimeInterval(30), streams: chart.streams)
        let manager = model.undoManager(for: ready.sessionID)
        model.setSelection(selection, session: session)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.timeline.selection, selection)
        XCTAssertEqual(manager.undoActionName, "Selection")
        manager.undo()
        XCTAssertNil(try model.store.snapshot(sessionID: ready.sessionID)?.timeline.selection)
    }

    func testExactHistoricDisplayIsReadyEvenWhenLatestStreamSampleIsOutsideRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("historic.sqlite"))
        let registration = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        _ = try model.store.append(
            SampleRow(timestamp: start, values: [10]), to: registration.attachmentID)
        _ = try model.store.append(
            SampleRow(timestamp: start.addingTimeInterval(400), values: [20]), to: registration.attachmentID)
        model.refreshAll()
        let session = try XCTUnwrap(model.sessions[registration.sessionID])
        let chart = try XCTUnwrap(session.charts.first)
        let range = start...start.addingTimeInterval(300)
        model.requestVisibleSamples(for: chart, session: session, range: range)
        var display = model.visibleSamples(for: chart, session: session, range: range)
        for _ in 0..<100 where !display.ready.contains(registration.streams[0].id) {
            try await Task.sleep(for: .milliseconds(20))
            display = model.visibleSamples(for: chart, session: session, range: range)
        }
        XCTAssertTrue(display.ready.contains(registration.streams[0].id))
        XCTAssertFalse(display.current.contains(registration.streams[0].id))
        XCTAssertEqual(display.samples[registration.streams[0].id]?.map(\.value), [10])
        let descriptor = content(
            chart: chart, session: session, samples: display.samples, ready: display.ready
        ).makeChartDescriptor()
        XCTAssertEqual(descriptor.series.count, 1)
        XCTAssertFalse(descriptor.summary?.contains("Loading visible data") == true)
        XCTAssertFalse(descriptor.summary?.contains("Updating visible data") == true)
    }
}
