import AppKit
import SwiftUI

/// App inactivity is not occlusion: a visible background window still updates.
struct SessionWindowObserver: NSViewRepresentable {
    let onFocus: () -> Void
    let onVisibility: (Bool) -> Void
    let sessionUndoManager: SessionUndoManager

    func makeNSView(context: Context) -> WindowStateView {
        let view = WindowStateView()
        view.onFocus = onFocus
        view.onVisibility = onVisibility
        view.sessionUndoManager = sessionUndoManager
        return view
    }
    func updateNSView(_ view: WindowStateView, context: Context) {
        view.onFocus = onFocus
        view.onVisibility = onVisibility
        view.sessionUndoManager = sessionUndoManager
        view.installUndoManager()
    }
    static func dismantleNSView(_ view: WindowStateView, coordinator: ()) { view.stopObserving() }
}

final class WindowStateView: NSView {
    var onFocus: (() -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var sessionUndoManager: SessionUndoManager?
    private weak var undoWindow: NSWindow?
    private var undoDelegate: SessionUndoWindowDelegate?
    private var tokens: [NSObjectProtocol] = []
    private var lastActive: Bool?

    static func displayIsActive(visible: Bool, miniaturized: Bool, occluded: Bool, appHidden: Bool) -> Bool {
        visible && !miniaturized && !occluded && !appHidden
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        installUndoManager()
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ] {
            tokens.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let becameKey = notification.name == NSWindow.didBecomeKeyNotification
                    // NotificationCenter executes this observer on the supplied main queue.
                    MainActor.assumeIsolated {
                        if becameKey { self?.onFocus?() }
                        self?.scheduleReport()
                    }
                })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // The observer queue is main, including when posted by a worker.
                    MainActor.assumeIsolated { self?.scheduleReport() }
                }
            )
        }
        scheduleReport()
    }

    private func scheduleReport() {
        // Leave SwiftUI's representable update before publishing state. Re-read
        // the window here so rapid hide/reveal notifications cannot apply stale state.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            AcceptanceTrace.record(
                "window-state-visible-\(window.isVisible)-occlusion-\(window.occlusionState.rawValue)-hidden-\(NSApp.isHidden)-appActive-\(NSApp.isActive)"
            )
            let active = Self.displayIsActive(
                visible: window.isVisible, miniaturized: window.isMiniaturized,
                occluded: !window.occlusionState.contains(.visible), appHidden: NSApp.isHidden)
            guard self.lastActive != active else { return }
            self.lastActive = active
            self.onVisibility?(active)
        }
    }

    func stopObserving() {
        if let undoWindow, let undoDelegate, undoWindow.delegate === undoDelegate {
            undoWindow.delegate = undoDelegate.previous
        }
        undoWindow = nil
        undoDelegate = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        lastActive = nil
    }
    isolated deinit { stopObserving() }

    func installUndoManager() {
        guard let window, let sessionUndoManager else { return }
        if undoWindow === window, undoDelegate?.manager === sessionUndoManager,
            window.delegate === undoDelegate
        {
            return
        }
        if let undoWindow, let undoDelegate, undoWindow.delegate === undoDelegate {
            undoWindow.delegate = undoDelegate.previous
        }
        let delegate = SessionUndoWindowDelegate(manager: sessionUndoManager, previous: window.delegate)
        window.delegate = delegate
        undoWindow = window
        undoDelegate = delegate
    }
}

/// Returns the same semantic manager when the window itself owns the responder
/// action. Other window delegate callbacks continue to the scene's delegate.
@MainActor
final class SessionUndoWindowDelegate: NSObject, NSWindowDelegate {
    let manager: SessionUndoManager
    // AppKit invokes window delegate selectors on the main thread. NSObject's
    // forwarding overrides are nonisolated, so this weak reference is the only
    // field they read outside Swift's actor model; it is assigned only at init.
    nonisolated(unsafe) private(set) weak var previous: (any NSWindowDelegate)?
    init(manager: SessionUndoManager, previous: (any NSWindowDelegate)?) {
        self.manager = manager
        self.previous = previous
        super.init()
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { manager }
    override nonisolated func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return (previous as? NSObject)?.responds(to: aSelector) == true
    }
    override nonisolated func forwardingTarget(for aSelector: Selector!) -> Any? { previous }
}
