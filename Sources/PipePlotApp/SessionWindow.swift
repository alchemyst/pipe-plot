import SwiftUI
import AppKit
import Observation
import PipePlotCore

struct SessionWindow: View {
    let sessionID: SessionID
    let model: PipePlotAppModel
    @Bindable var sessionModel: SessionModel
    @State private var hoverDate: Date?
    @State private var dragStart: Date?
    @State private var gestures = SessionGesturePreview()
    @State private var showRenameSession = false
    @State private var sessionTitle = ""
    @State private var editingLocator: Guide?

    init(sessionID: SessionID, model: PipePlotAppModel) {
        self.sessionID = sessionID
        self.model = model
        self.sessionModel = model.sessionModel(for: sessionID)
    }

    private var session: SessionSnapshot? { sessionModel.snapshot }
    private var visibleCharts: [ChartSnapshot] { session?.charts.filter(\.isVisible) ?? [] }
    private func timeReference(_ session: SessionSnapshot) -> Date? {
        session.timeGuides.first(where: { $0.id == session.timeline.referenceTimeGuideID }).map {
            Date(timeIntervalSince1970: $0.value)
        }
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
        .onReceive(model.refreshTimer) { _ in model.tick(sessionID) }
        .onReceive(NotificationCenter.default.publisher(for: .pipePlotWillTerminate)) { _ in
            model.prepareForTermination()
        }
        .onDisappear { model.windowClosed(sessionID) }
        .sheet(isPresented: $showRenameSession) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename session").font(.title3.weight(.semibold))
                TextField("Session name", text: $sessionTitle)
                HStack {
                    Spacer()
                    Button("Cancel") { showRenameSession = false }
                    Button("Save") {
                        model.renameSession(sessionID, to: sessionTitle)
                        showRenameSession = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 340)
        }
        .sheet(item: $editingLocator) { guide in
            TimeLocatorEditor(
                guide: guide, zone: session?.timeline.timeZone ?? .local,
                save: { model.updateTimeGuide($0, sessionID: sessionID) }, close: { editingLocator = nil })
        }
        .background(
            SessionWindowObserver(
                onFocus: { model.becameActive(sessionID) },
                onVisibility: { active in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        model.setDisplayActive(active, for: sessionID)
                        if !active {
                            hoverDate = nil
                            gestures = SessionGesturePreview()
                        }
                    }
                },
                sessionUndoManager: model.undoManager(for: sessionID)
            ).frame(width: 1, height: 1)
        )
        .focusedSceneValue(
            sessionModel.snapshot?.isOpen == true && sessionModel.snapshot?.isDeleted == false
                ? sessionModel : nil
        )
        .alert("PipePlot", isPresented: errorPresented) {
            errorButtons
        } message: {
            errorMessage
        }
        .onKeyPress(keys: [.escape, "a", "d", "f", "w", "s"]) { press in
            guard Self.acceptsNavigationModifiers(press.modifiers), !isEditingText, let session else {
                return .ignored
            }
            switch press.key {
            case .escape:
                if session.timeline.selection != nil {
                    model.setSelection(nil, session: session)
                    return .handled
                }
            case "a":
                model.pan(80, width: 800, session: session)
                return .handled
            case "d":
                model.pan(-80, width: 800, session: session)
                return .handled
            case "w", "s":
                let range = model.domain(for: session)
                let anchor = range.lowerBound.addingTimeInterval(
                    range.upperBound.timeIntervalSince(range.lowerBound) / 2)
                model.zoom(press.key == "w" ? 1.25 : 0.8, anchor: anchor, session: session)
                return .handled
            case "f":
                guard let selection = session.timeline.selection else { return .ignored }
                let bounds = model.resolvedSelectionBounds(selection, session: session)
                var timeline = session.timeline
                timeline.followNow = false
                timeline.visibleStart = bounds.lowerBound
                timeline.visibleEnd = bounds.upperBound
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
                ContentUnavailableView(
                    "No charts yet", systemImage: "chart.xyaxis.line",
                    description: Text("Create a chart or pipe values into pp."))
            } else {
                if sessionModel.displayActive { sharedRuler(session) }
                // Retain row identity (including open editors) while their canvases
                // and query entry points are suspended.
                chartRows(session)
                if sessionModel.displayActive, let selection = session.timeline.selection {
                    SelectionInspector(session: session, selection: selection, model: model) {
                        model.setSelection($0, session: session)
                    }
                }
            }
            if sessionModel.displayActive { timelineBar(session) }
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
            Button {
                model.createSessionWindow()
            } label: {
                Label("New Session", systemImage: "plus.rectangle.on.folder")
            }
            .help("Create a session in a new window (⌘N)")
            Button {
                createChart()
            } label: {
                Label("Add Chart", systemImage: "chart.bar.xaxis")
            }
            .help("Create a chart below and make it the Target (⌘⇧D)")
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(
                    newChartDropTarget.isTargeted(model) ? Color.accentColor : .clear, lineWidth: 3)
            )
            .onDrop(
                of: [StreamDragState.contentType],
                delegate: StreamDropDelegate(target: newChartDropTarget, model: model))
            Menu {
                Button("Rename Session…") {
                    sessionTitle = session?.title ?? ""
                    showRenameSession = true
                }
                Button("Move Session to Trash", role: .destructive) { model.deleteSession(sessionID) }
            } label: {
                Label("Session", systemImage: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
    }

    private func chartRows(_ session: SessionSnapshot) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleCharts) { chart in
                        StreamInsertionTarget(sessionID: session.id, destination: .before(chart.id), model: model)
                        ChartRowHost(
                            chart: chart, session: session, model: model, hoverDate: $hoverDate,
                            gestures: gestures, sessionModel: sessionModel,
                            selectedChartID: $sessionModel.selectedChartID
                        )
                        .id(chart.id)
                    }
                    StreamInsertionTarget(
                        sessionID: session.id,
                        destination: visibleCharts.last.map { .after($0.id) } ?? .unanchored,
                        model: model)
                }
                .padding(16)
            }
            .onChange(of: sessionModel.valueGuideRequest?.id, initial: true) { _, _ in
                if let request = sessionModel.valueGuideRequest { scroll.scrollTo(request.chartID) }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var newChartDropTarget: StreamDropTarget {
        let anchor = visibleCharts.first(where: { $0.id == sessionModel.selectedChartID })?.id ?? visibleCharts.last?.id
        return StreamDropTarget(sessionID: sessionID, destination: anchor.map { .after($0) } ?? .unanchored)
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
                Text(
                    TimeText.format(
                        date, zone: session.timeline.timeZone, reference: timeReference(session),
                        includeDate: true)
                ).monospacedDigit().font(.caption)
            }
            Button {
                model.navigateBack(session)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canNavigateBack(session.id)).help("Back in time navigation")
            Button {
                model.navigateForward(session)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canNavigateForward(session.id)).help("Forward in time navigation")
            Text(
                "Now  \(TimeText.format(model.sessionNow(session), zone: session.timeline.timeZone, reference: timeReference(session)))"
            )
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                model.followNow(session)
            } label: {
                Label("Follow Now", systemImage: "clock")
            }
            .buttonStyle(.borderedProminent).tint(session.timeline.followNow ? .accentColor : .gray)
            .disabled(session.timeline.followNow)
            Menu {
                Button("Last 5 minutes") { model.setSpan(5 * 60, session: session) }
                Button("Last 15 minutes") { model.setSpan(15 * 60, session: session) }
                Button("Last hour") { model.setSpan(60 * 60, session: session) }
                Button("Show all history") { model.showAllHistory(session) }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }.help("Time range")
            Menu {
                Button("Local time") { model.setTimeZone(.local, session: session) }
                Button("UTC") { model.setTimeZone(.utc, session: session) }
            } label: {
                Label(session.timeline.timeZone == .utc ? "UTC" : "Local", systemImage: "globe")
            }
            .help("Display timestamps in local time or UTC")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    private func sharedRuler(_ session: SessionSnapshot) -> some View {
        let range = gestures.domain ?? model.domain(for: session)
        let bounds: ClosedRange<Date>? = {
            if let start = gestures.selectionStart, let end = gestures.selectionEnd {
                return min(start, end)...max(start, end)
            }
            return session.timeline.selection.map { model.resolvedSelectionBounds($0, session: session) }
        }()
        var guides = session.timeGuides
        if let preview = gestures.guide, preview.orientation == .verticalTime {
            guides.removeAll { $0.id == preview.id }
            guides.append(preview)
        }
        return TimelineLocators(
            range: range, timeZone: session.timeline.timeZone, reference: timeReference(session),
            guides: guides, selection: bounds, selectionMode: session.timeline.selection?.mode,
            now: model.sessionNow(session), hover: hoverDate,
            onHover: { hoverDate = $0 },
            onGuide: { guide, phase in
                switch phase {
                case .began, .changed:
                    gestures.guide = guide
                    gestures.guideChartID = nil
                case .ended:
                    gestures.guide = nil
                    model.updateTimeGuide(guide, sessionID: sessionID)
                case .cancelled: gestures.guide = nil
                }
            }, onGuideSelected: { editingLocator = $0 },
            onSelection: { start, end, edge, linked, phase in
                switch phase {
                case .began, .changed:
                    gestures.selectionStart = start
                    gestures.selectionEnd = end
                    gestures.selectionLinked = linked
                case .cancelled:
                    gestures.selectionStart = nil
                    gestures.selectionEnd = nil
                    gestures.selectionLinked = false
                case .ended:
                    gestures.selectionStart = nil
                    gestures.selectionEnd = nil
                    gestures.selectionLinked = false
                    guard end.timeIntervalSince(start) > 0.5 else { return }
                    let duration = end.timeIntervalSince(start)
                    var mode: SelectionMode = linked ? .endFollowsNow : .fixed
                    switch (edge, session.timeline.selection?.mode) {
                    case (.start, .endFollowsNow?): mode = .endFollowsNow
                    case (.start, .startFollowsEnd?): mode = .startFollowsEnd(duration: duration)
                    case (.start, .bothFollowNow?): mode = .bothFollowNow(duration: duration)
                    case (.end, .startFollowsEnd?):
                        mode = linked ? .bothFollowNow(duration: duration) : .startFollowsEnd(duration: duration)
                    case (.end, .bothFollowNow?) where linked: mode = .bothFollowNow(duration: duration)
                    default: break
                    }
                    model.setSelection(
                        TimeSelection(
                            start: start, end: end, mode: mode,
                            selectedStreamIDs: session.timeline.selection?.selectedStreamIDs ?? []), session: session)
                }
            }, onToggle: { model.toggleSelectionBoundary($0, session: session) },
            onClear: { model.setSelection(nil, session: session) },
            onAddGuide: { model.addTimeGuide(at: $0, sessionID: sessionID) })
    }

    private func createChart() {
        model.createChart(in: sessionID, after: sessionModel.selectedChartID)
    }

    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    static func acceptsNavigationModifiers(_ modifiers: EventModifiers) -> Bool {
        !modifiers.contains(.command) && !modifiers.contains(.option) && !modifiers.contains(.control)
    }

}

