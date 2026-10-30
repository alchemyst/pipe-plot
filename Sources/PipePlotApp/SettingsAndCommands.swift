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
                    ForEach(model.sessions.values.sorted { $0.number < $1.number }) { Text("\($0.number) · \($0.title)").tag(Optional($0.id)) }
                }
                Picker("Chart", selection: $selectedChart) {
                    Text("Choose chart").tag(ChartID?.none)
                    ForEach(charts) { Text($0.title).tag(Optional($0.id)) }
                }
                TextField("Unit label", text: $unit, prompt: Text("e.g. MiB"))
                    .onSubmit { if let chart { model.updateUnit(unit, chart: chart.id) } }
                HStack {
                    TextField("Minimum", text: $minValue).frame(width: 110)
                    TextField("Maximum", text: $maxValue).frame(width: 110)
                    Button("Set Y range") { if let chart, let min = Double(minValue), let max = Double(maxValue) { model.updateScale(min: min, max: max, chart: chart.id) } }
                    Button("Auto") { if let chart { model.updateScale(min: 1, max: 0, chart: chart.id) } }
                }
                Text("Scale and unit belong to the chart. Moving a stream leaves these settings in place.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                Text("Sessions and samples are stored locally in Application Support/PipePlot.")
                Text("Closing a session window disconnects its samplers and keeps its captured data.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(width: 520, height: 350)
        .onChange(of: selectedChart) { _, _ in loadChartSettings() }
        .onChange(of: selectedSession) { _, _ in selectedChart = charts.first?.id; loadChartSettings() }
    }
    private func loadChartSettings() {
        guard let chart else { return }
        unit = chart.settings.unit ?? ""
        if case let .fixed(minimum, maximum) = chart.settings.yScale { minValue = "\(minimum)"; maxValue = "\(maximum)" } else { minValue = ""; maxValue = "" }
    }
}

struct PipePlotCommands: Commands {
    @Bindable var model: PipePlotAppModel
    private var textUndo: UndoManager? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable else { return nil }
        return editor.undoManager
    }
    private var undoName: String? { model.activeSessionID.flatMap { model.store.undoActionName(sessionID: $0) } }
    private var redoName: String? { model.activeSessionID.flatMap { model.store.redoActionName(sessionID: $0) } }
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
