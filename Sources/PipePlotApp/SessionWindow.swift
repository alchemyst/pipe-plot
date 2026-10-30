import SwiftUI
import AppKit
import Observation
import PipePlotCore

struct SessionWindow: View {
    let sessionID: SessionID
    @Bindable var model: PipePlotAppModel
    @State private var selectedChartID: ChartID?
    @State private var hoverDate: Date?
    @State private var dragStart: Date?
    @State private var gestures = SessionGesturePreview()
    @State private var showRenameSession = false
    @State private var sessionTitle = ""

    private var session: SessionSnapshot? { model.sessions[sessionID] }
    private var visibleCharts: [ChartSnapshot] { session?.charts.filter(\.isVisible) ?? [] }
    private func timeReference(_ session: SessionSnapshot) -> Date? {
        session.timeGuides.first(where: { $0.id == session.timeline.referenceTimeGuideID }).map { Date(timeIntervalSince1970: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            sessionContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(session.map { "\($0.number) · \($0.title)" } ?? "PipePlot")
        .onAppear { model.refresh(sessionID) }
        .onAppear { model.becameActive(sessionID) }
        .onChange(of: model.selectedChartIDs[sessionID]) { _, chartID in
            if let chartID { selectedChartID = chartID }
        }
        .onReceive(model.refreshTimer) { _ in model.tick(sessionID) }
        .onReceive(NotificationCenter.default.publisher(for: .pipePlotWillTerminate)) { _ in model.prepareForTermination() }
        .onDisappear { model.windowClosed(sessionID) }
        .sheet(isPresented: $showRenameSession) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename session").font(.title3.weight(.semibold))
                TextField("Session name", text: $sessionTitle)
                HStack { Spacer(); Button("Cancel") { showRenameSession = false }; Button("Save") { model.renameSession(sessionID, to: sessionTitle); showRenameSession = false }.keyboardShortcut(.defaultAction) }
            }.padding(22).frame(width: 340)
        }
        .background(WindowFocusObserver { model.becameActive(sessionID) }.frame(width: 0, height: 0))
        .alert("PipePlot", isPresented: errorPresented) { errorButtons } message: { errorMessage }
        .onKeyPress(keys: [.escape, "a", "d", "f", "w", "s"]) { press in
            guard !isEditingText, let session else { return .ignored }
            switch press.key {
            case .escape:
                if session.timeline.selection != nil { model.setSelection(nil, session: session); return .handled }
            case "a": model.pan(80, width: 800, session: session); return .handled
            case "d": model.pan(-80, width: 800, session: session); return .handled
            case "w", "s":
                let range = model.domain(for: session)
                let anchor = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2)
                model.zoom(press.key == "w" ? 1.25 : 0.8, anchor: anchor, session: session)
                return .handled
            case "f":
                guard let selection = session.timeline.selection else { return .ignored }
                let bounds = model.resolvedSelectionBounds(selection, session: session)
                var timeline = session.timeline; timeline.followNow = false
                timeline.visibleStart = bounds.lowerBound; timeline.visibleEnd = bounds.upperBound
                model.navigate(timeline, session: session)
                return .handled
            default: break
            }
            return .ignored
        }
    }

    @ViewBuilder private var sessionContent: some View {
        if let session {
            if session.isDeleted {
                ContentUnavailableView {
                    Label("Deleted session", systemImage: "trash")
                } description: {
                    Text("This session and its captured data are retained in Recently Deleted.")
                } actions: {
                    Button("Restore Session") { model.restoreSession(session.id) }.buttonStyle(.borderedProminent)
                }
            } else if session.charts.isEmpty {
                ContentUnavailableView("No charts yet", systemImage: "chart.xyaxis.line", description: Text("Create a chart or pipe values into pp."))
            } else {
                sharedRuler(session)
                chartRows(session)
                if let selection = session.timeline.selection {
                    SelectionInspector(session: session, selection: selection, model: model) { model.setSelection($0, session: session) }
                }
            }
            timelineBar(session)
        } else {
            ProgressView().task { model.refresh(sessionID) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("PipePlot").font(.headline)
                Text("Live measurements · local capture").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.createSessionWindow() } label: { Label("New Session", systemImage: "plus.rectangle.on.folder") }
                .help("Create a session in a new window (⌘N)")
            Button { createChart() } label: { Label("Add Chart", systemImage: "chart.bar.xaxis") }
                .help("Create a chart below and make it the target sink (⌘⇧D)")
                .dropDestination(for: String.self) { items, _ in
                    guard let rawID = items.first, let id = UUID(uuidString: rawID) else { return false }
                    model.moveToNewChart(id, sessionID: sessionID, after: selectedChartID)
                    return true
                }
            Menu {
                Button("Rename Session…") { sessionTitle = session?.title ?? ""; showRenameSession = true }
                Button("Move Session to Trash", role: .destructive) { model.deleteSession(sessionID) }
            } label: { Label("Session", systemImage: "ellipsis.circle") }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
    }

    private func chartRows(_ session: SessionSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(visibleCharts) { chart in
                    ChartRowHost(chart: chart, session: session, model: model, hoverDate: $hoverDate,
                                 gestures: gestures, selectedChartID: $selectedChartID)
                }
            }.padding(16)
        }.background(Color(nsColor: .underPageBackgroundColor))
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })
    }
    private var errorButtons: some View { Button("OK") { model.clearError() } }
    private var errorMessage: some View { Text(model.errorMessage ?? "") }

    @ViewBuilder private func timelineBar(_ session: SessionSnapshot) -> some View {
        HStack {
            Label("Session \(session.number)", systemImage: "circle.grid.2x2")
                .foregroundStyle(.secondary)
            if session.rejectedLineCount > 0 {
                Text("\(session.rejectedLineCount) rejected input row\(session.rejectedLineCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Rows rejected because the input was invalid or did not match the registered stream group")
            }
            Spacer()
            if let date = hoverDate {
                Text(TimeText.format(date, zone: session.timeline.timeZone ?? .local, reference: timeReference(session), includeDate: true)).monospacedDigit().font(.caption)
            }
            Button { model.navigateBack(session) } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canNavigateBack(session.id)).help("Back in time navigation")
            Button { model.navigateForward(session) } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canNavigateForward(session.id)).help("Forward in time navigation")
            Text("Now  \(TimeText.format(model.sessionNow(session), zone: session.timeline.timeZone ?? .local, reference: timeReference(session)))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { model.followNow(session) } label: { Label("Follow Now", systemImage: "clock") }
                .buttonStyle(.borderedProminent).tint(session.timeline.followNow ? .accentColor : .gray)
                .disabled(session.timeline.followNow)
            Menu {
                Button("Last 5 minutes") { model.setSpan(5 * 60, session: session) }
                Button("Last 15 minutes") { model.setSpan(15 * 60, session: session) }
                Button("Last hour") { model.setSpan(60 * 60, session: session) }
                Button("Show all history") { model.showAllHistory(session) }
            } label: { Image(systemName: "clock.arrow.circlepath") }.help("Time range")
            Menu {
                Button("Local time") { model.setTimeZone(.local, session: session) }
                Button("UTC") { model.setTimeZone(.utc, session: session) }
            } label: { Label(session.timeline.timeZone == .utc ? "UTC" : "Local", systemImage: "globe") }
                .help("Display timestamps in local time or UTC")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    private func sharedRuler(_ session: SessionSnapshot) -> some View {
        let range = gestures.domain ?? model.domain(for: session)
        return SharedTimeRuler(range: range, timeZone: session.timeline.timeZone ?? .local, reference: timeReference(session))
    }

    private func createChart() {
        model.createChart(in: sessionID, after: selectedChartID)
    }

    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

}

