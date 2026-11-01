import SwiftUI
import PipePlotCore

struct DerivedSeriesSheet: View {
    let stream: StreamDescriptor
    let model: PipePlotAppModel
    let dismiss: () -> Void
    @State private var interval = "1"
    @State private var window = "10"
    @State private var gap = "3"
    @State private var kernel: SmoothingKernel = .weightedSavitzkyGolay
    @State private var policy: ResamplingPolicy = .linear
    @State private var cadence: Double?
    @State private var loaded = false
    private var configuration: DerivedSeriesConfiguration? {
        guard let dt = Double(interval), let w = Double(window), let g = Double(gap) else { return nil }
        return DerivedSeriesConfiguration(interval: dt, window: w, maximumGap: g, kernel: kernel, resampling: policy)
    }
    private var validation: String? {
        guard let configuration else { return "Enter finite numbers in seconds." }
        do { try configuration.validate(cadence: cadence); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Smoothing and derivative · \(stream.name)").font(.headline)
            Text("Adds separate derived plots. Original observations, hover values, statistics and forecasts stay raw.").font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Grid interval (seconds)", text: $interval)
                TextField("Centered window (seconds)", text: $window)
                TextField("Maximum observation gap (seconds)", text: $gap)
                Picker("Kernel", selection: $kernel) {
                    ForEach(SmoothingKernel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Resampling", selection: $policy) {
                    Text("Linear interpolation within gap limit").tag(ResamplingPolicy.linear)
                    Text("Observed grid points only").tag(ResamplingPolicy.observedOnly)
                }
            }.textFieldStyle(.roundedBorder)
            if let cadence { Text("Suggested interval: \(cadence.formatted(.number.precision(.significantDigits(5)))) s (median initial cadence). Fixed until edited; larger intervals require antialiasing and are unavailable.").font(.caption) }
            else { Text(loaded ? "Capture at least two distinct timestamps to estimate cadence." : "Reading initial cadence…").font(.caption) }
            if let error = validation { Text(error).font(.caption).foregroundStyle(.red) }
            else if let c = configuration {
                Text("Actual window: \(c.effectiveWindow.formatted()) s · delay: \(c.delay.formatted()) s. Cubic fit; first derivative in value/second. No padded or provisional edges. Reconnects and long gaps restart the window.").font(.caption)
            }
            Text("Linear interpolation can attenuate fast changes and biases derivatives in missing runs. Derived estimates report interpolation in their support. Observed-only mode may produce no estimates with jitter.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if stream.derivedSeries != nil { Button("Remove derived plots") { if model.setDerivedSeries(nil, streamID: stream.id) { dismiss() } } }
                Spacer(); Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let configuration, model.setDerivedSeries(configuration, streamID: stream.id) { dismiss() }
                }.disabled(!loaded || cadence == nil || validation != nil).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 520)
        .task {
            cadence = await model.suggestedDerivedInterval(stream.id)
            let c = stream.derivedSeries ?? DerivedSeriesConfiguration(interval: cadence ?? 1, window: (cadence ?? 1) * 10, maximumGap: (cadence ?? 1) * 3)
            interval = String(c.interval); window = String(c.window); gap = String(c.maximumGap)
            kernel = c.kernel; policy = c.resampling; loaded = true
        }
    }
}

struct DerivedSeriesPanel: View {
    let stream: StreamDescriptor
    let unit: String?
    let domain: ClosedRange<Date>
    let result: DerivedSeriesResult?
    let hoverDate: Date?
    let edit: () -> Void
    let disable: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Derived · \(stream.name)").font(.caption.weight(.semibold))
                Text(stream.derivedSeries?.kernel.title ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Edit…", action: edit); Button("Remove", action: disable)
            }.buttonStyle(.borderless).font(.caption)
            Text(result?.message ?? "Calculating derived estimates…").font(.caption2).foregroundStyle(.secondary)
            trace(derivative: false)
            trace(derivative: true)
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    private func trace(derivative: Bool) -> some View {
        let points = result?.points ?? []
        let quantity = derivative ? "Rate (\(unit.map { $0 + "/s" } ?? "value/s"))" : "Smoothed (\(unit ?? "value"))"
        let values = points.map { derivative ? $0.derivative : $0.smoothed }
        let range = PlotValueRange.automatic(values)
        let scale = max(abs(range.lowerBound), abs(range.upperBound), 1)
        let low = range.lowerBound / scale, span = max(1e-15, range.upperBound / scale - low)
        return VStack(alignment: .leading, spacing: 2) {
            Text(quantity).font(.caption2).foregroundStyle(.secondary)
            Canvas { context, size in
                let plot = CGRect(x: 56, y: 4, width: max(1, size.width - 56), height: max(1, size.height - 14))
                let timeSpan = max(0.001, domain.upperBound.timeIntervalSince(domain.lowerBound))
                func x(_ time: Date) -> Double { plot.minX + time.timeIntervalSince(domain.lowerBound) / timeSpan * plot.width }
                var path = Path(), previous: DerivedPoint?
                for p in points where domain.contains(p.timestamp) {
                    let value = derivative ? p.derivative : p.smoothed
                    let position = CGPoint(x: x(p.timestamp), y: plot.maxY - (value / scale - low) / span * plot.height)
                    if let previous, p.run == previous.run { path.addLine(to: position) }
                    else { path.move(to: position) }
                    previous = p
                }
                var clipped = context; clipped.clip(to: Path(plot))
                clipped.stroke(path, with: .color(derivative ? .orange : .cyan), lineWidth: 1.5)
                if let hoverDate, domain.contains(hoverDate) {
                    var hover = Path(); hover.move(to: CGPoint(x: x(hoverDate), y: plot.minY)); hover.addLine(to: CGPoint(x: x(hoverDate), y: plot.maxY))
                    clipped.stroke(hover, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for (value, y) in [(range.upperBound, plot.minY), (range.lowerBound, plot.maxY)] {
                    context.draw(Text(value.formatted(.number.precision(.significantDigits(3)))).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 50, y: y), anchor: .trailing)
                }
            }.frame(height: 82)
        }
    }
}
