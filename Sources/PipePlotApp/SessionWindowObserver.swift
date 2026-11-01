import AppKit
import SwiftUI

/// App inactivity is not occlusion: a visible background window still updates.
struct SessionWindowObserver: NSViewRepresentable {
    let onFocus: () -> Void
    let onVisibility: (Bool) -> Void

    func makeNSView(context: Context) -> WindowStateView {
        let view = WindowStateView()
        view.onFocus = onFocus
        view.onVisibility = onVisibility
        return view
    }
    func updateNSView(_ view: WindowStateView, context: Context) {
        view.onFocus = onFocus
        view.onVisibility = onVisibility
    }
    static func dismantleNSView(_ view: WindowStateView, coordinator: ()) { view.stopObserving() }
}

final class WindowStateView: NSView {
    var onFocus: (() -> Void)?
    var onVisibility: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []
    private var lastActive: Bool?

    static func displayIsActive(visible: Bool, miniaturized: Bool, occluded: Bool, appHidden: Bool) -> Bool {
        visible && !miniaturized && !occluded && !appHidden
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                if notification.name == NSWindow.didBecomeKeyNotification { self?.onFocus?() }
                self?.scheduleReport()
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleReport() })
        }
        scheduleReport()
    }

    private func scheduleReport() {
        // Leave SwiftUI's representable update before publishing state. Re-read
        // the window here so rapid hide/reveal notifications cannot apply stale state.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            AcceptanceTrace.record("window-state-visible-\(window.isVisible)-occlusion-\(window.occlusionState.rawValue)-hidden-\(NSApp.isHidden)-appActive-\(NSApp.isActive)")
            let active = Self.displayIsActive(visible: window.isVisible, miniaturized: window.isMiniaturized,
                                              occluded: !window.occlusionState.contains(.visible), appHidden: NSApp.isHidden)
            guard self.lastActive != active else { return }
            self.lastActive = active
            self.onVisibility?(active)
        }
    }

    func stopObserving() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        lastActive = nil
    }
    deinit { stopObserving() }
}
