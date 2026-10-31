import SwiftUI
import PipePlotCore

/// One shared locator lane stays aligned with the plotting area in every row.
struct TimelineLocators: View {
    let range: ClosedRange<Date>
    let timeZone: PlotTimeZone
    let reference: Date?
    let guides: [Guide]
    let selection: ClosedRange<Date>?
    let selectionMode: SelectionMode?
    let now: Date
    let hover: Date?
    let onHover: (Date?) -> Void
    let onGuide: (Guide, PlotGesturePhase) -> Void
    let onGuideSelected: (Guide) -> Void
    let onSelection: (Date, Date, PlotSelectionEdge?, Bool, PlotGesturePhase) -> Void
    let onToggle: (PlotSelectionEdge) -> Void
    let onClear: () -> Void
    let onAddGuide: (Date) -> Void

    private var span: TimeInterval { max(0.001, range.upperBound.timeIntervalSince(range.lowerBound)) }
    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(x: 84, y: 23, width: max(1, geometry.size.width - 112), height: 49)
            let x: (Date) -> CGFloat = { plot.minX + $0.timeIntervalSince(range.lowerBound) / span * plot.width }
            let date: (CGFloat) -> Date = { range.lowerBound.addingTimeInterval(Double(($0 - plot.minX) / plot.width) * span) }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for index in 0...4 {
                        let t = range.lowerBound.addingTimeInterval(span * Double(index) / 4)
                        let anchor: UnitPoint = index == 0 ? .topLeading : (index == 4 ? .topTrailing : .top)
                        context.draw(Text(TimeText.format(t, zone: timeZone, reference: reference, includeDate: span > 86_400))
                            .font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary), at: CGPoint(x: x(t), y: 3), anchor: anchor)
                    }
                    if let selection {
                        let left = max(plot.minX, x(selection.lowerBound)), right = min(plot.maxX, x(selection.upperBound))
                        if right >= left {
                            let rect = CGRect(x: left, y: 59, width: max(1, right - left), height: 13)
                            context.fill(Path(rect), with: .color(.accentColor.opacity(0.15)))
                            var brace = Path()
                            brace.move(to: CGPoint(x: left, y: 69)); brace.addLine(to: CGPoint(x: left, y: 58))
                            brace.addLine(to: CGPoint(x: right, y: 58)); brace.addLine(to: CGPoint(x: right, y: 69))
                            context.stroke(brace, with: .color(.accentColor), lineWidth: 2)
                            if right - left > 120 {
                                context.draw(Text("Interval · \(selection.upperBound.timeIntervalSince(selection.lowerBound).formatted(.number.precision(.fractionLength(1))))s")
                                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.accentColor), at: CGPoint(x: (left + right) / 2, y: 65))
                            }
                        }
                    }
                    var laneEnds = [CGFloat](repeating: plot.minX - 4, count: 2)
                    for guide in guides.sorted(by: { $0.value < $1.value }) {
                        let t = Date(timeIntervalSince1970: guide.value)
                        guard range.contains(t) else { continue }
                        let gx = x(t), color = Color(hex: guide.color)
                        let lane = laneEnds.firstIndex(where: { $0 + 4 < gx })
                        let y: CGFloat = lane == 1 ? 41 : 23
                        var stem = Path(); stem.move(to: CGPoint(x: gx, y: y)); stem.addLine(to: CGPoint(x: gx, y: 56))
                        context.stroke(stem, with: .color(color), lineWidth: 1)
                        let flagWidth = min(104, max(12, plot.maxX - gx))
                        var flag = Path()
                        flag.move(to: CGPoint(x: gx, y: y)); flag.addLine(to: CGPoint(x: gx + flagWidth, y: y))
                        flag.addLine(to: CGPoint(x: gx + flagWidth - 5, y: y + 13)); flag.addLine(to: CGPoint(x: gx, y: y + 13)); flag.closeSubpath()
                        if let lane {
                            context.fill(flag, with: .color(color.opacity(0.22)))
                            context.stroke(flag, with: .color(color.opacity(0.8)), lineWidth: 1)
                            let title = String((guide.label?.isEmpty == false ? guide.label! : TimeText.format(t, zone: timeZone, reference: reference)).prefix(16))
                            context.drawLayer { layer in
                                layer.clip(to: Path(CGRect(x: gx + 3, y: y, width: max(1, flagWidth - 8), height: 14)))
                                layer.draw(Text(title).font(.system(size: 9, weight: .medium)).foregroundColor(color), at: CGPoint(x: gx + 4, y: y + 1), anchor: .topLeading)
                            }
                            laneEnds[lane] = gx + flagWidth
                        } else {
                            context.fill(Path(CGRect(x: gx, y: 49, width: 3, height: 7)), with: .color(color))
                        }
                    }
                    if let hover, range.contains(hover) {
                        var line = Path(); line.move(to: CGPoint(x: x(hover), y: 18)); line.addLine(to: CGPoint(x: x(hover), y: 74))
                        context.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                    if range.contains(now) {
                        var line = Path(); line.move(to: CGPoint(x: x(now), y: 19)); line.addLine(to: CGPoint(x: x(now), y: 74))
                        context.stroke(line, with: .color(.orange), lineWidth: 1.5)
                    }
                }
                PlotInteractionOverlay(guides: guides, guideHitRects: flagHitRects(in: plot, x: x), selectionRange: selection, selectionMode: selectionMode, now: now,
                    plotBounds: plot, timeAtX: date, valueAtY: { _ in 0 }, xAtTime: x, yAtValue: { _ in 0 },
                    onGuide: { guide, phase in if guide.orientation == .verticalTime { onGuide(guide, phase) } },
                    onSelection: onSelection, onPan: { _, _ in }, onZoom: { _, _, _ in }, onHover: onHover,
                    onBackgroundClick: onClear, onBackgroundDoubleClick: onAddGuide,
                    onGuideSelected: onGuideSelected, onSelectionModeToggle: onToggle)
            }
        }.frame(height: 78).background(.bar)
            .help("Drag a locator to move it; click to edit. Drag interval endpoints; double-click each triangle to toggle tracking.")
            .accessibilityLabel("Shared timeline locators and interval brace")
    }
    private func flagHitRects(in plot: CGRect, x: (Date) -> CGFloat) -> [UUID: CGRect] {
        var ends = [CGFloat](repeating: plot.minX - 4, count: 2)
        var rects: [UUID: CGRect] = [:]
        for guide in guides.sorted(by: { $0.value < $1.value }) {
            let date = Date(timeIntervalSince1970: guide.value)
            guard range.contains(date) else { continue }
            let gx = x(date)
            guard let lane = ends.firstIndex(where: { $0 + 4 < gx }) else { continue }
            let width = min(104, max(12, plot.maxX - gx))
            rects[guide.id] = CGRect(x: gx, y: lane == 1 ? 41 : 23, width: width, height: 14)
            ends[lane] = gx + width
        }
        return rects
    }

}

