import SwiftUI
import PipePlotCore

struct PlotCanvas: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let samples: [StreamID: [StoredSample]]
    let domain: ClosedRange<Date>
    @Binding var hoverDate: Date?
    @Binding var selectionStart: Date?
    @Binding var selectionPreview: Date?
    let onSelectionCommit: (Date, Date) -> Void

    private var timeSpan: TimeInterval { max(0.001, domain.upperBound.timeIntervalSince(domain.lowerBound)) }

    var body: some View {
        GeometryReader { geometry in
            Canvas(opaque: false, colorMode: .linear) { context, size in
                draw(in: context, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverDate = date(at: point.x, width: geometry.size.width)
                case .ended: hoverDate = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if selectionStart == nil { selectionStart = date(at: value.startLocation.x, width: geometry.size.width) }
                    selectionPreview = date(at: value.location.x, width: geometry.size.width)
                    hoverDate = selectionPreview
                }
                .onEnded { value in
                    let start = date(at: value.startLocation.x, width: geometry.size.width), end = date(at: value.location.x, width: geometry.size.width)
                    if abs(end.timeIntervalSince(start)) > 0.5 {
                        let lower = min(start, end), upper = max(start, end)
                        selectionStart = lower; selectionPreview = upper
                        onSelectionCommit(lower, upper)
                    } else {
                        selectionStart = nil; selectionPreview = nil
                        onSelectionCommit(Date.distantPast, Date.distantPast)
                    }
                }
            )
            .accessibilityLabel("Coordinated timeline plot. Drag to select a time interval.")
        }
    }

    private func date(at x: CGFloat, width: CGFloat) -> Date {
        let width = max(width, 1)
        return domain.lowerBound.addingTimeInterval(timeSpan * Double(min(max(x, 0), width)) / Double(width))
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let plot = CGRect(x: 0, y: 4, width: size.width, height: size.height - 22)
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
            let label = date.formatted(date: .omitted, time: .shortened)
            context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: x, y: plot.maxY + 12), anchor: index == 0 ? .leading : (index == tickCount ? .trailing : .center))
        }

        for (index, stream) in chart.streams.enumerated() {
            let data = samples[stream.id] ?? []
            guard !data.isEmpty else { continue }
            let color = Self.color(index)
            if chart.settings.linesVisible && data.count > 1 {
                var path = Path()
                for (pointIndex, sample) in data.enumerated() {
                    let position = CGPoint(x: x(sample.timestamp, in: plot), y: y(sample.value, range: valueRange, in: plot))
                    if pointIndex == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                context.stroke(path, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
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

        for guide in chart.guides {
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
            }
        }
        if let selectionStart, let selectionPreview {
            let a = x(selectionStart, in: plot), b = x(selectionPreview, in: plot)
            let rect = CGRect(x: min(a,b), y: plot.minY, width: abs(b-a), height: plot.height)
            context.fill(Path(rect), with: .color(.accentColor.opacity(0.13)))
            context.stroke(Path(rect), with: .color(.accentColor.opacity(0.8)), lineWidth: 1)
        }
        if let hoverDate {
            let xPos = x(hoverDate, in: plot)
            var path = Path(); path.move(to: CGPoint(x: xPos, y: plot.minY)); path.addLine(to: CGPoint(x: xPos, y: plot.maxY))
            context.stroke(path, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3,3]))
        }
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
