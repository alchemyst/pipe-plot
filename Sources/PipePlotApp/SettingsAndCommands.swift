import SwiftUI
import AppKit
import PipePlotCore

let sessionTrashName: String = {
    let localized = try? URL.trashDirectory.resourceValues(forKeys: [.localizedNameKey]).localizedName
    if let localized, localized != ".Trash", localized != "Trash" { return localized }

    // Foundation may report “Trash” even where the system uses “Bin”.
    let language = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    let binRegions: Set<String> = ["AU", "GB", "IN", "ZA"]
    if language.languageCode?.identifier == "en", let region = language.region?.identifier,
        binRegions.contains(region)
    {
        return "Bin"
    }
    return "Trash"
}()

struct SessionPicker: View {
    let model: PipePlotAppModel
    let onSelect: (SessionID) -> Void
    @State private var renaming: SessionListing?
    @State private var sessionTitle = ""
    @State private var isSelecting = false
    @State private var selection: Set<SessionID> = []
    @State private var pendingDeletion: [SessionID] = []
    @State private var cleanupCutoff: Date?
    @State private var confirmsDeletion = false
    @State private var confirmsEmptyTrash = false
    @State private var pendingPurge: Set<SessionID> = []

    private var trashedSessions: [SessionListing] {
        model.sessionCatalog.values.filter(\.isDeleted).sorted { $0.number < $1.number }
    }

    private var savedSessions: [SessionListing] {
        model.sessionCatalog.values.filter { !$0.isDeleted }.sorted { $0.number < $1.number }
    }

    private var selectedSessions: [SessionID] {
        savedSessions.map(\.id).filter { selection.contains($0) }
    }

    var body: some View {
        let trashedSessions = trashedSessions
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
            HStack {
                Text("Saved sessions").font(.headline)
                Spacer()
                Button(isSelecting ? "Done" : "Select Sessions") {
                    isSelecting.toggle()
                    selection.removeAll()
                }
                Button("Clean Up Older Than a Week…") {
                    let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
                    let oldSessions = savedSessions.filter { session in
                        guard !session.isOpen, let closedAt = session.closedAt else { return false }
                        return closedAt < cutoff
                    }
                    confirmDeletion(of: oldSessions.map(\.id), closedBefore: cutoff)
                }
            }.disabled(savedSessions.isEmpty)
            if savedSessions.isEmpty {
                ContentUnavailableView(
                    "No saved sessions", systemImage: "chart.xyaxis.line",
                    description: Text("Create a session or start a pipeline with `pp`."))
            } else {
                List(savedSessions) { session in
                    if isSelecting {
                        Toggle(
                            isOn: Binding(
                                get: { selection.contains(session.id) },
                                set: { selected in
                                    if selected {
                                        selection.insert(session.id)
                                    } else {
                                        selection.remove(session.id)
                                    }
                                }
                            )
                        ) {
                            sessionRow(session)
                        }.toggleStyle(.checkbox)
                    } else {
                        Button {
                            onSelect(session.id)
                        } label: {
                            sessionRow(session)
                        }.buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Move to \(sessionTrashName)", systemImage: "trash", role: .destructive) {
                                    model.deleteSession(session.id)
                                }
                            }
                            .contextMenu {
                                Button("Rename…") {
                                    sessionTitle = session.title
                                    renaming = session
                                }
                                Button("Move to \(sessionTrashName)", role: .destructive) {
                                    model.deleteSession(session.id)
                                }
                            }
                    }
                }.listStyle(.inset)
            }
            Menu(sessionTrashName) {
                ForEach(trashedSessions) { session in
                    Button("Restore \(session.number) · \(session.title)") { model.restoreSession(session.id) }
                }
                if !trashedSessions.isEmpty { Divider() }
                Button("Empty \(sessionTrashName)…", role: .destructive) {
                    pendingPurge = Set(trashedSessions.map(\.id))
                    confirmsEmptyTrash = true
                }.disabled(trashedSessions.isEmpty && !model.store.hasPendingTrashCleanup)
            }.disabled(model.isEmptyingTrash)
            HStack {
                if isSelecting && !savedSessions.isEmpty {
                    Button("Move Selected to \(sessionTrashName)…", systemImage: "trash", role: .destructive) {
                        confirmDeletion(of: selectedSessions)
                    }.disabled(selectedSessions.isEmpty)
                    Text("\(selectedSessions.count) selected").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.createSessionWindow()
                } label: {
                    Label("New Session", systemImage: "plus")
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: savedSessions.map(\.id)) { _, ids in
                selection.formIntersection(ids)
                if ids.isEmpty { isSelecting = false }
            }
            .alert(
                pendingDeletion.isEmpty ? "No old sessions" : "Move \(pendingDeletion.count) to \(sessionTrashName)?",
                isPresented: $confirmsDeletion
            ) {
                if pendingDeletion.isEmpty {
                    Button("OK", role: .cancel) {}
                } else {
                    Button("Cancel", role: .cancel) {}
                    Button("Move to \(sessionTrashName)", role: .destructive) {
                        model.deleteSessions(pendingDeletion, closedBefore: cleanupCutoff)
                    }
                }
            } message: {
                if pendingDeletion.isEmpty {
                    Text("There are no closed sessions older than seven days.")
                } else if cleanupCutoff != nil {
                    Text(
                        "Closed sessions older than seven days will be moved to the \(sessionTrashName), where you can restore them."
                    )
                } else {
                    Text("Selected sessions will be moved to the \(sessionTrashName), where you can restore them.")
                }
            }
            .alert("Empty \(sessionTrashName)?", isPresented: $confirmsEmptyTrash) {
                Button("Cancel", role: .cancel) {}
                Button("Empty \(sessionTrashName)", role: .destructive) {
                    let ids = pendingPurge
                    Task { await model.emptyTrash(ids) }
                }
            } message: {
                Text("Sessions in the \(sessionTrashName) and their captured data will be permanently deleted.")
            }
            .alert(
                "PipePlot",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.clearError() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
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
    private func sessionRow(_ session: SessionListing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("\(session.number) · \(session.title)").font(.headline)
                Text("\(session.chartCount) charts · \(session.streamCount) streams")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.isOpen ? "Open" : "Saved").font(.caption).foregroundStyle(.secondary)
            if !isSelecting {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 4)
    }

    private func confirmDeletion(of ids: [SessionID], closedBefore cutoff: Date? = nil) {
        pendingDeletion = ids
        cleanupCutoff = cutoff
        confirmsDeletion = true
    }

    private func commitTitle(_ id: SessionID) {
        model.renameSession(id, to: sessionTitle)
        renaming = nil
    }
}

