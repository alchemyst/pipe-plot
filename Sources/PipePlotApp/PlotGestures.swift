import SwiftUI
import AppKit
import PipePlotCore

/// Drop this transparent overlay over a plot canvas and provide the plot's
/// coordinate transforms. It owns native mouse, trackpad, guide, selection,
/// and pan gestures; rendering and model commits stay with the caller.
struct PlotInteractionOverlay: NSViewRepresentable {
    let guides: [Guide]
    let selectionRange: ClosedRange<Date>?
    let selectionMode: SelectionMode?
    let now: Date
    let plotBounds: CGRect
    let timeAtX: (CGFloat) -> Date
    let valueAtY: (CGFloat) -> Double
    let xAtTime: (Date) -> CGFloat
    let yAtValue: (Double) -> CGFloat
    let onGuide: (Guide, PlotGesturePhase) -> Void
    let onSelection: (Date, Date, PlotSelectionEdge?, Bool, PlotGesturePhase) -> Void
    let onPan: (CGSize, PlotGesturePhase) -> Void
    let onZoom: (Double, Date, PlotGesturePhase) -> Void
    let onHover: (Date?) -> Void
    var onBackgroundClick: () -> Void = {}
    var onBackgroundDoubleClick: (Date) -> Void = { _ in }
    var onGuideSelected: (Guide) -> Void = { _ in }
    var onSelectionModeToggle: (PlotSelectionEdge) -> Void = { _ in }

    func makeNSView(context: Context) -> PlotInteractionView {
        let view = PlotInteractionView()
        view.update(guides: guides, selectionRange: selectionRange, selectionMode: selectionMode, now: now, plotBounds: plotBounds, timeAtX: timeAtX,
                    valueAtY: valueAtY, xAtTime: xAtTime, yAtValue: yAtValue,
                    onGuide: onGuide, onSelection: onSelection, onPan: onPan, onZoom: onZoom, onHover: onHover,
                    onBackgroundClick: onBackgroundClick, onBackgroundDoubleClick: onBackgroundDoubleClick,
                    onGuideSelected: onGuideSelected, onSelectionModeToggle: onSelectionModeToggle)
        return view
    }

    func updateNSView(_ view: PlotInteractionView, context: Context) {
        view.update(guides: guides, selectionRange: selectionRange, selectionMode: selectionMode, now: now, plotBounds: plotBounds, timeAtX: timeAtX,
                    valueAtY: valueAtY, xAtTime: xAtTime, yAtValue: yAtValue,
                    onGuide: onGuide, onSelection: onSelection, onPan: onPan, onZoom: onZoom, onHover: onHover,
                    onBackgroundClick: onBackgroundClick, onBackgroundDoubleClick: onBackgroundDoubleClick,
                    onGuideSelected: onGuideSelected, onSelectionModeToggle: onSelectionModeToggle)
    }
}

enum PlotGesturePhase: Equatable { case began, changed, ended, cancelled }
enum PlotSelectionEdge { case start, end }

@MainActor
final class PlotInteractionView: NSView {
    private enum Drag {
        case guide(Guide, isNew: Bool)
        case selection(start: Date, end: Date, edge: PlotSelectionEdge?)
        case pan
    }

