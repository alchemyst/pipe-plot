import AppKit
import SwiftUI
import XCTest
import PipePlotCore
@testable import PipePlotApp

@MainActor private final class WindowResizeDelegate: NSObject, NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {}
}

@MainActor private struct UndoEnvironmentProbe: View {
    @Environment(\.undoManager) private var manager
    @State private var value = ""
    @FocusState private var focused: Bool
    let report: (UndoManager?) -> Void
    var body: some View {
        TextField("Undo probe", text: $value)
            .focused($focused)
            .onAppear {
                report(manager)
                DispatchQueue.main.async { focused = true }
            }
    }
}

@MainActor final class SessionUndoManagerTests: XCTestCase {
    private func makeModel() -> (PipePlotAppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite")), directory)
    }

    func testNativeNamesTrackOutsideFocusEditsAndOneStepCompoundForecastTarget() throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let manager = model.undoManager(for: ready.sessionID)
        XCTAssertTrue(manager === model.undoManager(for: ready.sessionID))
        XCTAssertFalse(manager.canUndo)
        let selection = TimeSelection(
            start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20))
        XCTAssertThrowsError(
            try model.store.createForecastTarget(
                value: .infinity, streamID: ready.streams[0].id, selection: selection))
        XCTAssertFalse(manager.canUndo)
        _ = try model.store.createForecastTarget(value: 10, streamID: ready.streams[0].id, selection: selection)
        XCTAssertEqual(manager.undoActionName, "Create Forecast Target")
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Create Forecast Target")
        manager.undo()
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.count, 0)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.timeline.forecasts.count, 0)
        XCTAssertEqual(manager.redoMenuItemTitle, "Redo Create Forecast Target")
        manager.redo()
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.charts[0].guides.count, 1)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.timeline.forecasts.count, 1)
    }

    func testReassociationIsOneNamedSemanticUndoGroup() throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try model.store.registerSampler(
            intent: .target, sampler: SamplerIntent(columnCount: 1, requestedNames: ["old"]))
        try model.store.append(SampleRow(values: [1]), to: old.attachmentID)
        try model.store.finishAttachment(old.attachmentID, reason: .eof)
        let incoming = try model.store.registerSampler(
            intent: .target, sampler: SamplerIntent(columnCount: 1, requestedNames: ["new"]))
        let manager = model.undoManager(for: old.sessionID)
        try model.store.reassociateStreams([incoming.streams[0].id], to: [old.streams[0].id])
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Reassociate Streams")
        manager.undo()
        XCTAssertEqual(manager.redoMenuItemTitle, "Redo Reassociate Streams")
        XCTAssertNotNil(
            try model.store.snapshot(sessionID: old.sessionID)?.charts[0].streams.first {
                $0.id == incoming.streams[0].id
            })
        manager.redo()
        XCTAssertNil(
            try model.store.snapshot(sessionID: old.sessionID)?.charts[0].streams.first {
                $0.id == incoming.streams[0].id
            })
    }

    func testGuideAndChartActionNamesReflectTheEdit() throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try model.store.createSession()
        let manager = model.undoManager(for: session.id)
        let chartID = try XCTUnwrap(session.charts.first?.id)
        var guide = Guide(orientation: .horizontalValue, value: 1)
        try model.store.upsertGuide(guide, chartID: chartID)
        XCTAssertEqual(manager.undoActionName, "Add Guide")
        guide.value = 2
        try model.store.upsertGuide(guide, chartID: chartID)
        XCTAssertEqual(manager.undoActionName, "Edit Guide")
        try model.store.removeGuide(guide.id, chartID: chartID)
        XCTAssertEqual(manager.undoActionName, "Delete Guide")
        let timeGuide = Guide(orientation: .verticalTime, value: 10)
        try model.store.upsertTimeGuide(timeGuide, sessionID: session.id)
        XCTAssertEqual(manager.undoActionName, "Add Time Guide")
        try model.store.removeTimeGuide(timeGuide.id, sessionID: session.id)
        XCTAssertEqual(manager.undoActionName, "Delete Time Guide")
        let second = try model.store.createChart(in: session.id, after: chartID)
        try model.store.deleteChart(second.id)
        XCTAssertEqual(manager.undoActionName, "Hide Chart")
        try model.store.restoreChart(second.id)
        XCTAssertEqual(manager.undoActionName, "Restore Chart")
    }

    func testFailedPersistenceDoesNotAdvanceBridgeOrDomainHistory() throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try model.store.createSession()
        let manager = model.undoManager(for: session.id)
        try model.store.renameSession(session.id, to: "Before")
        let metadata = directory.appendingPathComponent("test.sqlite.metadata.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.store.renameSession(session.id, to: "Failed"))
        XCTAssertEqual(manager.undoActionName, "Rename Session")
        manager.undo()
        XCTAssertEqual(try model.store.snapshot(sessionID: session.id)?.title, "Before")
        XCTAssertEqual(manager.undoActionName, "Rename Session")
        XCTAssertFalse(manager.canRedo)
        try FileManager.default.removeItem(at: metadata)
        manager.undo()
        XCTAssertEqual(try model.store.snapshot(sessionID: session.id)?.title, "Session 1")
        XCTAssertTrue(manager.canRedo)
        try model.store.renameSession(session.id, to: "Session 1")
        XCTAssertTrue(manager.canRedo)
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        manager.redo()
        XCTAssertEqual(try model.store.snapshot(sessionID: session.id)?.title, "Session 1")
        XCTAssertTrue(manager.canRedo)
        try FileManager.default.removeItem(at: metadata)
        manager.redo()
        XCTAssertEqual(try model.store.snapshot(sessionID: session.id)?.title, "Before")
        XCTAssertFalse(manager.canRedo)
    }

    func testIndependentSessionManagersSurviveCloseAndTrashRestore() throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try model.store.createSession(), b = try model.store.createSession()
        let first = model.undoManager(for: a.id), second = model.undoManager(for: b.id)
        try model.store.renameSession(a.id, to: "A")
        try model.store.renameSession(b.id, to: "B")
        first.undo()
        XCTAssertEqual(try model.store.snapshot(sessionID: a.id)?.title, "Session 1")
        XCTAssertEqual(try model.store.snapshot(sessionID: b.id)?.title, "B")
        model.windowClosed(a.id)
        model.openSession(a.id)
        XCTAssertTrue(first === model.undoManager(for: a.id))
        first.redo()
        XCTAssertEqual(try model.store.snapshot(sessionID: a.id)?.title, "A")
        model.deleteSession(a.id)
        XCTAssertEqual(first.undoActionName, "Delete Session")
        model.restoreSession(a.id)
        XCTAssertEqual(first.undoActionName, "Restore Session")
        first.undo()
        XCTAssertTrue(try XCTUnwrap(model.store.snapshot(sessionID: a.id)).isDeleted)
        first.redo()
        XCTAssertFalse(try XCTUnwrap(model.store.snapshot(sessionID: a.id)).isDeleted)
        second.undo()
        XCTAssertEqual(try model.store.snapshot(sessionID: b.id)?.title, "Session 2")
    }

    func testBridgeUsesCoreTwoHundredActionRetention() throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try model.store.createSession()
        let manager = model.undoManager(for: session.id)
        for i in 1...205 { try model.store.renameSession(session.id, to: "Name \(i)") }
        for _ in 0..<200 {
            XCTAssertEqual(manager.undoActionName, "Rename Session")
            manager.undo()
        }
        XCTAssertFalse(manager.canUndo)
        XCTAssertEqual(try model.store.snapshot(sessionID: session.id)?.title, "Name 5")
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(try model.store.snapshot(sessionID: session.id)?.title, "Name 6")
    }

    func testResponderRoutesEachWindowAndRestoresOriginalChain() throws {
        _ = NSApplication.shared
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try model.store.createSession(), b = try model.store.createSession()
        try model.store.renameSession(a.id, to: "A")
        try model.store.renameSession(b.id, to: "B")
        let windows = [a.id, b.id].map { id -> (NSWindow, WindowStateView, WindowResizeDelegate) in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let originalDelegate = WindowResizeDelegate()
            window.delegate = originalDelegate
            let host = NSView(frame: window.contentView!.bounds)
            window.contentView = host
            let state = WindowStateView(frame: .zero)
            state.sessionUndoManager = model.undoManager(for: id)
            host.addSubview(state)
            state.installUndoManager()
            return (window, state, originalDelegate)
        }
        defer { windows.forEach { $0.0.close() } }
        for (index, id) in [a.id, b.id].enumerated() {
            let (window, state, originalDelegate) = windows[index]
            window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(window.undoManager === model.undoManager(for: id))
            let bridgeDelegate = try XCTUnwrap(window.delegate as? SessionUndoWindowDelegate)
            let resizeSelector = NSSelectorFromString("windowDidResize:")
            XCTAssertTrue(bridgeDelegate.responds(to: resizeSelector))
            XCTAssertTrue((bridgeDelegate.forwardingTarget(for: resizeSelector) as AnyObject?) === originalDelegate)
            XCTAssertEqual(window.undoManager?.undoMenuItemTitle, "Undo Rename Session")
            let menu = NSMenu(title: "Edit")
            let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
            undoItem.keyEquivalentModifierMask = [.command]
            undoItem.target = window
            menu.addItem(undoItem)
            XCTAssertTrue(window.validateMenuItem(undoItem))
            XCTAssertTrue(menu.performKeyEquivalent(with: try keyEvent("z", modifiers: [.command], window: window)))
            XCTAssertEqual(try model.store.snapshot(sessionID: id)?.title, index == 0 ? "Session 1" : "Session 2")
            XCTAssertFalse(window.validateMenuItem(undoItem))
            XCTAssertTrue(model.undoManager(for: id).canRedo)
            let redoItem = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
            redoItem.keyEquivalentModifierMask = [.command, .shift]
            redoItem.target = window
            let redoMenu = NSMenu(title: "Edit")
            redoMenu.addItem(redoItem)
            XCTAssertTrue(window.validateMenuItem(redoItem))
            XCTAssertTrue(
                redoMenu.performKeyEquivalent(with: try keyEvent("Z", modifiers: [.command, .shift], window: window)))
            XCTAssertEqual(try model.store.snapshot(sessionID: id)?.title, index == 0 ? "A" : "B")
            XCTAssertTrue(window.validateMenuItem(undoItem))
            state.stopObserving()
            XCTAssertTrue(window.delegate === originalDelegate)
        }
    }

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
    }

    func testNativeFieldEditorKeepsTextUndoLocal() throws {
        _ = NSApplication.shared
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try model.store.createSession()
        try model.store.renameSession(session.id, to: "Semantic")
        let manager = model.undoManager(for: session.id)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView = host
        let state = WindowStateView(frame: .zero)
        state.sessionUndoManager = manager
        host.addSubview(state)
        state.installUndoManager()
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        host.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.allowsUndo = true
        XCTAssertFalse(editor.undoManager === manager)
        editor.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(field.stringValue, "typed")
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(window.validateMenuItem(undoItem))
        XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(try model.store.snapshot(sessionID: session.id)?.title, "Semantic")
        XCTAssertEqual(manager.undoActionName, "Rename Session")
    }

    func testSwiftUIEnvironmentReceivesSessionManager() throws {
        _ = NSApplication.shared
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try model.store.createSession()
        let manager = model.undoManager(for: session.id)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var observed: UndoManager?
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content
        let host = NSHostingView(rootView: UndoEnvironmentProbe { observed = $0 })
        host.frame = content.bounds
        content.addSubview(host)
        let state = WindowStateView(frame: .zero)
        state.sessionUndoManager = manager
        content.addSubview(state)
        state.installUndoManager()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while (observed !== manager || !(window.firstResponder is NSTextView)) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(observed === manager)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(editor.undoManager === manager)
        editor.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "typed")
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(window.validateMenuItem(undoItem))
        XCTAssertTrue(window.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        XCTAssertEqual(editor.string, "")
    }
}