struct SettingsView: View {
    @AppStorage("plotTextScale") private var plotTextScale = 1.0
    var body: some View {
        Form {
            Section("Charts") {
                Picker("Chart text size", selection: $plotTextScale) {
                    Text("Standard (100%)").tag(1.0)
                    Text("Large (150%)").tag(1.5)
                    Text("Extra Large (200%)").tag(2.0)
                }
            }
            Section("Storage") {
                Text("Sessions and samples are stored locally in Application Support/PipePlot.")
                Text("Closing a session window disconnects its samplers and keeps its captured data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(width: 460, height: 300)
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
    var canSelectVisibleRange: Bool { chart?.streams.contains(where: { $0.isLayoutHidden != true }) == true }

    var canEditSelection: Bool { snapshot?.timeline.selection != nil || canSelectVisibleRange }

    func editSelection(using model: PipePlotAppModel) {
        guard let snapshot, canEditSelection else { return }
        let selection: TimeSelection
        if let current = snapshot.timeline.selection {
            selection = current
        } else if let chart {
            selection = TimeSelection.visibleRange(model.domain(for: snapshot), streams: chart.streams)
        } else {
            return
        }
        focused?.selectionEditorRequest = SelectionEditorRequest(selection: selection, zone: snapshot.timeline.timeZone)
    }
    func zoom(_ factor: Double, using model: PipePlotAppModel) {
        guard let snapshot else { return }
        let range = model.domain(for: snapshot)
        let anchor = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2)
        model.zoom(factor, anchor: anchor, session: snapshot)
    }
    func exportChart(using model: PipePlotAppModel) {
        guard let chart, !chart.streams.isEmpty else { return }
        RawCSVExport.chooseDestination(store: model.store.samples, streams: chart.streams, name: chart.title)
    }
    func exportSelection(using model: PipePlotAppModel) {
        guard let snapshot, let selection = snapshot.timeline.selection else { return }
        let streams = snapshot.charts.flatMap(\.streams).filter {
            selection.selectedStreamIDs.isEmpty || selection.selectedStreamIDs.contains($0.id)
        }
        guard !streams.isEmpty else { return }
        RawCSVExport.chooseDestination(
            store: model.store.samples, streams: streams,
            bounds: model.resolvedSelectionBounds(selection, session: snapshot), name: "Selection")
    }
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
    func selectVisibleRange(using model: PipePlotAppModel) {
        guard canSelectVisibleRange, let chart, let snapshot else { return }
        model.setSelection(
            TimeSelection.visibleRange(model.domain(for: snapshot), streams: chart.streams), session: snapshot)
    }
}

struct PipePlotCommands: Commands {
    @AppStorage("plotTextScale") private var plotTextScale = 1.0
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
        CommandGroup(after: .appInfo) {
            Button("Install pp Command…") { PPCommandInstaller.install() }
                .disabled(PPCommandInstaller.bundledCommand == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.createSessionWindow() }.keyboardShortcut("n", modifiers: [.command])
        }
        CommandGroup(after: .importExport) {
            Button("Export Chart CSV…") { sessionTarget.exportChart(using: model) }
                .disabled(sessionTarget.chart?.streams.isEmpty != false)
            Button("Export Selection CSV…") { sessionTarget.exportSelection(using: model) }
                .disabled(sessionTarget.snapshot?.timeline.selection == nil)
        }
        CommandGroup(after: .toolbar) {
            Button(focusedSession?.inspectorVisible == true ? "Hide Chart Settings" : "Show Chart Settings") {
                focusedSession?.inspectorVisible.toggle()
            }.keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(focusedSession?.snapshot?.isOpen != true)
            Menu("Selected Chart") {
                ForEach(focusedSession?.snapshot?.charts.filter(\.isVisible) ?? []) { chart in
                    Toggle(
                        chart.title,
                        isOn: Binding(
                            get: {
                                SessionCommandTarget(focused: focusedSession, editingText: false).chart?.id == chart.id
                            },
                            set: { if $0 { focusedSession?.selectedChartID = chart.id } }))
                }
            }.disabled(focusedSession?.snapshot?.isOpen != true)
            Divider()
            Button("Back in Time Navigation") {
                if let session = sessionTarget.snapshot { model.navigateBack(session) }
            }.disabled(sessionTarget.snapshot == nil || focusedSession?.canNavigateBack != true)
            Button("Forward in Time Navigation") {
                if let session = sessionTarget.snapshot { model.navigateForward(session) }
            }.disabled(sessionTarget.snapshot == nil || focusedSession?.canNavigateForward != true)
            Button("Pan Earlier") {
                if let session = sessionTarget.snapshot { model.pan(80, width: 800, session: session) }
            }
            .disabled(sessionTarget.snapshot == nil)
            Button("Pan Later") {
                if let session = sessionTarget.snapshot { model.pan(-80, width: 800, session: session) }
            }
            .disabled(sessionTarget.snapshot == nil)
            Button("Zoom In") { sessionTarget.zoom(1.25, using: model) }.disabled(sessionTarget.snapshot == nil)
            Button("Zoom Out") { sessionTarget.zoom(0.8, using: model) }.disabled(sessionTarget.snapshot == nil)
            Button("Fit Selection") { if let session = sessionTarget.snapshot { model.frameSelection(session) } }
                .disabled(sessionTarget.snapshot?.timeline.selection == nil)
            Button("Follow Now") { if let session = sessionTarget.snapshot { model.followNow(session) } }
                .disabled(sessionTarget.snapshot == nil || sessionTarget.snapshot?.timeline.followNow == true)
            Menu("Time Range") {
                Button("Last 5 Minutes") {
                    if let session = sessionTarget.snapshot { model.setSpan(300, session: session) }
                }
                Button("Last 15 Minutes") {
                    if let session = sessionTarget.snapshot { model.setSpan(900, session: session) }
                }
                Button("Last Hour") {
                    if let session = sessionTarget.snapshot { model.setSpan(3600, session: session) }
                }
                Button("Show All History") { if let session = sessionTarget.snapshot { model.showAllHistory(session) } }
            }.disabled(sessionTarget.snapshot == nil)
            Divider()
            Picker("Chart Text Size", selection: $plotTextScale) {
                Text("Standard (100%)").tag(1.0)
                Text("Large (150%)").tag(1.5)
                Text("Extra Large (200%)").tag(2.0)
            }
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
            Button("Select Visible Time Range") { sessionTarget.selectVisibleRange(using: model) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!sessionTarget.canSelectVisibleRange)
            Button("Edit Selection…") { sessionTarget.editSelection(using: model) }
                .disabled(!sessionTarget.canEditSelection)
            Button("Clear Selection") {
                if let session = sessionTarget.snapshot { model.setSelection(nil, session: session) }
            }.disabled(sessionTarget.snapshot?.timeline.selection == nil)
            Button("Open Saved Sessions…") { model.presentSessionPicker() }
        }
    }
}

@MainActor
private enum PPCommandInstaller {
    static var bundledCommand: URL? {
        let command = Bundle.main.bundleURL.appending(path: "Contents/MacOS/pp")
        return FileManager.default.isExecutableFile(atPath: command.path) ? command : nil
    }

    static func install() {
        guard let command = bundledCommand else { return }
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let appDirectory = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        guard appDirectory == "/Applications" || appDirectory == home.appending(path: "Applications").path else {
            show("Install PipePlot First", "Move PipePlot.app to Applications, then open that copy and try again.")
            return
        }

        let bin = home.appending(path: ".local/bin")
        let link = bin.appending(path: "pp")
        let pathHelp = "If your shell can’t find pp, add ~/.local/bin to your PATH. See the PipePlot README for help."
        if (try? files.destinationOfSymbolicLink(atPath: link.path)) == command.path {
            show("pp Is Already Installed", pathHelp)
            return
        }

        let prompt = NSAlert()
        prompt.messageText = "Install the pp Command?"
        prompt.informativeText = "PipePlot will link ~/.local/bin/pp to the command bundled with this app. " + pathHelp
        prompt.addButton(withTitle: "Install")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        do {
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            // Creating a link fails if any file or symlink already occupies this name.
            try files.createSymbolicLink(atPath: link.path, withDestinationPath: command.path)
            show("pp Installed", pathHelp)
        } catch {
            show("Couldn’t Install pp", "PipePlot could not create ~/.local/bin/pp.\n\n\(error.localizedDescription)")
        }
    }

    private static func show(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
