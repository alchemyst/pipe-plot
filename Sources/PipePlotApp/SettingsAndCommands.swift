import SwiftUI
import AppKit
import PipePlotCore

struct SessionPicker: View {
    let model: PipePlotAppModel
    let onSelect: (SessionID) -> Void
    @State private var renaming: SessionListing?
    @State private var sessionTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("PipePlot").font(.largeTitle.weight(.semibold))
                    Text("Watch numeric streams as they arrive.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            Text("Saved sessions").font(.headline)
            if model.sessionCatalog.isEmpty {
                ContentUnavailableView(
                    "No saved sessions", systemImage: "chart.xyaxis.line",
                    description: Text("Create a session or start a pipeline with `pp`."))
            } else {
                List(model.sessionCatalog.values.filter { !$0.isDeleted }.sorted { $0.number < $1.number }) { session in
                    Button {
                        onSelect(session.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text("\(session.number) · \(session.title)").font(.headline)
                                Text(
                                    "\(session.chartCount) charts · \(session.streamCount) streams"
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(session.isOpen ? "Open" : "Saved").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                model.deleteSession(session.id)
                            }
                        }
                        .contextMenu {
                            Button("Rename…") {
                                sessionTitle = session.title
                                renaming = session
                            }
                            Button("Move to Trash", role: .destructive) { model.deleteSession(session.id) }
                        }
                }.listStyle(.inset)
            }
            if model.sessionCatalog.values.contains(where: \.isDeleted) {
                Menu("Recently deleted sessions") {
                    ForEach(model.sessionCatalog.values.filter(\.isDeleted).sorted { $0.number < $1.number }) {
                        session in
                        Button("Restore \(session.number) · \(session.title)") { model.restoreSession(session.id) }
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    model.createSessionWindow()
                } label: {
                    Label("New Session", systemImage: "plus")
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $renaming) { session in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Rename session").font(.headline)
                    TextField("Title", text: $sessionTitle).onSubmit { commitTitle(session.id) }
                    HStack {
                        Button("Cancel") { renaming = nil }
                        Spacer()
                        Button("Save") { commitTitle(session.id) }.keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 360)
            }
    }
    private func commitTitle(_ id: SessionID) {
        model.renameSession(id, to: sessionTitle)
        renaming = nil
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Storage") {
                Text("Sessions and samples are stored locally in Application Support/PipePlot.")
                Text("Closing a session window disconnects its samplers and keeps its captured data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(width: 460, height: 220)
    }
}

struct GuideAlertDraft: Equatable {
    var direction: CrossingDirection?
    var hysteresis: String?
    var cooldown: String?
}

struct GuideAlertSettingsRow: View {
    let guide: Guide
    let unit: String?
    let sessionID: SessionID
    let chartID: ChartID
    let model: PipePlotAppModel

    private var presentation: SessionModel { model.sessionModel(for: sessionID) }
    private var draft: GuideAlertDraft { presentation.guideAlertDrafts[guide.id] ?? GuideAlertDraft() }
    private var currentGuide: Guide {
        presentation.snapshot?.charts.first(where: { $0.id == chartID })?.guides.first(where: { $0.id == guide.id })
            ?? guide
    }
    private var enabled: Bool { currentGuide.alert != nil }
    private var direction: CrossingDirection { draft.direction ?? currentGuide.alert?.direction ?? .both }
    private var hysteresis: String { draft.hysteresis ?? "\(currentGuide.alert?.hysteresis ?? 0)" }
    private var cooldown: String { draft.cooldown ?? "\(currentGuide.alert?.cooldown ?? 10)" }
    private var parsedHysteresis: Double? { NumericText.parse(hysteresis, unit: unit) }
    private var parsedCooldown: Double? { NumericText.parse(cooldown, unit: "s") }
    private var validationMessage: String? {
        guard let parsedHysteresis, parsedHysteresis >= 0 else {
            return "Hysteresis must be a finite non-negative number."
        }
        guard let parsedCooldown, parsedCooldown >= 0 else { return "Cooldown must be finite and non-negative." }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                currentGuide.label?.isEmpty == false
                    ? currentGuide.label!
                    : "Guide at \(NumericText.format(currentGuide.value, scale: presentation.snapshot?.charts.first(where: { $0.id == chartID })?.settings.numericScale ?? .decimal, unit: unit))",
                isOn: Binding(
                    get: { enabled },
                    set: { value in
                        var next = currentGuide
                        if value {
                            guard let parsedHysteresis, parsedHysteresis >= 0,
                                let parsedCooldown, parsedCooldown >= 0
                            else { return }
                            next.alert = GuideAlert(
                                direction: direction, hysteresis: parsedHysteresis, cooldown: parsedCooldown)
                        } else {
                            next.alert = nil
                        }
                        if model.updateGuide(next, chartID: chartID, sessionID: sessionID) { clearDraft() }
                    }))
            if enabled {
                Picker(
                    "Crossing",
                    selection: Binding(
                        get: { direction },
                        set: { value in
                            updateDraft { $0.direction = value }
                            save(direction: value)
                        })
                ) {
                    Text("Rising").tag(CrossingDirection.rising)
                    Text("Falling").tag(CrossingDirection.falling)
                    Text("Both").tag(CrossingDirection.both)
                }
                HStack {
                    TextField(
                        "Hysteresis",
                        text: Binding(
                            get: { hysteresis }, set: { value in updateDraft { $0.hysteresis = value } })
                    )
                    .onSubmit { save() }.accessibilityLabel("Hysteresis")
                    TextField(
                        "Cooldown (s)",
                        text: Binding(
                            get: { cooldown }, set: { value in updateDraft { $0.cooldown = value } })
                    )
                    .onSubmit { save() }.accessibilityLabel("Cooldown in seconds")
                }
                if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.red) }
            }
        }
    }
    private func updateDraft(_ edit: (inout GuideAlertDraft) -> Void) {
        var next = draft
        edit(&next)
        presentation.guideAlertDrafts[guide.id] = next
    }
    private func clearDraft() { presentation.guideAlertDrafts[guide.id] = nil }
    func save(direction: CrossingDirection? = nil) {
        guard let parsedHysteresis, parsedHysteresis >= 0, let parsedCooldown, parsedCooldown >= 0 else { return }
        var next = currentGuide
        next.alert = GuideAlert(
            direction: direction ?? self.direction, hysteresis: parsedHysteresis, cooldown: parsedCooldown)
        if model.updateGuide(next, chartID: chartID, sessionID: sessionID) { clearDraft() }
    }
}

