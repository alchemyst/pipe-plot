import SwiftUI
import PipePlotCore

struct GuideSheetRequest: Identifiable {
    enum Route {
        case manage
        case addValue
        case edit(Guide)
    }
    let id = UUID()
    let route: Route
}

/// One editor mode at a time. Drafts belong to the sheet, so refreshed chart
/// snapshots do not replace text the user is entering.
struct ChartGuidePresentation {
    enum Mode: Equatable {
        case list
        case addValue
        case edit(Guide)
    }
    private(set) var mode: Mode = .list
    var value = ""
    var label = ""
    var date = Date()
    var seconds = "0"

    init(_ route: GuideSheetRequest.Route, calendar: Calendar) {
        switch route {
        case .manage: break
        case .addValue: beginAdding()
        case .edit(let guide): beginEditing(guide, calendar: calendar)
        }
    }
    mutating func beginAdding() {
        value = ""
        label = ""
        mode = .addValue
    }
    mutating func beginEditing(_ guide: Guide, calendar: Calendar) {
        label = guide.label ?? ""
        if guide.orientation == .verticalTime {
            // Round the whole timestamp first so a fractional second that
            // carries into the next minute does not open as invalid "60.000".
            let rounded = (guide.value * 1_000).rounded() / 1_000
            date = Date(timeIntervalSince1970: rounded)
            let wholeSeconds = Double(calendar.component(.second, from: date))
            seconds = String(format: "%.3f", wholeSeconds + (rounded - floor(rounded)))
        } else {
            value = "\(guide.value)"
        }
        mode = .edit(guide)
    }
    mutating func back() { mode = .list }
    func timeValue(calendar: Calendar) -> Double? {
        guard let seconds = Double(seconds), seconds >= 0, seconds < 60 else { return nil }
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.second = Int(seconds)
        guard let result = calendar.date(from: components) else { return nil }
        return result.timeIntervalSince1970 + seconds.truncatingRemainder(dividingBy: 1)
    }
}

struct ChartGuideManager: View {
    let chartID: ChartID
    let sessionID: SessionID
    let model: PipePlotAppModel
    let close: () -> Void
    @State private var presentation: ChartGuidePresentation

