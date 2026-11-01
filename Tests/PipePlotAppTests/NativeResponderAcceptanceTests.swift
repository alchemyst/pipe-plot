import AppKit
import XCTest
import PipePlotCore
@testable import PipePlotApp

/// Isolated native-responder integration, not external desktop input automation.
@MainActor final class NativeResponderAcceptanceTests: XCTestCase {
    func testGuideDragEscapePreservesRedoAndReleaseCommitsOnceWithLaterSamples() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        var guide = Guide(orientation: .horizontalValue, value: 100, label: "Native responder")
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        guide.value = 120; try model.store.upsertGuide(guide, chartID: ready.chartID)
        model.undo(ready.sessionID); guide.value = 100
        let redo = model.store.redoActionName(sessionID: ready.sessionID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PlotInteractionView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        window.contentView = view
        defer { window.close() }
        var preview: Guide?, phases: [PlotGesturePhase] = []
        view.update(guides: [guide], selectionRange: nil, selectionMode: nil, now: Date(), plotBounds: CGRect(x: 50, y: 20, width: 700, height: 240),
                    timeAtX: { Date(timeIntervalSince1970: Double($0)) }, valueAtY: { Double($0) },
                    xAtTime: { CGFloat($0.timeIntervalSince1970) }, yAtValue: { CGFloat($0) },
                    onGuide: { changed, phase in
                        phases.append(phase)
                        switch phase {
                        case .began, .changed: preview = changed
                        case .cancelled: preview = nil
                        case .ended: model.updateGuide(changed, chartID: ready.chartID, sessionID: ready.sessionID); preview = nil
                        }
                    }, onSelection: { _,_,_,_,_ in }, onPan: { _,_ in }, onZoom: { _,_,_ in }, onHover: { _ in },
                    onBackgroundClick: {}, onBackgroundDoubleClick: { _ in }, onGuideSelected: { _ in }, onSelectionModeToggle: { _ in })
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, 200, 100))
        view.mouseDragged(with: try event(.leftMouseDragged, 200, 130))
        XCTAssertEqual(preview?.value, 130)
        // Escape is AppKit's cancelOperation responder action. Invoke it between
        // native down/drag/up events so ordering is deterministic.
        view.cancelOperation(nil)
        view.mouseUp(with: try event(.leftMouseUp, 200, 130))
        XCTAssertNil(preview)
        XCTAssertEqual(phases, [.changed, .cancelled])
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.first?.value, 100)
        XCTAssertEqual(model.store.redoActionName(sessionID: ready.sessionID), redo)
        model.redo(ready.sessionID)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.first?.value, 120)
        model.undo(ready.sessionID)
        phases.removeAll()
        view.mouseDown(with: try event(.leftMouseDown, 200, 100))
        for value in [110.0,120,130,140] { view.mouseDragged(with: try event(.leftMouseDragged, 200, value)) }
        try model.store.append(SampleRow(values: [7]), to: ready.attachmentID)
        view.mouseUp(with: try event(.leftMouseUp, 200, 140))
        XCTAssertEqual(phases, [.changed,.changed,.changed,.changed,.ended])
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.first?.value, 140)
        model.undo(ready.sessionID)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.first?.value, 100)
        XCTAssertEqual(try model.store.samples.query(streamID: ready.streams[0].id).map(\.value), [7])
        print("NATIVE_RESPONDER guideEscape=preservedRedo guideRelease=singleUndo laterSamples=retained")
    }
}
