import SwiftUI
import AppKit
import PipePlotCore

struct SessionPicker: View {
    @Bindable var model: PipePlotAppModel
    let onSelect: (SessionID) -> Void
    @State private var renaming: SessionSnapshot?
    @State private var sessionTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tint); VStack(alignment: .leading) { Text("PipePlot").font(.largeTitle.weight(.semibold)); Text("Watch numeric streams as they arrive.").foregroundStyle(.secondary) }; Spacer() }
            Divider()
            Text("Saved sessions").font(.headline)
            if model.sessions.isEmpty {
                ContentUnavailableView("No saved sessions", systemImage: "chart.xyaxis.line", description: Text("Create a session or start a pipeline with `pp`."))
            } else {
                List(model.sessions.values.filter { !$0.isDeleted }.sorted { $0.number < $1.number }) { session in
                    Button { onSelect(session.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading) { Text("\(session.number) · \(session.title)").font(.headline); Text("\(session.charts.count) charts · \(session.charts.reduce(0) { $0 + $1.streams.count }) streams").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(session.isOpen ? "Open" : "Saved").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename…") { sessionTitle = session.title; renaming = session }
                        Button("Move to Trash", role: .destructive) { model.deleteSession(session.id) }
                    }
                }.listStyle(.inset)
            }
            if model.sessions.values.contains(where: \.isDeleted) {
                Menu("Recently deleted sessions") {
                    ForEach(model.sessions.values.filter(\.isDeleted).sorted { $0.number < $1.number }) { session in
                        Button("Restore \(session.number) · \(session.title)") { model.restoreSession(session.id) }
                    }
                }
            }
            HStack { Spacer(); Button { model.createSessionWindow() } label: { Label("New Session", systemImage: "plus") }.buttonStyle(.borderedProminent).keyboardShortcut("n", modifiers: [.command]) }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $renaming) { session in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename session").font(.headline)
                TextField("Title", text: $sessionTitle).onSubmit { commitTitle(session.id) }
                HStack { Button("Cancel") { renaming = nil }; Spacer(); Button("Save") { commitTitle(session.id) }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 360)
        }
    }
    private func commitTitle(_ id: SessionID) { model.renameSession(id, to: sessionTitle); renaming = nil }
}

struct SettingsView: View {
    @Bindable var model: PipePlotAppModel
    @State private var selectedSession: SessionID?
    @State private var selectedChart: ChartID?
    @State private var unit = ""
    @State private var minValue = ""
    @State private var maxValue = ""

    private var charts: [ChartSnapshot] { selectedSession.flatMap { model.sessions[$0]?.charts } ?? [] }
    private var chart: ChartSnapshot? { charts.first { $0.id == selectedChart } }

