import SwiftUI
import PipePlotCore

struct PlotCanvas: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let samples: [StreamID: [StoredSample]]
    let domain: ClosedRange<Date>
    let now: Date
    @Binding var hoverDate: Date?
    @Binding var selectionStart: Date?
    @Binding var selectionPreview: Date?
    @Binding var selectionLinkedPreview: Bool
    var onFollowSelectionDuration: (() -> Void)? = nil
    let selection: TimeSelection?
    let forecast: ForecastDrawing?
    let onSelectionCommit: (Date?, Date?, SelectionMode?) -> Void
    let onGuide: (Guide, PlotGesturePhase) -> Void
    let onPan: (CGSize, PlotGesturePhase, CGFloat) -> Void
    let onZoom: (Double, Date, PlotGesturePhase) -> Void

    private var timeSpan: TimeInterval { max(0.001, domain.upperBound.timeIntervalSince(domain.lowerBound)) }

    var body: some View {
        GeometryReader { geometry in
            let plot = plotRect(for: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas(opaque: false, colorMode: .linear) { context, size in
                    draw(in: context, size: size)
                }
                PlotInteractionOverlay(
                    guides: chart.guides + session.timeGuides,
                    selectionRange: currentSelectionRange,
                    now: now,
                    plotBounds: plot,
                    timeAtX: { date(at: $0, width: geometry.size.width, plot: plot) },
                    valueAtY: { value(at: $0, height: geometry.size.height, plot: plot) },
                    xAtTime: { x($0, in: plot) },
                    yAtValue: { y($0, range: yRange, in: plot) },
                    onGuide: onGuide,
                    onSelection: { start, end, edge, endFollowsNow, phase in
                        switch phase {
                        case .began, .changed:
                            selectionStart = start; selectionPreview = end
                            selectionLinkedPreview = endFollowsNow || (edge == .start && selection?.mode == .endFollowsNow)
                        case .ended:
                            selectionStart = nil; selectionPreview = nil; selectionLinkedPreview = false
                            if abs(end.timeIntervalSince(start)) > 0.5 {
                                var mode: SelectionMode = .fixed
                                if edge == .start, selection?.mode == .endFollowsNow { mode = .endFollowsNow }
                                else if endFollowsNow { mode = .endFollowsNow }
                                onSelectionCommit(start, mode == .endFollowsNow ? now : end, mode)
                            }
                        case .cancelled:
                            selectionStart = nil; selectionPreview = nil; selectionLinkedPreview = false
                        }
                    },
                    onPan: { delta, phase in onPan(delta, phase, plot.width) },
                    onZoom: onZoom,
                    onHover: { hoverDate = $0 }
                )
                if selection?.mode == .endFollowsNow, let onFollowSelectionDuration {
                    Button(action: onFollowSelectionDuration) {
                        Image(systemName: "arrow.left.to.line.compact")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(.green, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Make the start follow now at this fixed duration")
                    .position(x: x(selection!.start, in: plot), y: plot.maxY - 8)
                }
            }
        }
    }

    private var currentSelectionRange: ClosedRange<Date>? {
        selection.map { item in
            let start: Date, end: Date
            switch item.mode {
            case .fixed: start = item.start; end = item.end
            case .endFollowsNow: start = item.start; end = now
            case .bothFollowNow(let duration): start = now.addingTimeInterval(-duration); end = now
            }
            return min(start, end)...max(start, end)
        }
    }
    private func plotRect(for size: CGSize) -> CGRect { CGRect(x: 56, y: 4, width: max(1, size.width - 56), height: max(1, size.height - 22)) }
    private func date(at x: CGFloat, width: CGFloat, plot: CGRect) -> Date {
        let fraction = min(1, max(0, (x - plot.minX) / max(plot.width, 1)))
        return domain.lowerBound.addingTimeInterval(timeSpan * Double(fraction))
    }
    private func value(at y: CGFloat, height: CGFloat, plot: CGRect) -> Double {
        let range = yRange
        let fraction = min(1, max(0, 1 - (y - plot.minY) / max(plot.height, 1)))
        return range.lowerBound + (range.upperBound - range.lowerBound) * Double(fraction)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let plot = plotRect(for: size)
        let valueRange = yRange
        var grid = Path()
        for fraction in 0...4 {
            let y = plot.minY + plot.height * CGFloat(fraction) / 4
            grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.13)), lineWidth: 1)

        let tickCount = max(2, min(6, Int(size.width / 125)))
        for index in 0...tickCount {
            let fraction = Double(index) / Double(tickCount)
            let date = domain.lowerBound.addingTimeInterval(timeSpan * fraction)
            let x = plot.minX + plot.width * CGFloat(fraction)
            let label = date.formatted(date: .omitted, time: timeSpan < 120 ? .standard : .shortened)
            context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: x, y: plot.maxY + 12), anchor: index == 0 ? .leading : (index == tickCount ? .trailing : .center))
        }
        for index in 0...4 {
            let fraction = Double(index) / 4
            let value = valueRange.upperBound - (valueRange.upperBound - valueRange.lowerBound) * fraction
            let label = value.formatted(.number.precision(.significantDigits(4)))
            let yPosition = plot.minY + plot.height * CGFloat(fraction)
            context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 7, y: yPosition), anchor: .trailing)
        }

        for (index, stream) in chart.streams.enumerated() {
            let data = samples[stream.id] ?? []
            guard !data.isEmpty else { continue }
            let color = Self.color(index)
            if chart.settings.linesVisible && data.count > 1 {
                var path = Path()
                var previousSegment: String?
                for (pointIndex, sample) in data.enumerated() {
                    let position = CGPoint(x: x(sample.timestamp, in: plot), y: y(sample.value, range: valueRange, in: plot))
                    if pointIndex == 0 || sample.segmentID != previousSegment { path.move(to: position) }
                    else { path.addLine(to: position) }
                    previousSegment = sample.segmentID
                }
                context.stroke(path, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            if chart.settings.linesVisible && !chart.settings.dotsVisible {
                for (pointIndex, sample) in data.enumerated() {
                    let hasSameSegmentNeighbor = (pointIndex > 0 && data[pointIndex - 1].segmentID == sample.segmentID)
                        || (pointIndex + 1 < data.count && data[pointIndex + 1].segmentID == sample.segmentID)
                    guard !hasSameSegmentNeighbor else { continue }
                    let point = CGPoint(x: x(sample.timestamp, in: plot), y: y(sample.value, range: valueRange, in: plot))
                    let marker = CGRect(x: point.x - 3.2, y: point.y - 3.2, width: 6.4, height: 6.4)
                    context.fill(Path(ellipseIn: marker), with: .color(color))
                }
            }
            if chart.settings.dotsVisible {
                for sample in data {
                    let point = CGPoint(x: x(sample.timestamp, in: plot), y: y(sample.value, range: valueRange, in: plot))
                    guard plot.contains(point) else { continue }
                    let rect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }

        for guide in chart.guides + session.timeGuides {
            let color = Color(hex: guide.color)
            if guide.orientation == .horizontalValue {
                let yPos = y(guide.value, range: valueRange, in: plot)
                var path = Path(); path.move(to: CGPoint(x: plot.minX, y: yPos)); path.addLine(to: CGPoint(x: plot.maxX, y: yPos))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                if let label = guide.label, !label.isEmpty { context.draw(Text("\(label)  \(guide.value.formatted(.number.precision(.significantDigits(3))))").font(.system(size: 10, weight: .medium)).foregroundColor(color), at: CGPoint(x: plot.maxX - 5, y: yPos - 8), anchor: .trailing) }
            } else {
                let date = Date(timeIntervalSince1970: guide.value)
                let xPos = x(date, in: plot)
                var path = Path(); path.move(to: CGPoint(x: xPos, y: plot.minY)); path.addLine(to: CGPoint(x: xPos, y: plot.maxY))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                if let label = guide.label, !label.isEmpty {
                    context.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(color), at: CGPoint(x: min(plot.maxX - 5, xPos + 5), y: plot.minY + 8), anchor: .leading)
                }
            }
        }
        if let forecast {
            let forecastColor: Color = chart.streams.firstIndex(where: { $0.id == forecast.streamID }).map(Self.color) ?? .orange
            let start = min(max(forecast.range.upperBound, domain.lowerBound), now)
            if forecast.crossing > start {
                var path = Path()
                path.move(to: CGPoint(x: x(start, in: plot), y: y(forecast.fit.value(at: start), range: valueRange, in: plot)))
                path.addLine(to: CGPoint(x: x(forecast.crossing, in: plot), y: y(forecast.value, range: valueRange, in: plot)))
                context.stroke(path, with: .color(forecastColor), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
        }
        let savedSelection: (Date, Date)? = selection.map { item in
            switch item.mode {
            case .fixed: return (item.start, item.end)
            case .endFollowsNow: return (item.start, now)
            case .bothFollowNow(let duration): return (now.addingTimeInterval(-duration), now)
            }
        }
        if let selectionStart, let selectionPreview {
            drawSelection(from: selectionStart, to: selectionPreview, linked: selectionLinkedPreview, in: plot, context: context)
        } else if let (start, end) = savedSelection {
            drawSelection(from: start, to: end, linked: selection?.mode != .fixed, in: plot, context: context)
        }
        if domain.contains(now) {
            let nowX = x(now, in: plot)
            var path = Path(); path.move(to: CGPoint(x: nowX, y: plot.minY)); path.addLine(to: CGPoint(x: nowX, y: plot.maxY))
            context.stroke(path, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
            context.draw(Text("NOW").font(.system(size: 9, weight: .bold)).foregroundColor(.orange), at: CGPoint(x: min(plot.maxX - 4, nowX - 4), y: plot.minY + 8), anchor: .trailing)
        }
        if let hoverDate {
            let xPos = x(hoverDate, in: plot)
            var path = Path(); path.move(to: CGPoint(x: xPos, y: plot.minY)); path.addLine(to: CGPoint(x: xPos, y: plot.maxY))
            context.stroke(path, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3,3]))
        }
    }

    private func drawSelection(from start: Date, to end: Date, linked: Bool, in plot: CGRect, context: GraphicsContext) {
            let a = x(start, in: plot), b = x(end, in: plot)
            let rect = CGRect(x: min(a,b), y: plot.minY, width: abs(b-a), height: plot.height)
            let color: Color = linked ? .green : .accentColor
            context.fill(Path(rect), with: .color(color.opacity(0.13)))
            context.stroke(Path(rect), with: .color(color.opacity(0.8)), lineWidth: 1)
    }

    private var yRange: ClosedRange<Double> {
        if case let .fixed(minimum, maximum) = chart.settings.yScale, minimum < maximum { return minimum...maximum }
        let values = chart.streams.flatMap { samples[$0.id, default: []].map(\.value) }
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        if minimum == maximum {
            let delta = max(abs(minimum) * 0.08, 1)
            return (minimum - delta)...(maximum + delta)
        }
        let padding = (maximum - minimum) * 0.08
        return (minimum - padding)...(maximum + padding)
    }
    private func x(_ date: Date, in rect: CGRect) -> CGFloat { rect.minX + rect.width * CGFloat(date.timeIntervalSince(domain.lowerBound) / timeSpan) }
    private func y(_ value: Double, range: ClosedRange<Double>, in rect: CGRect) -> CGFloat { rect.maxY - rect.height * CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.000001)) }

    static func color(_ index: Int) -> Color {
        let palette: [Color] = [.cyan, .orange, .purple, .green, .pink, .yellow, .blue, .mint, .red]
        return palette[index % palette.count]
    }
}

private extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        self.init(.sRGB, red: Double((number >> 16) & 0xff) / 255, green: Double((number >> 8) & 0xff) / 255, blue: Double(number & 0xff) / 255, opacity: 1)
    }
}
