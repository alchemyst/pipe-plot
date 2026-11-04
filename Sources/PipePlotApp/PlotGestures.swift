import SwiftUI
import AppKit
import PipePlotCore

/// Drop this transparent overlay over a plot canvas and provide the plot's
/// coordinate transforms. It owns native mouse, trackpad, guide, selection,
/// and pan gestures; rendering and model commits stay with the caller.
struct PlotInteractionOverlay: NSViewRepresentable {
    let guides: [Guide]
    var guideHitRects: [UUID: CGRect] = [:]
    var selectionBar: CGRect?
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
        view.setAccessibilityElement(false)
        view.guideHitRects = guideHitRects
        view.selectionBar = selectionBar
        view.update(
            guides: guides, selectionRange: selectionRange, selectionMode: selectionMode, now: now,
            plotBounds: plotBounds, timeAtX: timeAtX,
            valueAtY: valueAtY, xAtTime: xAtTime, yAtValue: yAtValue,
            onGuide: onGuide, onSelection: onSelection, onPan: onPan, onZoom: onZoom, onHover: onHover,
            onBackgroundClick: onBackgroundClick, onBackgroundDoubleClick: onBackgroundDoubleClick,
            onGuideSelected: onGuideSelected, onSelectionModeToggle: onSelectionModeToggle)
        return view
    }

    func updateNSView(_ view: PlotInteractionView, context: Context) {
        view.guideHitRects = guideHitRects
        view.selectionBar = selectionBar
        view.update(
            guides: guides, selectionRange: selectionRange, selectionMode: selectionMode, now: now,
            plotBounds: plotBounds, timeAtX: timeAtX,
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
        case guide(Guide, isNew: Bool, offset: CGFloat)
        case selection(start: Date, end: Date, edge: PlotSelectionEdge?, offset: CGFloat)
        case moveSelection(ClosedRange<Date>, grabbedTime: Date)
        case pan
    }

    private var guides: [Guide] = []
    var guideHitRects: [UUID: CGRect] = [:]
    var selectionBar: CGRect?
    private var selectionRange: ClosedRange<Date>?
    private var selectionMode: SelectionMode?
    private var now = Date()
    private var plotBounds = CGRect.zero
    private var geometryNeedsReset = false
    private var canInteract: Bool { !geometryNeedsReset && PlotGeometry.isUsable(plotBounds) }
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
    private enum NavigationGesture { case pan, zoom }
    private var activeNavigation: NavigationGesture?
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

    func update(
        guides: [Guide], selectionRange: ClosedRange<Date>?, selectionMode: SelectionMode?, now: Date,
        plotBounds: CGRect,
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
        onSelectionModeToggle: @escaping (PlotSelectionEdge) -> Void
    ) {
        self.guides = guides
        self.selectionRange = selectionRange
        self.selectionMode = selectionMode
        self.now = now
        let collapsed = PlotGeometry.isUsable(self.plotBounds) && !PlotGeometry.isUsable(plotBounds)
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
        if collapsed && !geometryNeedsReset {
            geometryNeedsReset = true
            // SwiftUI may be laying out the representable while this update runs.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryNeedsReset = false
                self.cancelOperation(nil)
                self.onHover(nil)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return canInteract && bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard canInteract else { return }
        window?.makeFirstResponder(self)
        let point = localPoint(event)
        onHover(timeAtX(point.x))
        dragOrigin = point
        lastPoint = point
        dragMoved = false

        let target = dragTarget(at: point)
        if let edge = hitSelectionTriangle(at: point), event.clickCount >= 2 {
            onSelectionModeToggle(edge)
            activeDrag = nil
            return
        }
        if event.clickCount >= 2, plotBounds.contains(point), target == nil {
            onBackgroundDoubleClick(timeAtX(point.x))
            activeDrag = nil
            return
        }

        if event.modifierFlags.contains(.shift) {
            activeDrag = .pan
            onPan(.zero, .began)
        } else if let target {
            activeDrag = target
        } else if let orientation = edgeGuideOrientation(at: point) {
            let guide = Guide(orientation: orientation, value: guideValue(orientation, at: point))
            activeDrag = .guide(guide, isNew: true, offset: 0)
            onGuide(guide, .began)
        } else {
            let time = timeAtX(point.x)
            activeDrag = .selection(start: time, end: time, edge: nil, offset: 0)
            onSelection(time, time, nil, false, .began)
        }
        updateCursor(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard canInteract, let activeDrag else { return }
        let point = localPoint(event)
        onHover(timeAtX(point.x))
        let movement = CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y)
        if hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) >= 3 { dragMoved = true }
        if !dragMoved, case .pan = activeDrag {
            onPan(movement, .changed)
            lastPoint = point
            return
        }
        guard dragMoved else { return }
        switch activeDrag {
        case let .guide(original, _, offset):
            onGuide(replacingValue(in: original, at: point, offset: offset), .changed)
        case let .moveSelection(range, grabbedTime):
            moveSelection(range, grabbedTime: grabbedTime, to: point, phase: .changed)
        case let .selection(start, end, edge, offset):
            resizeSelection(start: start, end: end, edge: edge, offset: offset, to: point, phase: .changed)
        case .pan:
            onPan(movement, .changed)
        }
        lastPoint = point
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard canInteract else { return }
        let point = localPoint(event)
        onHover(timeAtX(point.x))
        updateCursor(at: point)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        onHover(nil)
        if activeDrag == nil { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: localPoint(event)) }

    override func mouseUp(with event: NSEvent) {
        guard canInteract, let activeDrag else { return }
        let point = localPoint(event)
        onHover(timeAtX(point.x))
        defer {
            self.activeDrag = nil
            updateCursor(at: point)
        }
        switch activeDrag {
        case let .guide(guide, isNew, offset):
            if !dragMoved {
                onGuide(guide, .cancelled)
                if !isNew { onGuideSelected(guide) }
            } else {
                onGuide(replacingValue(in: guide, at: point, offset: offset), .ended)
            }
        case let .moveSelection(range, grabbedTime):
            if dragMoved { moveSelection(range, grabbedTime: grabbedTime, to: point, phase: .ended) }
        case let .selection(start, end, edge, offset):
            if dragMoved {
                resizeSelection(start: start, end: end, edge: edge, offset: offset, to: point, phase: .ended)
            } else {
                onSelection(start, end, edge, false, .cancelled)
                if edge == nil { onBackgroundClick() }
            }
        case .pan:
            let movement = CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y)
            onPan(movement, .ended)
        }
    }

    private func moveSelection(
        _ range: ClosedRange<Date>, grabbedTime: Date, to point: CGPoint, phase: PlotGesturePhase
    ) {
        let delta = timeAtX(point.x).timeIntervalSince(grabbedTime)
        // Moving the whole interval sets both times explicitly, even for a live interval.
        onSelection(range.lowerBound + delta, range.upperBound + delta, nil, false, phase)
    }

    private func resizeSelection(
        start: Date, end: Date, edge: PlotSelectionEdge?, offset: CGFloat, to point: CGPoint, phase: PlotGesturePhase
    ) {
        let x = point.x - offset
        let time = timeAtX(x)
        switch edge {
        case .start:
            let upper = tracksNowFromStart ? now : end
            onSelection(min(time, upper), max(time, upper), .start, tracksNowFromStart, phase)
        case .end:
            let linked = isAtOrBeyondNow(x) && start <= now
            let upper = linked ? now : time
            if case .startFollowsEnd(let duration) = selectionMode {
                onSelection(upper - duration, upper, .end, linked, phase)
            } else if case .bothFollowNow(let duration) = selectionMode, linked {
                onSelection(now - duration, now, .end, true, phase)
            } else {
                onSelection(min(start, upper), max(start, upper), .end, linked, phase)
            }
        case nil:
            let origin = timeAtX(dragOrigin.x)
            let upper = max(origin, time)
            let linked = isAtOrBeyondNow(xAtTime(upper)) && min(origin, time) <= now
            onSelection(min(origin, time), linked ? now : upper, nil, linked, phase)
        }
    }

    override func magnify(with event: NSEvent) {
        guard canInteract else { return }
        let point = localPoint(event)
        let factor = exp(Double(event.magnification))
        let phase = gesturePhase(event.phase, default: .changed)
        activeNavigation = phase == .ended || phase == .cancelled ? nil : .zoom
        onZoom(factor, timeAtX(point.x), phase)
    }

    override func scrollWheel(with event: NSEvent) {
        guard canInteract else {
            super.scrollWheel(with: event)
            return
        }
        let eventPhase = event.phase.isEmpty ? event.momentumPhase : event.phase
        let phase = gesturePhase(eventPhase, default: .ended)
        if event.modifierFlags.contains(.control) {
            let point = localPoint(event)
            activeNavigation = phase == .ended || phase == .cancelled ? nil : .zoom
            onZoom(exp(Double(event.scrollingDeltaY) / 120), timeAtX(point.x), phase)
        } else if event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let delta = event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            activeNavigation = phase == .ended || phase == .cancelled ? nil : .pan
            onPan(CGSize(width: delta, height: 0), phase)
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
        switch activeNavigation {
        case .pan: onPan(.zero, .cancelled)
        case .zoom: onZoom(1, now, .cancelled)
        case nil: break
        }
        activeNavigation = nil
        guard let activeDrag else { return }
        switch activeDrag {
        case let .guide(guide, _, _):
            onGuide(guide, .cancelled)
        case let .selection(start, end, edge, _): onSelection(start, end, edge, false, .cancelled)
        case let .moveSelection(range, _):
            onSelection(range.lowerBound, range.upperBound, nil, false, .cancelled)
        case .pan: onPan(.zero, .cancelled)
        }
        self.activeDrag = nil
        if let window { updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard PlotGeometry.isUsable(plotBounds), let selectionRange else { return }
        let color = NSColor.controlAccentColor
        for (index, date) in [selectionRange.lowerBound, selectionRange.upperBound].enumerated() {
            let x = xAtTime(date)
            guard isVisibleEndpoint(x) else { continue }
            let y = triangleY
            if selectionBar == nil {
                let grip = NSBezierPath(roundedRect: gripRect(at: x), xRadius: 3, yRadius: 3)
                NSColor.windowBackgroundColor.setFill()
                grip.fill()
                color.setStroke()
                grip.lineWidth = 1.5
                grip.stroke()
            }
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x, y: y - 7))
            path.line(to: CGPoint(x: x + (index == 0 ? 8 : -8), y: y))
            path.line(to: CGPoint(x: x, y: y + 7))
            path.close()
            color.setStroke()
            path.lineWidth = 1.5
            let tracking: Bool
            switch (selectionMode ?? .fixed, index) {
            case (.fixed, _): tracking = false
            case (.endFollowsNow, 1), (.bothFollowNow, _), (.startFollowsEnd, 0): tracking = true
            default: tracking = false
            }
            if tracking {
                color.setFill()
                path.fill()
                path.stroke()
            } else {
                NSColor.windowBackgroundColor.setFill()
                path.fill()
                path.stroke()
            }
        }
    }

    private func localPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func hitGuide(at point: CGPoint) -> Guide? {
        if let flag = guides.first(where: { guideHitRects[$0.id]?.contains(point) == true }) { return flag }
        return guides.min { distance($0, to: point) < distance($1, to: point) }
            .flatMap { distance($0, to: point) <= 8 ? $0 : nil }
    }

    private func distance(_ guide: Guide, to point: CGPoint) -> CGFloat {
        switch guide.orientation {
        case .horizontalValue: abs(yAtValue(guide.value) - point.y)
        case .verticalTime: abs(xAtTime(Date(timeIntervalSince1970: guide.value)) - point.x)
        }
    }

    private var triangleY: CGFloat { selectionBar?.midY ?? plotBounds.maxY - 8 }

    private func gripRect(at x: CGFloat) -> CGRect {
        CGRect(x: x - 3.5, y: plotBounds.midY - 8, width: 7, height: 16)
    }

    private func isVisibleEndpoint(_ x: CGFloat) -> Bool { x >= plotBounds.minX && x <= plotBounds.maxX }

    private func hitSelectionEdge(at point: CGPoint) -> PlotSelectionEdge? {
        guard let selectionRange else { return nil }
        let start = xAtTime(selectionRange.lowerBound), end = xAtTime(selectionRange.upperBound)
        let startDistance = isVisibleEndpoint(start) ? abs(point.x - start) : .infinity
        let endDistance = isVisibleEndpoint(end) ? abs(point.x - end) : .infinity
        if min(startDistance, endDistance) > 9 { return nil }
        return startDistance <= endDistance ? .start : .end
    }

    private func hitSelectionTriangle(at point: CGPoint) -> PlotSelectionEdge? {
        guard abs(point.y - triangleY) <= 8 else { return nil }
        return hitSelectionEdge(at: point)
    }

    private func dragTarget(at point: CGPoint) -> Drag? {
        let edge =
            hitSelectionTriangle(at: point)
            ?? (selectionBar == nil && abs(point.y - plotBounds.midY) <= 10 ? hitSelectionEdge(at: point) : nil)
        if let edge, let selectionRange {
            return resizeTarget(edge, range: selectionRange, at: point)
        }
        if point.y < (selectionBar?.minY ?? .infinity), let guide = hitGuide(at: point) {
            let offset =
                switch guide.orientation {
                case .verticalTime: point.x - xAtTime(Date(timeIntervalSince1970: guide.value))
                case .horizontalValue: point.y - yAtValue(guide.value)
                }
            return .guide(guide, isNew: false, offset: offset)
        }
        guard let selectionRange else { return nil }
        if let selectionBar {
            let left = max(plotBounds.minX, xAtTime(selectionRange.lowerBound))
            let right = min(plotBounds.maxX, xAtTime(selectionRange.upperBound))
            if point.y >= selectionBar.minY, point.y <= selectionBar.maxY, point.x >= left, point.x <= right {
                return .moveSelection(selectionRange, grabbedTime: timeAtX(point.x))
            }
        } else if point.y >= plotBounds.minY, point.y <= plotBounds.maxY, let edge = hitSelectionEdge(at: point) {
            return resizeTarget(edge, range: selectionRange, at: point)
        }
        return nil
    }

    private func resizeTarget(_ edge: PlotSelectionEdge, range: ClosedRange<Date>, at point: CGPoint) -> Drag {
        let endpoint = edge == .start ? range.lowerBound : range.upperBound
        return .selection(
            start: range.lowerBound, end: range.upperBound, edge: edge, offset: point.x - xAtTime(endpoint))
    }

    private func updateCursor(at point: CGPoint) {
        guard canInteract else {
            NSCursor.arrow.set()
            return
        }
        switch activeDrag ?? (bounds.contains(point) ? dragTarget(at: point) : nil) {
        case .moveSelection: (activeDrag == nil ? NSCursor.openHand : .closedHand).set()
        case .selection(_, _, .some, _): NSCursor.columnResize.set()
        case let .guide(guide, _, _):
            (guide.orientation == .verticalTime ? NSCursor.columnResize : .rowResize).set()
        default: NSCursor.arrow.set()
        }
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
    private var tracksNowFromStart: Bool {
        switch selectionMode {
        case .endFollowsNow?, .bothFollowNow?: true
        default: false
        }
    }

    private func guideValue(_ orientation: GuideOrientation, at point: CGPoint) -> Double {
        switch orientation {
        case .horizontalValue: valueAtY(point.y)
        case .verticalTime: timeAtX(point.x).timeIntervalSince1970
        }
    }

    private func replacingValue(in guide: Guide, at point: CGPoint, offset: CGFloat) -> Guide {
        var changed = guide
        let anchor =
            switch guide.orientation {
            case .verticalTime: CGPoint(x: point.x - offset, y: point.y)
            case .horizontalValue: CGPoint(x: point.x, y: point.y - offset)
            }
        changed.value = guideValue(guide.orientation, at: anchor)
        return changed
    }
}
