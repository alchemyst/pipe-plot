import Accessibility
import PipePlotCore
import SwiftUI

/// A chart descriptor is rebuilt from the already bounded display query. It never reads history.
struct PlotAccessibility: AXChartDescriptorRepresentable {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let samples: [StreamID: [StoredSample]]
    let readyDisplays: Set<StreamID>
    let failedDisplays: Set<StreamID>
    let domain: ClosedRange<Date>
    let now: Date
    let valueRange: ClosedRange<Double>
    let selection: TimeSelection?
    let forecasts: [ForecastDrawing]

    private var visibleStreams: [StreamDescriptor] { chart.streams.filter { $0.isLayoutHidden != true } }
    private var referenceTime: Date? {
        session.timeGuides.first(where: { $0.id == session.timeline.referenceTimeGuideID })
            .map { Date(timeIntervalSince1970: $0.value) }
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(title: chart.title, summary: summary, xAxis: timeAxis, yAxis: valueAxis, series: series)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.title = chart.title
        descriptor.summary = summary
        descriptor.xAxis = timeAxis
        descriptor.yAxis = valueAxis
        descriptor.series = series
    }

    private var timeAxis: AXNumericDataAxisDescriptor {
        let title =
            referenceTime == nil
            ? "Time, \(session.timeline.timeZone == .utc ? "UTC" : "local")"
            : "Elapsed time from reference guide"
        return AXNumericDataAxisDescriptor(
            title: title,
            range: domain.lowerBound.timeIntervalSince1970...domain.upperBound.timeIntervalSince1970,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                TimeText.format(
                    Date(timeIntervalSince1970: value), zone: session.timeline.timeZone,
                    reference: referenceTime, includeDate: true)
            })
    }

    private var valueAxis: AXNumericDataAxisDescriptor {
        let unit = chart.settings.unit.flatMap { $0.isEmpty ? nil : $0 } ?? "value"
        let referenceValue = chart.guides.first(where: {
            $0.id == chart.settings.referenceGuideID && $0.orientation == .horizontalValue
        })?.value
        return AXNumericDataAxisDescriptor(
            title: referenceValue == nil ? "\(unit) axis" : "\(unit) relative to reference value guide",
            range: valueRange, gridlinePositions: [],
            valueDescriptionProvider: { value in
                NumericText.format(
                    value - (referenceValue ?? 0), scale: chart.settings.numericScale, unit: chart.settings.unit)
            })
    }

    private var series: [AXDataSeriesDescriptor] {
        visibleStreams.flatMap { stream -> [AXDataSeriesDescriptor] in
            let rows = samples[stream.id, default: []].filter { domain.contains($0.timestamp) }
            guard !rows.isEmpty else { return [] }
            // Display queries contain at most four raw bucket representatives per bucket.
            // Cap the spoken navigation set again so VoiceOver is useful at dense ranges.
            let limit = 120
            var indices: [Int] =
                rows.count <= limit
                ? Array(rows.indices)
                : (0..<limit).map { $0 * (rows.count - 1) / (limit - 1) }
            if rows.count > limit {
                let minimum = rows.indices.min { rows[$0].value < rows[$1].value }!
                let maximum = rows.indices.max { rows[$0].value < rows[$1].value }!
                indices += [minimum, maximum]
                indices = Array(Set(indices)).sorted()
            }
            let chosen = indices.map { rows[$0] }
            let marksVisible =
                (stream.linesVisible ?? chart.settings.linesVisible)
                || (stream.dotsVisible ?? chart.settings.dotsVisible)
            var runs: [[StoredSample]] = []
            for sample in chosen {
                if runs.isEmpty || runs[runs.count - 1].last?.segmentID != sample.segmentID {
                    runs.append([])
                }
                runs[runs.count - 1].append(sample)
            }
            return runs.enumerated().map { index, run in
                let suffix = runs.count > 1 ? ", segment \(index + 1) of \(runs.count)" : ""
                let points = run.map { sample in
                    AXDataPoint(
                        x: sample.timestamp.timeIntervalSince1970, y: sample.value,
                        label:
                            "Raw observation \(NumericText.format(sample.value, scale: chart.settings.numericScale, unit: chart.settings.unit)) at \(formatTime(sample.timestamp))"
                    )
                }
                return AXDataSeriesDescriptor(
                    name: stream.name + suffix + (marksVisible ? "" : ", marks off"),
                    isContinuous: marksVisible && (stream.linesVisible ?? chart.settings.linesVisible),
                    dataPoints: points)
            }
        }
    }

    var summary: String {
        let begin = formatTime(domain.lowerBound), end = formatTime(domain.upperBound)
        var parts = ["Visible time range \(begin) to \(end)."]
        let hidden = chart.streams.count - visibleStreams.count
        if visibleStreams.isEmpty {
            parts.append(
                chart.streams.isEmpty
                    ? "Waiting for a pipeline; no streams yet." : "All streams are hidden from layout.")
        } else {
            parts.append("\(visibleStreams.count) visible stream\(visibleStreams.count == 1 ? "" : "s").")
            if hidden > 0 { parts.append("\(hidden) hidden from layout; restore from Chart actions.") }
            let loading = visibleStreams.filter {
                !readyDisplays.contains($0.id) && !failedDisplays.contains($0.id)
                    && !samples[$0.id, default: []].contains(where: { domain.contains($0.timestamp) })
            }
            if !loading.isEmpty {
                parts.append("Loading visible data for \(loading.map(\.name).joined(separator: ", ")).")
            }
            let updating = visibleStreams.filter {
                !readyDisplays.contains($0.id) && !failedDisplays.contains($0.id)
                    && samples[$0.id, default: []].contains(where: { domain.contains($0.timestamp) })
            }
            if !updating.isEmpty {
                parts.append(
                    "Updating visible data for \(updating.map(\.name).joined(separator: ", ")); showing the last completed display query."
                )
            }
            let failed = visibleStreams.filter { failedDisplays.contains($0.id) }
            if !failed.isEmpty {
                parts.append(
                    "Visible data refresh failed for \(failed.map(\.name).joined(separator: ", ")); any displayed observations are from the last completed query."
                )
            }
            let empty = visibleStreams.filter { readyDisplays.contains($0.id) && samples[$0.id, default: []].isEmpty }
            if !empty.isEmpty {
                parts.append("No observations in range for \(empty.map(\.name).joined(separator: ", ")).")
            }
            for stream in visibleStreams {
                if let latest = samples[stream.id, default: []].last(where: { domain.contains($0.timestamp) }) {
                    let status =
                        readyDisplays.contains(stream.id)
                        ? "latest visible raw observation"
                        : "latest visible displayed raw observation"
                    parts.append(
                        "\(stream.name) \(status): \(NumericText.format(latest.value, scale: chart.settings.numericScale, unit: chart.settings.unit)) at \(formatTime(latest.timestamp))."
                    )
                }
            }
            if visibleStreams.contains(where: { stream in
                samples[stream.id, default: []].contains(where: { domain.contains($0.timestamp) })
            }) {
                parts.append(
                    "Display data uses first, last, minimum and maximum raw observations from each time bucket. Accessible navigation further samples at most 122 of those representatives per visible stream, retaining visible endpoints and overall minimum and maximum; it does not enumerate every raw observation."
                )
            }
            let marksOff = visibleStreams.filter {
                !($0.linesVisible ?? chart.settings.linesVisible) && !($0.dotsVisible ?? chart.settings.dotsVisible)
            }
            if !marksOff.isEmpty {
                parts.append(
                    "Marks off for \(marksOff.map(\.name).joined(separator: ", ")); values and analysis remain available."
                )
            }
            let derived = visibleStreams.filter { $0.derivedSeries != nil }
            if !derived.isEmpty {
                parts.append(
                    "\(derived.map(\.name).joined(separator: ", ")) also has separate smoothed and rate plots below; chart points here are raw display representatives."
                )
            }
        }
        let valueGuides = chart.guides.filter { $0.orientation == .horizontalValue }
        for guide in valueGuides {
            let name = guide.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Value guide"
            parts.append(
                "\(name), raw guide value: \(NumericText.format(guide.value, scale: chart.settings.numericScale, unit: chart.settings.unit))."
            )
        }
        for guide in session.timeGuides where domain.contains(Date(timeIntervalSince1970: guide.value)) {
            let name = guide.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Time guide"
            parts.append("\(name): \(formatTime(Date(timeIntervalSince1970: guide.value))).")
        }
        if let selection {
            let bounds = selection.resolvedBounds(at: now)
            let mode: String
            switch selection.mode {
            case .fixed: mode = "fixed"
            case .endFollowsNow: mode = "end follows now"
            case .bothFollowNow: mode = "both ends follow now"
            case .startFollowsEnd: mode = "start follows end"
            }
            parts.append("Selection \(formatTime(bounds.lowerBound)) to \(formatTime(bounds.upperBound)); \(mode).")
        }
        for forecast in forecasts {
            guard let name = visibleStreams.first(where: { $0.id == forecast.streamID })?.name else { continue }
            parts.append(
                "\(name) linear forecast estimates crossing \(NumericText.format(forecast.value, scale: chart.settings.numericScale, unit: chart.settings.unit)) at \(formatTime(forecast.crossing))."
            )
        }
        parts.append(
            "Use the timeline controls to change range; Guides and Chart actions menus provide plot operations.")
        return parts.joined(separator: " ")
    }

    private func formatTime(_ date: Date) -> String {
        TimeText.format(date, zone: session.timeline.timeZone, reference: referenceTime, includeDate: true)
    }
}