    init(
        request: GuideSheetRequest, chartID: ChartID, sessionID: SessionID, model: PipePlotAppModel,
        close: @escaping () -> Void
    ) {
        self.chartID = chartID
        self.sessionID = sessionID
        self.model = model
        self.close = close
        var calendar = Calendar(identifier: .gregorian)
        let zone = model.sessionModel(for: sessionID).snapshot?.timeline.timeZone
        calendar.timeZone = zone == .utc ? TimeZone(secondsFromGMT: 0)! : .current
        _presentation = State(initialValue: ChartGuidePresentation(request.route, calendar: calendar))
    }
    private var session: SessionSnapshot? { model.sessionModel(for: sessionID).snapshot }
    private var chart: ChartSnapshot? { session?.charts.first { $0.id == chartID } }
    private var guideCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = session?.timeline.timeZone == .utc ? TimeZone(secondsFromGMT: 0)! : .current
        return calendar
    }
    var body: some View {
        if let session, let chart {
            content(chart: chart, session: session)
        } else {
            ContentUnavailableView("Chart unavailable", systemImage: "chart.xyaxis.line")
                .frame(width: 340, height: 180)
        }
    }
    @ViewBuilder private func content(chart: ChartSnapshot, session: SessionSnapshot) -> some View {
        switch presentation.mode {
        case .list: guideList(chart: chart, session: session)
        case .addValue: valueEditor(chart: chart, session: session, guide: nil)
        case .edit(let guide):
            if guide.orientation == .verticalTime {
                timeEditor(session: session, guide: guide)
            } else {
                valueEditor(chart: chart, session: session, guide: guide)
            }
        }
    }
    private func guideList(chart: ChartSnapshot, session: SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Guides").font(.title3.weight(.semibold))
            HStack {
                Button("Add value guide…") { presentation.beginAdding() }
                Button("Add time guide at Now") {
                    model.addTimeGuide(at: model.sessionNow(session), sessionID: sessionID)
                }
            }
            List {
                Section("Chart guides") {
                    ForEach(chart.guides) { guide in guideRow(guide, chart: chart, session: session) }
                }
                Section("Session time guides") {
                    ForEach(session.timeGuides) { guide in guideRow(guide, chart: chart, session: session) }
                }
            }.listStyle(.inset)
            HStack {
                Spacer()
                Button("Done", action: close)
            }
        }.padding(20).frame(width: 460, height: 430)
    }
    private func guideRow(_ guide: Guide, chart: ChartSnapshot, session: SessionSnapshot) -> some View {
        HStack {
            Circle().fill(Color.accentColor).frame(width: 9, height: 9)
            VStack(alignment: .leading) {
                Text(
                    guide.label?.isEmpty == false
                        ? guide.label! : (guide.orientation == .horizontalValue ? "Value guide" : "Time guide"))
                Text(
                    guide.orientation == .verticalTime
                        ? TimeText.format(
                            Date(timeIntervalSince1970: guide.value), zone: session.timeline.timeZone,
                            reference: session.timeGuides.first(where: {
                                $0.id == session.timeline.referenceTimeGuideID
                            }).map { Date(timeIntervalSince1970: $0.value) }, includeDate: true)
                        : NumericText.format(
                            guide.value, scale: chart.settings.numericScale, unit: chart.settings.unit)
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SnapshotMenu(title: "Change guide color", symbol: "paintpalette", compact: true) {
                (0..<9).map { index in
                    .command("Color \(index + 1)") {
                        var updated = guide
                        updated.color = PlotCanvas.paletteHex(index)
                        if guide.orientation == .verticalTime {
                            model.updateTimeGuide(updated, sessionID: sessionID)
                        } else {
                            model.updateGuide(updated, chartID: chartID, sessionID: sessionID)
                        }
                    }
                }
            }.frame(width: 32).help("Change guide color")
            Button("Edit") { presentation.beginEditing(guide, calendar: guideCalendar) }
            Button(role: .destructive) {
                if guide.orientation == .verticalTime {
                    model.removeTimeGuide(guide, sessionID: sessionID)
                } else {
                    model.removeGuide(guide, chartID: chartID, sessionID: sessionID)
                }
            } label: {
                Image(systemName: "trash")
            }.help("Delete guide")
        }
    }
    private func valueEditor(chart: ChartSnapshot, session: SessionSnapshot, guide: Guide?) -> some View {
        let parsed = NumericText.parse(presentation.value, unit: chart.settings.unit)
        return VStack(alignment: .leading, spacing: 14) {
            Text(guide == nil ? "Add value guide" : "Edit value guide").font(.title3.weight(.semibold))
            TextField("Value", text: $presentation.value).textFieldStyle(.roundedBorder)
            if parsed == nil {
                Text("Enter a finite number, such as 10 Gi.").font(.caption).foregroundStyle(.red)
            }
            TextField("Label (optional)", text: $presentation.label).textFieldStyle(.roundedBorder)
            if let guide {
                GuideAlertSettingsRow(
                    guide: guide, unit: chart.settings.unit, sessionID: sessionID, chartID: chartID, model: model)
            }
            HStack {
                Button("Back") { presentation.back() }
                Spacer()
                Button(guide == nil ? "Add Guide" : "Save Guide") {
                    guard let value = parsed else { return }
                    if let guide {
                        model.updateGuideDetails(
                            guide.id, value: value, label: presentation.label.isEmpty ? nil : presentation.label,
                            chartID: chartID, sessionID: sessionID, orientation: guide.orientation)
                    } else {
                        model.addGuide(
                            value: value, chart: chart, session: session,
                            label: presentation.label.isEmpty ? nil : presentation.label)
                    }
                    presentation.back()
                }.disabled(parsed == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 340)
    }
    private func timeEditor(session: SessionSnapshot, guide: Guide) -> some View {
        let timestamp = presentation.timeValue(calendar: guideCalendar)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Edit time guide").font(.title3.weight(.semibold))
            DatePicker(
                session.timeline.timeZone == .utc ? "UTC date and time" : "Local date and time",
                selection: $presentation.date, displayedComponents: [.date, .hourAndMinute]
            )
            .environment(\.calendar, guideCalendar)
            TextField("Seconds (0–59.999)", text: $presentation.seconds).textFieldStyle(.roundedBorder)
            if timestamp == nil {
                Text("Enter seconds from 0 up to, but not including, 60.").font(.caption).foregroundStyle(.red)
            }
            TextField("Label (optional)", text: $presentation.label).textFieldStyle(.roundedBorder)
            HStack {
                Button("Back") { presentation.back() }
                Spacer()
                Button("Save Guide") {
                    guard let timestamp else { return }
                    model.updateGuideDetails(
                        guide.id, value: timestamp, label: presentation.label.isEmpty ? nil : presentation.label,
                        chartID: chartID, sessionID: sessionID, orientation: guide.orientation)
                    presentation.back()
                }.disabled(timestamp == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 340)
    }
}