    private var guides: [Guide] = []
    private var selectionRange: ClosedRange<Date>?
    private var selectionMode: SelectionMode?
    private var now = Date()
    private var plotBounds = CGRect.zero
    private var timeAtX: (CGFloat) -> Date = { _ in .now }
    private var valueAtY: (CGFloat) -> Double = { _ in 0 }
    private var xAtTime: (Date) -> CGFloat = { _ in 0 }
    private var yAtValue: (Double) -> CGFloat = { _ in 0 }
    private var onGuide: (Guide, PlotGesturePhase) -> Void = { _, _ in }
    private var onSelection: (Date, Date, PlotSelectionEdge?, Bool, PlotGesturePhase) -> Void = { _, _, _, _, _ in }
    private var onPan: (CGSize, PlotGesturePhase) -> Void = { _, _ in }
    private var onZoom: (Double, Date, PlotGesturePhase) -> Void = { _, _, _ in }
    private var onHover: (Date?) -> Void = { _ in }
    private var onBackgroundClick: () -> Void = {}
    private var onBackgroundDoubleClick: (Date) -> Void = { _ in }
    private var onGuideSelected: (Guide) -> Void = { _ in }
    private var onSelectionModeToggle: (PlotSelectionEdge) -> Void = { _ in }
    private var activeDrag: Drag?
    private var dragOrigin = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var dragMoved = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tracking areas do not deliver mouseMoved unless the window requests it.
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    func update(guides: [Guide], selectionRange: ClosedRange<Date>?, selectionMode: SelectionMode?, now: Date, plotBounds: CGRect,
                timeAtX: @escaping (CGFloat) -> Date, valueAtY: @escaping (CGFloat) -> Double,
                xAtTime: @escaping (Date) -> CGFloat, yAtValue: @escaping (Double) -> CGFloat,
                onGuide: @escaping (Guide, PlotGesturePhase) -> Void,
                onSelection: @escaping (Date, Date, PlotSelectionEdge?, Bool, PlotGesturePhase) -> Void,
                onPan: @escaping (CGSize, PlotGesturePhase) -> Void,
                onZoom: @escaping (Double, Date, PlotGesturePhase) -> Void,
                onHover: @escaping (Date?) -> Void,
                onBackgroundClick: @escaping () -> Void,
                onBackgroundDoubleClick: @escaping (Date) -> Void,
                onGuideSelected: @escaping (Guide) -> Void,
                onSelectionModeToggle: @escaping (PlotSelectionEdge) -> Void) {
        self.guides = guides
        self.selectionRange = selectionRange
        self.selectionMode = selectionMode
        self.now = now
        self.plotBounds = plotBounds
        self.timeAtX = timeAtX
        self.valueAtY = valueAtY
        self.xAtTime = xAtTime
        self.yAtValue = yAtValue
        self.onGuide = onGuide
        self.onSelection = onSelection
        self.onPan = onPan
        self.onZoom = onZoom
        self.onHover = onHover
        self.onBackgroundClick = onBackgroundClick
        self.onBackgroundDoubleClick = onBackgroundDoubleClick
        self.onGuideSelected = onGuideSelected
        self.onSelectionModeToggle = onSelectionModeToggle
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = localPoint(event)
        onHover(timeAtX(point.x))
        dragOrigin = point
        lastPoint = point
        dragMoved = false

        if let edge = hitSelectionEdge(at: point), event.clickCount >= 2, point.y >= bounds.maxY - 30 {
            onSelectionModeToggle(edge)
            activeDrag = nil
            return
        }
        if event.clickCount >= 2, plotBounds.contains(point), hitGuide(at: point) == nil,
           hitSelectionEdge(at: point) == nil {
            onBackgroundDoubleClick(timeAtX(point.x))
            activeDrag = nil
            return
        }

        if event.modifierFlags.contains(.shift) {
            activeDrag = .pan
            onPan(.zero, .began)
        } else if let guide = hitGuide(at: point) {
            activeDrag = .guide(guide, isNew: false)
        } else if let edge = hitSelectionEdge(at: point), let selectionRange {
            activeDrag = .selection(start: selectionRange.lowerBound, end: selectionRange.upperBound, edge: edge)
        } else if let orientation = edgeGuideOrientation(at: point) {
            let guide = Guide(orientation: orientation, value: guideValue(orientation, at: point))
            activeDrag = .guide(guide, isNew: true)
            onGuide(guide, .began)
        } else {
            let time = timeAtX(point.x)
            activeDrag = .selection(start: time, end: time, edge: nil)
            onSelection(time, time, nil, false, .began)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeDrag else { return }
        let point = localPoint(event)
        onHover(timeAtX(point.x))
        let movement = CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y)
        if hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) >= 3 { dragMoved = true }
        switch activeDrag {
        case let .guide(original, isNew):
            let changed = replacingValue(in: original, at: point)
            onGuide(changed, .changed)
            self.activeDrag = .guide(changed, isNew: isNew)
        case let .selection(start, end, edge):
            let time = timeAtX(point.x)
            switch edge {
            case .start: onSelection(min(time, end), max(time, end), .start, false, .changed)
            case .end: onSelection(min(start, time), max(start, time), .end, isAtOrBeyondNow(point.x), .changed)
            case nil:
                let lower = min(timeAtX(dragOrigin.x), time), upper = max(timeAtX(dragOrigin.x), time)
                onSelection(lower, upper, nil, isAtOrBeyondNow(xAtTime(upper)), .changed)
            }
        case .pan:
            onPan(movement, .changed)
        }
        lastPoint = point
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { onHover(timeAtX(localPoint(event).x)) }
    override func mouseEntered(with event: NSEvent) { onHover(timeAtX(localPoint(event).x)) }
    override func mouseExited(with event: NSEvent) { onHover(nil) }

