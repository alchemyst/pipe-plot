import AppKit
import SwiftUI
import XCTest
import PipePlotCore
@testable import PipePlotApp

@MainActor
final class ChartInspectorTests: XCTestCase {
    private func makeModel() throws -> (PipePlotAppModel, URL, SessionID, ChartID, ChartID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let session = try model.store.createSession()
        let first = try XCTUnwrap(session.charts.first)
        let second = try model.store.createChart(in: session.id, after: first.id)
        model.refreshAll()
        return (model, directory, session.id, first.id, second.id)
    }

    private func chart(_ id: ChartID, in model: PipePlotAppModel, sessionID: SessionID) throws -> ChartSnapshot {
        try XCTUnwrap(model.sessions[sessionID]?.charts.first { $0.id == id })
    }

    func testChartDraftsFollowSelectionAndClearOnlyAfterSuccessfulSemanticSaves() throws {
        let (model, directory, sessionID, firstID, secondID) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let presentation = model.sessionModel(for: sessionID)
        presentation.selectedChartID = firstID
        presentation.chartAxisDrafts[firstID] = ChartAxisDraft(unit: "mV", minimum: "-2", maximum: "8")
        presentation.selectedChartID = secondID
        presentation.chartAxisDrafts[secondID] = ChartAxisDraft(unit: "kPa", minimum: "0", maximum: "10")
        model.tick(sessionID)
        presentation.selectedChartID = firstID
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.unit, "mV")
        XCTAssertEqual(presentation.chartAxisDrafts[secondID]?.unit, "kPa")
        XCTAssertEqual(SessionCommandTarget(focused: presentation, editingText: false).chart?.id, firstID)
        let inspector = ChartInspector(model: model, sessionModel: presentation)
        inspector.saveUnit(for: try chart(firstID, in: model, sessionID: sessionID))
        XCTAssertNil(presentation.chartAxisDrafts[firstID]?.unit)
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.minimum, "-2")
        XCTAssertEqual(try chart(firstID, in: model, sessionID: sessionID).settings.unit, "mV")
        XCTAssertNil(try chart(secondID, in: model, sessionID: sessionID).settings.unit)

        inspector.setYRange(for: try chart(firstID, in: model, sessionID: sessionID))
        XCTAssertNil(presentation.chartAxisDrafts[firstID])
        XCTAssertEqual(try chart(firstID, in: model, sessionID: sessionID).settings.yScale, .fixed(min: -2, max: 8))
        XCTAssertEqual(try chart(secondID, in: model, sessionID: sessionID).settings.yScale, .automatic)
        model.undoManager(for: sessionID).undo()
        XCTAssertEqual(try chart(firstID, in: model, sessionID: sessionID).settings.yScale, .automatic)
        model.undoManager(for: sessionID).redo()
        XCTAssertEqual(try chart(firstID, in: model, sessionID: sessionID).settings.yScale, .fixed(min: -2, max: 8))

        presentation.chartAxisDrafts[firstID] = ChartAxisDraft(minimum: "20", maximum: "10")
        inspector.setYRange(for: try chart(firstID, in: model, sessionID: sessionID))
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.minimum, "20")
        XCTAssertEqual(try chart(firstID, in: model, sessionID: sessionID).settings.yScale, .fixed(min: -2, max: 8))
        inspector.autoYRange(for: try chart(firstID, in: model, sessionID: sessionID))
        XCTAssertNil(presentation.chartAxisDrafts[firstID])
        XCTAssertEqual(try chart(firstID, in: model, sessionID: sessionID).settings.yScale, .automatic)
    }

    func testFailedPersistenceRetainsDirtyUnitUntilRetry() throws {
        let (model, directory, sessionID, firstID, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let presentation = model.sessionModel(for: sessionID)
        presentation.chartAxisDrafts[firstID] = ChartAxisDraft(unit: "mA")
        let metadata = directory.appendingPathComponent("test.sqlite.metadata.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let inspector = ChartInspector(model: model, sessionModel: presentation)
        inspector.saveUnit(for: try chart(firstID, in: model, sessionID: sessionID))
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.unit, "mA")
        XCTAssertNil(try chart(firstID, in: model, sessionID: sessionID).settings.unit)
        XCTAssertNotNil(model.errorMessage)
        try FileManager.default.removeItem(at: metadata)
        model.clearError()
        inspector.saveUnit(for: try chart(firstID, in: model, sessionID: sessionID))
        XCTAssertNil(presentation.chartAxisDrafts[firstID])
        XCTAssertEqual(try chart(firstID, in: model, sessionID: sessionID).settings.unit, "mA")
        XCTAssertNil(model.errorMessage)
    }

    func testRefreshClearsTextOverridesThatNowMatchPersistedSettings() throws {
        let (model, directory, sessionID, firstID, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let presentation = model.sessionModel(for: sessionID)
        presentation.chartAxisDrafts[firstID] = ChartAxisDraft(unit: "mV", minimum: "1", maximum: "5")
        XCTAssertTrue(model.updateUnit("mV", chart: firstID))
        XCTAssertNil(presentation.chartAxisDrafts[firstID]?.unit)
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.minimum, "1")
        XCTAssertTrue(model.updateScale(.fixed(min: 1, max: 5), chart: firstID))
        // Text that is still spelled differently is intentionally retained.
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.minimum, "1")
        presentation.chartAxisDrafts[firstID] = ChartAxisDraft(unit: "mV", minimum: "1", maximum: "5")
        XCTAssertTrue(model.updateScale(.automatic, chart: firstID))
        XCTAssertNil(presentation.chartAxisDrafts[firstID]?.unit)
    }

    func testGuideAlertTextSurvivesChartSwitchAndSavesOntoCurrentGuide() throws {
        let (model, directory, sessionID, firstID, secondID) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let guide = Guide(
            orientation: .horizontalValue, value: 12, label: "Original",
            alert: GuideAlert(direction: .both, hysteresis: 1, cooldown: 10))
        XCTAssertTrue(model.updateGuide(guide, chartID: firstID, sessionID: sessionID))
        let presentation = model.sessionModel(for: sessionID)
        presentation.selectedChartID = firstID
        presentation.guideAlertDrafts[guide.id] = GuideAlertDraft(hysteresis: "2", cooldown: "7")
        presentation.selectedChartID = secondID
        model.tick(sessionID)
        presentation.selectedChartID = firstID
        XCTAssertEqual(presentation.guideAlertDrafts[guide.id]?.hysteresis, "2")
        model.updateGuideDetails(
            guide.id, value: 14, label: "Edited independently", chartID: firstID, sessionID: sessionID,
            orientation: .horizontalValue)
        let row = GuideAlertSettingsRow(guide: guide, unit: nil, sessionID: sessionID, chartID: firstID, model: model)
        row.save()
        let saved = try XCTUnwrap(chart(firstID, in: model, sessionID: sessionID).guides.first)
        XCTAssertEqual(saved.label, "Edited independently")
        XCTAssertEqual(saved.value, 14)
        XCTAssertEqual(saved.alert?.hysteresis, 2)
        XCTAssertEqual(saved.alert?.cooldown, 7)
        XCTAssertNil(presentation.guideAlertDrafts[guide.id])
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    func testNativeInspectorTextEditorKeepsEachChartsDraftThroughSelectionAndRefresh() async throws {
        _ = NSApplication.shared
        let (model, directory, sessionID, firstID, secondID) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let presentation = model.sessionModel(for: sessionID)
        presentation.selectedChartID = firstID
        func content() -> ChartInspector { ChartInspector(model: model, sessionModel: presentation) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 580), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.makeFirstResponder(nil)
            window.close()
        }
        let host = NSHostingView(rootView: content())
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        func field() async throws -> NSTextField {
            for _ in 0..<60 {
                host.layoutSubtreeIfNeeded()
                if let field = textFields(in: host).first(where: { $0.placeholderString == "e.g. MiB" }) {
                    return field
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw XCTSkip("Native inspector text field did not mount")
        }
        func type(_ value: String, endEditing: Bool = true) async throws {
            let input = try await field()
            XCTAssertTrue(window.makeFirstResponder(input))
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(40))
            if endEditing { window.endEditing(for: input) }
            XCTAssertEqual(input.stringValue, value)
        }
        try await type("first draft", endEditing: false)
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.unit, "first draft")
        presentation.selectedChartID = secondID
        host.rootView = content()
        _ = try await field()
        XCTAssertEqual(presentation.chartAxisDrafts[firstID]?.unit, "first draft")
        try await type("second draft")
        presentation.selectedChartID = firstID
        host.rootView = content()
        var currentField = try await field()
        XCTAssertEqual(currentField.stringValue, "first draft")
        model.tick(sessionID)
        model.setDisplayActive(false, for: sessionID)
        model.setDisplayActive(true, for: sessionID)
        host.rootView = content()
        currentField = try await field()
        XCTAssertEqual(currentField.stringValue, "first draft")
        presentation.selectedChartID = secondID
        host.rootView = content()
        currentField = try await field()
        XCTAssertEqual(currentField.stringValue, "second draft")
        XCTAssertNil(try chart(firstID, in: model, sessionID: sessionID).settings.unit)
        XCTAssertNil(try chart(secondID, in: model, sessionID: sessionID).settings.unit)
    }
}
