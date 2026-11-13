import Accessibility
import XCTest
import SwiftUI
import PipePlotCore
@testable import PipePlotApp

@MainActor
final class HIGAccessibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSelectionPanelHasBoundedIntrinsicHeightAtNarrowWidth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("layout.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 3))
        let session = try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID))
        model.refreshAll()
        let selection = TimeSelection(start: now.addingTimeInterval(-30), end: now)
        let host = NSHostingView(
            rootView: SelectionInspector(session: session, selection: selection, model: model) { _ in }.frame(
                width: 530))
        host.frame = CGRect(x: 0, y: 0, width: 530, height: 240)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, 260)
    }

    func testExistingSelectionCanBeEditedWithAnEmptyChartSelected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("commands.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let empty = try model.store.createChart(in: ready.sessionID)
        model.refreshAll()
        let presentation = model.sessionModel(for: ready.sessionID)
        presentation.selectedChartID = empty.id
        let selection = TimeSelection(start: now.addingTimeInterval(-12.5), end: now)
        model.setSelection(selection, session: try XCTUnwrap(presentation.snapshot))
        let target = SessionCommandTarget(focused: presentation, editingText: false)
        XCTAssertFalse(target.canSelectVisibleRange)
        XCTAssertTrue(target.canEditSelection)
        target.editSelection(using: model)
        XCTAssertEqual(presentation.selectionEditorRequest?.selection, selection)
        XCTAssertEqual(presentation.snapshot?.timeline.selection, selection)
        XCTAssertFalse(SessionCommandTarget(focused: presentation, editingText: true).canEditSelection)
    }

    func testExactSelectionDraftPreservesStreamsAndRejectsInvalidBounds() throws {
        let stream = UUID()
        let selection = TimeSelection(start: now.addingTimeInterval(-30), end: now, selectedStreamIDs: [stream])
        var draft = SelectionEditorDraft(selection: selection, zone: .utc, now: now)
        draft.start = "2023-11-14 22:12:50.125"
        draft.end = "2023-11-14 22:13:15.625"
        let edited = try XCTUnwrap(draft.selection(at: now))
        XCTAssertEqual(edited.end.timeIntervalSince(edited.start), 25.5, accuracy: 0.0001)
        XCTAssertEqual(edited.selectedStreamIDs, [stream])
        XCTAssertEqual(edited.mode, .fixed)
        draft.end = draft.start
        XCTAssertNil(draft.selection(at: now))
        draft.start = "2023-02-30 12:00:00"
        XCTAssertNil(draft.selection(at: now))
        XCTAssertNil(SelectionEditorDraft.parse("2023-11-14 22:12:50 trailing", zone: .utc))
        XCTAssertEqual(SelectionEditorDraft.parse(SelectionEditorDraft.format(now, zone: .local), zone: .local), now)
    }

    func testTrackingDraftUsesCommitClockAndRetainsDuration() throws {
        var draft = SelectionEditorDraft(
            selection: TimeSelection(start: now.addingTimeInterval(-60), end: now), zone: .utc, now: now)
        draft.tracking = .bothFollowNow
        draft.duration = "12.5"
        let commit = now.addingTimeInterval(10)
        var selection = try XCTUnwrap(draft.selection(at: commit))
        XCTAssertEqual(selection.end, commit)
        XCTAssertEqual(selection.mode, .bothFollowNow(duration: 12.5))
        XCTAssertEqual(
            selection.resolvedBounds(at: commit.addingTimeInterval(20)).lowerBound,
            commit.addingTimeInterval(7.5))
        draft.tracking = .startFollowsEnd
        selection = try XCTUnwrap(draft.selection(at: commit))
        XCTAssertEqual(selection.end, now)
        XCTAssertEqual(selection.start, now.addingTimeInterval(-12.5))
        draft.tracking = .endFollowsNow
        selection = try XCTUnwrap(draft.selection(at: commit))
        XCTAssertEqual(selection.start, now.addingTimeInterval(-60))
        XCTAssertEqual(selection.end, commit)
        draft.tracking = .bothFollowNow
        for invalid in ["nan", "inf", "-1", "0.49", "1e300"] {
            draft.duration = invalid
            XCTAssertNil(draft.selection(at: commit))
        }
    }

    func testDerivedDescriptorExposesValuesUnitsAndIndependentRuns() throws {
        let points = [
            DerivedAccessiblePoint(timestamp: now, value: -2, run: 1),
            DerivedAccessiblePoint(timestamp: now.addingTimeInterval(1), value: -1, run: 1),
            DerivedAccessiblePoint(timestamp: now.addingTimeInterval(5), value: 3, run: 2),
        ]
        let plot = DerivedPlotAccessibility(
            title: "Rate · pressure", unit: "kPa/s", points: points,
            domain: now...now.addingTimeInterval(10), range: -3...4, zone: .utc, status: nil)
        let descriptor = plot.makeChartDescriptor()
        XCTAssertEqual(descriptor.series.count, 2)
        XCTAssertEqual(descriptor.series.map { $0.dataPoints.count }, [2, 1])
        XCTAssertEqual(descriptor.yAxis?.valueDescriptionProvider(-2), "-2 kPa/s")
        XCTAssertTrue(plot.summary.contains("positive"))
        XCTAssertTrue(plot.summary.contains("not raw measurements"))
        XCTAssertTrue(plot.summary.contains("Minimum -2 kPa/s"))
        let failed = DerivedPlotAccessibility(
            title: "Rate", unit: "kPa/s", points: points,
            domain: plot.domain, range: plot.range, zone: .utc, status: "Derived estimates unavailable.")
        failed.updateChartDescriptor(descriptor)
        XCTAssertTrue(descriptor.series.isEmpty)
        XCTAssertTrue(descriptor.summary?.contains("unavailable") == true)
    }

    func testDerivedSamplingRetainsEndpointsAndExtrema() {
        let points: [DerivedAccessiblePoint] = (0..<1000).map { index in
            let value: Double = index == 431 ? -100 : (index == 632 ? 100 : Double(index % 7))
            return DerivedAccessiblePoint(
                timestamp: now.addingTimeInterval(Double(index)), value: value,
                run: index < 500 ? 0 : 1)
        }
        let descriptor = DerivedPlotAccessibility(
            title: "Smoothed", unit: "V", points: points,
            domain: now...now.addingTimeInterval(999), range: -100...100, zone: .utc, status: nil
        ).makeChartDescriptor()
        let values = descriptor.series.flatMap(\.dataPoints)
        XCTAssertLessThanOrEqual(values.count, 122)
        XCTAssertEqual(descriptor.series.count, 2)
        XCTAssertEqual(values.first?.xValue.__number, now.timeIntervalSince1970)
        XCTAssertEqual(values.last?.xValue.__number, now.addingTimeInterval(999).timeIntervalSince1970)
        XCTAssertTrue(values.contains { $0.yValue?.__number == -100 })
        XCTAssertTrue(values.contains { $0.yValue?.__number == 100 })
    }

    func testPaletteAndCustomColorsMeetContrastTargetsInBothAppearances() {
        for hex in (0..<9).map(PlotCanvas.paletteHex) + ["#000000", "#ffffff", "#777777"] {
            for dark in [false, true] {
                for high in [false, true] {
                    let color = PlotAppearance.components(hex: hex, dark: dark, increasedContrast: high)
                    let background = [Double](repeating: dark ? 30.0 / 255 : 1, count: 3)
                    XCTAssertGreaterThanOrEqual(PlotAppearance.contrast(color, background), high ? 7 : 5, hex)
                }
            }
        }
    }

    func testStreamPatternSurvivesRenameAndColorChange() {
        var stream = StreamDescriptor(id: UUID(), name: "Before")
        let style = PlotSeriesStyle(stream)
        stream.name = "After"
        stream.colorHex = "#ff0000"
        XCTAssertEqual(style.index, PlotSeriesStyle(stream).index)
        XCTAssertEqual(style.dash, PlotSeriesStyle(stream).dash)
        XCTAssertEqual(style.markerName, PlotSeriesStyle(stream).markerName)
    }
}
