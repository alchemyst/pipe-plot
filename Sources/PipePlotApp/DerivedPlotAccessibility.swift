import Accessibility
import SwiftUI
import PipePlotCore

struct DerivedAccessiblePoint {
    let timestamp: Date
    let value: Double
    let run: Int
}

struct DerivedPlotAccessibility: AXChartDescriptorRepresentable {
    let title: String
    let unit: String
    let points: [DerivedAccessiblePoint]
    let domain: ClosedRange<Date>
    let range: ClosedRange<Double>
    let zone: PlotTimeZone
    let status: String?

    private var visible: [DerivedAccessiblePoint] {
        points.filter { domain.contains($0.timestamp) && $0.value.isFinite }
    }
    private func value(_ value: Double) -> String { NumericText.format(value, unit: unit) }
    private func time(_ date: Date) -> String { TimeText.format(date, zone: zone, includeDate: true) }

    var summary: String {
        let overview =
            "Line chart of derived estimates, not raw measurements. Time range \(time(domain.lowerBound)) to \(time(domain.upperBound)). Value axis \(value(range.lowerBound)) to \(value(range.upperBound))."
        if let status { return overview + " " + status }
        let rows = visible
        guard let first = rows.first, let last = rows.last else { return overview + " No estimates in this range." }
        let low = rows.map(\.value).min()!, high = rows.map(\.value).max()!
        let sign = last.value == 0 ? "zero" : (last.value > 0 ? "positive" : "negative")
        return overview
            + " \(rows.count) estimates. Minimum \(value(low)); maximum \(value(high)). First \(value(first.value)); latest \(value(last.value)), \(sign), at \(time(last.timestamp)). Gaps separate independent runs. Accessible navigation includes at most 122 representative estimates, retaining visible endpoints and extrema."
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: title, summary: summary,
            xAxis: AXNumericDataAxisDescriptor(
                title: zone == .utc ? "Time, UTC" : "Time, local",
                range: domain.lowerBound.timeIntervalSince1970...domain.upperBound.timeIntervalSince1970,
                gridlinePositions: [], valueDescriptionProvider: { time(Date(timeIntervalSince1970: $0)) }),
            yAxis: AXNumericDataAxisDescriptor(
                title: unit, range: range, gridlinePositions: [], valueDescriptionProvider: { value($0) }),
            series: series)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let next = makeChartDescriptor()
        descriptor.title = next.title
        descriptor.summary = next.summary
        descriptor.xAxis = next.xAxis
        descriptor.yAxis = next.yAxis
        descriptor.series = next.series
    }

    private var series: [AXDataSeriesDescriptor] {
        guard status == nil else { return [] }
        let rows = visible
        guard !rows.isEmpty else { return [] }
        var indices = Array(rows.indices)
        if rows.count > 120 {
            indices = (0..<120).map { $0 * (rows.count - 1) / 119 }
            indices += [
                rows.indices.min { rows[$0].value < rows[$1].value }!,
                rows.indices.max { rows[$0].value < rows[$1].value }!,
            ]
            indices = Array(Set(indices)).sorted()
        }
        var runs: [[DerivedAccessiblePoint]] = []
        for index in indices {
            let point = rows[index]
            if runs.last?.last?.run != point.run { runs.append([]) }
            runs[runs.count - 1].append(point)
        }
        return runs.enumerated().map { index, run in
            AXDataSeriesDescriptor(
                name: "\(title), run \(index + 1)", isContinuous: true,
                dataPoints: run.map {
                    AXDataPoint(
                        x: $0.timestamp.timeIntervalSince1970, y: $0.value,
                        label: "Derived estimate \(value($0.value)) at \(time($0.timestamp))")
                })
        }
    }
}