private struct SharedTimeRuler: View {
    let range: ClosedRange<Date>
    let timeZone: PlotTimeZone
    let reference: Date?
    private var span: TimeInterval { max(0.001, range.upperBound.timeIntervalSince(range.lowerBound)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0...4, id: \.self) { index in
                    let fraction = CGFloat(index) / 4
                    let date = range.lowerBound.addingTimeInterval(span * Double(fraction))
                    Text(TimeText.format(date, zone: timeZone, reference: reference, includeDate: span > 86_400))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 72, alignment: index == 0 ? .leading : (index == 4 ? .trailing : .center))
                        .position(x: 84 + max(1, geometry.size.width - 112) * fraction + (index == 0 ? 36 : (index == 4 ? -36 : 0)), y: 10)
                }
            }
        }
        .frame(height: 20).padding(.vertical, 3).background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5) }
    }
}

private struct SelectionInspector: View {
    let session: SessionSnapshot
    let selection: TimeSelection
    let model: PipePlotAppModel
    let onSelection: (TimeSelection?) -> Void

    private var charts: [ChartSnapshot] { session.charts }
    private var streams: [StreamDescriptor] { charts.flatMap(\.streams) }
    private var streamIDs: Set<StreamID> { Set(streams.map(\.id)) }
    private var bounds: ClosedRange<Date> { model.resolvedSelectionBounds(selection, session: session) }
    private var includedIDs: Set<StreamID> { selection.selectedStreamIDs.isEmpty ? streamIDs : selection.selectedStreamIDs.intersection(streamIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("Selection", systemImage: "selection.pin.in.out").font(.caption.weight(.semibold))
                let reference = session.timeGuides.first(where: { $0.id == session.timeline.referenceTimeGuideID }).map { Date(timeIntervalSince1970: $0.value) }
                Text("\(TimeText.format(bounds.lowerBound, zone: session.timeline.timeZone ?? .local, reference: reference, includeDate: true)) – \(TimeText.format(bounds.upperBound, zone: session.timeline.timeZone ?? .local, reference: reference, includeDate: true))")
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
        Menu("Boundary") {
            Button("Fix interval") { updateMode(.fixed) }
            Button("Link end to now") { updateMode(.endFollowsNow) }
            Button("Link start to end at fixed duration") {
                updateMode(.startFollowsEnd(duration: max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))))
            }
            Button("Follow now at fixed duration") {
                let duration = max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))
                updateMode(.bothFollowNow(duration: duration))
            }
        }
    }

    private var inclusionMenu: some View {
        Menu("Streams · \(includedIDs.count)/\(streams.count)") {
            ForEach(streams) { stream in
                let included = includedIDs.contains(stream.id)
                Button {
                    var ids = includedIDs
                    if included { ids.remove(stream.id) } else { ids.insert(stream.id) }
                    var value = selection
                    value.selectedStreamIDs = ids.count == streamIDs.count ? [] : ids
                    onSelection(value)
                    } label: {
                        let chart = charts.first(where: { $0.streams.contains(where: { $0.id == stream.id }) })
                        let suffix = chart.map { " · \($0.title)\($0.isVisible ? "" : " (hidden)")" } ?? ""
                        Label(stream.name + suffix, systemImage: included ? "checkmark" : "")
                    }
                    .disabled(included && includedIDs.count == 1)
            }
            Button("Include all") { var value = selection; value.selectedStreamIDs = []; onSelection(value) }
        }
    }

    private var forecastMenu: some View {
        Menu {
            ForEach(charts) { chart in
                ForEach(chart.streams) { stream in
                    ForEach(chart.guides.filter { $0.orientation == .horizontalValue }) { guide in
                        Button("\(stream.name) · \(guide.label?.isEmpty == false ? guide.label! : guide.value.formatted(.number.precision(.significantDigits(4))))") {
                            model.setForecast(ForecastConfiguration(streamID: stream.id, guideID: guide.id, selection: selection), session: session)
                        }
                    }
                }
            }
        } label: { Label("Forecast", systemImage: "chart.xyaxis.line") }
            .disabled(charts.allSatisfy { $0.guides.allSatisfy { $0.orientation != .horizontalValue } })
            .help("Fit selected observations to a value guide")
    }

    private func updateMode(_ mode: SelectionMode) {
        let now = model.sessionNow(session)
        var value = selection
        value.mode = mode
        switch mode {
        case .fixed: value.start = bounds.lowerBound; value.end = bounds.upperBound
        case .endFollowsNow: value.start = bounds.lowerBound; value.end = now
        case .bothFollowNow(let duration): value.start = now.addingTimeInterval(-duration); value.end = now
        case .startFollowsEnd(let duration): value.end = bounds.upperBound; value.start = value.end.addingTimeInterval(-duration)
        }
        onSelection(value)
    }

    private func statisticCard(_ stream: StreamDescriptor) -> some View {
        let stats = model.stats(for: stream.id, in: selection)
        return VStack(alignment: .leading, spacing: 2) {
            Text(stream.name).font(.caption.weight(.semibold)).lineLimit(1)
            if let stats {
                Text("n \(stats.count) · \(duration(stats.lastSampleAt.timeIntervalSince(stats.firstSampleAt))): \(format(stats.firstValue)) → \(format(stats.lastValue))")
                Text("min \(format(stats.minimum)) · max \(format(stats.maximum)) · sample-weighted mean \(format(stats.mean)) · Δ \(format(stats.change))")
            } else {
                Text(model.isCalculatingStats(stream.id) ? "Calculating…" : "No samples in range").foregroundStyle(.secondary)
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

private struct ChartRowHost: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let model: PipePlotAppModel
    @Binding var hoverDate: Date?
    let gestures: SessionGesturePreview
    @Binding var selectedChartID: ChartID?

    var body: some View {
        ChartRow(chart: chart, session: session, samples: model.visibleSamples(for: chart, session: session, range: gestures.domain),
                 now: model.sessionNow(session), hoverDate: $hoverDate,
                 sharedGestureDomain: Binding(get: { gestures.domain }, set: { gestures.domain = $0 }),
                 sharedSelectionStart: Binding(get: { gestures.selectionStart }, set: { gestures.selectionStart = $0 }),
                 sharedSelectionEnd: Binding(get: { gestures.selectionEnd }, set: { gestures.selectionEnd = $0 }),
                 sharedSelectionLinked: Binding(get: { gestures.selectionLinked }, set: { gestures.selectionLinked = $0 }),
                 sharedGuidePreview: Binding(get: { gestures.guide }, set: { gestures.guide = $0 }),
                 sharedGuideChartID: Binding(get: { gestures.guideChartID }, set: { gestures.guideChartID = $0 }), model: model,
                 onTarget: { model.setTarget(chart.id) },
                 onToggleDots: { model.toggleDots(chart) }, onToggleLines: { model.toggleLines(chart) },
                 onAddGuide: { value, label in model.addGuide(value: value, chart: chart, session: session, label: label) },
                 onEditGuide: { guide in model.updateGuide(guide, chartID: chart.id, sessionID: session.id) },
                 onRemoveGuide: { guide in model.removeGuide(guide, chartID: chart.id, sessionID: session.id) },
                 onSelection: { model.setSelection($0, session: session) },
                 onRename: { stream, name in model.rename(stream, to: name) },
                 onMove: { stream, destination in model.move(stream, to: destination) })
            .onTapGesture { selectedChartID = chart.id; model.selectChart(chart.id, sessionID: session.id) }
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedChartID == chart.id ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 2))
    }
}

