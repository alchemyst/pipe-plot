import AppKit
import SwiftUI

private struct Observation {
    let time: Double
    let value: Double
    let segment: Int
    let sequence: Int

    var state: String {
        switch value {
        case 0: "Low"
        case 1: "High"
        default: "Unsupported"
        }
    }
}

private struct PlotRow: Identifiable {
    let name: String
    let color: Color
    let discrete: Bool
    let points: [Observation]

    var id: String { name }

    init(_ name: String, _ color: Color, discrete: Bool = true, _ observations: [(Double, Double, Int)]) {
        self.name = name
        self.color = color
        self.discrete = discrete
        self.points = observations.enumerated().map { index, row in
            Observation(time: row.0, value: row.1, segment: row.2, sequence: index)
        }
    }

    func associates(_ a: Observation, _ b: Observation) -> Bool {
        guard a.segment == b.segment else { return false }
        if !discrete { return true }
        return a.value == b.value && a.state != "Unsupported" && b.time - a.time <= 2
    }
}

private struct StateLaneLab: View {
    private enum DragMode: String, CaseIterable { case pan = "Pan", select = "Select" }

    private struct Cursor {
        let row: String
        let observation: Observation
    }

    private static let initialDomain = 0.0...20.0
    private static let epoch = Date(timeIntervalSince1970: 1_799_136_000)
    private let rows = [
        PlotRow(
            "Pressure", .blue, discrete: false,
            [
                (0, 26, 0), (2, 54, 0), (3.5, 63, 0), (5, 57, 0), (6.5, 77, 0), (8, 52, 0), (9.5, 39, 0),
                (11, 46, 0), (12, 72, 0), (14, 85, 0), (16, 56, 0), (18, 52, 0), (20, 31, 0),
            ]),
        PlotRow(
            "Inlet valve", .cyan,
            [
                (1, 0, 0), (2.25, 0, 0), (3, 1, 0), (4.25, 1, 0), (5, 0.5, 0), (6, 1, 0), (10.5, 1, 0),
                (11.5, 1, 0), (13.75, 1, 1), (14.5, 0, 1), (15.75, 0, 1),
            ]),
        PlotRow(
            "Pump enabled", .orange,
            [
                (0.5, 1, 0), (1.75, 1, 0), (2.5, 0, 0), (4, 0, 0), (5.25, 0, 1), (6.75, 0, 1),
                (8.25, 2, 1), (9.5, 1, 1), (10.5, 1, 1), (16.5, 1, 1), (17.5, 0, 1), (18.25, 0, 1),
            ]),
    ]