    var body: some View {
        Form {
            Section("Axis presentation") {
                Picker("Session", selection: $selectedSession) {
                    Text("Choose session").tag(SessionID?.none)
                    ForEach(model.sessions.values.filter { !$0.isDeleted }.sorted { $0.number < $1.number }) { Text("\($0.number) · \($0.title)").tag(Optional($0.id)) }
                }
                Picker("Chart", selection: $selectedChart) {
                    Text("Choose chart").tag(ChartID?.none)
                    ForEach(charts) { Text($0.title).tag(Optional($0.id)) }
                }
                TextField("Unit label", text: $unit, prompt: Text("e.g. MiB"))
                    .onSubmit { if let chart { model.updateUnit(unit, chart: chart.id) } }
                Picker("Number scale", selection: Binding(get: { chart?.settings.numericScale ?? .decimal }, set: { value in updateSettings { $0.numericScale = value } })) {
                    Text("SI (k, M, G)").tag(NumericScale.decimal)
                    Text("Binary (Ki, Mi, Gi)").tag(NumericScale.binary)
                }
                Toggle("Include zero", isOn: Binding(get: { chart?.settings.includeZero ?? false }, set: { value in updateSettings { $0.includeZero = value } }))
                Picker("Relative value origin", selection: Binding(get: { chart?.settings.referenceGuideID }, set: { value in updateSettings { $0.referenceGuideID = value } })) {
                    Text("Absolute values").tag(UUID?.none)
                    ForEach(chart?.guides.filter { $0.orientation == .horizontalValue } ?? []) { guide in
                        Text(guide.label?.isEmpty == false ? guide.label! : guide.value.formatted(.number.precision(.significantDigits(4)))).tag(Optional(guide.id))
                    }
                }
                HStack {
                    TextField("Minimum", text: $minValue).frame(width: 110)
                    TextField("Maximum", text: $maxValue).frame(width: 110)
                    Button("Set Y range") { if let chart, let min = NumericText.parse(minValue, unit: chart.settings.unit), let max = NumericText.parse(maxValue, unit: chart.settings.unit) { model.updateScale(min: min, max: max, chart: chart.id) } }
                    Button("Auto") { if let chart { model.updateScale(min: 1, max: 0, chart: chart.id) } }
                }
                Text("Scale and unit belong to the chart. Moving a stream leaves these settings in place.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Relative time origin") {
                Picker("Relative time origin", selection: Binding(get: { selectedSession.flatMap { model.sessions[$0]?.timeline.referenceTimeGuideID } }, set: { value in if let session = selectedSession.flatMap({ model.sessions[$0] }) { model.setTimeReference(value, session: session) } })) {
                    Text("Absolute time").tag(UUID?.none)
                    ForEach(selectedSession.flatMap { model.sessions[$0]?.timeGuides } ?? []) { guide in
                        let session = selectedSession.flatMap { model.sessions[$0] }
                        let zone = session?.timeline.timeZone ?? .local
                        Text(guide.label?.isEmpty == false ? guide.label! : TimeText.format(Date(timeIntervalSince1970: guide.value), zone: zone, includeDate: true)).tag(Optional(guide.id))
                    }
                }
            }
            Section("Guide notifications") {
                if let chart, let sessionID = selectedSession {
                    ForEach(chart.guides.filter { $0.orientation == .horizontalValue }) { guide in
                        GuideAlertSettingsRow(guide: guide, unit: chart.settings.unit, sessionID: sessionID, chartID: chart.id, model: model)
                    }
                    if chart.guides.allSatisfy({ $0.orientation != .horizontalValue }) { Text("Add a horizontal value guide to configure notifications.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Storage") {
                Text("Sessions and samples are stored locally in Application Support/PipePlot.")
                Text("Closing a session window disconnects its samplers and keeps its captured data.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(width: 560, height: 650)
        .onChange(of: selectedChart) { _, _ in loadChartSettings() }
        .onChange(of: selectedSession) { _, _ in selectedChart = charts.first?.id; loadChartSettings() }
    }
    private func loadChartSettings() {
        guard let chart else { return }
        unit = chart.settings.unit ?? ""
        if case let .fixed(minimum, maximum) = chart.settings.yScale { minValue = "\(minimum)"; maxValue = "\(maximum)" } else { minValue = ""; maxValue = "" }
    }
    private func updateSettings(_ edit: (inout AxisSettings) -> Void) {
        guard let chart else { return }; var value = chart.settings; edit(&value); model.update(value, chart.id)
    }
}

struct GuideAlertSettingsRow: View {
    let guide: Guide
    let unit: String?
    let sessionID: SessionID
    let chartID: ChartID
    let model: PipePlotAppModel
    @State private var direction: CrossingDirection = .both
    @State private var hysteresis = "0"
    @State private var cooldown = "10"
    private var currentGuide: Guide {
        model.sessions[sessionID]?.charts.first(where: { $0.id == chartID })?.guides.first(where: { $0.id == guide.id }) ?? guide
    }
    private var enabled: Bool { currentGuide.alert != nil }
    private var parsedHysteresis: Double? { NumericText.parse(hysteresis, unit: unit) }
    private var parsedCooldown: Double? { NumericText.parse(cooldown, unit: "s") }
    private var validationMessage: String? {
        guard let parsedHysteresis, parsedHysteresis >= 0 else { return "Hysteresis must be a finite non-negative number." }
        guard let parsedCooldown, parsedCooldown >= 0 else { return "Cooldown must be finite and non-negative." }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(currentGuide.label?.isEmpty == false ? currentGuide.label! : "Guide at \(NumericText.format(currentGuide.value, scale: model.sessions[sessionID]?.charts.first(where: { $0.id == chartID })?.settings.numericScale ?? .decimal, unit: unit))", isOn: Binding(get: { enabled }, set: { value in
                if !value { var next = currentGuide; next.alert = nil; model.updateGuide(next, chartID: chartID, sessionID: sessionID) }
                else if let parsedHysteresis, parsedHysteresis >= 0, let parsedCooldown, parsedCooldown >= 0 { var next = currentGuide; next.alert = GuideAlert(direction: direction, hysteresis: parsedHysteresis, cooldown: parsedCooldown); model.updateGuide(next, chartID: chartID, sessionID: sessionID) }
            }))
            if enabled {
                Picker("Crossing", selection: $direction) { Text("Rising").tag(CrossingDirection.rising); Text("Falling").tag(CrossingDirection.falling); Text("Both").tag(CrossingDirection.both) }
                    .onChange(of: direction) { _, value in save(direction: value) }
                HStack {
                    TextField("Hysteresis", text: $hysteresis).onSubmit { save() }.accessibilityLabel("Hysteresis")
                    TextField("Cooldown (s)", text: $cooldown).onSubmit { save() }.accessibilityLabel("Cooldown in seconds")
                }
                if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.red) }
            }
        }.onAppear(perform: loadAlert).onChange(of: currentGuide.alert) { _, _ in loadAlert() }
    }
    private func loadAlert() { direction = currentGuide.alert?.direction ?? .both; hysteresis = "\(currentGuide.alert?.hysteresis ?? 0)"; cooldown = "\(currentGuide.alert?.cooldown ?? 10)" }
    private func save(direction: CrossingDirection? = nil) {
        guard let hysteresis = parsedHysteresis, hysteresis >= 0, let cooldown = parsedCooldown, cooldown >= 0 else { return }
        var next = currentGuide; next.alert = GuideAlert(direction: direction ?? self.direction, hysteresis: hysteresis, cooldown: cooldown)
        model.updateGuide(next, chartID: chartID, sessionID: sessionID)
    }
}

struct PipePlotCommands: Commands {
    @Bindable var model: PipePlotAppModel
    private var textUndo: UndoManager? {
        _ = model.commandRevision
        let responder = NSApp.keyWindow?.firstResponder
        let editor = (responder as? NSTextView) ?? (responder as? NSTextField)?.currentEditor() as? NSTextView
        guard let editor, editor.isEditable else { return nil }
        return editor.undoManager
    }
    private var undoName: String? { _ = model.editRevision; return model.activeSessionID.flatMap { model.store.undoActionName(sessionID: $0) } }
    private var redoName: String? { _ = model.editRevision; return model.activeSessionID.flatMap { model.store.redoActionName(sessionID: $0) } }
    private var canUndo: Bool { textUndo?.canUndo ?? (undoName != nil) }
    private var canRedo: Bool { textUndo?.canRedo ?? (redoName != nil) }
    private var undoTitle: String { textUndo?.undoMenuItemTitle ?? undoName.map { "Undo \($0)" } ?? "Undo" }
    private var redoTitle: String { textUndo?.redoMenuItemTitle ?? redoName.map { "Redo \($0)" } ?? "Redo" }
    private func performUndo(redo: Bool) {
        if let manager = textUndo {
            if redo { manager.redo() } else { manager.undo() }
        } else if let session = model.activeSessionID {
            if redo { model.redo(session) } else { model.undo(session) }
        }
    }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.createSessionWindow() }.keyboardShortcut("n", modifiers: [.command])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) { performUndo(redo: false) }
                .keyboardShortcut("z", modifiers: [.command]).disabled(!canUndo)
            Button(redoTitle) { performUndo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!canRedo)
        }
        CommandMenu("Session") {
            Button("New Chart Below") { if let id = model.activeSessionID { model.createChart(in: id, after: model.selectedChartIDs[id] ?? model.sessions[id]?.charts.last(where: { $0.isVisible })?.id) } }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.activeSessionID == nil)
            Button("Open Saved Sessions…") { model.presentSessionPicker() }
        }
    }
}
