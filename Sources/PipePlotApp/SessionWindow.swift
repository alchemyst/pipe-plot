import SwiftUI
import AppKit
import PipePlotCore

struct SessionWindow: View {
    let sessionID: SessionID
    @Bindable var model: PipePlotAppModel
    @State private var selectedChartID: ChartID?
    @State private var hoverDate: Date?
    @State private var dragStart: Date?

    private var session: SessionSnapshot? { model.sessions[sessionID] }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let session {
                if session.charts.isEmpty {
                    ContentUnavailableView("No charts yet", systemImage: "chart.xyaxis.line", description: Text("Create a chart or pipe values into pp."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(session.charts.filter(\.isVisible)) { chart in
                                ChartRow(chart: chart, session: session, samples: model.visibleSamples(for: chart, session: session), now: model.sessionNow(session), hoverDate: $hoverDate,
                                         model: model,
                                         onTarget: { model.setTarget(chart.id) },
                                         onToggleDots: { model.toggleDots(chart) },
                                         onToggleLines: { model.toggleLines(chart) },
                                         onAddGuide: { value, label in model.addGuide(value: value, chart: chart, session: session, label: label) },
                                         onEditGuide: { guide in model.updateGuide(guide, chartID: chart.id, sessionID: session.id) },
                                         onRemoveGuide: { guide in model.removeGuide(guide, chartID: chart.id, sessionID: session.id) },
                                         onSelection: { model.setSelection($0, session: session) },
                                         onRename: { stream, name in model.rename(stream, to: name) },
                                         onMove: { stream, destination in model.move(stream, to: destination) })
                                    .onTapGesture { selectedChartID = chart.id }
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedChartID == chart.id ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 2))
                            }
                        }
                        .padding(16)
                    }
                    .background(Color(nsColor: .underPageBackgroundColor))
                }
                timelineBar(session)
            } else {
                ProgressView().task { model.refresh(sessionID) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(session.map { "\($0.number) · \($0.title)" } ?? "PipePlot")
        .onAppear { model.refresh(sessionID) }
        .onAppear { model.becameActive(sessionID) }
        .onReceive(model.refreshTimer) { _ in model.tick(sessionID) }
        .onReceive(NotificationCenter.default.publisher(for: .pipePlotReopen)) { _ in model.openSession(sessionID) }
        .onReceive(NotificationCenter.default.publisher(for: .pipePlotWillTerminate)) { _ in model.prepareForTermination() }
        .onDisappear { model.windowClosed(sessionID) }
        .background(WindowFocusObserver { model.becameActive(sessionID) }.frame(width: 0, height: 0))
        .alert("PipePlot", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK") { model.clearError() }
        } message: { Text(model.errorMessage ?? "") }
        .background {
            Button("New Chart") { createChart() }.keyboardShortcut("d", modifiers: [.command, .shift]).hidden()
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
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Create a chart below and make it the target sink (⌘⇧D)")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder private func timelineBar(_ session: SessionSnapshot) -> some View {
        HStack {
            Label("Session \(session.number)", systemImage: "circle.grid.2x2")
                .foregroundStyle(.secondary)
            Spacer()
            if let date = hoverDate {
                Text(date.formatted(date: .abbreviated, time: .standard)).monospacedDigit().font(.caption)
            }
            Button { model.navigateBack(session) } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canNavigateBack(session.id)).help("Back in time navigation")
            Button { model.navigateForward(session) } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canNavigateForward(session.id)).help("Forward in time navigation")
            Text("Now  \(model.sessionNow(session).formatted(date: .omitted, time: .standard))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { model.followNow(session) } label: { Label("Follow Now", systemImage: "dot.scope") }
                .buttonStyle(.borderedProminent).tint(session.timeline.followNow ? .accentColor : .gray)
                .disabled(session.timeline.followNow)
            Menu {
                Button("Last 5 minutes") { model.setSpan(5 * 60, session: session) }
                Button("Last 15 minutes") { model.setSpan(15 * 60, session: session) }
                Button("Last hour") { model.setSpan(60 * 60, session: session) }
                Button("Show all history") { model.showAllHistory(session) }
            } label: { Image(systemName: "clock.arrow.circlepath") }.help("Time range")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    private func createChart() {
        model.createChart(in: sessionID, after: selectedChartID)
    }
}

private struct ChartRow: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let samples: [StreamID: [StoredSample]]
    let now: Date
    @Binding var hoverDate: Date?
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

    @State private var selectionStart: Date?
    @State private var selectionPreview: Date?
    @State private var showGuideEditor = false
    @State private var guideValue = ""
    @State private var guideLabel = ""
    @State private var editingGuide: Guide?
    @State private var renameStream: StreamDescriptor?
    @State private var renameText = ""
    @State private var showingMove = false
    @State private var panPixels: CGFloat = 0
    @State private var zoomFactor = 1.0
    @State private var zoomAnchor: Date?

    private var domain: ClosedRange<Date> {
        model.domain(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ZStack(alignment: .topLeading) {
                PlotCanvas(chart: chart, session: session, samples: samples, domain: domain, now: now, hoverDate: $hoverDate, selectionStart: $selectionStart, selectionPreview: $selectionPreview,
                           selection: session.timeline.selection,
                           forecast: model.forecastDrawing(for: chart, session: session),
                           onSelectionCommit: { start, end, mode in
                                guard let start, let end else { onSelection(nil); return }
                                onSelection(TimeSelection(start: start, end: end, mode: mode ?? .fixed, selectedStreamIDs: Set(chart.streams.map(\.id))))
                           },
                           onGuide: { guide, phase in if phase == .ended { model.updateGuide(guide, chartID: chart.id, sessionID: session.id) } },
                           onPan: { delta, phase, width in
                                switch phase {
                                case .began: panPixels = 0
                                case .changed: panPixels += delta.width
                                case .ended:
                                    panPixels += delta.width
                                    model.pan(panPixels, width: width, session: session)
                                    panPixels = 0
                                case .cancelled: panPixels = 0
                                }
                           },
                           onZoom: { factor, anchor, phase in
                                switch phase {
                                case .began: zoomFactor = 1; zoomAnchor = anchor
                                case .changed: zoomFactor *= factor; zoomAnchor = anchor
                                case .ended:
                                    zoomFactor *= factor
                                    model.zoom(zoomFactor, anchor: anchor, session: session)
                                    zoomFactor = 1; zoomAnchor = nil
                                case .cancelled: zoomFactor = 1; zoomAnchor = nil
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
                                Text("\(stream.name)  \(format(sample.value))\(chart.settings.unit.map { " \($0)" } ?? "")  \(offset >= 0 ? "+" : "")\(String(format: "%.1f", offset))s")
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
            if let selection = session.timeline.selection { selectionSummary(selection) }
            if let status = model.forecastStatuses[session.id], chart.streams.contains(where: { $0.id == status.configuration.streamID }) {
                HStack(spacing: 8) {
                    Label("Linear forecast", systemImage: "arrow.up.right")
                    Text(status.message).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let crossing = status.crossing, crossing > now {
                        Text("in \(max(0, Int(crossing.timeIntervalSince(now))) / 60)m").font(.caption.monospacedDigit()).foregroundStyle(.tint)
                    }
                    Button("Disable") { model.setForecast(nil, session: session) }.buttonStyle(.borderless).font(.caption)
                }.padding(.horizontal, 15).padding(.bottom, 10)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
        .sheet(isPresented: $showGuideEditor) { guideSheet }
        .sheet(item: $renameStream) { stream in
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename stream").font(.title3.weight(.semibold))
                TextField("Stream name", text: $renameText).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Cancel") { renameStream = nil }; Button("Save") { onRename(stream.id, renameText); renameStream = nil }.keyboardShortcut(.defaultAction) }
            }.padding(22).frame(width: 340)
        }
        .confirmationDialog("Move stream to chart", isPresented: $showingMove) {
            ForEach(session.charts.filter { $0.id != chart.id }) { destination in
                Button(destination.title.isEmpty ? "Chart" : destination.title) { if let stream = renameStream { onMove(stream.id, destination.id) } }
            }
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
                ForEach(chart.guides) { guide in
                    Menu("\(guide.label?.isEmpty == false ? guide.label! : guide.orientation == .horizontalValue ? "Value guide" : "Time guide") · \(guide.value.formatted(.number.precision(.significantDigits(4))))") {
                        Button("Edit exact value…") { editingGuide = guide; guideValue = "\(guide.value)"; guideLabel = guide.label ?? ""; showGuideEditor = true }
                        Button("Delete guide", role: .destructive) { onRemoveGuide(guide) }
                    }
                }
            } label: { Label("Guides", systemImage: "line.3.horizontal") }.help("Create and edit chart guides")
            Button(action: onToggleLines) { Image(systemName: chart.settings.linesVisible ? "point.topleft.down.to.point.bottomright.curvepath" : "point.topleft.down.to.point.bottomright.curvepath") }
                .buttonStyle(.plain).foregroundStyle(chart.settings.linesVisible ? Color.accentColor : .secondary).help("Toggle connecting lines")
            Button(action: onToggleDots) { Image(systemName: "circle.fill") }.buttonStyle(.plain).foregroundStyle(chart.settings.dotsVisible ? Color.accentColor : .secondary).help("Toggle dots")
            Button(action: onTarget) {
                Label(chart.isTarget ? "Target sink" : "Set target", systemImage: chart.isTarget ? "scope" : "circle.dashed")
            }.buttonStyle(.bordered).tint(chart.isTarget ? .accentColor : .secondary).controlSize(.small)
        }
        .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 5)
    }

    private var streamLegend: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(chart.streams.enumerated()), id: \.element.id) { index, stream in
                    HStack(spacing: 6) {
                        Circle().fill(PlotCanvas.color(index)).frame(width: 8, height: 8)
                        Text(stream.name).font(.caption.weight(.medium))
                        Text(stream.state.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                        Menu {
                            Button("Rename…") { renameText = stream.name; renameStream = stream }
                            Menu("Move to Chart") {
                                ForEach(session.charts.filter { $0.id != chart.id }) { destination in
                                    Button(destination.title) { onMove(stream.id, destination.id) }
                                }
                            }
                        } label: { Image(systemName: "ellipsis").font(.caption).foregroundStyle(.secondary) }.menuStyle(.borderlessButton)
                    }
                    .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .contextMenu {
                        Button("Rename…") { renameText = stream.name; renameStream = stream }
                        Menu("Move to Chart") {
                            ForEach(session.charts.filter { $0.id != chart.id }) { destination in Button(destination.title) { onMove(stream.id, destination.id) } }
                        }
                    }
                }
                if chart.streams.isEmpty { Text("No streams").font(.caption).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 14).padding(.vertical, 9)
        }.scrollIndicators(.hidden)
    }

    @ViewBuilder private func selectionSummary(_ selection: TimeSelection) -> some View {
        HStack(spacing: 12) {
            Label("Selection", systemImage: "selection.pin.in.out")
                .font(.caption.weight(.semibold))
            Text("\(selection.start.formatted(date: .omitted, time: .shortened)) – \(selection.end.formatted(date: .omitted, time: .shortened))")
                .font(.caption.monospacedDigit())
            Text(selection.mode == .fixed ? "Fixed interval" : (selection.mode == .endFollowsNow ? "End follows now" : "Fixed duration follows now"))
                .font(.caption).foregroundStyle(.secondary)
            Menu("Selection") {
                Button("Fix interval") { var value = selection; value.mode = .fixed; onSelection(value) }
                Button("Link end to now") { var value = selection; value.mode = .endFollowsNow; onSelection(value) }
                Button("Follow now at fixed duration") {
                    let duration = max(0.5, selection.end.timeIntervalSince(selection.start)); let now = model.sessionNow(session)
                    onSelection(TimeSelection(start: now.addingTimeInterval(-duration), end: now, mode: .bothFollowNow(duration: duration), selectedStreamIDs: selection.selectedStreamIDs))
                }
                Divider()
                Button("Clear selection", role: .destructive) { onSelection(nil) }
            }
            Spacer()
            ForEach(chart.streams) { stream in
                if selection.selectedStreamIDs.isEmpty || selection.selectedStreamIDs.contains(stream.id) {
                    let stats = modelStatistics(stream.id, selection)
                    if let stats {
                        Text("\(stream.name): n \(stats.count) · min \(format(stats.minimum)) · max \(format(stats.maximum)) · mean \(format(stats.mean)) · Δ \(format(stats.change))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Menu { forecastMenu(selection) } label: { Label("Forecast", systemImage: "chart.xyaxis.line") }
                .disabled(chart.guides.filter { $0.orientation == .horizontalValue }.isEmpty)
                .help("Fit selected observations to a guide")
        }.padding(.horizontal, 15).padding(.bottom, 11)
    }

    @ViewBuilder private func forecastMenu(_ selection: TimeSelection) -> some View {
        ForEach(chart.streams) { stream in
            Menu(stream.name) {
                ForEach(chart.guides.filter { $0.orientation == .horizontalValue }) { guide in
                    Button(guide.label?.isEmpty == false ? guide.label! : "Guide at \(guide.value.formatted(.number.precision(.significantDigits(4))))") {
                        model.setForecast(ForecastConfiguration(streamID: stream.id, guideID: guide.id, selection: selection), session: session)
                    }
                }
            }
        }
        if session.timeline.forecast != nil { Divider(); Button("Disable forecast", role: .destructive) { model.setForecast(nil, session: session) } }
    }

    private func modelStatistics(_ streamID: StreamID, _ selection: TimeSelection) -> SelectionStatistics? { model.stats(for: streamID, in: selection) }
    private func format(_ value: Double) -> String { String(format: "%.3g", value) }

    private var guideSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingGuide == nil ? "Add value guide" : "Edit value guide").font(.title3.weight(.semibold))
            TextField("Value", text: $guideValue).textFieldStyle(.roundedBorder)
            TextField("Label (optional)", text: $guideLabel).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Cancel") { showGuideEditor = false; editingGuide = nil }; Button(editingGuide == nil ? "Add Guide" : "Save Guide") {
                if let value = Double(guideValue), value.isFinite {
                    if var guide = editingGuide { guide.value = value; guide.label = guideLabel.isEmpty ? nil : guideLabel; onEditGuide(guide) }
                    else { onAddGuide(value, guideLabel.isEmpty ? nil : guideLabel) }
                }
                showGuideEditor = false; editingGuide = nil
            }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 340)
    }

    private func onAddGuideFromCurrentScale() { editingGuide = nil; guideValue = ""; guideLabel = ""; showGuideEditor = true }
}

extension StreamDescriptor: Identifiable {}

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