@Observable
@MainActor
private final class SessionGesturePreview {
    var domain: ClosedRange<Date>?
    var selectionStart: Date?
    var selectionEnd: Date?
    var selectionLinked = false
    var guide: Guide?
    var guideChartID: ChartID?
}

private struct ChartRow: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let samples: [StreamID: [StoredSample]]
    let now: Date
    @Binding var hoverDate: Date?
    @Binding var sharedGestureDomain: ClosedRange<Date>?
    @Binding var sharedSelectionStart: Date?
    @Binding var sharedSelectionEnd: Date?
    @Binding var sharedSelectionLinked: Bool
    @Binding var sharedGuidePreview: Guide?
    @Binding var sharedGuideChartID: ChartID?
    let model: PipePlotAppModel
    let onTarget: () -> Void
    let onToggleDots: () -> Void
    let onToggleLines: () -> Void
    let onAddGuide: (Double, String?) -> Void
    let onEditGuide: (Guide) -> Void
    let onRemoveGuide: (Guide) -> Void
    let onSelection: (TimeSelection?) -> Void
    let onRename: (StreamID, String) -> Void
    let onMove: (StreamID, ChartID) -> Void

    @State private var showGuideManager = false
    @State private var guideValue = ""
    @State private var guideLabel = ""
    @State private var guideEntryError: String?
    @State private var guideDate = Date()
    @State private var guideSecond = "0"
    @State private var editingGuide: Guide?
    @State private var isAddingGuide = false
    @State private var renameStream: StreamDescriptor?
    @State private var renameText = ""
    @State private var renameChartText = ""
    @State private var showRenameChart = false
    @State private var reassociationSource: StreamDescriptor?
    @State private var panPixels: CGFloat = 0
    @State private var zoomFactor = 1.0
    @State private var zoomAnchor: Date?
    @State private var gestureBaseDomain: ClosedRange<Date>?

    private var domain: ClosedRange<Date> {
        model.domain(for: session)
    }
    private var plotDomain: ClosedRange<Date> { sharedGestureDomain ?? domain }
    private var guideCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = session.timeline.timeZone == .utc ? TimeZone(secondsFromGMT: 0)! : .current
        return calendar
    }
    private var plotChart: ChartSnapshot {
        guard let guidePreview = sharedGuidePreview, sharedGuideChartID == chart.id, guidePreview.orientation == .horizontalValue else { return chart }
        var value = chart
        if let index = value.guides.firstIndex(where: { $0.id == guidePreview.id }) { value.guides[index] = guidePreview }
        else { value.guides.append(guidePreview) }
        return value
    }
    private var plotSession: SessionSnapshot {
        guard let guidePreview = sharedGuidePreview, guidePreview.orientation == .verticalTime else { return session }
        var value = session
        if let index = value.timeGuides.firstIndex(where: { $0.id == guidePreview.id }) { value.timeGuides[index] = guidePreview }
        else { value.timeGuides.append(guidePreview) }
        return value
    }
    private func shifted(_ range: ClosedRange<Date>, pixels: CGFloat, width: CGFloat) -> ClosedRange<Date> {
        let delta = -Double(pixels / max(width, 1)) * range.upperBound.timeIntervalSince(range.lowerBound)
        return range.lowerBound.addingTimeInterval(delta)...range.upperBound.addingTimeInterval(delta)
    }
    private func scaled(_ range: ClosedRange<Date>, factor: Double, anchor: Date) -> ClosedRange<Date> {
        let oldSpan = max(1, range.upperBound.timeIntervalSince(range.lowerBound))
        let newSpan = min(7 * 24 * 3600, max(5, oldSpan / factor))
        let fraction = min(1, max(0, anchor.timeIntervalSince(range.lowerBound) / oldSpan))
        return anchor.addingTimeInterval(-newSpan * fraction)...anchor.addingTimeInterval(newSpan * (1 - fraction))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ZStack(alignment: .topLeading) {
                PlotCanvas(chart: plotChart, session: plotSession, samples: samples, domain: plotDomain, now: now, hoverDate: $hoverDate, selectionStart: $sharedSelectionStart, selectionPreview: $sharedSelectionEnd, selectionLinkedPreview: $sharedSelectionLinked,
                           onFollowSelectionDuration: {
                                guard let selection = session.timeline.selection else { return }
                                let bounds = model.resolvedSelectionBounds(selection, session: session)
                                let duration = max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))
                                let current = model.sessionNow(session)
                                onSelection(TimeSelection(start: current.addingTimeInterval(-duration), end: current, mode: .bothFollowNow(duration: duration), selectedStreamIDs: selection.selectedStreamIDs))
                           },
                           onBackgroundClick: { onSelection(nil) },
                           onBackgroundDoubleClick: { date in model.addTimeGuide(at: date, sessionID: session.id) },
                           onGuideSelected: { beginEditingGuide($0) },
                           onSelectionModeToggle: { toggleSelectionBoundary($0) },
                           selection: session.timeline.selection,
                           forecasts: model.forecastDrawings(for: chart, session: session),
                           onSelectionCommit: { start, end, mode in
                                guard let start, let end else { onSelection(nil); return }
                                onSelection(TimeSelection(start: start, end: end, mode: mode ?? .fixed, selectedStreamIDs: Set(chart.streams.map(\.id))))
                           },
                           onGuide: { guide, phase in
                                switch phase {
                                case .began, .changed: sharedGuidePreview = guide; sharedGuideChartID = chart.id
                                case .ended:
                                    sharedGuidePreview = nil; sharedGuideChartID = nil
                                    if guide.orientation == .verticalTime { model.updateTimeGuide(guide, sessionID: session.id) }
                                    else { model.updateGuide(guide, chartID: chart.id, sessionID: session.id) }
                                case .cancelled: sharedGuidePreview = nil; sharedGuideChartID = nil
                                }
                           },
                           onPan: { delta, phase, width in
                                switch phase {
                                case .began: panPixels = 0; gestureBaseDomain = domain; sharedGestureDomain = domain
                                case .changed:
                                    if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                    panPixels += delta.width
                                    if let base = gestureBaseDomain { sharedGestureDomain = shifted(base, pixels: panPixels, width: width) }
                                case .ended:
                                    if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                    panPixels += delta.width
                                    model.pan(panPixels, width: width, session: session, from: gestureBaseDomain)
                                    panPixels = 0; gestureBaseDomain = nil; sharedGestureDomain = nil
                                case .cancelled: panPixels = 0; gestureBaseDomain = nil; sharedGestureDomain = nil
                                }
                           },
                           onZoom: { factor, anchor, phase in
                                switch phase {
                                case .began: zoomFactor = 1; zoomAnchor = anchor; gestureBaseDomain = domain
                                case .changed:
                                    if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                    zoomFactor *= factor; zoomAnchor = anchor
                                    if let base = gestureBaseDomain { sharedGestureDomain = scaled(base, factor: zoomFactor, anchor: anchor) }
                                case .ended:
                                    if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                    zoomFactor *= factor
                                    model.zoom(zoomFactor, anchor: anchor, session: session, from: gestureBaseDomain)
                                    zoomFactor = 1; zoomAnchor = nil; gestureBaseDomain = nil; sharedGestureDomain = nil
                                case .cancelled: zoomFactor = 1; zoomAnchor = nil; gestureBaseDomain = nil; sharedGestureDomain = nil
                                }
                           })
                    .frame(height: 210)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                if chart.streams.isEmpty {
                    Text("Waiting for a pipeline…  Run `sampler | pp` to add data here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            streamLegend
            Group {
            if let hoverDate {
                    ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(chart.streams) { stream in
                            if let sample = model.nearestSample(stream.id, at: hoverDate) {
                                let offset = sample.timestamp.timeIntervalSince(hoverDate)
                                Text(hoverReadout(stream: stream, sample: sample, offset: offset))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.horizontal, 15)
                    }.scrollIndicators(.hidden)
                } else {
                    Color.clear
                }
            }
            .frame(height: 25)
            ForEach(model.allForecastStatuses[session.id, default: []].filter { status in chart.streams.contains(where: { $0.id == status.configuration.streamID }) }, id: \.configuration.id) { status in
                HStack(spacing: 8) {
                    Label("Linear forecast", systemImage: "arrow.up.right")
                    Text(status.message).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let crossing = status.crossing, crossing > now {
                        Text("in \(max(0, Int(crossing.timeIntervalSince(now))) / 60)m").font(.caption.monospacedDigit()).foregroundStyle(.tint)
                    }
                    Button("Disable") { model.removeForecast(status.configuration.id, session: session) }.buttonStyle(.borderless).font(.caption)
                }.padding(.horizontal, 15).padding(.bottom, 10)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
        .onChange(of: sharedSelectionStart) { _, start in
            if start != nil, sharedGestureDomain == nil { sharedGestureDomain = domain }
            if start == nil, gestureBaseDomain == nil { sharedGestureDomain = nil }
        }
        .sheet(isPresented: $showGuideManager) { guideManagerSheet }
        .sheet(item: $renameStream) { stream in
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename stream").font(.title3.weight(.semibold))
                TextField("Stream name", text: $renameText).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Cancel") { renameStream = nil }; Button("Save") { onRename(stream.id, renameText); renameStream = nil }.keyboardShortcut(.defaultAction) }
            }.padding(22).frame(width: 340)
        }
        .sheet(isPresented: $showRenameChart) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename chart").font(.title3.weight(.semibold))
                TextField("Chart name", text: $renameChartText).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Cancel") { showRenameChart = false }; Button("Save") { model.renameChart(chart.id, to: renameChartText); showRenameChart = false }.keyboardShortcut(.defaultAction) }
            }.padding(22).frame(width: 340)
        }
        .sheet(item: $reassociationSource) { source in
            ReassociationSheet(source: source, session: session, model: model) { reassociationSource = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line").foregroundStyle(Color.accentColor)
            Text(chart.title).font(.headline)
            if let unit = chart.settings.unit, !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
            Spacer()
            Menu {
                Button("Add horizontal value guide…", action: onAddGuideFromCurrentScale)
                    .keyboardShortcut(isCurrentChart ? KeyboardShortcut("g", modifiers: [.command, .option]) : nil)
                Button("Add time guide at Now") {
                    model.addTimeGuide(at: now, sessionID: session.id)
                }.keyboardShortcut(isCurrentChart ? KeyboardShortcut("t", modifiers: [.command, .option]) : nil)
                Button("Manage Guides…") { showGuideManager = true; editingGuide = nil }
            } label: { Label("Guides", systemImage: "line.3.horizontal") }.help("Create and edit chart guides")
            Menu {
                Button("Rename Chart…") { renameChartText = chart.title; showRenameChart = true }
                let charts = session.charts.filter(\.isVisible)
                if let index = charts.firstIndex(where: { $0.id == chart.id }) {
                    Button("Move Up") { model.reorderChart(chart.id, to: max(0, index - 1)) }.disabled(index == 0)
                    Button("Move Down") { model.reorderChart(chart.id, to: min(charts.count - 1, index + 1)) }.disabled(index == charts.count - 1)
                }
                Button(chart.streams.isEmpty ? "Delete Empty Chart" : "Hide Chart") { model.deleteChart(chart.id) }
                let hidden = session.charts.filter { !$0.isVisible }
                if !hidden.isEmpty {
                    Divider(); Menu("Restore Hidden Chart") {
                        ForEach(hidden) { item in Button(item.title) { model.restoreChart(item.id) } }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }.help("Chart actions")
            Button(action: onToggleLines) { Image(systemName: chart.settings.linesVisible ? "point.topleft.down.to.point.bottomright.curvepath" : "point.topleft.down.to.point.bottomright.curvepath") }
                .buttonStyle(.plain).foregroundStyle(chart.settings.linesVisible ? Color.accentColor : .secondary).help("Toggle connecting lines")
            Button(action: onToggleDots) { Image(systemName: "circle.fill") }.buttonStyle(.plain).foregroundStyle(chart.settings.dotsVisible ? Color.accentColor : .secondary).help("Toggle dots")
            Button(action: onTarget) {
                Label(chart.isTarget ? "Target" : "Set target", systemImage: chart.isTarget ? "scope" : "circle.dashed")
            }.buttonStyle(.bordered).tint(chart.isTarget ? .accentColor : .secondary).controlSize(.small)
        }
        .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 5)
    }

    private var streamLegend: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(chart.streams.enumerated()), id: \.element.id) { index, stream in
                    HStack(spacing: 6) {
                        Circle().fill(PlotCanvas.color(for: stream, fallback: index)).frame(width: 8, height: 8)
                        Text(stream.name).font(.caption.weight(.medium))
                        Text(stream.state.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                        Menu {
                            streamActions(stream)
                            Divider()
                            Button((stream.linesVisible ?? chart.settings.linesVisible) ? "Hide connecting lines" : "Show connecting lines") {
                                model.updateStreamStyle(stream.id, colorHex: stream.colorHex, dotsVisible: stream.dotsVisible, linesVisible: !(stream.linesVisible ?? chart.settings.linesVisible))
                            }
                            Button((stream.dotsVisible ?? chart.settings.dotsVisible) ? "Hide dots" : "Show dots") {
                                model.updateStreamStyle(stream.id, colorHex: stream.colorHex, dotsVisible: !(stream.dotsVisible ?? chart.settings.dotsVisible), linesVisible: stream.linesVisible)
                            }
                            Menu("Color") {
                                ForEach(0..<9, id: \.self) { index in
                                    Button("Color \(index + 1)") {
                                        model.updateStreamStyle(stream.id, colorHex: PlotCanvas.paletteHex(index), dotsVisible: stream.dotsVisible, linesVisible: stream.linesVisible)
                                    }
                                }
                            }
                        } label: { Image(systemName: "ellipsis").font(.caption).foregroundStyle(.secondary) }.menuStyle(.borderlessButton)
                    }
                    .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .draggable(stream.id.uuidString)
                    .contextMenu {
                        streamActions(stream)
                    }
                }
                if chart.streams.isEmpty { Text("No streams").font(.caption).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 14).padding(.vertical, 9)
        }.scrollIndicators(.hidden)
            .dropDestination(for: String.self) { items, _ in
                guard let rawID = items.first, let id = UUID(uuidString: rawID) else { return false }
                onMove(id, chart.id)
                return true
            }
            .help("Drop a stream here to move it to this chart")
    }

    @ViewBuilder private func guideColorMenu(_ guide: Guide) -> some View {
        Menu("Guide Color") {
            ForEach(0..<9, id: \.self) { index in
                Button {
                    var value = guide
                    value.color = PlotCanvas.paletteHex(index)
                    if value.orientation == .verticalTime { model.updateTimeGuide(value, sessionID: session.id) }
                    else { onEditGuide(value) }
                } label: {
                    Label("Color \(index + 1)", systemImage: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(PlotCanvas.paletteColor(index))
                }
            }
        }
    }

    @ViewBuilder private func streamActions(_ stream: StreamDescriptor) -> some View {
        Button("Rename…") { renameText = stream.name; renameStream = stream }
        Menu("Move to Chart") {
            ForEach(session.charts.filter { $0.id != chart.id && $0.isVisible }) { destination in
                Button(destination.title) { onMove(stream.id, destination.id) }
            }
        }
        Button("Move to New Chart") { model.moveToNewChart(stream.id, sessionID: session.id, after: chart.id) }
        Button("Continue / Reassociate Group…") { reassociationSource = stream }
    }

    private var isCurrentChart: Bool {
        (model.selectedChartIDs[session.id] ?? session.charts.last(where: \.isVisible)?.id) == chart.id
    }

    @ViewBuilder private var guideManagerSheet: some View {
        if let editingGuide { guideEditor(editingGuide) }
        else if isAddingGuide { newGuideEditor }
        else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Guides").font(.title3.weight(.semibold))
                HStack { Button("Add value guide…") { onAddGuideFromCurrentScale() }; Button("Add time guide at Now") { model.addTimeGuide(at: now, sessionID: session.id) } }
                List {
                    Section("Chart guides") {
                        ForEach(chart.guides) { guide in guideRow(guide, isTime: false) }
                    }
                    Section("Session time guides") {
                        ForEach(session.timeGuides) { guide in guideRow(guide, isTime: true) }
                    }
                }.listStyle(.inset)
                HStack { Spacer(); Button("Done") { showGuideManager = false } }
            }.padding(20).frame(width: 460, height: 430)
        }
    }

    private func guideRow(_ guide: Guide, isTime: Bool) -> some View {
        HStack {
            Circle().fill(Color.accentColor).frame(width: 9, height: 9)
            VStack(alignment: .leading) {
                Text(guide.label?.isEmpty == false ? guide.label! : (guide.orientation == .horizontalValue ? "Value guide" : "Time guide"))
                Text(guide.orientation == .verticalTime ? TimeText.format(Date(timeIntervalSince1970: guide.value), zone: session.timeline.timeZone ?? .local, reference: session.timeGuides.first(where: { $0.id == session.timeline.referenceTimeGuideID }).map { Date(timeIntervalSince1970: $0.value) }, includeDate: true) : NumericText.format(guide.value, scale: chart.settings.numericScale ?? .decimal, unit: chart.settings.unit) )
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(0..<9, id: \.self) { index in
                    Button("Color \(index + 1)") {
                        var updated = guide; updated.color = PlotCanvas.paletteHex(index)
                        if isTime { model.updateTimeGuide(updated, sessionID: session.id) } else { onEditGuide(updated) }
                    }
                }
            } label: { Image(systemName: "paintpalette") }.help("Change guide color")
            Button("Edit") { beginEditingGuide(guide) }
            Button(role: .destructive) { if isTime { model.removeTimeGuide(guide, sessionID: session.id) } else { onRemoveGuide(guide) } } label: { Image(systemName: "trash") }.help("Delete guide")
        }
    }

    private func guideEditor(_ item: Guide) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.orientation == .verticalTime ? "Edit time guide" : "Edit value guide").font(.title3.weight(.semibold))
            if item.orientation == .verticalTime {
                DatePicker(session.timeline.timeZone == .utc ? "UTC date and time" : "Local date and time", selection: $guideDate, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.calendar, guideCalendar)
                TextField("Seconds (0–59.999)", text: $guideSecond).textFieldStyle(.roundedBorder)
                if editedGuideTimestamp() == nil { Text("Enter seconds from 0 up to, but not including, 60.").font(.caption).foregroundStyle(.red) }
            } else {
                TextField("Value", text: $guideValue).textFieldStyle(.roundedBorder)
                    .onChange(of: guideValue) { _, _ in validateGuideValue() }
                if let guideEntryError { Text(guideEntryError).font(.caption).foregroundStyle(.red) }
            }
            TextField("Label (optional)", text: $guideLabel).textFieldStyle(.roundedBorder)
            if item.orientation == .horizontalValue {
                GuideAlertSettingsRow(guide: item, unit: chart.settings.unit, sessionID: session.id, chartID: chart.id, model: model)
            }
            HStack { Button("Back") { editingGuide = nil }; Spacer(); Button("Save Guide") {
                let enteredValue = item.orientation == .verticalTime ? editedGuideTimestamp() : NumericText.parse(guideValue, unit: chart.settings.unit)
                if let value = enteredValue, value.isFinite {
                    var guide = item.orientation == .verticalTime ? (session.timeGuides.first(where: { $0.id == item.id }) ?? item) : (chart.guides.first(where: { $0.id == item.id }) ?? item)
                    guide.value = value; guide.label = guideLabel.isEmpty ? nil : guideLabel
                    if guide.orientation == .verticalTime { model.updateTimeGuide(guide, sessionID: session.id) } else { onEditGuide(guide) }
                }
                editingGuide = nil
            }.disabled(item.orientation == .verticalTime ? editedGuideTimestamp() == nil : NumericText.parse(guideValue, unit: chart.settings.unit) == nil).keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 340)
    }

    private var newGuideEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add value guide").font(.title3.weight(.semibold))
            TextField("Value", text: $guideValue).textFieldStyle(.roundedBorder)
                .onChange(of: guideValue) { _, _ in validateGuideValue() }
            if let guideEntryError { Text(guideEntryError).font(.caption).foregroundStyle(.red) }
            TextField("Label (optional)", text: $guideLabel).textFieldStyle(.roundedBorder)
            HStack { Button("Back") { isAddingGuide = false }; Spacer(); Button("Add Guide") {
                if let value = NumericText.parse(guideValue, unit: chart.settings.unit) { onAddGuide(value, guideLabel.isEmpty ? nil : guideLabel) }
                isAddingGuide = false
            }.disabled(NumericText.parse(guideValue, unit: chart.settings.unit) == nil).keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 340)
    }

    private func onAddGuideFromCurrentScale() { editingGuide = nil; isAddingGuide = true; guideValue = ""; guideLabel = ""; validateGuideValue(); showGuideManager = true }
    private func hoverReadout(stream: StreamDescriptor, sample: StoredSample, offset: TimeInterval) -> String {
        let value = NumericText.format(sample.value, scale: chart.settings.numericScale ?? .decimal, unit: chart.settings.unit)
        let signedOffset = String(format: "%+.1fs", offset)
        return "\(stream.name)  \(value)  \(signedOffset)"
    }
    private func beginEditingGuide(_ guide: Guide) {
        isAddingGuide = false
        editingGuide = guide
        guideLabel = guide.label ?? ""
        if guide.orientation == .verticalTime {
            guideDate = Date(timeIntervalSince1970: guide.value)
            let seconds = Double(guideCalendar.component(.second, from: guideDate)) + guide.value.truncatingRemainder(dividingBy: 1)
            guideSecond = String(format: "%.3f", seconds)
        } else { guideValue = "\(guide.value)"; validateGuideValue() }
        showGuideManager = true
    }
    private func validateGuideValue() {
        guideEntryError = NumericText.parse(guideValue, unit: chart.settings.unit) == nil ? "Enter a finite number, such as 10 Gi." : nil
    }
    private func toggleSelectionBoundary(_ edge: PlotSelectionEdge) {
        guard let selection = session.timeline.selection else { return }
        let bounds = model.resolvedSelectionBounds(selection, session: session)
        let duration = max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))
        switch edge {
        case .start:
            switch selection.mode {
            case .fixed: updateSelectionMode(.startFollowsEnd(duration: duration), bounds: bounds, selection: selection)
            case .startFollowsEnd: updateSelectionMode(.fixed, bounds: bounds, selection: selection)
            case .endFollowsNow: updateSelectionMode(.bothFollowNow(duration: duration), bounds: bounds, selection: selection)
            case .bothFollowNow: updateSelectionMode(.endFollowsNow, bounds: bounds, selection: selection)
            }
        case .end:
            switch selection.mode {
            case .fixed: updateSelectionMode(.endFollowsNow, bounds: bounds, selection: selection)
            case .endFollowsNow: updateSelectionMode(.fixed, bounds: bounds, selection: selection)
            case .startFollowsEnd: updateSelectionMode(.bothFollowNow(duration: duration), bounds: bounds, selection: selection)
            case .bothFollowNow: updateSelectionMode(.startFollowsEnd(duration: duration), bounds: bounds, selection: selection)
            }
        }
    }
    private func updateSelectionMode(_ mode: SelectionMode, bounds: ClosedRange<Date>, selection: TimeSelection) {
        var value = selection; value.mode = mode
        switch mode {
        case .fixed: value.start = bounds.lowerBound; value.end = bounds.upperBound
        case .endFollowsNow: value.start = bounds.lowerBound; value.end = model.sessionNow(session)
        case .bothFollowNow(let duration): let current = model.sessionNow(session); value.start = current.addingTimeInterval(-duration); value.end = current
        case .startFollowsEnd(let duration): value.end = bounds.upperBound; value.start = bounds.upperBound.addingTimeInterval(-duration)
        }
        onSelection(value)
    }
    private func editedGuideTimestamp() -> Double? {
        guard let seconds = Double(guideSecond), seconds >= 0, seconds < 60 else { return nil }
        var components = guideCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: guideDate)
        components.second = Int(seconds)
        guard let date = guideCalendar.date(from: components) else { return nil }
        return date.timeIntervalSince1970 + seconds.truncatingRemainder(dividingBy: 1)
    }
}