private struct StreamInsertionTarget: View {
    let sessionID: SessionID
    let destination: StreamDropDestination
    let model: PipePlotAppModel
    private var target: StreamDropTarget { StreamDropTarget(sessionID: sessionID, destination: destination) }
    private var targeted: Bool { target.isTargeted(model) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(targeted ? Color.accentColor : Color.secondary.opacity(0.18)).frame(
                height: targeted ? 4 : 1)
            if targeted {
                Text("New chart here").font(.caption.weight(.semibold)).padding(.horizontal, 10)
                    .background(.regularMaterial, in: Capsule())
            }
        }.frame(height: 20).contentShape(Rectangle())
            .accessibilityLabel("Drop stream here to insert a new chart")
            .onDrop(of: [StreamDragState.contentType], delegate: StreamDropDelegate(target: target, model: model))
    }
}

private struct ChartRowHost: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let model: PipePlotAppModel
    @Binding var hoverDate: Date?
    let gestures: SessionGesturePreview
    let sessionModel: SessionModel
    @Binding var selectedChartID: ChartID?
    private var target: StreamDropTarget { StreamDropTarget(sessionID: session.id, destination: .onto(chart.id)) }
    private var mergeTargeted: Bool { target.isTargeted(model) }
    private struct DisplayRequestID: Equatable {
        let chart: ChartSnapshot
        let range: ClosedRange<Date>
        let active: Bool
    }
    private struct HoverRequestID: Equatable {
        let streams: [StreamDescriptor]
        let date: Date?
        let active: Bool
    }

    var body: some View {
        let display = model.visibleSamples(for: chart, session: session, range: gestures.domain)
        ChartRow(
            chart: chart, session: session, samples: display.samples, currentDisplays: display.current,
            now: model.sessionNow(session), hoverDate: $hoverDate,
            sharedGestureDomain: Binding(get: { gestures.domain }, set: { gestures.domain = $0 }),
            sharedSelectionStart: Binding(get: { gestures.selectionStart }, set: { gestures.selectionStart = $0 }),
            sharedSelectionEnd: Binding(get: { gestures.selectionEnd }, set: { gestures.selectionEnd = $0 }),
            sharedSelectionLinked: Binding(get: { gestures.selectionLinked }, set: { gestures.selectionLinked = $0 }),
            sharedGuidePreview: Binding(get: { gestures.guide }, set: { gestures.guide = $0 }),
            sharedGuideChartID: Binding(get: { gestures.guideChartID }, set: { gestures.guideChartID = $0 }),
            model: model, sessionModel: sessionModel,
            onSelection: { model.setSelection($0, session: session) }
        )
        .onTapGesture {
            selectedChartID = chart.id
        }
        .task(
            id: DisplayRequestID(
                chart: chart, range: gestures.domain ?? model.domain(for: session), active: sessionModel.displayActive
            )
        ) {
            guard sessionModel.displayActive else { return }
            let range = gestures.domain ?? model.domain(for: session)
            model.requestVisibleSamples(for: chart, session: session, range: range)
            for stream in chart.streams {
                if stream.isLayoutHidden != true && stream.derivedSeries != nil {
                    model.requestDerivedSeries(stream, range: range, sessionID: session.id)
                } else {
                    model.cancelDerived(stream.id)
                }
            }
        }
        .task(
            id: HoverRequestID(
                streams: chart.streams, date: hoverDate, active: sessionModel.displayActive
            )
        ) {
            guard sessionModel.displayActive, let hoverDate else { return }
            for stream in chart.streams {
                if stream.isLayoutHidden == true {
                    model.cancelNearest(stream.id)
                } else {
                    model.requestNearestSample(stream.id, at: hoverDate)
                }
            }
        }
        .onChange(of: hoverDate) { _, date in
            if date == nil {
                for stream in chart.streams { model.cancelNearest(stream.id) }
            }
        }
        .onDisappear { model.cancelChartQueries(for: chart, sessionID: session.id) }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(chart.streams.filter { $0.isLayoutHidden != true && model.displayFailed($0.id) }) { stream in
                    HStack {
                        Text("Chart samples unavailable for \(stream.name)")
                        Button("Retry") { model.retryDisplay(stream.id) }
                    }
                    .font(.caption)
                    .padding(6)
                    .background(.regularMaterial)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 13).stroke(
                mergeTargeted
                    ? Color.accentColor : (selectedChartID == chart.id ? Color.accentColor.opacity(0.5) : .clear),
                lineWidth: mergeTargeted ? 4 : 2)
        )
        .overlay(alignment: .topLeading) {
            if mergeTargeted {
                Text("Merge stream into \(chart.title)").font(.caption.weight(.semibold)).padding(8)
                    .background(.regularMaterial, in: Capsule()).padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [StreamDragState.contentType], delegate: StreamDropDelegate(target: target, model: model))
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
    let currentDisplays: Set<StreamID>
    let now: Date
    @Binding var hoverDate: Date?
    @Binding var sharedGestureDomain: ClosedRange<Date>?
    @Binding var sharedSelectionStart: Date?
    @Binding var sharedSelectionEnd: Date?
    @Binding var sharedSelectionLinked: Bool
    @Binding var sharedGuidePreview: Guide?
    @Binding var sharedGuideChartID: ChartID?
    let model: PipePlotAppModel
    let sessionModel: SessionModel
    let onSelection: (TimeSelection?) -> Void

    @State private var guideSheet: GuideSheetRequest?
    @State private var derivedStream: StreamDescriptor?
    @State private var panPixels: CGFloat = 0
    @State private var zoomFactor = 1.0
    @State private var zoomAnchor: Date?
    @State private var gestureBaseDomain: ClosedRange<Date>?

    private var domain: ClosedRange<Date> {
        model.domain(for: session)
    }
    private var plotDomain: ClosedRange<Date> { sharedGestureDomain ?? domain }
    private var layoutStreams: [StreamDescriptor] { chart.streams.filter { $0.isLayoutHidden != true } }
    private var plotChart: ChartSnapshot {
        var value = chart
        value.streams = layoutStreams
        guard let guidePreview = sharedGuidePreview, sharedGuideChartID == chart.id,
            guidePreview.orientation == .horizontalValue
        else { return value }
        if let index = value.guides.firstIndex(where: { $0.id == guidePreview.id }) {
            value.guides[index] = guidePreview
        } else {
            value.guides.append(guidePreview)
        }
        return value
    }
    private var plotSession: SessionSnapshot {
        guard let guidePreview = sharedGuidePreview, guidePreview.orientation == .verticalTime else { return session }
        var value = session
        if let index = value.timeGuides.firstIndex(where: { $0.id == guidePreview.id }) {
            value.timeGuides[index] = guidePreview
        } else {
            value.timeGuides.append(guidePreview)
        }
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
            ChartHeader(chart: chart, session: session, model: model, sessionModel: sessionModel) {
                guideSheet = GuideSheetRequest(route: .manage)
            }
            ZStack(alignment: .topLeading) {
                if sessionModel.displayActive {
                    PlotCanvas(
                        chart: plotChart, session: plotSession, samples: samples, currentDisplays: currentDisplays,
                        domain: plotDomain, now: now, hoverDate: $hoverDate, selectionStart: $sharedSelectionStart,
                        selectionPreview: $sharedSelectionEnd, selectionLinkedPreview: $sharedSelectionLinked,
                        onFollowSelectionDuration: {
                            guard let selection = session.timeline.selection else { return }
                            let bounds = model.resolvedSelectionBounds(selection, session: session)
                            let duration = max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))
                            let current = model.sessionNow(session)
                            onSelection(
                                TimeSelection(
                                    start: current.addingTimeInterval(-duration), end: current,
                                    mode: .bothFollowNow(duration: duration),
                                    selectedStreamIDs: selection.selectedStreamIDs))
                        },
                        onBackgroundClick: { onSelection(nil) },
                        onBackgroundDoubleClick: { date in model.addTimeGuide(at: date, sessionID: session.id) },
                        onGuideSelected: { guideSheet = GuideSheetRequest(route: .edit($0)) },
                        onSelectionModeToggle: { toggleSelectionBoundary($0) },
                        selection: session.timeline.selection,
                        forecasts: model.forecastDrawings(for: plotChart, session: session),
                        draggingGuideID: sharedGuidePreview?.id,
                        trainingRanges: model.forecastTrainingRanges(for: plotChart, session: session),
                        onSelectionCommit: { start, end, mode in
                            guard let start, let end else {
                                onSelection(nil)
                                return
                            }
                            onSelection(
                                TimeSelection(
                                    start: start, end: end, mode: mode ?? .fixed,
                                    selectedStreamIDs: Set(layoutStreams.map(\.id))))
                        },
                        onGuide: { guide, phase in
                            switch phase {
                            case .began, .changed:
                                sharedGuidePreview = guide
                                sharedGuideChartID = chart.id
                            case .ended:
                                sharedGuidePreview = nil
                                sharedGuideChartID = nil
                                if guide.orientation == .verticalTime {
                                    model.updateTimeGuide(guide, sessionID: session.id)
                                } else {
                                    model.updateGuide(guide, chartID: chart.id, sessionID: session.id)
                                }
                            case .cancelled:
                                sharedGuidePreview = nil
                                sharedGuideChartID = nil
                            }
                        },
                        onPan: { delta, phase, width in
                            switch phase {
                            case .began:
                                panPixels = 0
                                gestureBaseDomain = domain
                                sharedGestureDomain = domain
                            case .changed:
                                if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                panPixels += delta.width
                                if let base = gestureBaseDomain {
                                    sharedGestureDomain = shifted(base, pixels: panPixels, width: width)
                                }
                            case .ended:
                                if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                panPixels += delta.width
                                model.pan(panPixels, width: width, session: session, from: gestureBaseDomain)
                                panPixels = 0
                                gestureBaseDomain = nil
                                sharedGestureDomain = nil
                            case .cancelled:
                                panPixels = 0
                                gestureBaseDomain = nil
                                sharedGestureDomain = nil
                            }
                        },
                        onZoom: { factor, anchor, phase in
                            switch phase {
                            case .began:
                                zoomFactor = 1
                                zoomAnchor = anchor
                                gestureBaseDomain = domain
                            case .changed:
                                if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                zoomFactor *= factor
                                zoomAnchor = anchor
                                if let base = gestureBaseDomain {
                                    sharedGestureDomain = scaled(base, factor: zoomFactor, anchor: anchor)
                                }
                            case .ended:
                                if gestureBaseDomain == nil { gestureBaseDomain = domain }
                                zoomFactor *= factor
                                model.zoom(zoomFactor, anchor: anchor, session: session, from: gestureBaseDomain)
                                zoomFactor = 1
                                zoomAnchor = nil
                                gestureBaseDomain = nil
                                sharedGestureDomain = nil
                            case .cancelled:
                                zoomFactor = 1
                                zoomAnchor = nil
                                gestureBaseDomain = nil
                                sharedGestureDomain = nil
                            }
                        }
                    )
                    .frame(height: 210)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                } else {
                    Color.clear.frame(height: 216)
                }
                if layoutStreams.isEmpty {
                    Text(
                        chart.streams.isEmpty
                            ? "Waiting for a pipeline…  Run `sampler | pp` to add data here."
                            : "All streams are hidden. Restore them from Chart actions; capture continues."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
            StreamLegend(chart: chart, session: session, model: model)
            Group {
                if let hoverDate {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(layoutStreams) { stream in
                                if let sample = model.nearestSample(stream.id, at: hoverDate) {
                                    let offset = sample.timestamp.timeIntervalSince(hoverDate)
                                    Text(hoverReadout(stream: stream, sample: sample, offset: offset))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                } else if model.nearestFailed(stream.id) {
                                    Text("\(stream.name): readout unavailable").font(.caption).foregroundStyle(
                                        .secondary)
                                    Button("Retry") { model.retryNearest(stream.id) }.font(.caption)
                                }
                            }
                        }.padding(.horizontal, 15)
                    }.scrollIndicators(.hidden)
                } else {
                    Color.clear
                }
            }
            .frame(height: 25)
            if sessionModel.displayActive {
                ForEach(layoutStreams.filter { $0.derivedSeries != nil }) { stream in
                    DerivedSeriesPanel(
                        stream: stream, unit: chart.settings.unit, domain: plotDomain,
                        result: model.derivedSeries(stream, range: plotDomain, sessionID: session.id),
                        hoverDate: hoverDate,
                        edit: { derivedStream = stream },
                        disable: { model.setDerivedSeries(nil, streamID: stream.id) },
                        failed: model.derivedFailed(stream.id),
                        retry: { model.retryDerived(stream.id) })
                }
            }
            ForEach(
                sessionModel.forecastStatuses.filter { status in
                    layoutStreams.contains(where: { $0.id == status.configuration.streamID })
                }, id: \.configuration.id
            ) { status in
                HStack(spacing: 8) {
                    Label("Linear forecast", systemImage: "arrow.up.right")
                    Text(status.message).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let crossing = status.crossing, crossing > now {
                        Text("in \(max(0, Int(crossing.timeIntervalSince(now))) / 60)m").font(
                            .caption.monospacedDigit()
                        ).foregroundStyle(.tint)
                    }
                    Button("Disable") { model.removeForecast(status.configuration.id, session: session) }.buttonStyle(
                        .borderless
                    ).font(.caption)
                    if model.fitFailed(status.configuration.id) {
                        Button("Retry") { model.retryFit(status.configuration) }.buttonStyle(.borderless).font(.caption)
                    }
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
        .onChange(of: sessionModel.valueGuideRequest?.id, initial: true) { _, _ in
            guard sessionModel.takeValueGuideRequest(for: chart.id) else { return }
            guideSheet = GuideSheetRequest(route: .addValue)
        }
        .sheet(item: $guideSheet) { request in
            ChartGuideManager(request: request, chartID: chart.id, sessionID: session.id, model: model) {
                guideSheet = nil
            }
        }
        .sheet(item: $derivedStream) { stream in
            DerivedSeriesSheet(stream: stream, model: model) { derivedStream = nil }
        }

    }

    private func hoverReadout(stream: StreamDescriptor, sample: StoredSample, offset: TimeInterval) -> String {
        let value = NumericText.format(
            sample.value, scale: chart.settings.numericScale, unit: chart.settings.unit)
        let signedOffset = String(format: "%+.1fs", offset)
        return "\(stream.name)  \(value)  \(signedOffset)"
    }
    private func toggleSelectionBoundary(_ edge: PlotSelectionEdge) {
        model.toggleSelectionBoundary(edge, session: session)
    }
}
