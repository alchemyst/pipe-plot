import AppKit
import PipePlotCore

/// AppKit's view of the store's semantic history. There is deliberately no
/// second stack: failed edits and failed replay cannot advance native history.
@MainActor
final class SessionUndoManager: UndoManager {
    let sessionID: SessionID
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
