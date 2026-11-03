import SwiftUI
import PipePlotCore

/// Nil means the inspector reads the latest persisted setting. Text entered by
/// the user is kept per chart until a successful save or explicit discard.
struct ChartAxisDraft: Equatable {
    var unit: String?
    var minimum: String?
    var maximum: String?
    var hasChanges: Bool { unit != nil || minimum != nil || maximum != nil }

    mutating func clearValuesMatching(_ chart: ChartSnapshot) {
        if unit == (chart.settings.unit ?? "") { unit = nil }
        let range: (String, String)
        if case let .fixed(minimum, maximum) = chart.settings.yScale {
            range = ("\(minimum)", "\(maximum)")
        } else {
            range = ("", "")
        }
        if minimum == range.0 { minimum = nil }
        if maximum == range.1 { maximum = nil }
    }
}

struct ChartInspector: View {
    let model: PipePlotAppModel
    let sessionModel: SessionModel

    private var target: SessionCommandTarget {
        SessionCommandTarget(focused: sessionModel, editingText: false)
    }
    private var selectedChart: ChartSnapshot? { target.chart }

    var body: some View {
        Group {
            if let session = target.snapshot, let chart = selectedChart {
                settings(for: chart, session: session).id(chart.id)
            } else {
                ContentUnavailableView(
                    "No chart selected", systemImage: "slider.horizontal.3",
                    description: Text("Select an open chart to edit its settings."))
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
    }

    private func settings(for chart: ChartSnapshot, session: SessionSnapshot) -> some View {
        let draft = sessionModel.chartAxisDrafts[chart.id] ?? ChartAxisDraft()
        let range = rangeText(for: chart)
        let minimum = draft.minimum ?? range.0
        let maximum = draft.maximum ?? range.1
        let parsedMinimum = NumericText.parse(minimum, unit: chart.settings.unit)
        let parsedMaximum = NumericText.parse(maximum, unit: chart.settings.unit)
        let validRange = parsedMinimum.map { min in parsedMaximum.map { min < $0 } ?? false } ?? false
        return Form {
            Section {
                Text(chart.title).font(.headline)
                Text("Select another chart to edit its settings. Draft text stays with each chart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Axis presentation") {
                HStack {
                    TextField(
                        "Unit label",
                        text: draftBinding(\.unit, chartID: chart.id, fallback: chart.settings.unit ?? ""),
                        prompt: Text("e.g. MiB")
                    )
                    .onSubmit { saveUnit(for: chart) }
                    Button("Save Unit") { saveUnit(for: chart) }
                        .disabled(draft.unit == nil || draft.unit == (chart.settings.unit ?? ""))
                }
                Picker(
                    "Number scale",
                    selection: Binding(
                        get: { chart.settings.numericScale },
                        set: { value in updateSettings(chart.id) { $0.numericScale = value } })
                ) {
                    Text("SI (k, M, G)").tag(NumericScale.decimal)
                    Text("Binary (Ki, Mi, Gi)").tag(NumericScale.binary)
                }
                Toggle(
                    "Include zero",
                    isOn: Binding(
                        get: { chart.settings.includeZero },
                        set: { value in updateSettings(chart.id) { $0.includeZero = value } }))
                Picker(
                    "Relative value origin",
                    selection: Binding(
                        get: { chart.settings.referenceGuideID },
                        set: { value in updateSettings(chart.id) { $0.referenceGuideID = value } })
                ) {
                    Text("Absolute values").tag(UUID?.none)
                    ForEach(chart.guides.filter { $0.orientation == .horizontalValue }) { guide in
                        Text(
                            guide.label?.isEmpty == false
                                ? guide.label! : guide.value.formatted(.number.precision(.significantDigits(4)))
                        ).tag(Optional(guide.id))
                    }
                }
                HStack {
                    TextField("Minimum", text: draftBinding(\.minimum, chartID: chart.id, fallback: range.0))
                    TextField("Maximum", text: draftBinding(\.maximum, chartID: chart.id, fallback: range.1))
                }
                HStack {
                    Button("Set Y range") {
                        setYRange(for: chart)
                    }.disabled(!validRange)
                    Button("Auto") {
                        autoYRange(for: chart)
                    }
                }
                if draft.minimum != nil || draft.maximum != nil, !validRange {
                    Text("Enter a finite minimum below the maximum.")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("Scale and unit belong to the chart. Moving a stream leaves these settings in place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Relative time origin") {
                Picker(
                    "Relative time origin",
                    selection: Binding(
                        get: { session.timeline.referenceTimeGuideID },
                        set: { value in
                            guard let current = target.snapshot else { return }
                            model.setTimeReference(value, session: current)
                        })
                ) {
                    Text("Absolute time").tag(UUID?.none)
                    ForEach(session.timeGuides) { guide in
                        Text(
                            guide.label?.isEmpty == false
                                ? guide.label!
                                : TimeText.format(
                                    Date(timeIntervalSince1970: guide.value), zone: session.timeline.timeZone,
                                    includeDate: true)
                        ).tag(Optional(guide.id))
                    }
                }
            }
            Section("Guide notifications") {
                ForEach(chart.guides.filter { $0.orientation == .horizontalValue }) { guide in
                    GuideAlertSettingsRow(
                        guide: guide, unit: chart.settings.unit, sessionID: session.id, chartID: chart.id,
                        model: model)
                }
                if chart.guides.allSatisfy({ $0.orientation != .horizontalValue }) {
                    Text("Add a horizontal value guide to configure notifications.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if draft.hasChanges {
                Section {
                    Button("Discard unsaved axis text") { sessionModel.chartAxisDrafts[chart.id] = nil }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func draftBinding(
        _ keyPath: WritableKeyPath<ChartAxisDraft, String?>, chartID: ChartID, fallback: String
    ) -> Binding<String> {
        Binding(
            get: {
                sessionModel.chartAxisDrafts[chartID]?[keyPath: keyPath] ?? persistedText(keyPath, chartID, fallback)
            },
            set: { text in
                var draft = sessionModel.chartAxisDrafts[chartID] ?? ChartAxisDraft()
                draft[keyPath: keyPath] = text == persistedText(keyPath, chartID, fallback) ? nil : text
                sessionModel.chartAxisDrafts[chartID] = draft.hasChanges ? draft : nil
            })
    }
    private func persistedText(
        _ keyPath: WritableKeyPath<ChartAxisDraft, String?>, _ chartID: ChartID, _ fallback: String
    ) -> String {
        guard let chart = sessionModel.snapshot?.charts.first(where: { $0.id == chartID }) else { return fallback }
        if keyPath == \ChartAxisDraft.unit { return chart.settings.unit ?? "" }
        let range = rangeText(for: chart)
        return keyPath == \ChartAxisDraft.minimum ? range.0 : range.1
    }
    private func clearDraft(_ chartID: ChartID, _ keyPath: WritableKeyPath<ChartAxisDraft, String?>) {
        var draft = sessionModel.chartAxisDrafts[chartID] ?? ChartAxisDraft()
        draft[keyPath: keyPath] = nil
        sessionModel.chartAxisDrafts[chartID] = draft.hasChanges ? draft : nil
    }
    private func currentChart(_ id: ChartID) -> ChartSnapshot? {
        target.snapshot?.charts.first { $0.id == id }
    }
    func saveUnit(for chart: ChartSnapshot) {
        guard let text = sessionModel.chartAxisDrafts[chart.id]?.unit else { return }
        if model.updateUnit(text, chart: chart.id) {
            clearDraft(chart.id, \.unit)
        }
    }
    func setYRange(for chart: ChartSnapshot) {
        let draft = sessionModel.chartAxisDrafts[chart.id] ?? ChartAxisDraft()
        let range = rangeText(for: chart)
        guard let minimum = NumericText.parse(draft.minimum ?? range.0, unit: chart.settings.unit),
            let maximum = NumericText.parse(draft.maximum ?? range.1, unit: chart.settings.unit),
            minimum < maximum
        else { return }
        if model.updateScale(.fixed(min: minimum, max: maximum), chart: chart.id) {
            clearDraft(chart.id, \.minimum)
            clearDraft(chart.id, \.maximum)
        }
    }
    func autoYRange(for chart: ChartSnapshot) {
        if model.updateScale(.automatic, chart: chart.id) {
            clearDraft(chart.id, \.minimum)
            clearDraft(chart.id, \.maximum)
        }
    }
    private func updateSettings(_ chartID: ChartID, _ edit: (inout AxisSettings) -> Void) {
        guard let current = currentChart(chartID) else { return }
        var settings = current.settings
        edit(&settings)
        model.update(settings, chartID)
    }
    private func rangeText(for chart: ChartSnapshot) -> (String, String) {
        if case let .fixed(minimum, maximum) = chart.settings.yScale {
            return ("\(minimum)", "\(maximum)")
        }
        return ("", "")
    }
}
