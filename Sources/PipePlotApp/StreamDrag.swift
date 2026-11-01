import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import PipePlotCore

/// The payload is private to the running app. Plain text (including a UUID)
/// must never advertise a move or light up a destination.
@MainActor @Observable
final class StreamDragState {
    static let contentType = UTType(exportedAs: "com.cactusdynamics.pipeplot.stream", conformingTo: .data)
    static let pasteboardType = contentType.identifier
    private(set) var streamID: StreamID?
    var target: StreamDropTarget?

    func begin(_ id: StreamID) { streamID = id; target = nil }
    func end() { streamID = nil; target = nil }
}

struct StreamDropTarget: Equatable {
    let sessionID: SessionID
    var onto: ChartID? = nil
    var before: ChartID? = nil
    var after: ChartID? = nil

    @MainActor func accepts(_ model: PipePlotAppModel) -> Bool {
        guard let id = model.streamDrag.streamID else { return false }
        return model.canDropStream([id.uuidString], sessionID: sessionID, onto: onto, before: before, after: after)
    }

    @MainActor func isTargeted(_ model: PipePlotAppModel) -> Bool {
        model.streamDrag.target == self && accepts(model)
    }
}

struct StreamDropDelegate: DropDelegate {
    let target: StreamDropTarget
    let model: PipePlotAppModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [StreamDragState.pasteboardType]) && target.accepts(model)
    }
    func dropEntered(info: DropInfo) {
        model.streamDrag.target = validateDrop(info: info) ? target : nil
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let valid = validateDrop(info: info)
        model.streamDrag.target = valid ? target : nil
        return DropProposal(operation: valid ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) {
        if model.streamDrag.target == target { model.streamDrag.target = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        defer { model.streamDrag.end() }
        guard validateDrop(info: info), let id = model.streamDrag.streamID else { return false }
        return model.dropStream([id.uuidString], sessionID: target.sessionID,
                                onto: target.onto, before: target.before, after: target.after)
    }
}

/// A dedicated native handle avoids competing with horizontal legend scrolling
/// and the menu button. AppKit reports every end, including Escape/outside drops.
struct StreamDragHandle: NSViewRepresentable {
    let stream: StreamDescriptor
    let state: StreamDragState

    func makeNSView(context: Context) -> StreamDragHandleView { StreamDragHandleView() }
    func updateNSView(_ view: StreamDragHandleView, context: Context) {
        view.stream = stream
        view.state = state
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Drag \(stream.name) to move to a chart or insert a new chart")
        view.toolTip = "Drag \(stream.name) onto a chart to merge, or onto a separator to insert a chart"
    }
}

final class StreamDragHandleView: NSView, NSDraggingSource {
    var stream: StreamDescriptor?
    var state: StreamDragState?
    private var mouseDownPoint: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for offset in [-4.0, 0.0, 4.0] {
            path.move(to: NSPoint(x: 3, y: bounds.midY + offset))
            path.line(to: NSPoint(x: bounds.width - 3, y: bounds.midY + offset))
        }
        path.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, let stream, let state,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 3 else { return }
        mouseDownPoint = nil
        let payload = NSPasteboardItem()
        payload.setString(stream.id.uuidString, forType: NSPasteboard.PasteboardType(StreamDragState.pasteboardType))
        let item = NSDraggingItem(pasteboardWriter: payload)
        let label = NSAttributedString(string: stream.name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        let size = NSSize(width: label.size().width + 20, height: 30)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            label.draw(at: NSPoint(x: 10, y: 7))
            return true
        }
        item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: size), contents: image)
        state.begin(stream.id)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        state?.end()
    }
}
