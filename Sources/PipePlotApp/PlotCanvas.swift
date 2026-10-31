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
    var onBackgroundClick: () -> Void = {}
    var onBackgroundDoubleClick: (Date) -> Void = { _ in }
    var onGuideSelected: (Guide) -> Void = { _ in }
    var onSelectionModeToggle: (PlotSelectionEdge) -> Void = { _ in }
    let selection: TimeSelection?
    let forecasts: [ForecastDrawing]
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
                    selectionMode: selection?.mode,
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
                            var previewStart = start
                            var previewEnd = end
                            if edge == .end, case .startFollowsEnd(let duration) = selection?.mode {
                                previewStart = end.addingTimeInterval(-duration)
                                previewEnd = end
                            }
                            selectionStart = previewStart; selectionPreview = previewEnd
                            selectionLinkedPreview = endFollowsNow || (selection.map { $0.mode != .fixed } ?? false)
                        case .ended:
                            selectionStart = nil; selectionPreview = nil; selectionLinkedPreview = false
                            if abs(end.timeIntervalSince(start)) > 0.5 {
                                var mode: SelectionMode = .fixed
                                let duration = max(0.5, abs(end.timeIntervalSince(start)))
                                switch (edge, selection?.mode) {
                                case (.start, .endFollowsNow?): mode = .endFollowsNow
                                case (.start, .startFollowsEnd?): mode = .startFollowsEnd(duration: duration)
                                case (.start, .bothFollowNow?): mode = .bothFollowNow(duration: duration)
                                case (.end, .startFollowsEnd?) where endFollowsNow: mode = .bothFollowNow(duration: duration)
                                case (.end, .startFollowsEnd?): mode = .startFollowsEnd(duration: duration)
                                case (.end, .bothFollowNow?) where endFollowsNow: mode = .bothFollowNow(duration: duration)
                                case (_, _) where endFollowsNow: mode = .endFollowsNow
                                default: break
                                }
                                let committedEnd = (mode == .endFollowsNow || isBothFollowNow(mode)) ? now : end
                                onSelectionCommit(start, committedEnd, mode)
                            }
                        case .cancelled:
                            selectionStart = nil; selectionPreview = nil; selectionLinkedPreview = false
                        }
                    },
                    onPan: { delta, phase in onPan(delta, phase, plot.width) },
                    onZoom: onZoom,
                    onHover: { hoverDate = $0 },
                    onBackgroundClick: onBackgroundClick,
                    onBackgroundDoubleClick: onBackgroundDoubleClick,
                    onGuideSelected: onGuideSelected,
                    onSelectionModeToggle: onSelectionModeToggle
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
            case .startFollowsEnd(let duration): start = item.end.addingTimeInterval(-duration); end = item.end
            }
            return min(start, end)...max(start, end)
        }
    }

    private func isBothFollowNow(_ mode: SelectionMode) -> Bool {
        if case .bothFollowNow = mode { return true }
        return false
    }
    private func plotRect(for size: CGSize) -> CGRect { CGRect(x: 56, y: 4, width: max(1, size.width - 56), height: max(1, size.height - 22)) }
    private func date(at x: CGFloat, width: CGFloat, plot: CGRect) -> Date {
        let fraction = min(1, max(0, (x - plot.minX) / max(plot.width, 1)))
        return domain.lowerBound.addingTimeInterval(timeSpan * Double(fraction))
    }
    private func value(at y: CGFloat, height: CGFloat, plot: CGRect) -> Double {
        let range = yRange
        let fraction = min(1, max(0, 1 - (y - plot.minY) / max(plot.height, 1)))
        return interpolatedValue(in: range, fraction: Double(fraction))
    }

    private func draw(in graphicsContext: GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        var context = graphicsContext
        let plot = plotRect(for: size)
        let valueRange = yRange
        var grid = Path()
        let numericScale = chart.settings.numericScale ?? .decimal
        let yTicks = NumericText.ticks(in: valueRange, scale: numericScale, targetCount: max(2, min(6, Int(plot.height / 55))))
        for value in yTicks {
            let position = y(value, range: valueRange, in: plot)
            grid.move(to: CGPoint(x: plot.minX, y: position)); grid.addLine(to: CGPoint(x: plot.maxX, y: position))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.13)), lineWidth: 1)

        let tickCount = max(2, min(6, Int(size.width / 125)))
        let referenceTime = session.timeGuides.first(where: { $0.id == session.timeline.referenceTimeGuideID })
            .map { Date(timeIntervalSince1970: $0.value) }
        for index in 0...tickCount {
            let fraction = Double(index) / Double(tickCount)
            let date = domain.lowerBound.addingTimeInterval(timeSpan * fraction)
            let x = plot.minX + plot.width * CGFloat(fraction)
            let label = TimeText.format(date, zone: session.timeline.timeZone ?? .local, reference: referenceTime)
            context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: x, y: plot.maxY + 12), anchor: index == 0 ? .leading : (index == tickCount ? .trailing : .center))
        }
        let referenceValue = chart.guides.first(where: { $0.id == chart.settings.referenceGuideID && $0.orientation == .horizontalValue })?.value
        for value in yTicks {
            let label = NumericText.format(value - (referenceValue ?? 0), scale: numericScale, unit: chart.settings.unit)
            let yPosition = y(value, range: valueRange, in: plot)
            context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 7, y: yPosition), anchor: .trailing)
        }

        context.clip(to: Path(plot))
        var extremaLabels: [CGRect] = []
        for (index, stream) in chart.streams.enumerated() {
            let data = samples[stream.id] ?? []
            guard !data.isEmpty else { continue }
            let color = Self.color(for: stream, fallback: index)
            let linesVisible = stream.linesVisible ?? chart.settings.linesVisible
            let dotsVisible = stream.dotsVisible ?? chart.settings.dotsVisible
            if linesVisible && data.count > 1 {
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
            if linesVisible && !dotsVisible {
                for (pointIndex, sample) in data.enumerated() {
                    let hasSameSegmentNeighbor = (pointIndex > 0 && data[pointIndex - 1].segmentID == sample.segmentID)
                        || (pointIndex + 1 < data.count && data[pointIndex + 1].segmentID == sample.segmentID)
                    guard !hasSameSegmentNeighbor else { continue }
                    let point = CGPoint(x: x(sample.timestamp, in: plot), y: y(sample.value, range: valueRange, in: plot))
                    let marker = CGRect(x: point.x - 3.2, y: point.y - 3.2, width: 6.4, height: 6.4)
                    context.fill(Path(ellipseIn: marker), with: .color(color))
                }
            }
            if dotsVisible {
                for sample in data {
                    let point = CGPoint(x: x(sample.timestamp, in: plot), y: y(sample.value, range: valueRange, in: plot))
                    guard plot.contains(point) else { continue }
                    let rect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
            if chart.settings.showExtrema != false, chart.streams.count <= 6, data.count >= 3 {
                let extrema = PeakFinder.extrema(samples: data, visibleRange: domain, plotWidth: Double(plot.width), valueRange: valueRange, maximumCount: 3)
                for extremum in extrema {
                    let sample = data[extremum.sampleIndex]
                    let point = CGPoint(x: x(sample.timestamp, in: plot), y: y(sample.value, range: valueRange, in: plot))
                    let symbol = extremum.kind == .peak ? "▲" : "▼"
                    let name = chart.streams.count > 1 ? "\(stream.name) " : ""
                    let label = Text("\(symbol) \(name)\(NumericText.format(sample.value, scale: numericScale, unit: chart.settings.unit))")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(color)
                    let resolved = context.resolve(label)
                    let labelSize = resolved.measure(in: plot.size)
                    let width = min(plot.width, labelSize.width + 6)
                    let height = labelSize.height + 4
                    let preferredY = extremum.kind == .peak ? point.y - height - 5 : point.y + 5
                    let alternateY = extremum.kind == .peak ? point.y + 5 : point.y - height - 5
                    for candidateY in [preferredY, alternateY] {
                        let rect = CGRect(x: min(max(point.x - width / 2, plot.minX), plot.maxX - width),
                                          y: min(max(candidateY, plot.minY), plot.maxY - height), width: width, height: height)
                        guard !extremaLabels.contains(where: { $0.intersects(rect.insetBy(dx: -2, dy: -2)) }) else { continue }
                        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.black.opacity(0.75)))
                        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                        extremaLabels.append(rect)
                        break
                    }
                }
            }
            if let last = data.last {
                let point = CGPoint(x: x(last.timestamp, in: plot), y: y(last.value, range: valueRange, in: plot))
                if plot.maxX - point.x >= 64 {
                    let name = chart.streams.count > 1 ? "\(stream.name) " : ""
                    context.draw(Text(name + NumericText.format(last.value, scale: chart.settings.numericScale ?? .decimal, unit: chart.settings.unit))
                        .font(.system(size: 9, weight: .medium)).foregroundColor(color), at: CGPoint(x: point.x + 6, y: point.y), anchor: .leading)
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
                let label = guide.label.flatMap { $0.isEmpty ? nil : $0 }
                    ?? TimeText.format(date, zone: session.timeline.timeZone ?? .local, includeDate: timeSpan > 86_400)
                let textWidth = CGFloat(label.count) * 5.5
                let labelX = min(plot.maxX - textWidth - 10, max(plot.minX, xPos + 5))
                let badge = CGRect(x: labelX, y: plot.minY + 2, width: textWidth + 10, height: 15)
                context.fill(Path(roundedRect: badge, cornerRadius: 4), with: .color(.black.opacity(0.32)))
                context.draw(Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(color), at: CGPoint(x: labelX + 5, y: badge.midY), anchor: .leading)
            }
        }
        for forecast in forecasts {
            let forecastColor: Color = chart.streams.first(where: { $0.id == forecast.streamID }).map { Self.color(for: $0, fallback: 0) } ?? .orange
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
            case .startFollowsEnd(let duration): return (item.end.addingTimeInterval(-duration), item.end)
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
        var values = chart.streams.flatMap { samples[$0.id, default: []].map(\.value) }
        values.append(contentsOf: chart.guides.filter { $0.orientation == .horizontalValue }.map(\.value))
        if chart.settings.includeZero == true { values.append(0) }
        values.append(contentsOf: forecasts.filter { forecast in
            forecast.value.isFinite && chart.streams.contains(where: { $0.id == forecast.streamID })
        }.map(\.value))
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let scale = max(abs(minimum), abs(maximum), 1)
        let lower = minimum / scale
        let upper = maximum / scale
        var paddedLower: Double
        var paddedUpper: Double
        if upper > lower {
            let padding = (upper - lower) * 0.08
            paddedLower = max(-1, lower - padding)
            paddedUpper = min(1, upper + padding)
        } else if upper >= 1 {
            paddedLower = 0.92; paddedUpper = 1
        } else if lower <= -1 {
            paddedLower = -1; paddedUpper = -0.92
        } else {
            let delta = max(abs(lower) * 0.08, 0.02)
            paddedLower = max(-1, lower - delta); paddedUpper = min(1, upper + delta)
        }
        if paddedLower >= paddedUpper { return -1...1 }
        return (paddedLower * scale)...(paddedUpper * scale)
    }
    private func x(_ date: Date, in rect: CGRect) -> CGFloat { rect.minX + rect.width * CGFloat(date.timeIntervalSince(domain.lowerBound) / timeSpan) }
    private func y(_ value: Double, range: ClosedRange<Double>, in rect: CGRect) -> CGFloat {
        let scale = max(abs(range.lowerBound), abs(range.upperBound), abs(value.isFinite ? value : 0), 1)
        let low = range.lowerBound / scale
        let high = range.upperBound / scale
        let normalized = value.isFinite ? value / scale : (value.sign == .minus ? low : high)
        let rawFraction = (normalized - low) / max(high - low, Double.leastNonzeroMagnitude)
        let safeFraction = rawFraction.isFinite ? min(16, max(-16, rawFraction)) : (rawFraction.sign == .minus ? -16 : 16)
        return rect.maxY - rect.height * CGFloat(safeFraction)
    }

    private func interpolatedValue(in range: ClosedRange<Double>, fraction: Double) -> Double {
        let scale = max(abs(range.lowerBound), abs(range.upperBound), 1)
        let low = range.lowerBound / scale
        let high = range.upperBound / scale
        return (low + (high - low) * fraction) * scale
    }

    private static func elapsedLabel(_ interval: TimeInterval) -> String {
        let sign = interval < 0 ? "−" : "+"
        let total = Int(abs(interval).rounded())
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        if hours > 0 { return "\(sign)\(hours):\(String(format: "%02d:%02d", minutes, seconds))" }
        if minutes > 0 { return "\(sign)\(minutes):\(String(format: "%02d", seconds))" }
        return "\(sign)\(seconds)s"
    }

    static func color(_ index: Int) -> Color {
        color(hex: paletteHex(index))
    }

    static func color(for stream: StreamDescriptor, fallback: Int) -> Color {
        if let colorHex = stream.colorHex, !colorHex.isEmpty { return color(hex: colorHex) }
        let bytes = withUnsafeBytes(of: stream.id.uuid) { Array($0) }
        let stableIndex = bytes.isEmpty ? UInt32(fallback % 9) : bytes.prefix(4).reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) } % 9
        return color(Int(stableIndex))
    }

    static func paletteHex(_ index: Int) -> String {
        ["#38bdf8", "#fb923c", "#c084fc", "#4ade80", "#f472b6", "#facc15", "#60a5fa", "#2dd4bf", "#f87171"][index % 9]
    }

    static func paletteColor(_ index: Int) -> Color { color(hex: paletteHex(index)) }

    private static func color(hex: String) -> Color {
        Color(hex: hex)
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