    override func mouseUp(with event: NSEvent) {
        guard let activeDrag else { return }
        let point = localPoint(event)
        onHover(timeAtX(point.x))
        switch activeDrag {
        case let .guide(guide, isNew):
            if !dragMoved {
                onGuide(guide, .cancelled)
                if !isNew { onGuideSelected(guide) }
            } else { onGuide(replacingValue(in: guide, at: point), .ended) }
        case let .selection(start, end, edge):
            if !dragMoved {
                onSelection(start, end, edge, false, .cancelled)
                onBackgroundClick()
                self.activeDrag = nil
                return
            }
            let time = timeAtX(point.x)
            switch edge {
            case .start: onSelection(min(time, end), max(time, end), .start, false, .ended)
            case .end:
                let linked = isAtOrBeyondNow(point.x) && start <= now
                let lower = min(start, linked ? now : time), upper = max(start, linked ? now : time)
                onSelection(lower, upper, .end, linked, .ended)
            case nil:
                let origin = timeAtX(dragOrigin.x)
                let linked = isAtOrBeyondNow(xAtTime(max(origin, time)))
                let lower = min(origin, time), upper = max(origin, time)
                onSelection(lower, linked ? now : upper, nil, linked, .ended)
            }
        case .pan:
            let movement = CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y)
            onPan(movement, .ended)
        }
        self.activeDrag = nil
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let point = localPoint(event)
        let factor = exp(Double(event.magnification))
        onZoom(factor, timeAtX(point.x), gesturePhase(event.phase, default: .changed))
    }

    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase.isEmpty ? event.momentumPhase : event.phase
        if event.modifierFlags.contains(.control) {
            let point = localPoint(event)
            onZoom(exp(Double(event.scrollingDeltaY) / 120), timeAtX(point.x), gesturePhase(phase, default: .ended))
        } else if event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let delta = event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            onPan(CGSize(width: delta, height: 0), gesturePhase(phase, default: .ended))
        } else {
            // Ordinary vertical scrolling belongs to the stack, not its X scale.
            super.scrollWheel(with: event)
        }
    }

    private func gesturePhase(_ phase: NSEvent.Phase, default fallback: PlotGesturePhase) -> PlotGesturePhase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        return fallback
    }

    override func cancelOperation(_ sender: Any?) {
        guard let activeDrag else { return }
        switch activeDrag {
        case let .guide(guide, _):
            onGuide(guide, .cancelled)
        case let .selection(start, end, edge): onSelection(start, end, edge, false, .cancelled)
        case .pan: onPan(.zero, .cancelled)
        }
        self.activeDrag = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let selectionRange, let context = NSGraphicsContext.current?.cgContext else { return }
        let y = min(bounds.maxY - 16, max(bounds.minY + 10, bounds.maxY - 16))
        for (index, date) in [selectionRange.lowerBound, selectionRange.upperBound].enumerated() {
            let x = xAtTime(date)
            let centerY = y
            let path = NSBezierPath()
            if index == 0 {
                path.move(to: CGPoint(x: x - 7, y: centerY))
                path.line(to: CGPoint(x: x + 4, y: centerY - 7))
                path.line(to: CGPoint(x: x + 4, y: centerY + 7))
            } else {
                path.move(to: CGPoint(x: x + 7, y: centerY))
                path.line(to: CGPoint(x: x - 4, y: centerY - 7))
                path.line(to: CGPoint(x: x - 4, y: centerY + 7))
            }
            path.close()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            let tracking: Bool
            switch (selectionMode ?? .fixed, index) {
            case (.fixed, _): tracking = false
            case (.endFollowsNow, 1), (.bothFollowNow, _), (.startFollowsEnd, 0): tracking = true
            default: tracking = false
            }
            if tracking {
                NSColor.controlAccentColor.setFill()
                path.fill()
            } else {
                NSColor.windowBackgroundColor.setFill()
                path.fill()
                path.stroke()
            }
        }
    }

    private func localPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func hitGuide(at point: CGPoint) -> Guide? {
        guides.min { distance($0, to: point) < distance($1, to: point) }
            .flatMap { distance($0, to: point) <= 8 ? $0 : nil }
    }

    private func distance(_ guide: Guide, to point: CGPoint) -> CGFloat {
        switch guide.orientation {
        case .horizontalValue: abs(yAtValue(guide.value) - point.y)
        case .verticalTime: abs(xAtTime(Date(timeIntervalSince1970: guide.value)) - point.x)
        }
    }

    private func hitSelectionEdge(at point: CGPoint) -> PlotSelectionEdge? {
        guard let selectionRange else { return nil }
        let startDistance = abs(point.x - xAtTime(selectionRange.lowerBound))
        let endDistance = abs(point.x - xAtTime(selectionRange.upperBound))
        if min(startDistance, endDistance) > 9 { return nil }
        return startDistance <= endDistance ? .start : .end
    }

    private func edgeGuideOrientation(at point: CGPoint) -> GuideOrientation? {
        let edgeInset: CGFloat = 15
        // Keep pulls in axis gutters, outside the plot. In particular, points
        // within the 18 pt Now-snap zone at the right edge remain selectable.
        if point.x <= plotBounds.minX, point.x >= plotBounds.minX - edgeInset { return .horizontalValue }
        if point.x >= plotBounds.maxX, point.x <= plotBounds.maxX + edgeInset { return .horizontalValue }
        if point.y <= plotBounds.minY, point.y >= plotBounds.minY - edgeInset { return .verticalTime }
        if point.y >= plotBounds.maxY, point.y <= plotBounds.maxY + edgeInset { return .verticalTime }
        return nil
    }

    private func isAtOrBeyondNow(_ screenX: CGFloat) -> Bool { screenX >= xAtTime(now) - 18 }

    private func guideValue(_ orientation: GuideOrientation, at point: CGPoint) -> Double {
        switch orientation {
        case .horizontalValue: valueAtY(point.y)
        case .verticalTime: timeAtX(point.x).timeIntervalSince1970
        }
    }

    private func replacingValue(in guide: Guide, at point: CGPoint) -> Guide {
        var changed = guide
        changed.value = guideValue(guide.orientation, at: point)
        return changed
    }
}
