import AppKit
import SwiftUI
import XCTest
import PipePlotCore
@testable import PipePlotApp

@MainActor
final class ChartPresentationTests: XCTestCase {
    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testGuideModeSwitchAndDraftSurviveLiveRefreshWithoutCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let guide = Guide(orientation: .horizontalValue, value: 10, label: "Original")
        model.updateGuide(guide, chartID: ready.chartID, sessionID: ready.sessionID)
        model.refreshAll()

        var presentation = ChartGuidePresentation(.manage, calendar: utc)
        XCTAssertEqual(presentation.mode, .list)
        presentation.beginAdding()
        presentation.value = "20"
        presentation.label = "Unsaved"
        XCTAssertEqual(presentation.mode, .addValue)
        _ = try model.store.append(SampleRow(values: [1]), to: ready.attachmentID)
        model.refreshAll()
        XCTAssertEqual(presentation.value, "20")
        XCTAssertEqual(presentation.label, "Unsaved")
        XCTAssertEqual(presentation.mode, .addValue)
        presentation.back()
        XCTAssertEqual(presentation.mode, .list)
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].guides, [guide])

        presentation.beginEditing(guide, calendar: utc)
        XCTAssertEqual(presentation.mode, .edit(guide))
        presentation.value = "25"
        presentation.label = "Edited draft"
        _ = try model.store.append(SampleRow(values: [2]), to: ready.attachmentID)
        model.refreshAll()
        XCTAssertEqual(presentation.value, "25")
        XCTAssertEqual(presentation.label, "Edited draft")
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].guides, [guide])
        presentation.back()
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].guides, [guide])

        presentation.beginEditing(guide, calendar: utc)
        presentation.value = "25"
        presentation.label = "Saved"
        model.updateGuideDetails(
            guide.id, value: try XCTUnwrap(Double(presentation.value)), label: presentation.label,
            chartID: ready.chartID, sessionID: ready.sessionID, orientation: guide.orientation)
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].guides.first?.value, 25)
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].guides.first?.label, "Saved")
    }

    func testTimeGuideDraftRoundTripsBeforeUnixEpoch() throws {
        let guide = Guide(orientation: .verticalTime, value: -0.5, label: "Before epoch")
        let presentation = ChartGuidePresentation(.edit(guide), calendar: utc)
        XCTAssertEqual(presentation.mode, .edit(guide))
        XCTAssertEqual(presentation.seconds, "59.500")
        XCTAssertEqual(try XCTUnwrap(presentation.timeValue(calendar: utc)), -0.5, accuracy: 0.000_001)
        var invalid = presentation
        invalid.seconds = "60"
        XCTAssertNil(invalid.timeValue(calendar: utc))

        let carried = Guide(orientation: .verticalTime, value: 59.9996)
        let carriedDraft = ChartGuidePresentation(.edit(carried), calendar: utc)
        XCTAssertEqual(carriedDraft.seconds, "0.000")
        XCTAssertEqual(try XCTUnwrap(carriedDraft.timeValue(calendar: utc)), 60, accuracy: 0.000_001)
    }

    func testForecastTargetRequestKeepsStreamAndTrainingSelectionTogether() {
        let stream = StreamDescriptor(id: UUID(), name: "Training")
        let selection = TimeSelection(
            start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20))
        let request = ForecastTargetRequest(stream: stream, selection: selection)
        XCTAssertEqual(request.stream, stream)
        XCTAssertEqual(request.selection, selection)
    }

    func testNativeGuideDraftSurvivesSampleRefreshAndOcclusionWithoutSave() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("native.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let guide = Guide(orientation: .horizontalValue, value: 10, label: "Original")
        model.updateGuide(guide, chartID: ready.chartID, sessionID: ready.sessionID)
        model.refreshAll()
        let request = GuideSheetRequest(route: .edit(guide))
        func content() -> ChartGuideManager {
            ChartGuideManager(
                request: request, chartID: ready.chartID, sessionID: ready.sessionID, model: model, close: {})
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: content())
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<50 where textFields(in: host).first(where: { $0.placeholderString == "Value" }) == nil {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        let field = try XCTUnwrap(textFields(in: host).first { $0.placeholderString == "Value" })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("42", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(field.stringValue, "42")
        window.endEditing(for: field)
        XCTAssertEqual(field.stringValue, "42")
        _ = try model.store.append(SampleRow(values: [1]), to: ready.attachmentID)
        model.refreshAll()
        host.rootView = content()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(textFields(in: host).first { $0.placeholderString == "Value" }?.stringValue, "42")
        model.setDisplayActive(false, for: ready.sessionID)
        model.setDisplayActive(true, for: ready.sessionID)
        host.rootView = content()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(textFields(in: host).first { $0.placeholderString == "Value" }?.stringValue, "42")
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].guides.first, guide)
    }
}
