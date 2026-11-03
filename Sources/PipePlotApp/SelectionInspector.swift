import SwiftUI
import PipePlotCore

struct SelectionInspector: View {
    let session: SessionSnapshot
    let selection: TimeSelection
    let model: PipePlotAppModel
    let onSelection: (TimeSelection?) -> Void

    @State private var forecastRequest: ForecastTargetRequest?

    private var charts: [ChartSnapshot] { session.charts }
    private var streams: [StreamDescriptor] { charts.flatMap(\.streams) }
    private var streamIDs: Set<StreamID> { Set(streams.map(\.id)) }
    private var bounds: ClosedRange<Date> { model.resolvedSelectionBounds(selection, session: session) }
    private var includedIDs: Set<StreamID> {
        selection.selectedStreamIDs.isEmpty ? streamIDs : selection.selectedStreamIDs.intersection(streamIDs)
    }
    private struct RequestID: Equatable {
        let bounds: ClosedRange<Date>
        let selection: TimeSelection
        let streams: [StreamDescriptor]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("Selection", systemImage: "selection.pin.in.out").font(.caption.weight(.semibold))
                let reference = session.timeGuides.first(where: { $0.id == session.timeline.referenceTimeGuideID }).map
                { Date(timeIntervalSince1970: $0.value) }
                Text(
                    "\(TimeText.format(bounds.lowerBound, zone: session.timeline.timeZone, reference: reference, includeDate: true)) – \(TimeText.format(bounds.upperBound, zone: session.timeline.timeZone, reference: reference, includeDate: true))"
                )
                .font(.caption.monospacedDigit())
                Text("duration \(duration(bounds.upperBound.timeIntervalSince(bounds.lowerBound)) )")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(modeLabel).font(.caption).foregroundStyle(.secondary)
                selectionMenu
                inclusionMenu
                forecastMenu
                Spacer(minLength: 0)
                Button("Clear") { onSelection(nil) }.buttonStyle(.borderless)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(streams.filter { includedIDs.contains($0.id) }) { stream in
                        statisticCard(stream)
                    }
                    if streams.isEmpty { Text("No visible streams").foregroundStyle(.secondary).font(.caption) }
                }
            }.scrollIndicators(.hidden)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(height: 108)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection inspector")
        .task(id: RequestID(bounds: bounds, selection: selection, streams: streams)) {
            for stream in streams {
                if includedIDs.contains(stream.id) {
                    model.requestStats(for: stream.id, in: selection)
                } else {
                    model.cancelStats(stream.id)
                }
            }
        }
        .onDisappear {
            let current = model.sessionModel(for: session.id).snapshot?.timeline.selection
            if current == nil || current == selection {
                for stream in streams { model.cancelStats(stream.id) }
            }
        }
        .sheet(item: $forecastRequest) { request in
            let unit = charts.first { $0.streams.contains { $0.id == request.stream.id } }?.settings.unit
            ForecastTargetSheet(request: request, unit: unit, model: model) { forecastRequest = nil }
        }

    }

    private var modeLabel: String {
        switch selection.mode {
        case .fixed: "Fixed interval"
        case .endFollowsNow: "End follows now"
        case .bothFollowNow: "Fixed duration follows now"
        case .startFollowsEnd: "Start follows end"
        }
    }

    private var selectionMenu: some View {
        SnapshotMenu(title: "Boundary") {
            [
                .command("Fix interval") { updateMode(.fixed) },
                .command("Link end to now") { updateMode(.endFollowsNow) },
                .command("Link start to end at fixed duration") {
                    updateMode(
                        .startFollowsEnd(duration: max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))))
                },
                .command("Follow now at fixed duration") {
                    updateMode(
                        .bothFollowNow(duration: max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))))
                },
            ]
        }
    }

    private var inclusionMenu: some View {
        SnapshotMenu(title: "Streams · \(includedIDs.count)/\(streams.count)") {
            streams.map { stream in
                let included = includedIDs.contains(stream.id)
                let chart = charts.first { $0.streams.contains { $0.id == stream.id } }
                let suffix = chart.map { " · \($0.title)\($0.isVisible ? "" : " (hidden)")" } ?? ""
                return .command(
                    stream.name + (stream.isLayoutHidden == true ? " (layout hidden)" : "") + suffix,
                    enabled: !included || includedIDs.count > 1, checked: included
                ) {
                    var ids = includedIDs
                    if included { ids.remove(stream.id) } else { ids.insert(stream.id) }
                    var value = selection
                    value.selectedStreamIDs = ids.count == streamIDs.count ? [] : ids
                    onSelection(value)
                }
            } + [
                .command("Include all") {
                    var value = selection
                    value.selectedStreamIDs = []
                    onSelection(value)
                }
            ]
        }
    }

    private var forecastMenu: some View {
        SnapshotMenu(title: "Forecast", symbol: "chart.xyaxis.line") {
            charts.flatMap { chart in
                chart.streams.filter { includedIDs.contains($0.id) }.flatMap { stream in
                    [
                        SnapshotMenuItem.command("Create target for \(stream.name)…") {
                            forecastRequest = ForecastTargetRequest(stream: stream, selection: selection)
                        }
                    ]
                        + chart.guides.filter { $0.orientation == .horizontalValue }.map { guide in
                            SnapshotMenuItem.command(
                                "\(stream.name) · \(guide.label?.isEmpty == false ? guide.label! : guide.value.formatted(.number.precision(.significantDigits(4))))"
                            ) {
                                model.setForecast(
                                    ForecastConfiguration(streamID: stream.id, guideID: guide.id, selection: selection),
                                    session: session)
                            }
                        }
                }
            }
        }.disabled(includedIDs.isEmpty)
            .help("Fit selected observations to a value guide")
    }

    private func updateMode(_ mode: SelectionMode) {
        let now = model.sessionNow(session)
        var value = selection
        value.mode = mode
        switch mode {
        case .fixed:
            value.start = bounds.lowerBound
            value.end = bounds.upperBound
        case .endFollowsNow:
            value.start = bounds.lowerBound
            value.end = now
        case .bothFollowNow(let duration):
            value.start = now.addingTimeInterval(-duration)
            value.end = now
        case .startFollowsEnd(let duration):
            value.end = bounds.upperBound
            value.start = value.end.addingTimeInterval(-duration)
        }
        onSelection(value)
    }

    private func statisticCard(_ stream: StreamDescriptor) -> some View {
        let stats = model.stats(for: stream.id, in: selection)
        return VStack(alignment: .leading, spacing: 2) {
            Text(stream.name).font(.caption.weight(.semibold)).lineLimit(1)
            if let stats {
                Text(
                    "n \(stats.count) · \(duration(stats.lastSampleAt.timeIntervalSince(stats.firstSampleAt))): \(format(stats.firstValue)) → \(format(stats.lastValue))"
                )
                Text(
                    "min \(format(stats.minimum)) · max \(format(stats.maximum)) · sample-weighted mean \(format(stats.mean)) · Δ \(format(stats.change))"
                )
            } else {
                if model.statisticsFailed(stream.id) {
                    HStack {
                        Text("Statistics unavailable")
                        Button("Retry") { model.retryStats(stream.id) }
                    }.foregroundStyle(.secondary)
                } else {
                    Text(model.isCalculatingStats(stream.id) ? "Calculating…" : "No samples in range")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .frame(minWidth: 245, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }

    private func format(_ value: Double) -> String { String(format: "%.4g", value) }
    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        if seconds < 3600 { return String(format: "%.1fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }
}

struct ForecastTargetRequest: Identifiable {
    let id = UUID()
    let stream: StreamDescriptor
    let selection: TimeSelection
}

private struct ForecastTargetSheet: View {
    let request: ForecastTargetRequest
    let unit: String?
    let model: PipePlotAppModel
    let close: () -> Void
    @State private var targetValue = ""
    @State private var targetLabel = ""

    var body: some View {
        let parsed = NumericText.parse(targetValue, unit: unit)
        VStack(alignment: .leading, spacing: 14) {
            Text("Create forecast target").font(.title3.weight(.semibold))
            Text("Stream: \(request.stream.name)").font(.callout)
            TextField("Target value (for example 10 Gi)", text: $targetValue).textFieldStyle(.roundedBorder)
            if parsed == nil {
                Text("Enter a finite value, with an optional SI or binary postfix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Label (optional)", text: $targetLabel).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", action: close)
                Spacer()
                Button("Create Guide and Forecast") {
                    guard let value = parsed else { return }
                    if model.createForecastTarget(
                        value: value, label: targetLabel.isEmpty ? nil : targetLabel,
                        streamID: request.stream.id, selection: request.selection)
                    {
                        close()
                    }
                }.disabled(parsed == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 390)
    }
}