/// Only the focused, open session may receive contextual menu actions.
@MainActor
struct SessionCommandTarget {
    let focused: SessionModel?
    let editingText: Bool

    static func isTextResponder(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    var snapshot: SessionSnapshot? {
        guard !editingText, let snapshot = focused?.snapshot, snapshot.isOpen, !snapshot.isDeleted else { return nil }
        return snapshot
    }
    var chart: ChartSnapshot? {
        guard let snapshot else { return nil }
        let visible = snapshot.charts.filter(\.isVisible)
        return visible.first(where: { $0.id == focused?.selectedChartID }) ?? visible.last
    }
    var canCreateChart: Bool { snapshot != nil }
    var canAddGuide: Bool { chart != nil }

    func createChart(using model: PipePlotAppModel) {
        guard let snapshot else { return }
        model.createChart(in: snapshot.id, after: chart?.id)
    }
    func requestValueGuide() {
        guard let chart else { return }
        focused?.requestValueGuide(for: chart.id)
    }
    func addTimeGuide(using model: PipePlotAppModel) {
        guard chart != nil, let snapshot else { return }
        model.addTimeGuide(at: model.sessionNow(snapshot), sessionID: snapshot.id)
    }
}

struct PipePlotCommands: Commands {
    let model: PipePlotAppModel
    var installInitialWindowOpener: ((OpenWindowAction) -> Void)? = nil
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(SessionModel.self) private var focusedSession: SessionModel?
    private var isEditingText: Bool {
        SessionCommandTarget.isTextResponder(NSApp.keyWindow?.firstResponder)
    }
    private var sessionTarget: SessionCommandTarget {
        SessionCommandTarget(focused: focusedSession, editingText: isEditingText)
    }
    private var activeUndoManager: UndoManager? {
        _ = model.editRevision
        if let sessionManager = (NSApp.keyWindow?.delegate as? SessionUndoWindowDelegate)?.manager {
            _ = sessionManager.menuState.revision
        }
        return SessionUndoMenuTarget.manager(for: NSApp.keyWindow)
    }
    var body: some Commands {
        let _ = installInitialWindowOpener?(openWindow)
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.createSessionWindow() }.keyboardShortcut("n", modifiers: [.command])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(activeUndoManager?.undoMenuItemTitle ?? "Undo") { activeUndoManager?.undo() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(activeUndoManager?.canUndo != true)
            Button(activeUndoManager?.redoMenuItemTitle ?? "Redo") { activeUndoManager?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(activeUndoManager?.canRedo != true)
        }
        CommandMenu("Session") {
            Button("New Chart Below") { sessionTarget.createChart(using: model) }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!sessionTarget.canCreateChart)
            Button("Add Value Guide…") { sessionTarget.requestValueGuide() }
                .keyboardShortcut("g", modifiers: [.command, .option]).disabled(!sessionTarget.canAddGuide)
            Button("Add Time Guide at Now") { sessionTarget.addTimeGuide(using: model) }
                .keyboardShortcut("t", modifiers: [.command, .option]).disabled(!sessionTarget.canAddGuide)
            Button("Open Saved Sessions…") { model.presentSessionPicker() }
        }
    }
}
