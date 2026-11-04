import AppKit
import XCTest
import PipePlotCore
@testable import PipePlotApp

/// Isolated native-responder integration, not external desktop input automation.
@MainActor final class NativeResponderAcceptanceTests: XCTestCase {
    func testRulerDragsPreserveTheGrabPointAndKeepResizeSeparateFromMove() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 78), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let view = PlotInteractionView(frame: NSRect(x: 0, y: 0, width: 600, height: 78))
        window.contentView = view
        defer { window.close() }

        let time: (CGFloat) -> Date = { Date(timeIntervalSince1970: Double($0)) }
        let marker = Guide(orientation: .verticalTime, value: 230, label: "Marker")
        let initial = time(160)...time(300)
        var selectionUpdates: [(ClosedRange<Date>, PlotSelectionEdge?, PlotGesturePhase)] = []
        var guideUpdates: [(Double, PlotGesturePhase)] = []
        var cleared = false
        view.guideHitRects = [marker.id: CGRect(x: 230, y: 23, width: 100, height: 14)]
        view.selectionBar = CGRect(x: 84, y: 56, width: 488, height: 16)
        view.update(
            guides: [marker], selectionRange: initial, selectionMode: .fixed, now: time(550),
            plotBounds: CGRect(x: 84, y: 23, width: 488, height: 49),
            timeAtX: time, valueAtY: { _ in 0 }, xAtTime: { CGFloat($0.timeIntervalSince1970) }, yAtValue: { _ in 0 },
            onGuide: { guideUpdates.append(($0.value, $1)) },
            onSelection: { start, end, edge, _, phase in selectionUpdates.append((start...end, edge, phase)) },
            onPan: { _, _ in }, onZoom: { _, _, _ in }, onHover: { _ in },
            onBackgroundClick: { cleared = true }, onBackgroundDoubleClick: { _ in }, onGuideSelected: { _ in },
            onSelectionModeToggle: { _ in })

        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        // The bar remains draggable directly below a time marker.
        view.mouseDown(with: try event(.leftMouseDown, 230, 64))
        view.mouseUp(with: try event(.leftMouseUp, 230, 64))
        XCTAssertFalse(cleared)
        XCTAssertTrue(selectionUpdates.isEmpty)
        view.mouseDown(with: try event(.leftMouseDown, 230, 64))
        view.mouseDragged(with: try event(.leftMouseDragged, 260, 64))
        view.mouseUp(with: try event(.leftMouseUp, 270, 64))
        XCTAssertEqual(selectionUpdates.map(\.0), [time(190)...time(330), time(200)...time(340)])
        XCTAssertEqual(selectionUpdates.map(\.2), [.changed, .ended])
        XCTAssertTrue(guideUpdates.isEmpty)

        selectionUpdates.removeAll()
        // Grabbing inside the triangle leaves the opposite boundary fixed.
        view.mouseDown(with: try event(.leftMouseDown, 164, 64))
        view.mouseDragged(with: try event(.leftMouseDragged, 184, 64))
        view.mouseUp(with: try event(.leftMouseUp, 184, 64))
        XCTAssertEqual(selectionUpdates.map(\.0), [time(180)...time(300), time(180)...time(300)])
        XCTAssertEqual(selectionUpdates.map(\.1), [.start, .start])

        // The flag is picked up 50 points from its stem. Keep that offset through mouse-up.
        view.mouseDown(with: try event(.leftMouseDown, 280, 28))
        view.mouseDragged(with: try event(.leftMouseDragged, 290, 28))
        view.mouseUp(with: try event(.leftMouseUp, 305, 28))
        XCTAssertEqual(guideUpdates.map(\.0), [240, 255])
        XCTAssertEqual(guideUpdates.map(\.1), [.changed, .ended])
    }

    func testPlotCollapseCancelsSelectionDragAndSkipsCoordinateTransforms() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 210), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let view = PlotInteractionView(frame: NSRect(x: 0, y: 0, width: 400, height: 210))
        window.contentView = view
        defer { window.close() }

        let initial = Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 200)
        var phases: [PlotGesturePhase] = []
        var hover: Date?
        var transforms = 0
        let didClear = expectation(description: "Cleared hover on collapse")
        func layout(width: CGFloat) {
            view.update(
                guides: [], selectionRange: initial, selectionMode: .fixed, now: Date(timeIntervalSince1970: 400),
                plotBounds: CGRect(x: 56, y: 4, width: width, height: 188),
                timeAtX: {
                    transforms += 1
                    return Date(timeIntervalSince1970: Double($0))
                }, valueAtY: { _ in 0 }, xAtTime: { CGFloat($0.timeIntervalSince1970) }, yAtValue: { _ in 0 },
                onGuide: { _, _ in },
                onSelection: { _, _, _, _, phase in phases.append(phase) },
                onPan: { _, _ in XCTFail("Unexpected pan") },
                onZoom: { _, _, _ in XCTFail("Unexpected zoom") },
                onHover: {
                    hover = $0
                    if $0 == nil { didClear.fulfill() }
                },
                onBackgroundClick: { XCTFail("Unexpected clear-selection action") },
                onBackgroundDoubleClick: { _ in XCTFail("Unexpected locator action") },
                onGuideSelected: { _ in }, onSelectionModeToggle: { _ in })
        }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(NSPoint(x: x, y: 100), to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
        }

        layout(width: 344)
        view.mouseDown(with: try event(.leftMouseDown, x: 250))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 270))
        XCTAssertEqual(phases, [.began, .changed])
        XCTAssertNotNil(hover)

        layout(width: 0)
        let beforeCollapse = transforms
        view.mouseMoved(with: try event(.mouseMoved, x: 250))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 280))
        view.mouseUp(with: try event(.leftMouseUp, x: 280))
        view.mouseDown(with: try event(.leftMouseDown, x: 250))
        await fulfillment(of: [didClear], timeout: 1)
        XCTAssertEqual(transforms, beforeCollapse)
        XCTAssertEqual(phases, [.began, .changed, .cancelled])
        XCTAssertNil(hover)

        layout(width: 344)
        view.mouseMoved(with: try event(.mouseMoved, x: 175))
        XCTAssertEqual(hover, Date(timeIntervalSince1970: 175))
        XCTAssertEqual(phases, [.began, .changed, .cancelled])
    }

    func testGuideDragEscapePreservesRedoAndReleaseCommitsOnceWithLaterSamples() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        var guide = Guide(orientation: .horizontalValue, value: 100, label: "Native responder")
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        guide.value = 120
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        model.undo(ready.sessionID)
        guide.value = 100
        let redo = model.store.redoActionName(sessionID: ready.sessionID)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let view = PlotInteractionView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        window.contentView = view
        defer { window.close() }
        var preview: Guide?, phases: [PlotGesturePhase] = []
        view.update(
            guides: [guide], selectionRange: nil, selectionMode: nil, now: Date(),
            plotBounds: CGRect(x: 50, y: 20, width: 700, height: 240),
            timeAtX: { Date(timeIntervalSince1970: Double($0)) }, valueAtY: { Double($0) },
            xAtTime: { CGFloat($0.timeIntervalSince1970) }, yAtValue: { CGFloat($0) },
            onGuide: { changed, phase in
                phases.append(phase)
                switch phase {
                case .began, .changed: preview = changed
                case .cancelled: preview = nil
                case .ended:
                    model.updateGuide(changed, chartID: ready.chartID, sessionID: ready.sessionID)
                    preview = nil
                }
            }, onSelection: { _, _, _, _, _ in }, onPan: { _, _ in }, onZoom: { _, _, _ in }, onHover: { _ in },
            onBackgroundClick: {}, onBackgroundDoubleClick: { _ in }, onGuideSelected: { _ in },
            onSelectionModeToggle: { _ in })
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
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
        for value in [110.0, 120, 130, 140] { view.mouseDragged(with: try event(.leftMouseDragged, 200, value)) }
        try model.store.append(SampleRow(values: [7]), to: ready.attachmentID)
        view.mouseUp(with: try event(.leftMouseUp, 200, 140))
        XCTAssertEqual(phases, [.changed, .changed, .changed, .changed, .ended])
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.first?.value, 140)
        model.undo(ready.sessionID)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.first?.value, 100)
        XCTAssertEqual(try model.store.samples.query(streamID: ready.streams[0].id).map(\.value), [7])
        print("NATIVE_RESPONDER guideEscape=preservedRedo guideRelease=singleUndo laterSamples=retained")
    }
}
