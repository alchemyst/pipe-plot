import AppKit
import SwiftUI

/// Materialize a menu once per opening. SwiftUI may update the button and its
/// builder during capture, but never mutates the NSMenu currently being tracked.
struct SnapshotMenu: NSViewRepresentable {
    let title: String
    var symbol: String? = nil
    var compact = false
    let items: () -> [SnapshotMenuItem]

    func makeNSView(context: Context) -> SnapshotMenuButton {
        let button = SnapshotMenuButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(SnapshotMenuButton.openMenu)
        button.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: SnapshotMenuButton, context: Context) {
        button.title = compact ? "" : title
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        button.imagePosition = compact ? .imageOnly : .imageLeading
        button.setAccessibilityLabel(title)
        button.builder = items
    }
}

enum SnapshotMenuItem {
    case separator
    case command(title: String, enabled: Bool, checked: Bool, action: () -> Void)
    case submenu(title: String, children: [Self])

    static func command(_ title: String, enabled: Bool = true, checked: Bool = false, action: @escaping () -> Void)
        -> Self
    {
        .command(title: title, enabled: enabled, checked: checked, action: action)
    }
    static func submenu(_ title: String, _ children: [Self]) -> Self {
        .submenu(title: title, children: children)
    }

    static func menu(_ entries: [Self]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .command(let title, let enabled, let checked, let action):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                let target = MenuCommand(action)
                item.target = target
                item.action = #selector(MenuCommand.run)
                item.representedObject = target  // NSMenuItem's target is weak.
                menu.addItem(item)
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = !children.isEmpty
                item.submenu = Self.menu(children)
                menu.addItem(item)
            }
        }
        return menu
    }
}

final class SnapshotMenuButton: NSButton {
    var builder: (() -> [SnapshotMenuItem])?
    @objc func openMenu() {
        let menu = SnapshotMenuItem.menu(builder?() ?? [])
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }
}

private final class MenuCommand: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Preserve the legend's secondary-click shortcut with the same snapshot policy.
struct SnapshotContextMenu: NSViewRepresentable {
    let items: () -> [SnapshotMenuItem]
    func makeNSView(context: Context) -> ContextMenuRegion { ContextMenuRegion() }
    func updateNSView(_ view: ContextMenuRegion, context: Context) { view.builder = items }
    static func dismantleNSView(_ view: ContextMenuRegion, coordinator: ()) { view.stopMonitoring() }
}

final class ContextMenuRegion: NSView {
    var builder: (() -> [SnapshotMenuItem])?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window,
                self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            let menu = SnapshotMenuItem.menu(self.builder?() ?? [])
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { stopMonitoring() }
}
