import AppKit
import Observation
import PipePlotCore

@MainActor @Observable
final class SessionUndoMenuState {
    private(set) var revision = 0
    func invalidate() { revision &+= 1 }
}

/// AppKit's view of the store's semantic history. There is deliberately no
/// second stack: failed edits and failed replay cannot advance native history.
@MainActor
final class SessionUndoManager: UndoManager {
    let sessionID: SessionID
    let menuState = SessionUndoMenuState()
    private let store: PipePlotStore
    private let replay: (Bool) -> Void

    init(sessionID: SessionID, store: PipePlotStore, replay: @escaping (Bool) -> Void) {
        self.sessionID = sessionID
        self.store = store
        self.replay = replay
        super.init()
        groupsByEvent = false
        disableUndoRegistration()
    }

    override var canUndo: Bool { store.undoActionName(sessionID: sessionID) != nil }
    override var canRedo: Bool { store.redoActionName(sessionID: sessionID) != nil }
    override var undoActionName: String { store.undoActionName(sessionID: sessionID) ?? "" }
    override var redoActionName: String { store.redoActionName(sessionID: sessionID) ?? "" }
    override var undoMenuItemTitle: String { undoMenuTitle(forUndoActionName: undoActionName) }
    override var redoMenuItemTitle: String { redoMenuTitle(forUndoActionName: redoActionName) }

    override func undo() {
        guard canUndo else { return }
        replay(false)
    }

    override func redo() {
        guard canRedo else { return }
        replay(true)
    }
}

/// SwiftUI's WindowGroup may cache an NSWindow UndoManager before the session
/// delegate is installed. Commands resolve the active session bridge directly.
@MainActor
enum SessionUndoMenuTarget {
    static func manager(for window: NSWindow?) -> UndoManager? {
        guard let window else { return nil }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable {
            return editor.undoManager
        }
        return (window.delegate as? SessionUndoWindowDelegate)?.manager
    }
}
