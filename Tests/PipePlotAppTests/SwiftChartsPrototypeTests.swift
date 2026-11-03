import AppKit
import Charts
import Observation
import PipePlotCore
import SwiftUI
import XCTest
@testable import PipePlotApp

/// Issue #35 research only. This view is deliberately absent from the app target.
private struct PrototypePoint: Identifiable {
    let id: String
    let series: String
    let sample: StoredSample
    let color: Color
    let lines: Bool
    let dots: Bool
}

private struct PrototypeVectorPoint {
    let timestamp: Date
    let value: Double
    let series: String
    let color: Color
    let lines: Bool
    let dots: Bool
}

@MainActor
private final class PlotProbe {
    var frames: [String: CGRect] = [:]
    var mappedX: [String: CGFloat] = [:]
    var mappedMidX: [String: CGFloat] = [:]
    var mappedUpperX: [String: CGFloat] = [:]
    var mappedY: [String: CGFloat] = [:]
    var hover: [String: Date] = [:]
    var panCount = 0
}

@MainActor
private final class MenuProbe: NSObject, NSMenuDelegate {
    var opened = false
    var closed = false
    var openAtUpdate = false
    func menuWillOpen(_ menu: NSMenu) { opened = true }
    func menuDidClose(_ menu: NSMenu) { closed = true }
}

