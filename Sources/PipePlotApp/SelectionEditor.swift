import SwiftUI
import PipePlotCore

struct SelectionEditorRequest: Identifiable {
    let id = UUID()
    let selection: TimeSelection
    let zone: PlotTimeZone
}

enum SelectionTracking: String, CaseIterable {
    case fixed = "Fixed interval"
    case endFollowsNow = "End follows now"
    case bothFollowNow = "Fixed duration follows now"
    case startFollowsEnd = "Start follows end"
}

/// Drafts are isolated from incoming samples and commit as a single selection edit.
struct SelectionEditorDraft {
    var start: String
    var end: String
    var duration: String
    var tracking: SelectionTracking
    let streamIDs: Set<StreamID>
    let zone: PlotTimeZone

    init(selection: TimeSelection, zone: PlotTimeZone, now: Date) {
        let bounds = selection.resolvedBounds(at: now)
        self.zone = zone
        start = Self.format(bounds.lowerBound, zone: zone)
        end = Self.format(bounds.upperBound, zone: zone)
        duration = String(format: "%.3f", bounds.upperBound.timeIntervalSince(bounds.lowerBound))
        streamIDs = selection.selectedStreamIDs
        switch selection.mode {
        case .fixed: tracking = .fixed
        case .endFollowsNow: tracking = .endFollowsNow
        case .bothFollowNow: tracking = .bothFollowNow
        case .startFollowsEnd: tracking = .startFollowsEnd
        }
    }

    static func format(_ date: Date, zone: PlotTimeZone) -> String {
        formatter(zone: zone, fractional: true).string(from: date)
    }

    private static func formatter(zone: PlotTimeZone, fractional: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone == .utc ? TimeZone(secondsFromGMT: 0) : .current
        formatter.dateFormat = fractional ? "yyyy-MM-dd HH:mm:ss.SSS" : "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }

    static func parse(_ text: String, zone: PlotTimeZone) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for fractional in [true, false] {
            let formatter = formatter(zone: zone, fractional: fractional)
            if let date = formatter.date(from: text), formatter.string(from: date) == text { return date }
        }
        return nil
    }

    func selection(at now: Date) -> TimeSelection? {
        let lower: Date, upper: Date, mode: SelectionMode
        switch tracking {
        case .fixed:
            guard let a = Self.parse(start, zone: zone), let b = Self.parse(end, zone: zone) else { return nil }
            lower = a
            upper = b
            mode = .fixed
        case .endFollowsNow:
            guard let a = Self.parse(start, zone: zone) else { return nil }
            lower = a
            upper = now
            mode = .endFollowsNow
        case .bothFollowNow, .startFollowsEnd:
            guard let seconds = Double(duration), seconds.isFinite, seconds >= 0.5 else { return nil }
            if tracking == .startFollowsEnd {
                guard let b = Self.parse(end, zone: zone) else { return nil }
                upper = b
                mode = .startFollowsEnd(duration: seconds)
            } else {
                upper = now
                mode = .bothFollowNow(duration: seconds)
            }
            lower = upper.addingTimeInterval(-seconds)
        }
        guard lower.timeIntervalSince1970.isFinite, upper.timeIntervalSince1970.isFinite, lower >= .distantPast,
            upper <= .distantFuture,
            upper.timeIntervalSince(lower) >= 0.5
        else { return nil }
        return TimeSelection(start: lower, end: upper, mode: mode, selectedStreamIDs: streamIDs)
    }
}

struct SelectionEditor: View {
    let now: () -> Date
    let save: (TimeSelection) -> Void
    let cancel: () -> Void
    @State private var draft: SelectionEditorDraft
    @FocusState private var startFocused: Bool

    init(
        request: SelectionEditorRequest, now: @escaping () -> Date,
        save: @escaping (TimeSelection) -> Void, cancel: @escaping () -> Void
    ) {
        self.now = now
        self.save = save
        self.cancel = cancel
        _draft = State(initialValue: SelectionEditorDraft(selection: request.selection, zone: request.zone, now: now()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Selection").font(.title2).accessibilityAddTraits(.isHeader)
            Text(
                "Times are in \(draft.zone == .utc ? "UTC" : "local time (\(TimeZone.current.identifier))"). Enter YYYY-MM-DD HH:MM:SS, optionally with .SSS milliseconds."
            )
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Tracking", selection: $draft.tracking) {
                    ForEach(SelectionTracking.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if draft.tracking == .fixed || draft.tracking == .endFollowsNow {
                    TextField("Start", text: $draft.start).focused($startFocused)
                }
                if draft.tracking == .fixed || draft.tracking == .startFollowsEnd {
                    TextField("End", text: $draft.end)
                } else {
                    LabeledContent("End", value: "Now, follows the session clock")
                }
                if draft.tracking == .bothFollowNow || draft.tracking == .startFollowsEnd {
                    TextField("Duration (seconds)", text: $draft.duration)
                }
            }.textFieldStyle(.roundedBorder)
            if draft.selection(at: now()) == nil {
                Text(
                    "Enter valid timestamps with an end at least 0.5 seconds after the start, or a finite duration of at least 0.5 seconds."
                )
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { if let selection = draft.selection(at: now()) { save(selection) } }
                    .disabled(draft.selection(at: now()) == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
            .onAppear { startFocused = true }
    }
}
