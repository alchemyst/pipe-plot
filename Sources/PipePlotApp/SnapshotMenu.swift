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

struct SnapshotMenuItem {
    let title: String
    var enabled = true
    var checked = false
    var children: [SnapshotMenuItem]? = nil
    var action: (() -> Void)? = nil
    static var separator: Self { .init(title: "-") }

    static func command(_ title: String, enabled: Bool = true, checked: Bool = false, action: @escaping () -> Void) -> Self {
        .init(title: title, enabled: enabled, checked: checked, action: action)
    }
    static func submenu(_ title: String, _ children: [Self]) -> Self {
        .init(title: title, enabled: !children.isEmpty, children: children)
    }

    static func menu(_ entries: [Self]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.title == "-", entry.action == nil, entry.children == nil { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            if let children = entry.children { item.submenu = Self.menu(children) }
            if let action = entry.action {
                let target = MenuCommand(action)
                item.target = target
                item.action = #selector(MenuCommand.run)
                item.representedObject = target // NSMenuItem's target is weak.
            }
            menu.addItem(item)
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
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            let menu = SnapshotMenuItem.menu(self.builder?() ?? [])
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }
    func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stopMonitoring() }
}