private struct SwiftChartsPrototype: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let samples: [StreamID: [StoredSample]]
    let domain: ClosedRange<Date>
    let now: Date
    let selection: TimeSelection?
    let forecasts: [ForecastDrawing]
    let probe: PlotProbe
    let key: String
    let vectorized: Bool
    var onGuide: (Guide, PlotGesturePhase) -> Void = { _, _ in }
    var onSelection: (Date, Date, PlotGesturePhase) -> Void = { _, _, _ in }
    var onPan: (CGSize, PlotGesturePhase, CGFloat) -> Void = { _, _, _ in }
    var onZoom: (Double, Date, PlotGesturePhase) -> Void = { _, _, _ in }

    private var valueRange: ClosedRange<Double> {
        if case let .fixed(low, high) = chart.settings.yScale, low < high { return low...high }
        var values = chart.streams.flatMap { samples[$0.id, default: []].map(\.value) }
        values += chart.guides.filter { $0.orientation == .horizontalValue }.map(\.value)
        if chart.settings.includeZero { values.append(0) }
        values += forecasts.filter { forecast in
            chart.streams.contains(where: { $0.id == forecast.streamID })
        }.map(\.value)
        return PlotValueRange.automatic(values)
    }

    private var points: [PrototypePoint] {
        chart.streams.enumerated().flatMap { index, stream in
            var previous: String?
            var segmentNumber = -1
            return (samples[stream.id] ?? []).enumerated().map { position, sample in
                if position == 0 || previous != sample.segmentID { segmentNumber += 1 }
                previous = sample.segmentID
                return PrototypePoint(
                    id: "\(stream.id)-\(sample.sequence)",
                    series: "\(stream.id)-\(segmentNumber)", sample: sample,
                    color: PlotCanvas.color(for: stream, fallback: index),
                    lines: stream.linesVisible ?? chart.settings.linesVisible,
                    dots: stream.dotsVisible ?? chart.settings.dotsVisible)
            }
        }
    }

    private var vectorPoints: [PrototypeVectorPoint] {
        chart.streams.enumerated().flatMap { index, stream in
            let rows = samples[stream.id] ?? []
            var previous: String?
            var segment = -1
            let color = PlotCanvas.color(for: stream, fallback: index)
            let dots = stream.dotsVisible ?? chart.settings.dotsVisible
            let lines = stream.linesVisible ?? chart.settings.linesVisible
            guard lines || dots else { return [PrototypeVectorPoint]() }
            return rows.enumerated().map { position, sample in
                if position == 0 || previous != sample.segmentID { segment += 1 }
                previous = sample.segmentID
                return PrototypeVectorPoint(
                    timestamp: sample.timestamp, value: sample.value,
                    series: "\(stream.id)-\(segment)", color: color, lines: lines, dots: dots)
            }
        }
    }

    var body: some View {
        let range = valueRange
        let collection = vectorized ? vectorPoints : []
        let lineData = collection.filter(\.lines)
        let dotData = collection.filter(\.dots)
        let timeReference = session.timeGuides.first { $0.id == session.timeline.referenceTimeGuideID }
            .map { Date(timeIntervalSince1970: $0.value) }
        let valueReference = chart.guides.first { $0.id == chart.settings.referenceGuideID }?.value ?? 0
        Chart {
            if let selection {
                let bounds = selection.resolvedBounds(at: now)
                RectangleMark(xStart: .value("Start", bounds.lowerBound), xEnd: .value("End", bounds.upperBound))
                    .foregroundStyle((selection.mode == .fixed ? Color.accentColor : .green).opacity(0.13))
            }
            if vectorized {
                LinePlot(
                    lineData, x: .value("Time", \.timestamp), y: .value("Value", \.value),
                    series: .value("Segment", \.series)
                )
                .foregroundStyle(\.color)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                PointPlot(dotData, x: .value("Time", \.timestamp), y: .value("Value", \.value))
                    .foregroundStyle(\.color)
                    .symbolSize(24)
            } else {
                ForEach(points) { point in
                    if point.lines {
                        LineMark(
                            x: .value("Time", point.sample.timestamp), y: .value("Value", point.sample.value),
                            series: .value("Segment", point.series)
                        )
                        .foregroundStyle(point.color.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    if point.dots {
                        PointMark(x: .value("Time", point.sample.timestamp), y: .value("Value", point.sample.value))
                            .foregroundStyle(point.color)
                            .symbolSize(24)
                    }
                }
            }
            ForEach(chart.guides.filter { $0.orientation == .horizontalValue }) { guide in
                RuleMark(y: .value("Guide", guide.value))
                    .foregroundStyle(Color(hex: guide.color))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            ForEach(session.timeGuides.filter { $0.orientation == .verticalTime }) { guide in
                RuleMark(x: .value("Guide", Date(timeIntervalSince1970: guide.value)))
                    .foregroundStyle(Color(hex: guide.color))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            if domain.contains(now) {
                RuleMark(x: .value("Now", now)).foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
            }
            ForEach(forecasts.indices, id: \.self) { index in
                let forecast = forecasts[index]
                let start = min(max(forecast.range.upperBound, domain.lowerBound), now)
                if forecast.crossing > start {
                    LineMark(
                        x: .value("Forecast time", start), y: .value("Estimate", forecast.fit.value(at: start)),
                        series: .value("Forecast", "forecast-\(index)")
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    LineMark(
                        x: .value("Forecast time", forecast.crossing), y: .value("Estimate", forecast.value),
                        series: .value("Forecast", "forecast-\(index)")
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
        }
        .chartPlotStyle { plot in
            plot.padding(.top, 4).padding(.bottom, 1)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: range)
        .chartXAxis {
            AxisMarks(position: .bottom, values: .automatic(desiredCount: 5)) { axis in
                AxisValueLabel {
                    if let date = axis.as(Date.self) {
                        Text(TimeText.format(date, zone: session.timeline.timeZone, reference: timeReference))
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { axis in
                AxisGridLine()
                AxisValueLabel {
                    if let value = axis.as(Double.self) {
                        Text(
                            NumericText.format(
                                value - valueReference, scale: chart.settings.numericScale, unit: chart.settings.unit)
                        )
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    PlotInteractionOverlay(
                        guides: chart.guides + session.timeGuides,
                        selectionRange: selection?.resolvedBounds(at: now), selectionMode: selection?.mode,
                        now: now, plotBounds: frame,
                        timeAtX: { x in
                            proxy.value(atX: x - frame.minX, as: Date.self) ?? domain.lowerBound
                        },
                        valueAtY: { y in
                            proxy.value(atY: y - frame.minY, as: Double.self) ?? range.lowerBound
                        },
                        xAtTime: { date in frame.minX + (proxy.position(forX: date) ?? 0) },
                        yAtValue: { value in frame.minY + (proxy.position(forY: value) ?? 0) },
                        onGuide: onGuide,
                        onSelection: { start, end, _, _, phase in
                            onSelection(start, end, phase)
                        },
                        onPan: { delta, phase in
                            probe.panCount += 1
                            onPan(delta, phase, frame.width)
                        },
                        onZoom: onZoom, onHover: { probe.hover[key] = $0 }
                    )
                    .onAppear {
                        probe.frames[key] = frame
                        probe.mappedX[key] = frame.minX + (proxy.position(forX: domain.lowerBound) ?? 0)
                        let middle = domain.lowerBound.addingTimeInterval(
                            domain.upperBound.timeIntervalSince(domain.lowerBound) / 2)
                        probe.mappedMidX[key] = frame.minX + (proxy.position(forX: middle) ?? 0)
                        probe.mappedUpperX[key] = frame.minX + (proxy.position(forX: domain.upperBound) ?? 0)
                        probe.mappedY[key] = frame.minY + (proxy.position(forY: range.lowerBound) ?? 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.title)
        .accessibilityAddTraits(.isImage)
        .accessibilityValue(
            PlotAccessibility(
                chart: chart, session: session, samples: samples, readyDisplays: Set(chart.streams.map(\.id)),
                failedDisplays: [], domain: domain, now: now, valueRange: range, selection: selection,
                forecasts: forecasts
            ).summary
        )
        .accessibilityChartDescriptor(
            PlotAccessibility(
                chart: chart, session: session, samples: samples, readyDisplays: Set(chart.streams.map(\.id)),
                failedDisplays: [], domain: domain, now: now, valueRange: range, selection: selection,
                forecasts: forecasts))
    }
}

private struct ResearchStack: View {
    let kind: String
    let session: SessionSnapshot
    let samples: [StreamID: [StoredSample]]
    let domain: ClosedRange<Date>
    let now: Date
    let selection: TimeSelection
    let forecasts: [ForecastDrawing]
    let probe: PlotProbe

    var body: some View {
        VStack(spacing: 0) {
            ForEach(session.charts) { chart in
                Group {
                    if kind != "canvas" {
                        SwiftChartsPrototype(
                            chart: chart, session: session, samples: samples, domain: domain,
                            now: now, selection: selection,
                            forecasts: forecasts.filter { forecast in
                                chart.streams.contains { $0.id == forecast.streamID }
                            }, probe: probe, key: chart.title, vectorized: kind == "chartsVector")
                    } else {
                        PlotCanvas(
                            chart: chart, session: session, samples: samples,
                            currentDisplays: Set(chart.streams.map(\.id)),
                            readyDisplays: Set(chart.streams.map(\.id)), domain: domain, now: now,
                            hoverDate: .constant(nil), selectionStart: .constant(nil),
                            selectionPreview: .constant(nil), selectionLinkedPreview: .constant(false),
                            selection: selection,
                            forecasts: forecasts.filter { forecast in
                                chart.streams.contains { $0.id == forecast.streamID }
                            }, onSelectionCommit: { _, _, _ in },
                            onGuide: { _, _ in }, onPan: { _, _, _ in probe.panCount += 1 },
                            onZoom: { _, _, _ in })
                    }
                }.frame(height: 310)
            }
        }
    }
}

@MainActor
@Observable
private final class ResearchPreviewState {
    var domain: ClosedRange<Date>
    var reconnect = false
    init(domain: ClosedRange<Date>) { self.domain = domain }
}

/// Temporary interactive windows for native inspection; never used by the app scene.
private struct ResearchPreview: View {
    let kind: String
    let liveSamples: [StreamID: [StoredSample]]
    let reconnectSamples: [StreamID: [StoredSample]]
    let liveForecasts: [ForecastDrawing]
    let reconnectForecasts: [ForecastDrawing]
    let liveDomain: ClosedRange<Date>
    let reconnectDomain: ClosedRange<Date>
    let now: Date
    let viewState: ResearchPreviewState
    let probe = PlotProbe()
    @State private var session: SessionSnapshot
    @State private var selection: TimeSelection?
    @State private var hover: Date?
    @State private var selectionStart: Date?
    @State private var selectionPreview: Date?
    @State private var selectionLinkedPreview = false

    init(
        kind: String, session: SessionSnapshot, liveSamples: [StreamID: [StoredSample]],
        reconnectSamples: [StreamID: [StoredSample]], liveForecasts: [ForecastDrawing],
        reconnectForecasts: [ForecastDrawing], liveDomain: ClosedRange<Date>,
        reconnectDomain: ClosedRange<Date>, now: Date, viewState: ResearchPreviewState
    ) {
        self.kind = kind
        self.liveSamples = liveSamples
        self.reconnectSamples = reconnectSamples
        self.liveForecasts = liveForecasts
        self.reconnectForecasts = reconnectForecasts
        self.liveDomain = liveDomain
        self.reconnectDomain = reconnectDomain
        self.now = now
        self.viewState = viewState
        _session = State(initialValue: session)
        _selection = State(
            initialValue: TimeSelection(
                start: liveDomain.lowerBound.addingTimeInterval(120),
                end: liveDomain.lowerBound.addingTimeInterval(480)))
    }

    private var domain: ClosedRange<Date> { viewState.domain }
    private var samples: [StreamID: [StoredSample]] {
        viewState.reconnect ? reconnectSamples : liveSamples
    }
    private var forecasts: [ForecastDrawing] {
        viewState.reconnect ? reconnectForecasts : liveForecasts
    }

    private func pan(_ delta: CGSize, _ phase: PlotGesturePhase, _ width: CGFloat) {
        guard phase == .changed || phase == .ended else { return }
        let shift = -Double(delta.width / max(width, 1)) * domain.upperBound.timeIntervalSince(domain.lowerBound)
        viewState.domain = domain.lowerBound.addingTimeInterval(shift)...domain.upperBound.addingTimeInterval(shift)
    }

    private func zoom(_ factor: Double, _ anchor: Date, _ phase: PlotGesturePhase) {
        guard phase == .changed || phase == .ended, factor.isFinite, factor > 0 else { return }
        let low = anchor.addingTimeInterval(domain.lowerBound.timeIntervalSince(anchor) / factor)
        let high = anchor.addingTimeInterval(domain.upperBound.timeIntervalSince(anchor) / factor)
        viewState.domain = low...high
    }

    private func updateGuide(_ guide: Guide, phase: PlotGesturePhase, chartID: ChartID) {
        guard phase == .changed || phase == .ended,
            let index = session.charts.firstIndex(where: { $0.id == chartID })
        else { return }
        if let existing = session.charts[index].guides.firstIndex(where: { $0.id == guide.id }) {
            session.charts[index].guides[existing] = guide
        } else {
            session.charts[index].guides.append(guide)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(kind == "canvas" ? "Canvas · research fixture" : "Swift Charts vector · research fixture")
                    .font(.headline)
                Spacer()
                Button(kind == "canvas" ? "Show Swift Charts" : "Show Canvas") {
                    let title = kind == "canvas" ? "Issue 35 · Swift Charts vector" : "Issue 35 · Canvas"
                    NSApp.activate()
                    NSApp.windows.first { $0.title.hasPrefix(title) }?.makeKeyAndOrderFront(nil)
                }
                SnapshotMenu(title: "Plot navigation") {
                    [
                        .command("Select visible time range") {
                            selection = TimeSelection(start: domain.lowerBound, end: domain.upperBound)
                        },
                        .command("Clear selection") { selection = nil },
                        .command("Show reconnect gap") {
                            viewState.reconnect = true
                            viewState.domain = reconnectDomain
                            selection = nil
                        },
                        .command("Show live 15 minutes") {
                            viewState.reconnect = false
                            viewState.domain = liveDomain
                            selection = nil
                        },
                        .command("Reset view") {
                            viewState.domain = viewState.reconnect ? reconnectDomain : liveDomain
                        },
                    ]
                }
            }.padding(.horizontal, 12)
            ForEach(session.charts) { chart in
                Group {
                    if kind == "canvas" {
                        PlotCanvas(
                            chart: chart, session: session, samples: samples,
                            currentDisplays: Set(chart.streams.map(\.id)),
                            readyDisplays: Set(chart.streams.map(\.id)), domain: domain, now: now,
                            hoverDate: $hover, selectionStart: $selectionStart,
                            selectionPreview: $selectionPreview, selectionLinkedPreview: $selectionLinkedPreview,
                            selection: selection,
                            forecasts: forecasts.filter { forecast in
                                chart.streams.contains { $0.id == forecast.streamID }
                            },
                            onSelectionCommit: { start, end, mode in
                                if let start, let end {
                                    selection = TimeSelection(start: start, end: end, mode: mode ?? .fixed)
                                }
                            },
                            onGuide: { guide, phase in updateGuide(guide, phase: phase, chartID: chart.id) },
                            onPan: pan, onZoom: zoom)
                    } else {
                        SwiftChartsPrototype(
                            chart: chart, session: session, samples: samples, domain: domain,
                            now: now, selection: selection,
                            forecasts: forecasts.filter { forecast in
                                chart.streams.contains { $0.id == forecast.streamID }
                            }, probe: probe,
                            key: chart.title, vectorized: true,
                            onGuide: { guide, phase in updateGuide(guide, phase: phase, chartID: chart.id) },
                            onSelection: { start, end, phase in
                                if phase == .ended { selection = TimeSelection(start: start, end: end) }
                            },
                            onPan: pan, onZoom: zoom)
                    }
                }.frame(height: 310)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 1000, height: 700)
    }
}

@MainActor
final class SwiftChartsPrototypeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture(streams: Int, points: Int, spacing: TimeInterval) -> (
        SessionSnapshot, [StreamID: [StoredSample]], ClosedRange<Date>
    ) {
        var charts: [ChartSnapshot] = []
        var samples: [StreamID: [StoredSample]] = [:]
        let end = start.addingTimeInterval(Double(points - 1) * spacing)
        for row in 0..<2 {
            var descriptors: [StreamDescriptor] = []
            for column in 0..<streams {
                let id = UUID()
                var stream = StreamDescriptor(id: id, name: "Series \(row)-\(column)")
                stream.colorHex = PlotCanvas.paletteHex(row * 5 + column)
                stream.dotsVisible = column == 0
                stream.lastSampleAt = end
                descriptors.append(stream)
                samples[id] = (0..<points).map { index in
                    StoredSample(
                        timestamp: start.addingTimeInterval(Double(index) * spacing), sequence: UInt64(index),
                        value: Double(row * 1000 + column * 30) + sin(Double(index) / 17) * Double(row == 0 ? 3 : 60),
                        segmentID: index < points / 2 ? "first" : "reconnected")
                }
            }
            var chart = ChartSnapshot(id: UUID(), title: "Row \(row)", streams: descriptors)
            chart.settings.unit = row == 0 ? "mV" : "kPa"
            let guide = Guide(orientation: .horizontalValue, value: row == 0 ? 2 : 1030, label: "Reference")
            chart.guides = [guide]
            chart.settings.referenceGuideID = guide.id
            charts.append(chart)
        }
        var session = SessionSnapshot(id: UUID(), number: 1, title: "Prototype", charts: charts)
        let event = Guide(
            orientation: .verticalTime, value: start.addingTimeInterval(spacing * 3).timeIntervalSince1970)
        session.timeGuides = [event]
        session.timeline.referenceTimeGuideID = event.id
        return (session, samples, start...end.addingTimeInterval(spacing * 10))
    }

    private func historyFixture(path: String, live: Bool) throws -> (
        SessionSnapshot, [StreamID: [StoredSample]], ClosedRange<Date>, Int
    ) {
        let store = try SampleStore(readOnlyDatabaseURL: URL(fileURLWithPath: path))
        let end = start.addingTimeInterval(Double(120_959 * 5 + 180))
        let from = live ? end.addingTimeInterval(-900) : start
        let domain = from...end.addingTimeInterval(300)
        var charts: [ChartSnapshot] = []
        var samples: [StreamID: [StoredSample]] = [:]
        let queryStart = CFAbsoluteTimeGetCurrent()
        for row in 0..<2 {
            var descriptors: [StreamDescriptor] = []
            for column in 0..<5 {
                let suffix = row * 5 + column + 1
                let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", suffix)))
                var stream = StreamDescriptor(id: id, name: "Series \(row)-\(column)")
                stream.colorHex = PlotCanvas.paletteHex(row * 5 + column)
                stream.dotsVisible = column == 0
                stream.lastSampleAt = end
                descriptors.append(stream)
                let bounded = try store.displaySamples(streamID: id, from: from, to: end, bucketCount: 800)
                XCTAssertFalse(bounded.isEmpty, "Seeded stream \(id) must have visible rows")
                XCTAssertLessThanOrEqual(bounded.count, 3200)
                samples[id] = bounded
            }
            var chart = ChartSnapshot(id: UUID(), title: "Row \(row)", streams: descriptors)
            chart.settings.unit = row == 0 ? "mV" : "kPa"
            let guide = Guide(orientation: .horizontalValue, value: row == 0 ? 2 : 1030, label: "Reference")
            chart.guides = [guide]
            chart.settings.referenceGuideID = guide.id
            charts.append(chart)
        }
        print(
            "CHARTS_RESEARCH query=\(live ? "last15m" : "fullWeek") duration=\(CFAbsoluteTimeGetCurrent() - queryStart)s boundedRows=\(samples.values.reduce(0) { $0 + $1.count })"
        )
        var session = SessionSnapshot(id: UUID(), number: 1, title: "History", charts: charts)
        let event = Guide(orientation: .verticalTime, value: from.addingTimeInterval(180).timeIntervalSince1970)
        session.timeGuides = [event]
        session.timeline.referenceTimeGuideID = event.id
        return (session, samples, domain, 120_960 * 10)
    }

    private func forecast(
        for stream: StreamDescriptor, samples: [StreamID: [StoredSample]], domain: ClosedRange<Date>
    ) throws -> [ForecastDrawing] {
        let rows = try XCTUnwrap(samples[stream.id])
        guard rows.count > 3 else { return [] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(databaseURL: directory.appendingPathComponent("forecast.sqlite"))
        let first = rows[rows.count - 3]
        let last = rows[rows.count - 1]
        try store.append(first, to: stream.id)
        try store.append(last, to: stream.id)
        guard let fit = try store.linearFit(streamID: stream.id, from: first.timestamp, to: last.timestamp) else {
            return []
        }
        let crossing = min(domain.upperBound, last.timestamp.addingTimeInterval(60))
        return [
            ForecastDrawing(
                streamID: stream.id, fit: fit, range: first.timestamp...last.timestamp,
                crossing: crossing, value: fit.value(at: crossing))
        ]
    }

    private func plotViews(in view: NSView) -> [PlotInteractionView] {
        (view as? PlotInteractionView).map { [$0] } ?? view.subviews.flatMap { plotViews(in: $0) }
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func runComparison(
        name: String, session: SessionSnapshot, samples: [StreamID: [StoredSample]],
        domain: ClosedRange<Date>, rawRows: Int
    ) throws {
        let now = domain.upperBound.addingTimeInterval(-300)
        let selection = TimeSelection(start: domain.lowerBound.addingTimeInterval(120), end: now)
        let forecasts = try forecast(for: session.charts[0].streams[0], samples: samples, domain: domain)
        for kind in ["canvas", "charts", "chartsVector", "chartsVector", "charts", "canvas"] {
            let probe = PlotProbe()
            let rssBefore = residentBytes()
            let began = CFAbsoluteTimeGetCurrent()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: ResearchStack(
                    kind: kind, session: session, samples: samples, domain: domain,
                    now: now, selection: selection, forecasts: forecasts, probe: probe))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let mountElapsed = CFAbsoluteTimeGetCurrent() - began
            let updateStart = CFAbsoluteTimeGetCurrent()
            for step in 1...3 {
                let updatedNow = now.addingTimeInterval(Double(step) * 5)
                let updatedSelection = TimeSelection(
                    start: selection.start.addingTimeInterval(Double(step) * 5), end: updatedNow)
                var updatedSamples = samples
                for id in updatedSamples.keys {
                    guard let last = updatedSamples[id]?.last else { continue }
                    updatedSamples[id]?.append(
                        StoredSample(
                            timestamp: updatedNow, sequence: last.sequence + UInt64(step),
                            value: last.value + Double(step) * 0.1, segmentID: last.segmentID))
                }
                host.rootView = ResearchStack(
                    kind: kind, session: session, samples: updatedSamples, domain: domain,
                    now: updatedNow, selection: updatedSelection, forecasts: forecasts, probe: probe)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            let updatesElapsed = CFAbsoluteTimeGetCurrent() - updateStart
            let rssAfterUpdates = residentBytes()
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let bounded = samples.values.reduce(0) { $0 + $1.count }
            print(
                "CHARTS_RESEARCH case=\(name) kind=\(kind) rawRows=\(rawRows) boundedRows=\(bounded) mount=\(mountElapsed)s update3=\(updatesElapsed)s rssBefore=\(rssBefore) rssAfterUpdates=\(rssAfterUpdates) processPeakRSS=\(usage.ru_maxrss)"
            )
            XCTAssertLessThanOrEqual(bounded, 32_000)
            let views = plotViews(in: host)
            XCTAssertEqual(views.count, 2)
            let gestureStart = CFAbsoluteTimeGetCurrent()
            for (index, view) in views.enumerated() {
                let key = session.charts[index].title
                let frame =
                    kind != "canvas"
                    ? try XCTUnwrap(probe.frames[key])
                    : CGRect(x: 56, y: 4, width: 944, height: 288)
                let beforePan = probe.panCount
                func mouse(_ type: NSEvent.EventType, _ offset: CGFloat) throws -> NSEvent {
                    try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type,
                            location: view.convert(NSPoint(x: frame.minX + 30 + offset, y: frame.midY), to: nil),
                            modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                }
                view.mouseDown(with: try mouse(.leftMouseDown, 0))
                view.mouseDragged(with: try mouse(.leftMouseDragged, 20))
                view.mouseUp(with: try mouse(.leftMouseUp, 20))
                XCTAssertGreaterThan(probe.panCount, beforePan)
            }
            print(
                "CHARTS_RESEARCH case=\(name) kind=\(kind) nativePanDispatch2=\(CFAbsoluteTimeGetCurrent() - gestureStart)s"
            )
            if kind != "canvas" {
                XCTAssertEqual(probe.frames.count, 2)
                for frame in probe.frames.values {
                    XCTAssertEqual(frame, CGRect(x: 56, y: 4, width: 944, height: 288))
                }
                XCTAssertEqual(
                    try XCTUnwrap(probe.frames["Row 0"]).minX,
                    try XCTUnwrap(probe.frames["Row 1"]).minX, accuracy: 1)
                for (index, view) in views.enumerated() {
                    let key = session.charts[index].title
                    let frame = try XCTUnwrap(probe.frames[key])
                    let x = try XCTUnwrap(probe.mappedX[key])
                    XCTAssertEqual(x, 56, accuracy: 1)
                    XCTAssertEqual(try XCTUnwrap(probe.mappedMidX[key]), 528, accuracy: 1)
                    XCTAssertEqual(try XCTUnwrap(probe.mappedUpperX[key]), 1000, accuracy: 1)
                    XCTAssertEqual(try XCTUnwrap(probe.mappedY[key]), frame.maxY, accuracy: 2)
                    let event = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: .mouseMoved, location: view.convert(NSPoint(x: x + 10, y: frame.midY), to: nil),
                            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                    view.mouseMoved(with: event)
                    XCTAssertNotNil(probe.hover[key])
                    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
                    let expected = domain.lowerBound.addingTimeInterval(span * 10 / frame.width)
                    XCTAssertLessThan(
                        abs(try XCTUnwrap(probe.hover[key]).timeIntervalSince(expected)),
                        max(0.05, span / frame.width / 2))
                }
                print("CHARTS_RESEARCH case=\(name) frames=\(probe.frames) mappedY=\(probe.mappedY)")
            }
            if name == "sparse1m" {
                let menuProbe = MenuProbe()
                let menu = SnapshotMenuItem.menu([.command("Select visible time range", action: {})])
                menu.delegate = menuProbe
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    menuProbe.openAtUpdate = menuProbe.opened && !menuProbe.closed
                    host.rootView = ResearchStack(
                        kind: kind, session: session, samples: samples, domain: domain,
                        now: now.addingTimeInterval(20), selection: selection,
                        forecasts: forecasts, probe: probe)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    menu.cancelTracking()
                }
                _ = menu.popUp(positioning: nil, at: NSPoint(x: 80, y: 320), in: host)
                XCTAssertTrue(menuProbe.opened)
                XCTAssertTrue(menuProbe.openAtUpdate)
                XCTAssertEqual(menu.items.map(\.title), ["Select visible time range"])
                print(
                    "CHARTS_RESEARCH case=\(name) kind=\(kind) menuStayedOpenDuringHostUpdate=\(menuProbe.openAtUpdate)"
                )
            }
            window.orderOut(nil)
            XCTAssertFalse(window.isVisible)
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.isVisible)
            window.close()
            print("CHARTS_RESEARCH case=\(name) kind=\(kind) rssAfterClose=\(residentBytes())")
        }
    }

    func testHostedResearchComparison() throws {
        let marker = URL(fileURLWithPath: "/tmp/pipeplot-issue35-research.optin")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Opt in with scripts/research/evaluate-issue35.sh")
        }
        _ = NSApplication.shared
        let path = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let (sparseSession, sparseSamples, sparseDomain) = fixture(streams: 5, points: 180, spacing: 60)
        try runComparison(
            name: "sparse1m", session: sparseSession, samples: sparseSamples,
            domain: sparseDomain, rawRows: 1800)
        let (liveSession, liveSamples, liveDomain, liveRows) = try historyFixture(path: path, live: true)
        try runComparison(
            name: "live15m", session: liveSession, samples: liveSamples,
            domain: liveDomain, rawRows: liveRows)
        let (weekSession, weekSamples, weekDomain, weekRows) = try historyFixture(path: path, live: false)
        try runComparison(
            name: "week", session: weekSession, samples: weekSamples,
            domain: weekDomain, rawRows: weekRows)
    }

    func testHostedNativePreview() async throws {
        let marker = URL(fileURLWithPath: "/tmp/pipeplot-issue35-research.optin")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Opt in with scripts/research/evaluate-issue35.sh preview")
        }
        _ = NSApplication.shared
        let path = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let (session, samples, domain, _) = try historyFixture(path: path, live: true)
        let transition = start.addingTimeInterval(Double(60_480 * 5))
        let reconnectDomain = transition.addingTimeInterval(-150)...transition.addingTimeInterval(450)
        let queryEnd = transition.addingTimeInterval(330)
        let store = try SampleStore(readOnlyDatabaseURL: URL(fileURLWithPath: path))
        var reconnectSamples: [StreamID: [StoredSample]] = [:]
        for stream in session.charts.flatMap(\.streams) {
            let rows = try store.displaySamples(
                streamID: stream.id, from: reconnectDomain.lowerBound, to: queryEnd)
            XCTAssertTrue(rows.contains { $0.segmentID == "first" })
            XCTAssertTrue(rows.contains { $0.segmentID == "reconnected" })
            reconnectSamples[stream.id] = rows
        }
        let forecastStream = session.charts[0].streams[0]
        let liveForecasts = try forecast(for: forecastStream, samples: samples, domain: domain)
        let reconnectForecasts = try forecast(
            for: forecastStream, samples: reconnectSamples, domain: reconnectDomain)
        XCTAssertEqual(liveForecasts.count, 1)
        XCTAssertEqual(reconnectForecasts.count, 1)
        let sharedState = ResearchPreviewState(domain: domain)
        let now = domain.upperBound.addingTimeInterval(-300)
        var windows: [NSWindow] = []
        for (index, kind) in ["canvas", "chartsVector"].enumerated() {
            let window = NSWindow(
                contentRect: NSRect(
                    x: CGFloat(100 + index * 110), y: CGFloat(100 + index * 70),
                    width: 1000, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Issue 35 · \(kind == "canvas" ? "Canvas" : "Swift Charts vector") · isolated test"
            window.contentView = NSHostingView(
                rootView: ResearchPreview(
                    kind: kind, session: session, liveSamples: samples, reconnectSamples: reconnectSamples,
                    liveForecasts: liveForecasts, reconnectForecasts: reconnectForecasts,
                    liveDomain: domain, reconnectDomain: reconnectDomain, now: now, viewState: sharedState))
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            windows.append(window)
        }
        NSApp.activate()
        windows.last?.makeKeyAndOrderFront(nil)
        let ready = URL(fileURLWithPath: "/tmp/pipeplot-issue35-preview.ready")
        let release = URL(fileURLWithPath: "/tmp/pipeplot-issue35-preview.release")
        try "pid=\(getpid()) windows=\(windows.map(\.windowNumber))".write(to: ready, atomically: true, encoding: .utf8)
        print("CHARTS_PREVIEW ready pid=\(getpid()) windows=\(windows.map(\.windowNumber))")
        let deadline = Date().addingTimeInterval(1200)
        while Date() < deadline && !FileManager.default.fileExists(atPath: release.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        windows.forEach { $0.close() }
        try? FileManager.default.removeItem(at: ready)
        print("CHARTS_PREVIEW released")
    }
}