extension StreamDescriptor: Identifiable {}

private struct ReassociationSheet: View {
    let source: StreamDescriptor
    let session: SessionSnapshot
    let model: PipePlotAppModel
    let onClose: () -> Void
    @State private var targets: [StreamID: StreamID] = [:]

    private var sourceIDs: [StreamID] { model.samplerGroup(containing: source.id, sessionID: session.id) }
    private var sourceStreams: [StreamDescriptor] {
        let all = session.charts.flatMap(\.streams)
        return sourceIDs.compactMap { id in all.first(where: { $0.id == id }) }
    }
    private var candidates: [StreamDescriptor] {
        let sourceSet = Set(sourceIDs)
        return session.charts.filter(\.isVisible).flatMap(\.streams).filter {
            !sourceSet.contains($0.id) && ($0.state == .ended || $0.state == .disconnected)
        }
    }
    private var valid: Bool {
        sourceIDs.count > 0 && sourceStreams.count == sourceIDs.count
            && targets.count == sourceIDs.count && Set(targets.values).count == sourceIDs.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reassociate sampler group").font(.title3.weight(.semibold))
            Text("Map each incoming column to a disconnected stream. The entire group is applied together.")
                .font(.callout).foregroundStyle(.secondary)
            if candidates.count < sourceIDs.count {
                ContentUnavailableView("Not enough destination streams", systemImage: "arrow.left.arrow.right", description: Text("The destination group must have one disconnected stream per incoming column."))
            } else {
                ForEach(sourceStreams) { item in
                    HStack {
                        Text(item.name).frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Destination", selection: targetBinding(for: item.id)) {
                            Text("Choose destination…").tag(Optional<StreamID>.none)
                            ForEach(candidates) { candidate in
                                Text("\(candidate.name) · \(candidateChartTitle(candidate.id))")
                                    .tag(Optional(candidate.id))
                            }
                        }.frame(width: 240)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Reassociate") {
                    let destinationIDs = sourceIDs.compactMap { targets[$0] }
                    model.reassociate(sourceIDs, with: destinationIDs, sessionID: session.id)
                    onClose()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(22).frame(width: 520)
    }

    private func targetBinding(for id: StreamID) -> Binding<StreamID?> {
        Binding(get: { targets[id] }, set: { value in
            if let value { targets[id] = value } else { targets.removeValue(forKey: id) }
        })
    }

    private func candidateChartTitle(_ streamID: StreamID) -> String {
        session.charts.first(where: { $0.streams.contains(where: { $0.id == streamID }) })?.title ?? "Chart"
    }
}

private struct WindowFocusObserver: NSViewRepresentable {
    let onFocus: () -> Void
    func makeNSView(context: Context) -> FocusView { let view = FocusView(); view.onFocus = onFocus; return view }
    func updateNSView(_ nsView: FocusView, context: Context) { nsView.onFocus = onFocus; nsView.observeWindow() }
    static func dismantleNSView(_ nsView: FocusView, coordinator: ()) { nsView.stopObserving() }

    final class FocusView: NSView {
        var onFocus: (() -> Void)?
        private var token: NSObjectProtocol?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeWindow() }
        func observeWindow() {
            guard let window, token == nil else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onFocus?() }
            if window.isKeyWindow { onFocus?() }
        }
        func stopObserving() { if let token { NotificationCenter.default.removeObserver(token) }; token = nil }
        deinit { stopObserving() }
    }
}