    @State private var domain = Self.initialDomain
    @State private var dragDomain: ClosedRange<Double>?
    @State private var selection: ClosedRange<Double>?
    @State private var selectionAnchor: Double?
    @State private var mode = DragMode.pan
    @State private var cursor: Cursor?
    @FocusState private var focusedRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("State lane experiment").font(.title2.weight(.semibold))
            Text("Observed states share the pressure timeline. Space between observations is unknown.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Picker("Drag", selection: $mode) {
                    ForEach(DragMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button("Pan left") { pan(-span / 4) }
                Button("Pan right") { pan(span / 4) }
                Button("Zoom in") { zoom(by: 0.5) }
                Button("Zoom out") { zoom(by: 2) }
                Button("Reset view") {
                    domain = Self.initialDomain
                    cursor = nil
                }
                Button("Clear selection") {
                    selection = nil
                    selectionAnchor = nil
                }.disabled(selection == nil)
            }
            VStack(spacing: 3) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        rowLabel(row)
                        plot(row)
                    }
                    .frame(height: row.discrete ? 88 : 150)
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: 108)
                    GeometryReader { geometry in
                        ForEach(0...4, id: \.self) { index in
                            let time = domain.lowerBound + Double(index) * span / 4
                            Text("\(time.formatted(.number.precision(.fractionLength(1)))) s")
                                .font(.caption2.monospacedDigit())
                                .position(x: x(time, geometry.size.width), y: 9)
                        }
                    }
                    .frame(height: 19)
                    .accessibilityHidden(true)
                }
            }
            Text(rangeSummary).font(.callout.monospacedDigit())
            Text(cursor.map(describe) ?? "No nearby observation")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Tab to a plot. Left and Right step through observations. Space sets a selection boundary.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .padding(.trailing, 14)
        .frame(minWidth: 840, minHeight: 535)
    }

    private var span: Double { domain.upperBound - domain.lowerBound }

    private var rangeSummary: String {
        let visible = "Visible \(seconds(domain.lowerBound)) to \(seconds(domain.upperBound))"
        guard let selection else { return visible + " · No selection" }
        let status = selectionAnchor == nil ? "Selected" : "Selecting"
        return visible + " · \(status) \(seconds(selection.lowerBound)) to \(seconds(selection.upperBound))"
    }

    private func seconds(_ time: Double) -> String {
        time.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    private func describe(_ cursor: Cursor) -> String {
        let observation = cursor.observation
        let date = Self.epoch.addingTimeInterval(observation.time)
        let receipt = date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        let raw = "\(cursor.row), raw \(observation.value) at \(receipt)"
        let row = rows.first { $0.id == cursor.row }
        return row?.discrete == true ? raw + ", " + observation.state : raw
    }

    private func rowLabel(_ row: PlotRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.name).font(.headline)
            Text(row.discrete ? "High / Low / Other" : "Analog · 0–100")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 108, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func plot(_ row: PlotRow) -> some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(row, in: size, context: context)
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(focusedRow == row.id ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .clipped()
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let width = geometry.size.width
                    let nearby = row.points.filter { domain.contains($0.time) }
                        .min {
                            abs(x($0.time, width) - point.x) < abs(x($1.time, width) - point.x)
                        }
                    if let nearby, abs(x(nearby.time, width) - point.x) <= 10 {
                        cursor = Cursor(row: row.id, observation: nearby)
                    } else {
                        cursor = nil
                    }
                case .ended:
                    if cursor?.row == row.id { cursor = nil }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { gesture in
                        let width = geometry.size.width
                        if mode == .pan {
                            let base = dragDomain ?? domain
                            dragDomain = base
                            let offset = -gesture.translation.width / width * (base.upperBound - base.lowerBound)
                            domain = (base.lowerBound + offset)...(base.upperBound + offset)
                            cursor = nil
                        } else {
                            selectionAnchor = nil
                            let start = time(at: gesture.startLocation.x, width: width)
                            let end = time(at: gesture.location.x, width: width)
                            selection = min(start, end)...max(start, end)
                        }
                    }
                    .onEnded { _ in dragDomain = nil }
            )
        }
        .focusable()
        .focused($focusedRow, equals: row.id)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
            step(row, forward: key.key == .rightArrow)
            return .handled
        }
        .onKeyPress(.space) {
            setSelectionBoundary(in: row)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.discrete ? "\(row.name) state lane" : "\(row.name) analog chart")
        .accessibilityValue(cursor.flatMap { $0.row == row.id ? describe($0) : nil } ?? "No observation selected")
        .accessibilityHint("Adjust to step between visible raw observations.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(row, forward: true)
            case .decrement: step(row, forward: false)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Set selection boundary")) { setSelectionBoundary(in: row) }
    }

    private func step(_ row: PlotRow, forward: Bool) {
        let visible = row.points.filter { domain.contains($0.time) }
        guard let first = visible.first, let last = visible.last else {
            cursor = nil
            return
        }
        if let cursor, cursor.row == row.id,
            let index = visible.firstIndex(where: { $0.sequence == cursor.observation.sequence })
        {
            let next = min(max(index + (forward ? 1 : -1), 0), visible.count - 1)
            self.cursor = Cursor(row: row.id, observation: visible[next])
        } else {
            cursor = Cursor(row: row.id, observation: forward ? first : last)
        }
        if let selectionAnchor, let time = cursor?.observation.time {
            selection = min(selectionAnchor, time)...max(selectionAnchor, time)
        }
    }

    private func setSelectionBoundary(in row: PlotRow) {
        if cursor?.row != row.id { step(row, forward: true) }
        guard let time = cursor?.observation.time else { return }
        if let selectionAnchor {
            selection = min(selectionAnchor, time)...max(selectionAnchor, time)
            self.selectionAnchor = nil
        } else {
            selectionAnchor = time
            selection = time...time
        }
    }

    private func pan(_ offset: Double) {
        domain = (domain.lowerBound + offset)...(domain.upperBound + offset)
        cursor = nil
    }

    private func zoom(by factor: Double) {
        let center = (domain.lowerBound + domain.upperBound) / 2
        let halfSpan = min(max(span * factor / 2, 0.5), 100)
        domain = (center - halfSpan)...(center + halfSpan)
        cursor = nil
    }

    private func x(_ time: Double, _ width: Double) -> Double {
        (time - domain.lowerBound) / span * width
    }

    private func time(at x: Double, width: Double) -> Double {
        domain.lowerBound + min(max(x / width, 0), 1) * span
    }

    private func draw(_ row: PlotRow, in size: CGSize, context: GraphicsContext) {
        func line(_ a: CGPoint, _ b: CGPoint, color: Color, style: StrokeStyle = .init(lineWidth: 1)) {
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(path, with: .color(color), style: style)
        }
        func point(_ sample: Observation) -> CGPoint {
            let fraction: Double
            if row.discrete {
                fraction = sample.value == 1 ? 0.23 : sample.value == 0 ? 0.55 : 0.83
            } else {
                fraction = 1 - sample.value / 100
            }
            return CGPoint(x: x(sample.time, size.width), y: size.height * fraction)
        }
        if let selection {
            let lower = x(selection.lowerBound, size.width), upper = x(selection.upperBound, size.width)
            let shade = CGRect(x: lower, y: 0, width: upper - lower, height: size.height)
            context.fill(Path(shade), with: .color(Color.accentColor.opacity(0.17)))
        }
        for index in 0...4 {
            let gridX = Double(index) * size.width / 4
            line(CGPoint(x: gridX, y: 0), CGPoint(x: gridX, y: size.height), color: .secondary.opacity(0.25))
        }
        if row.discrete {
            for fraction in [0.23, 0.55, 0.83] {
                let y = size.height * fraction
                line(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y), color: .secondary.opacity(0.18))
            }
        }
        for (a, b) in zip(row.points, row.points.dropFirst()) where row.associates(a, b) {
            line(
                point(a), point(b), color: row.color.opacity(row.discrete ? 0.65 : 1),
                style: StrokeStyle(lineWidth: 1.5, dash: row.discrete ? [2, 4] : []))
        }
        for sample in row.points where domain.contains(sample.time) {
            let p = point(sample)
            let mark = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            if row.discrete, sample.state == "Unsupported" {
                context.stroke(Path(mark), with: .color(.pink), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: mark), with: .color(row.color))
            }
        }
        if let cursor, domain.contains(cursor.observation.time) {
            let current = x(cursor.observation.time, size.width)
            line(
                CGPoint(x: current, y: 0), CGPoint(x: current, y: size.height),
                color: .primary.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

@main
struct StateLaneLabApp: App {
    var body: some Scene {
        WindowGroup("PipePlot State Lane Lab") {
            StateLaneLab()
        }
        .defaultSize(width: 970, height: 585)
    }
}