struct TimeLocatorEditor: View {
    let guide: Guide
    let zone: PlotTimeZone
    let save: (Guide) -> Void
    let close: () -> Void
    @State private var date: Date
    @State private var seconds: String
    @State private var label: String
    init(guide: Guide, zone: PlotTimeZone, save: @escaping (Guide) -> Void, close: @escaping () -> Void) {
        self.guide = guide; self.zone = zone; self.save = save; self.close = close
        let date = Date(timeIntervalSince1970: guide.value)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone == .utc ? TimeZone(secondsFromGMT: 0)! : .current
        _date = State(initialValue: date)
        _seconds = State(initialValue: String(format: "%.3f", Double(calendar.component(.second, from: date)) + guide.value.truncatingRemainder(dividingBy: 1)))
        _label = State(initialValue: guide.label ?? "")
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = zone == .utc ? TimeZone(secondsFromGMT: 0)! : .current; return value
    }
    private var timestamp: Double? {
        guard let second = Double(seconds), second.isFinite, second >= 0, second < 60 else { return nil }
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date); parts.second = Int(second)
        return calendar.date(from: parts).map { $0.timeIntervalSince1970 + second.truncatingRemainder(dividingBy: 1) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit time locator").font(.title3.weight(.semibold))
            DatePicker(zone == .utc ? "UTC date and time" : "Local date and time", selection: $date, displayedComponents: [.date, .hourAndMinute]).environment(\.calendar, calendar)
            TextField("Seconds (0–59.999)", text: $seconds).textFieldStyle(.roundedBorder)
            TextField("Label", text: $label).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", action: close); Spacer()
                Button("Save") { if let timestamp { var updated = guide; updated.value = timestamp; updated.label = label.isEmpty ? nil : label; save(updated); close() } }
                    .disabled(timestamp == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 360)
    }
}
