import SwiftUI
import PipePlotCore

struct SessionPicker: View {
    @Bindable var model: PipePlotAppModel
    let onSelect: (SessionID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tint); VStack(alignment: .leading) { Text("PipePlot").font(.largeTitle.weight(.semibold)); Text("Watch numeric streams as they arrive.").foregroundStyle(.secondary) }; Spacer() }
            Divider()
            Text("Saved sessions").font(.headline)
            if model.sessions.isEmpty {
                ContentUnavailableView("No saved sessions", systemImage: "chart.xyaxis.line", description: Text("Create a session or start a pipeline with `pp`."))
            } else {
                List(model.sessions.values.sorted { $0.number < $1.number }) { session in
                    Button { onSelect(session.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading) { Text("\(session.number) · \(session.title)").font(.headline); Text("\(session.charts.count) charts · \(session.charts.reduce(0) { $0 + $1.streams.count }) streams").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(session.isOpen ? "Open" : "Saved").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }
            HStack { Spacer(); Button { model.createSessionWindow() } label: { Label("New Session", systemImage: "plus") }.buttonStyle(.borderedProminent).keyboardShortcut("n", modifiers: [.command]) }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
    }
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
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.createSessionWindow() }.keyboardShortcut("n", modifiers: [.command])
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Undo Session Edit") { if let id = model.activeSessionID { model.undo(id) } }
                .keyboardShortcut("z", modifiers: [.command]).disabled(model.activeSessionID == nil)
            Button("Redo Session Edit") { if let id = model.activeSessionID { model.redo(id) } }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(model.activeSessionID == nil)
        }
        CommandMenu("Session") {
            Button("New Chart Below") { if let id = model.activeSessionID { model.createChart(in: id, after: model.sessions[id]?.charts.last?.id) } }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.activeSessionID == nil)
            Button("Open Saved Sessions…") { model.presentSessionPicker() }
        }
    }
}
