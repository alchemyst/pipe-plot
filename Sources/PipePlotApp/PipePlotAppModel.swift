import Foundation
import SwiftUI
import AppKit
import Observation
import PipePlotCore
import PipePlotTransport

@MainActor
@Observable
final class PipePlotAppModel {
    let store: PipePlotStore
    private let queryStore: SampleStore
    private let notifications: GuideNotifications
    @ObservationIgnored private var ingestion: IngestionService?
    private var openWindowAction: ((SessionID) -> Void)?
    private var pendingWindowIDs: Set<SessionID> = []
    private var openSessionPickerAction: (() -> Void)?
    private var didBootstrap = false
    private var serverStarted = false
    @ObservationIgnored private var sessionModels: [SessionID: SessionModel] = [:]
    @ObservationIgnored private var undoManagers: [SessionID: SessionUndoManager] = [:]
    @ObservationIgnored private var streamSessions: [StreamID: SessionID] = [:]
    private(set) var sessionCatalog: [SessionID: SessionListing] = [:]
    var sessions: [SessionID: SessionSnapshot] {
        sessionModels.compactMapValues(\.snapshot)
    }
    func sessionModel(for id: SessionID) -> SessionModel {
        if let existing = sessionModels[id] { return existing }
        let created = SessionModel(id: id)
        sessionModels[id] = created
        return created
    }
    private(set) var errorMessage: String?
    private(set) var editRevision = 0
    let streamDrag = StreamDragState()
    var forecastStatuses: [SessionID: ForecastStatus] {
        sessionModels.compactMapValues { $0.forecastStatuses.first }
    }
    var allForecastStatuses: [SessionID: [ForecastStatus]] {
        sessionModels.mapValues(\.forecastStatuses)
    }
    private(set) var openedSessionIDs: Set<SessionID> = []
    private var terminating = false
    // Unknown state allows model-only clients; attached windows immediately report
    // their actual state. Suspension never changes capture or persistent session state.
    @ObservationIgnored private(set) var displayRefreshCount = 0
    let queries = BackgroundQueries()
    let refreshTimer = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    init(databaseURL: URL? = nil, socketURL: URL? = nil) {
        notifications = GuideNotifications(enabled: databaseURL == nil)
        do {
            let database = databaseURL ?? PipePlotLocations.supportDirectory.appendingPathComponent("pipeplot.sqlite")
            store = try PipePlotStore(databaseURL: database)
            queryStore = try SampleStore(readOnlyDatabaseURL: database)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "PipePlot could not open its saved data"
            alert.informativeText =
                "\(error.localizedDescription)\nYour saved files have not been replaced. Check available disk space and access to Application Support/PipePlot, then reopen the app."
            alert.runModal()
            exit(EXIT_FAILURE)
        }
        let mailbox = IngestionEventMailbox { [weak self] batch in
            self?.applyIngestionEvents(batch)
        }
        ingestion = IngestionService(
            store: store, socketURL: socketURL ?? PipePlotLocations.socketURL, emit: { mailbox.post($0) })
        refreshAll()
        // IPC readiness must not wait for a background/occluded SwiftUI scene
        // to appear. Model-only test clients keep their isolated stores offline.
        if databaseURL == nil || socketURL != nil { startServer() }
    }

    isolated deinit {
        ingestion?.stop()
    }

    func undoManager(for id: SessionID) -> SessionUndoManager {
        if let existing = undoManagers[id] { return existing }
        let created = SessionUndoManager(sessionID: id, store: store) { [weak self] redo in
            if redo { self?.redo(id) } else { self?.undo(id) }
        }
        undoManagers[id] = created
        return created
    }

    func installOpenWindow(_ action: @escaping (SessionID) -> Void) {
        AcceptanceTrace.record("window-opener-installed-pending-\(pendingWindowIDs.count)")
        openWindowAction = action
        let pending = pendingWindowIDs.sorted { (sessions[$0]?.number ?? 0) < (sessions[$1]?.number ?? 0) }
        pendingWindowIDs.removeAll()
        for id in pending { action(id) }
    }
    func requestSessionWindow(_ id: SessionID) {
        AcceptanceTrace.record("window-request-opener-\(openWindowAction != nil)")
        guard openedSessionIDs.insert(id).inserted else { return }
        if let openWindowAction { openWindowAction(id) } else { pendingWindowIDs.insert(id) }
    }
    func installOpenSessionPicker(_ action: @escaping () -> Void) { openSessionPickerAction = action }
    func presentSessionPicker() { openSessionPickerAction?() }
    func becameActive(_ id: SessionID) {
        openedSessionIDs.insert(id)
        refresh(id)
    }

    /// Returns the session to show in the initial WindowGroup. CLI launches deliberately start fresh.
    func bootstrap() -> SessionID? {
        guard !didBootstrap else { return nil }
        didBootstrap = true
        do {
            let all = try store.listSessions()
            for session in all {
                _ = sessionModel(for: session.id).update(session)
                indexStreams(in: session)
            }
            updateCatalog(all)
            let cliLaunch = ProcessInfo.processInfo.arguments.contains("--pipeplot-launched-by-cli")
            if cliLaunch {
                // Registration atomically creates the requested destination. Listing and
                // explicit-session lookup must not create an empty bootstrap session.
                startServer()
                return nil
            }
            let prior = store.previouslyOpenSessionIDs
            if !prior.isEmpty {
                for id in prior {
                    try store.setSessionOpen(true, sessionID: id)
                    refresh(id)
                }
                let ids = prior.compactMap { id in sessions[id]?.number == nil ? nil : id }.sorted {
                    (sessions[$0]?.number ?? 0) < (sessions[$1]?.number ?? 0)
                }
                // Let the initial scene bind the returned session before asking
                // its opener for additional restored windows.
                let additional = Array(ids.dropFirst())
                DispatchQueue.main.async { [weak self] in
                    for id in additional { self?.requestSessionWindow(id) }
                }
                startServer()
                return ids.first
            }
            if !all.isEmpty {
                startServer()
                return nil
            }
            let created = try store.createSession()
            refresh(created.id)
            startServer()
            return created.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func startServer() {
        guard !serverStarted else { return }
        do {
            try ingestion?.start()
            serverStarted = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func applyIngestionEvents(_ batch: IngestionEventBatch) {
        if batch.refreshAll {
            let now = Date()
            for session in sessionModels.values where session.snapshot?.timeline.clockStoppedAt == nil {
                if session.displayActive { session.advanceClock(to: now) }
            }
        }
        if !batch.registered.isEmpty || !batch.lifecycleChanges.isEmpty || batch.metadataChanged
            || batch.reconcileRegistrations || batch.refreshAll
        {
            refreshAll()
        }
        let registrationIDs: [SessionID]
        if batch.reconcileRegistrations {
            registrationIDs = sessions.values.filter { $0.isOpen && !$0.isDeleted }.map(\.id)
        } else {
            registrationIDs = batch.registered
        }
        for id in registrationIDs where sessions[id]?.isOpen == true && sessions[id]?.isDeleted == false {
            requestSessionWindow(id)
        }
        if !batch.refreshAll {
            for id in batch.firstSamples { tick(id) }
        }
        for crossing in batch.crossings {
            notifications.deliver(crossing) { [weak self] message in
                guard let message else { return }
                DispatchQueue.main.async { self?.errorMessage = message }
            }
        }
        if batch.omittedCrossings > 0 {
            errorMessage = "\(batch.omittedCrossings) guide crossing alerts were omitted while the app was busy."
        }
        if batch.omittedErrors > 0 {
            errorMessage =
                "\(batch.omittedErrors) ingestion errors were omitted; latest: \(batch.errors.last ?? "unknown")"
        } else if let message = batch.errors.last {
            errorMessage = message
        }
    }

    func createSessionWindow() {
        do {
            let session = try store.createSession()
            refreshAll()
            requestSessionWindow(session.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func createChart(in sessionID: SessionID, after chartID: ChartID?) {
        do {
            let chart = try store.createChart(in: sessionID, after: chartID)
            sessionModel(for: sessionID).selectedChartID = chart.id
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }

    func selectChart(_ chartID: ChartID, sessionID: SessionID) {
        sessionModel(for: sessionID).selectedChartID = chartID
    }

    func addTimeGuide(at date: Date, sessionID: SessionID) {
        updateTimeGuide(Guide(orientation: .verticalTime, value: date.timeIntervalSince1970), sessionID: sessionID)
    }

    func updateTimeGuide(_ guide: Guide, sessionID: SessionID) {
        do {
            try store.upsertTimeGuide(guide, sessionID: sessionID)
            refresh(sessionID)
        } catch { errorMessage = error.localizedDescription }
    }
    func removeTimeGuide(_ guide: Guide, sessionID: SessionID) {
        do {
            try store.removeTimeGuide(guide.id, sessionID: sessionID)
            refresh(sessionID)
        } catch { errorMessage = error.localizedDescription }
    }

    func setTarget(_ chartID: ChartID) {
        do {
            _ = try store.setTarget(chartID)
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleDots(_ chart: ChartSnapshot) {
        var value = chart.settings
        value.dotsVisible.toggle()
        update(value, chart.id)
    }
    func toggleLines(_ chart: ChartSnapshot) {
        var value = chart.settings
        value.linesVisible.toggle()
        update(value, chart.id)
    }
    @discardableResult
    func update(_ settings: AxisSettings, _ chartID: ChartID) -> Bool {
        do {
            try store.updateSettings(settings, chartID: chartID)
            refreshAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    @discardableResult
    func updateUnit(_ unit: String, chart: ChartID) -> Bool {
        guard let snapshot = sessions.values.first(where: { $0.charts.contains(where: { $0.id == chart }) }),
            let item = snapshot.charts.first(where: { $0.id == chart })
        else { return false }
        var settings = item.settings
        settings.unit = unit.isEmpty ? nil : unit
        return update(settings, chart)
    }
    @discardableResult
    func updateScale(_ scale: YScale, chart: ChartID) -> Bool {
        guard let snapshot = sessions.values.first(where: { $0.charts.contains(where: { $0.id == chart }) }),
            let item = snapshot.charts.first(where: { $0.id == chart })
        else { return false }
        var settings = item.settings
        settings.yScale = scale
        return update(settings, chart)
    }
    func addGuide(value: Double, chart: ChartSnapshot, session: SessionSnapshot, label: String? = nil) {
        do {
            try store.upsertGuide(Guide(orientation: .horizontalValue, value: value, label: label), chartID: chart.id)
            refresh(session.id)
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func updateGuide(_ guide: Guide, chartID: ChartID, sessionID: SessionID) -> Bool {
        do {
            try store.upsertGuide(guide, chartID: chartID)
            refresh(sessionID)
            if guide.alert != nil {
                notifications.requestAuthorization { [weak self] message in
                    DispatchQueue.main.async { if let message { self?.errorMessage = message } }
                }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    /// A sheet edits coordinates/text while alert controls save independently.
    /// Merge those fields into the current guide, never its captured sheet value.
    func updateGuideDetails(
        _ id: UUID, value: Double, label: String?, chartID: ChartID, sessionID: SessionID, orientation: GuideOrientation
    ) {
        guard let session = sessions[sessionID] else { return }
        let current =
            orientation == .verticalTime
            ? session.timeGuides.first(where: { $0.id == id })
            : session.charts.first(where: { $0.id == chartID })?.guides.first(where: { $0.id == id })
        guard var guide = current else { return }
        guide.value = value
        guide.label = label
        if orientation == .verticalTime {
            updateTimeGuide(guide, sessionID: sessionID)
        } else {
            updateGuide(guide, chartID: chartID, sessionID: sessionID)
        }
    }
    func removeGuide(_ guide: Guide, chartID: ChartID, sessionID: SessionID) {
        do {
            try store.removeGuide(guide.id, chartID: chartID)
            refresh(sessionID)
        } catch { errorMessage = error.localizedDescription }
    }
    func rename(_ stream: StreamID, to name: String) {
        do {
            try store.renameStream(stream, to: name)
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }
    func move(_ stream: StreamID, to chart: ChartID) {
        do {
            try store.moveStream(stream, to: chart)
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }
    func moveToNewChart(_ stream: StreamID, sessionID: SessionID, after chartID: ChartID?) {
        do {
            _ = try store.moveStreamToNewChart(stream, after: chartID)
            refreshAll()
        } catch {
            errorMessage = error.localizedDescription
            refresh(sessionID)
        }
    }
    func canDropStream(_ items: [String], sessionID: SessionID, destination: StreamDropDestination) -> Bool {
        guard items.count == 1, let id = UUID(uuidString: items[0]),
            let session = try? store.snapshot(sessionID: sessionID),
            !session.isDeleted,
            let source = session.charts.first(where: {
                $0.isVisible && $0.streams.contains(where: { $0.id == id && $0.isLayoutHidden != true })
            })
        else { return false }
        switch destination {
        case .onto(let chartID):
            return chartID != source.id && session.charts.contains(where: { $0.id == chartID && $0.isVisible })
        case .before(let anchor), .after(let anchor):
            return session.charts.contains(where: { $0.id == anchor && $0.isVisible })
        case .unanchored:
            return true
        }
    }

    func dropStream(_ items: [String], sessionID: SessionID, destination: StreamDropDestination) -> Bool {
        guard canDropStream(items, sessionID: sessionID, destination: destination),
            let id = UUID(uuidString: items[0])
        else { return false }
        do {
            switch destination {
            case .onto(let chartID):
                try store.moveStream(id, to: chartID)
            case .before(let anchor):
                _ = try store.moveStreamToNewChart(id, before: anchor)
            case .after(let anchor):
                _ = try store.moveStreamToNewChart(id, after: anchor)
            case .unanchored:
                _ = try store.moveStreamToNewChart(id)
            }
            refreshAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameSession(_ id: SessionID, to title: String) { perform { try store.renameSession(id, to: title) } }
    func renameChart(_ id: ChartID, to title: String) { perform { try store.renameChart(id, to: title) } }
    func reorderChart(_ id: ChartID, to index: Int) { perform { try store.reorderChart(id, to: index) } }
    func deleteChart(_ id: ChartID) { perform { try store.deleteChart(id) } }
    func restoreChart(_ id: ChartID) { perform { try store.restoreChart(id) } }
    func deleteSession(_ id: SessionID) {
        do {
            if let ingestion {
                try ingestion.closeSession(id, delete: true)
            } else {
                try store.deleteSession(sessionID: id)
            }
            refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func restoreSession(_ id: SessionID) {
        do {
            try store.restoreSession(sessionID: id)
            refreshAll()
            requestSessionWindow(id)
        } catch { errorMessage = error.localizedDescription }
    }
    func setStreamLayoutHidden(_ hidden: Bool, streamID: StreamID) {
        perform { try store.setStreamLayoutHidden(hidden, streamID: streamID) }
    }
    func updateStreamStyle(_ id: StreamID, colorHex: String?, dotsVisible: Bool?, linesVisible: Bool?) {
        perform {
            try store.updateStreamStyle(id, colorHex: colorHex, dotsVisible: dotsVisible, linesVisible: linesVisible)
        }
    }
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }
    func samplerGroup(containing stream: StreamID, sessionID: SessionID) -> [StreamID] {
        store.samplerGroup(containing: stream) ?? [stream]
    }
    func reassociate(_ sources: [StreamID], with destinations: [StreamID], sessionID: SessionID) {
        queries.invalidateFits()
        perform { try store.reassociateStreams(sources, to: destinations) }
    }
    func reassociate(_ source: StreamID, with destination: StreamID, sessionID: SessionID) {
        queries.invalidateFits()
        do {
            try store.reassociateStreams([source], to: [destination])
            refresh(sessionID)
        } catch { errorMessage = error.localizedDescription }
    }
    func undo(_ sessionID: SessionID) {
        queries.invalidateFits()
        do {
            _ = try store.undo(sessionID: sessionID)
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }
    func redo(_ sessionID: SessionID) {
        queries.invalidateFits()
        do {
            _ = try store.redo(sessionID: sessionID)
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh(_ id: SessionID) {
        do {
            if let value = try store.snapshot(sessionID: id) {
                if sessionModel(for: id).update(value) {
                    indexStreams(in: value)
                    editRevision &+= 1
                }
                updateCatalogEntry(value)
                updateQueryRetention()
                refreshForecast(value)
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func isDisplayActive(_ id: SessionID) -> Bool { sessionModel(for: id).displayActive }

    func setDisplayActive(_ active: Bool, for id: SessionID) {
        if active {
            guard sessionModel(for: id).setDisplayActive(true) else { return }
            // One current snapshot, never replay samples or alter navigation modes.
            tick(id)
        } else {
            guard sessionModel(for: id).setDisplayActive(false) else { return }
            if let snapshot = sessionModel(for: id).snapshot {
                queries.suspend(
                    streamIDs: Set(snapshot.charts.flatMap(\.streams).map(\.id)),
                    forecastIDs: Set(snapshot.timeline.forecasts.map(\.id)))
            }
        }
    }

    private func isDisplayActive(for stream: StreamID) -> Bool {
        guard let id = streamSessions[stream] else { return true }
        return isDisplayActive(id)
    }
    private func canRequestAnalysis(for stream: StreamID) -> Bool {
        guard let id = streamSessions[stream], let snapshot = sessionModel(for: id).snapshot else { return false }
        return snapshot.isOpen && !snapshot.isDeleted && sessionModel(for: id).displayActive
    }

    func tick(_ id: SessionID, now: Date = Date()) {
        guard isDisplayActive(id) else { return }
        displayRefreshCount &+= 1
        if sessionModel(for: id).snapshot?.timeline.clockStoppedAt == nil {
            sessionModel(for: id).advanceClock(to: now)
        }
        refresh(id)
    }
    func sessionNow(_ session: SessionSnapshot) -> Date {
        session.timeline.clockStoppedAt ?? sessionModel(for: session.id).clockPulse
    }
    private func sessionNow(for streamID: StreamID) -> Date {
        guard let id = streamSessions[streamID], let snapshot = sessionModel(for: id).snapshot else { return Date() }
        return sessionNow(snapshot)
    }
    func refreshAll() {
        do {
            let all = try store.listSessions() + store.listDeletedSessions()
            updateCatalog(all)
            for session in all {
                if sessionModel(for: session.id).update(session) {
                    indexStreams(in: session)
                    editRevision &+= 1
                }
            }
            updateQueryRetention()
            for session in all { refreshForecast(session) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func updateQueryRetention() {
        let active = sessionModels.values.compactMap(\.snapshot).filter { $0.isOpen && !$0.isDeleted }
        queries.retain(
            Set(active.flatMap(\.charts).flatMap(\.streams).map(\.id)),
            forecastIDs: Set(active.flatMap { $0.timeline.forecasts.map(\.id) }))
    }

    private func updateCatalog(_ snapshots: [SessionSnapshot]) {
        let updated = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, SessionListing($0)) })
        if sessionCatalog != updated { sessionCatalog = updated }
    }
    private func updateCatalogEntry(_ snapshot: SessionSnapshot) {
        let listing = SessionListing(snapshot)
        if sessionCatalog[snapshot.id] != listing { sessionCatalog[snapshot.id] = listing }
    }
    private func indexStreams(in snapshot: SessionSnapshot) {
        streamSessions = streamSessions.filter { $0.value != snapshot.id }
        for stream in snapshot.charts.flatMap(\.streams) { streamSessions[stream.id] = snapshot.id }
    }

    func visibleSamples(
        for chart: ChartSnapshot, session: SessionSnapshot, range requestedRange: ClosedRange<Date>? = nil
    ) -> (samples: [StreamID: [StoredSample]], current: Set<StreamID>) {
        guard isDisplayActive(session.id) else { return ([:], []) }
        let range = requestedRange ?? domain(for: session)
        var current: Set<StreamID> = []
        let samples = Dictionary(
            uniqueKeysWithValues: chart.streams.filter { $0.isLayoutHidden != true }.map { stream in
                let key = BackgroundQueries.QueryKey(
                    start: range.lowerBound, end: range.upperBound, count: stream.sampleCount, last: stream.lastSampleAt
                )
                _ = queries.observeDisplay(stream.id)
                let rows = queries.display(stream.id, key: key)
                if queries.isCurrentDisplay(stream.id, key: key) { current.insert(stream.id) }
                return (stream.id, rows)
            })
        return (samples, current)
    }
    func requestVisibleSamples(
        for chart: ChartSnapshot, session: SessionSnapshot, range requestedRange: ClosedRange<Date>? = nil
    ) {
        guard let current = sessionModel(for: session.id).snapshot,
            current.isOpen, !current.isDeleted, isDisplayActive(session.id),
            current.charts.contains(where: { $0 == chart && $0.isVisible })
        else { return }
        let range = requestedRange ?? domain(for: session)
        for stream in chart.streams {
            if stream.isLayoutHidden == true {
                queries.cancelDisplay(stream.id)
                continue
            }
            let key = BackgroundQueries.QueryKey(
                start: range.lowerBound, end: range.upperBound, count: stream.sampleCount, last: stream.lastSampleAt)
            queries.requestDisplay(stream.id, key: key, store: queryStore) { [weak self] in
                self?.errorMessage = $0.localizedDescription
            }
        }
    }
    func displayFailed(_ stream: StreamID) -> Bool {
        if case .failed = queries.observeDisplay(stream) { return true }
        return false
    }
    func retryDisplay(_ stream: StreamID) {
        guard canRequestAnalysis(for: stream) else { return }
        queries.retryDisplay(stream)
    }
    func cancelChartQueries(for chart: ChartSnapshot, sessionID: SessionID) {
        let current = sessionModel(for: sessionID).snapshot?.charts.first { $0.id == chart.id }
        guard current == chart else { return }
        for stream in chart.streams {
            queries.cancelDisplay(stream.id)
            queries.cancelDerived(stream.id)
            queries.cancelNearest(stream.id)
        }
    }
    func suggestedDerivedInterval(_ id: StreamID) async -> Double? {
        await queries.suggestedInterval(id, store: queryStore)
    }
    @discardableResult func setDerivedSeries(_ configuration: DerivedSeriesConfiguration?, streamID: StreamID) -> Bool {
        do {
            try store.setDerivedSeries(configuration, streamID: streamID)
            refreshAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    func derivedSeries(_ stream: StreamDescriptor, range: ClosedRange<Date>, sessionID: SessionID)
        -> DerivedSeriesResult?
    {
        guard isDisplayActive(sessionID), let configuration = stream.derivedSeries else { return nil }
        _ = queries.observeDerived(stream.id)
        return queries.derivedSeries(
            stream.id,
            key: .init(
                query: queryKey(stream.id, range: range), configuration: configuration,
                live: stream.state == .live || stream.state == .quiet))
    }
    func requestDerivedSeries(_ stream: StreamDescriptor, range: ClosedRange<Date>, sessionID: SessionID) {
        guard streamSessions[stream.id] == sessionID, canRequestAnalysis(for: stream.id),
            let currentStream = sessionModel(for: sessionID).snapshot?.charts.flatMap(\.streams).first(where: {
                $0.id == stream.id
            }), currentStream == stream, let configuration = stream.derivedSeries
        else { return }
        queries.requestDerived(
            stream.id,
            key: .init(
                query: queryKey(stream.id, range: range), configuration: configuration,
                live: stream.state == .live || stream.state == .quiet), store: queryStore)
    }
    func derivedFailed(_ stream: StreamID) -> Bool {
        if case .failed = queries.observeDerived(stream) { return true }
        return false
    }
    func retryDerived(_ stream: StreamID) {
        guard canRequestAnalysis(for: stream) else { return }
        queries.retryDerived(stream)
    }
    func cancelDerived(_ stream: StreamID) { queries.cancelDerived(stream) }
    private func queryKey(_ stream: StreamID, range: ClosedRange<Date>) -> BackgroundQueries.QueryKey {
        let descriptor = streamSessions[stream].flatMap { sessionModel(for: $0).snapshot }?
            .charts.flatMap(\.streams).first { $0.id == stream }
        return .init(
            start: range.lowerBound, end: range.upperBound, count: descriptor?.sampleCount ?? 0,
            last: descriptor?.lastSampleAt)
    }
    func domain(for session: SessionSnapshot) -> ClosedRange<Date> {
        let now = sessionNow(session)
        let start = session.timeline.visibleStart ?? defaultStart(session, now: now)
        var end =
            session.timeline.followNow
            ? max(now, session.timeline.visibleEnd ?? now) : (session.timeline.visibleEnd ?? now)
        if session.timeline.followNow,
            let crossing = sessionModel(for: session.id).forecastStatuses.compactMap(\.crossing).max(),
            crossing > now
        {
            end = max(end, crossing.addingTimeInterval(max(15, crossing.timeIntervalSince(now) * 0.05)))
        }
        return start < end ? start...end : now.addingTimeInterval(-60)...now
    }
    func pan(_ deltaX: CGFloat, width: CGFloat, session: SessionSnapshot, from baseRange: ClosedRange<Date>? = nil) {
        let now = sessionNow(session)
        let end = baseRange?.upperBound ?? session.timeline.visibleEnd ?? now
        let start = baseRange?.lowerBound ?? session.timeline.visibleStart ?? defaultStart(session, now: end)
        let span = max(1, end.timeIntervalSince(start))
        let shift = -Double(deltaX / max(width, 1)) * span
        var timeline = session.timeline
        timeline.followNow = false
        timeline.visibleStart = start.addingTimeInterval(shift)
        timeline.visibleEnd = end.addingTimeInterval(shift)
        navigate(timeline, session: session)
    }
    func defaultStart(_ session: SessionSnapshot, now: Date? = nil) -> Date {
        let now = now ?? sessionNow(session)
        let earliest =
            (session.charts.flatMap(\.streams).compactMap(\.firstSampleAt)
            + session.timeGuides.map { Date(timeIntervalSince1970: $0.value) }).min()
        let span = session.timeline.historySpan ?? 15 * 60
        return max(earliest ?? now.addingTimeInterval(-span), now.addingTimeInterval(-span))
    }

    func isCalculatingStats(_ stream: StreamID) -> Bool { queries.isCalculatingStatistics(stream) }
    func stats(for stream: StreamID, in selection: TimeSelection) -> SelectionStatistics? {
        guard isDisplayActive(for: stream) else { return nil }
        let range = selection.resolvedBounds(at: sessionNow(for: stream))
        _ = queries.observeStatistics(stream)
        return queries.stats(stream, key: queryKey(stream, range: range))
    }
    func requestStats(for stream: StreamID, in selection: TimeSelection) {
        guard canRequestAnalysis(for: stream) else { return }
        let range = selection.resolvedBounds(at: sessionNow(for: stream))
        queries.requestStats(stream, key: queryKey(stream, range: range), store: queryStore) { [weak self] in
            self?.errorMessage = $0.localizedDescription
        }
    }
    func statisticsFailed(_ stream: StreamID) -> Bool {
        if case .failed = queries.observeStatistics(stream) { return true }
        return false
    }
    func retryStats(_ stream: StreamID) {
        guard canRequestAnalysis(for: stream) else { return }
        queries.retryStatistics(stream)
    }
    func cancelStats(_ stream: StreamID) { queries.cancelStatistics(stream) }
    func setTimeZone(_ zone: PlotTimeZone, session: SessionSnapshot) {
        do {
            try store.setTimeZone(zone, sessionID: session.id)
            refresh(session.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func setTimeReference(_ guide: UUID?, session: SessionSnapshot) {
        do {
            try store.setTimeReference(guide, sessionID: session.id)
            refresh(session.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func resolvedSelectionBounds(_ selection: TimeSelection, session: SessionSnapshot) -> ClosedRange<Date> {
        selection.resolvedBounds(at: sessionNow(session))
    }
    func nearestSample(_ stream: StreamID, at date: Date) -> StoredSample? {
        guard isDisplayActive(for: stream) else { return nil }
        _ = queries.observeNearest(stream)
        return queries.nearestSample(stream, key: queryKey(stream, range: date...date))
    }
    func requestNearestSample(_ stream: StreamID, at date: Date) {
        guard canRequestAnalysis(for: stream) else { return }
        queries.requestNearest(stream, key: queryKey(stream, range: date...date), store: queryStore)
    }
    func nearestFailed(_ stream: StreamID) -> Bool {
        if case .failed = queries.observeNearest(stream) { return true }
        return false
    }
    func retryNearest(_ stream: StreamID) {
        guard canRequestAnalysis(for: stream) else { return }
        queries.retryNearest(stream)
    }
    func cancelNearest(_ stream: StreamID) { queries.cancelNearest(stream) }
    func fit(for stream: StreamID, selection: TimeSelection, cacheID: UUID? = nil) -> LinearFit? {
        guard isDisplayActive(for: stream) else { return nil }
        let range = selection.resolvedBounds(at: sessionNow(for: stream))
        return queries.fit(cacheID ?? stream, stream: stream, key: queryKey(stream, range: range), settings: selection)
    }
    func requestFit(for stream: StreamID, selection: TimeSelection, cacheID: UUID? = nil) {
        guard canRequestAnalysis(for: stream) else { return }
        let range = selection.resolvedBounds(at: sessionNow(for: stream))
        queries.requestFit(
            stream, cacheID: cacheID ?? stream, key: queryKey(stream, range: range), settings: selection,
            store: queryStore,
            completed: { [weak self] in
                guard let self else { return }
                // Read current configurations, never the configuration that launched a
                // query: Undo/removal while work is running cannot resurrect an overlay.
                if let id = self.streamSessions[stream], let session = self.sessionModel(for: id).snapshot {
                    self.refreshForecast(session)
                }
            }, failed: { [weak self] in self?.errorMessage = $0.localizedDescription })
    }
    func fitFailed(_ id: UUID) -> Bool {
        if case .failed = queries.fitState(id) { return true }
        return false
    }
    func retryFit(_ configuration: ForecastConfiguration) {
        guard canRequestAnalysis(for: configuration.streamID) else { return }
        queries.retryFit(configuration.id)
    }
    func followNow(_ session: SessionSnapshot) {
        var timeline = session.timeline
        timeline.followNow = true
        timeline.visibleEnd = nil
        timeline.visibleStart = nil
        timeline.historySpan = nil
        navigate(timeline, session: session)
    }
    func setSpan(_ seconds: TimeInterval, session: SessionSnapshot) {
        var timeline = session.timeline
        timeline.followNow = true
        timeline.visibleEnd = nil
        timeline.visibleStart = nil
        timeline.historySpan = seconds
        navigate(timeline, session: session)
    }
    func showAllHistory(_ session: SessionSnapshot) {
        var starts = session.timeGuides.map { Date(timeIntervalSince1970: $0.value) }
        for chart in session.charts {
            for stream in chart.streams { if let first = stream.firstSampleAt { starts.append(first) } }
        }
        let now = sessionNow(session)
        var timeline = session.timeline
        timeline.followNow = false
        timeline.visibleStart = starts.min() ?? now.addingTimeInterval(-15 * 60)
        timeline.visibleEnd = now
        timeline.historySpan = nil
        navigate(timeline, session: session)
    }
    func setSelection(_ selection: TimeSelection?, session: SessionSnapshot) {
        do {
            try store.setSelection(selection, sessionID: session.id)
            refresh(session.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func toggleSelectionBoundary(_ edge: PlotSelectionEdge, session: SessionSnapshot) {
        guard var selection = session.timeline.selection else { return }
        let bounds = resolvedSelectionBounds(selection, session: session)
        let duration = max(0.5, bounds.upperBound.timeIntervalSince(bounds.lowerBound))
        switch (edge, selection.mode) {
        case (.start, .fixed): selection.mode = .startFollowsEnd(duration: duration)
        case (.start, .startFollowsEnd): selection.mode = .fixed
        case (.start, .endFollowsNow): selection.mode = .bothFollowNow(duration: duration)
        case (.start, .bothFollowNow): selection.mode = .endFollowsNow
        case (.end, .fixed): selection.mode = .endFollowsNow
        case (.end, .endFollowsNow): selection.mode = .fixed
        case (.end, .startFollowsEnd): selection.mode = .bothFollowNow(duration: duration)
        case (.end, .bothFollowNow): selection.mode = .startFollowsEnd(duration: duration)
        }
        selection.start = bounds.lowerBound
        selection.end = bounds.upperBound
        setSelection(selection, session: session)
    }

    func setForecast(_ forecast: ForecastConfiguration?, session: SessionSnapshot) {
        do {
            var configurations = session.timeline.forecasts
            if let forecast {
                configurations.removeAll { $0.streamID == forecast.streamID && $0.guideID == forecast.guideID }
                configurations.append(forecast)
            } else {
                configurations = []
            }
            try store.setForecasts(configurations, sessionID: session.id)
            refresh(session.id)
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func createForecastTarget(value: Double, label: String?, streamID: StreamID, selection: TimeSelection) -> Bool {
        do {
            try store.createForecastTarget(value: value, label: label, streamID: streamID, selection: selection)
            refreshAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeForecast(_ id: UUID, session: SessionSnapshot) {
        let configurations = session.timeline.forecasts.filter {
            $0.id != id
        }
        perform { try store.setForecasts(configurations, sessionID: session.id) }
    }
    func refreshForecast(_ session: SessionSnapshot) {
        let presentation = sessionModel(for: session.id)
        guard session.isOpen, !session.isDeleted else {
            presentation.setForecastStatuses([])
            return
        }
        guard isDisplayActive(session.id) else { return }
        let configurations =
            session.isDeleted ? [] : session.timeline.forecasts
        let statuses = configurations.map { configuration -> ForecastStatus in
            guard
                let chart = session.charts.first(where: {
                    $0.streams.contains(where: { $0.id == configuration.streamID })
                }),
                let guide = chart.guides.first(where: {
                    $0.id == configuration.guideID && $0.orientation == .horizontalValue
                })
            else {
                return ForecastStatus(
                    configuration: configuration, fit: nil, guide: nil, crossing: nil,
                    message: "Target guide is missing")
            }
            let count = chart.streams.first(where: { $0.id == configuration.streamID })?.sampleCount ?? 0
            let range = configuration.selection.resolvedBounds(at: sessionNow(session))
            requestFit(for: configuration.streamID, selection: configuration.selection, cacheID: configuration.id)
            let fitted = fit(for: configuration.streamID, selection: configuration.selection, cacheID: configuration.id)
            let crossing = fitted?.crossing(value: guide.value)
            let now = sessionNow(session)
            let message: String
            if let fitted, let crossing {
                let slope = fitted.slope.formatted(.number.precision(.significantDigits(3)))
                let detail =
                    "n \(fitted.count) · \(Int(range.upperBound.timeIntervalSince(range.lowerBound)))s training · slope \(slope)/s"
                let remaining = crossing.timeIntervalSince(now)
                let countdown =
                    remaining < 60
                    ? String(format: "%.0f s", remaining)
                    : (remaining < 3600
                        ? String(format: "%.1f min", remaining / 60)
                        : (remaining < 86400
                            ? String(format: "%.1f h", remaining / 3600)
                            : String(format: "%.1f days", remaining / 86400)))
                message =
                    crossing > now
                    ? "Crossing \(TimeText.format(crossing, zone: session.timeline.timeZone, includeDate: true)) · in \(countdown) · \(detail)"
                    : "No future crossing · \(detail)"
            } else {
                message =
                    fitted == nil
                    ? (fitFailed(configuration.id)
                        ? "Could not calculate forecast"
                        : (queries.isFitting(configuration.id) ? "Calculating…" : "Not enough distinct sample times"))
                    : "No finite crossing predicted"
            }
            return ForecastStatus(
                configuration: configuration, fit: fitted, guide: guide, crossing: crossing, message: message,
                fitSampleCount: count, fitRange: range)
        }
        presentation.setForecastStatuses(statuses)
    }
    func forecastTrainingRanges(for chart: ChartSnapshot, session: SessionSnapshot) -> [ForecastTrainingRange] {
        let configurations = session.timeline.forecasts
        return configurations.compactMap { configuration in
            guard let stream = chart.streams.first(where: { $0.id == configuration.streamID }) else { return nil }
            let guide = chart.guides.first { $0.id == configuration.guideID }
            let target =
                guide?.label.flatMap { $0.isEmpty ? nil : $0 }
                ?? guide.map {
                    NumericText.format(
                        $0.value, scale: chart.settings.numericScale, unit: chart.settings.unit)
                }
                ?? "missing target"
            return ForecastTrainingRange(
                id: configuration.id, streamID: stream.id,
                label: "\(stream.name) → \(target) · training",
                range: configuration.selection.resolvedBounds(at: sessionNow(session)),
                linked: configuration.selection.mode != .fixed)
        }
    }
    func forecastDrawings(for chart: ChartSnapshot, session: SessionSnapshot) -> [ForecastDrawing] {
        sessionModel(for: session.id).forecastStatuses.compactMap { status in
            guard chart.streams.contains(where: { $0.id == status.configuration.streamID }),
                let fit = status.fit, let crossing = status.crossing, crossing > sessionNow(session),
                let guide = status.guide
            else { return nil }
            return ForecastDrawing(
                streamID: status.configuration.streamID, fit: fit,
                range: status.configuration.selection.resolvedBounds(at: sessionNow(session)), crossing: crossing,
                value: guide.value)
        }
    }
    func forecastDrawing(for chart: ChartSnapshot, session: SessionSnapshot) -> ForecastDrawing? {
        forecastDrawings(for: chart, session: session).first
    }
    private func saveTimeline(_ timeline: TimelineState, _ id: SessionID) {
        do {
            // Navigation restores only viewport fields, using current persisted preferences.
            guard var current = try store.snapshot(sessionID: id)?.timeline else { return }
            current.visibleStart = timeline.visibleStart
            current.visibleEnd = timeline.visibleEnd
            current.followNow = timeline.followNow
            current.historySpan = timeline.historySpan
            try store.updateTimeline(current, sessionID: id)
            refresh(id)
        } catch { errorMessage = error.localizedDescription }
    }
    func navigate(_ timeline: TimelineState, session: SessionSnapshot) {
        sessionModel(for: session.id).navigate(from: session.timeline)
        saveTimeline(timeline, session.id)
    }
    func navigateBack(_ session: SessionSnapshot) {
        guard let previous = sessionModel(for: session.id).back(from: session.timeline) else { return }
        saveTimeline(previous, session.id)
    }
    func navigateForward(_ session: SessionSnapshot) {
        guard let next = sessionModel(for: session.id).forward(from: session.timeline) else { return }
        saveTimeline(next, session.id)
    }
    func canNavigateBack(_ sessionID: SessionID) -> Bool { sessionModel(for: sessionID).canNavigateBack }
    func canNavigateForward(_ sessionID: SessionID) -> Bool { sessionModel(for: sessionID).canNavigateForward }
    func zoom(_ factor: Double, anchor: Date, session: SessionSnapshot, from baseRange: ClosedRange<Date>? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let now = sessionNow(session)
        let domainEnd = baseRange?.upperBound ?? session.timeline.visibleEnd ?? now
        let domainStart =
            baseRange?.lowerBound ?? session.timeline.visibleStart ?? defaultStart(session, now: domainEnd)
        let oldSpan = max(1, domainEnd.timeIntervalSince(domainStart))
        let newSpan = min(7 * 24 * 3600, max(5, oldSpan / factor))
        let anchorFraction = min(1, max(0, anchor.timeIntervalSince(domainStart) / oldSpan))
        var timeline = session.timeline
        timeline.followNow = false
        timeline.visibleStart = anchor.addingTimeInterval(-newSpan * anchorFraction)
        timeline.visibleEnd = anchor.addingTimeInterval(newSpan * (1 - anchorFraction))
        navigate(timeline, session: session)
    }
    func clearError() { errorMessage = nil }

    func openSession(_ id: SessionID) {
        do {
            try store.setSessionOpen(true, sessionID: id)
            openedSessionIDs.insert(id)
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }
    func windowClosed(_ id: SessionID) {
        guard !terminating else { return }
        _ = sessionModel(for: id).setDisplayActive(true)
        openedSessionIDs.remove(id)
        pendingWindowIDs.remove(id)
        do {
            if let ingestion {
                try ingestion.closeSession(id)
            } else {
                try store.setSessionOpen(false, sessionID: id)
            }
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }
    func applicationWillTerminate() {
        terminating = true
        ingestion?.stop()
    }
    func prepareForTermination() {
        do { try store.recordTerminationOpenSessions(openedSessionIDs) } catch {
            errorMessage = error.localizedDescription
        }
        terminating = true
        ingestion?.stop()
    }

}

struct ForecastStatus: Equatable {
    let configuration: ForecastConfiguration
    let fit: LinearFit?
    let guide: Guide?
    let crossing: Date?
    let message: String
    let fitSampleCount: Int64
    let fitRange: ClosedRange<Date>?
    init(
        configuration: ForecastConfiguration, fit: LinearFit?, guide: Guide?, crossing: Date?, message: String,
        fitSampleCount: Int64 = 0, fitRange: ClosedRange<Date>? = nil
    ) {
        self.configuration = configuration
        self.fit = fit
        self.guide = guide
        self.crossing = crossing
        self.message = message
        self.fitSampleCount = fitSampleCount
        self.fitRange = fitRange
    }
}

struct ForecastTrainingRange: Identifiable {
    let id: UUID
    let streamID: StreamID
    let label: String
    let range: ClosedRange<Date>
    let linked: Bool
}

struct ForecastDrawing {
    let streamID: StreamID
    let fit: LinearFit
    let range: ClosedRange<Date>
    let crossing: Date
    let value: Double
}

extension Notification.Name {
    static let pipePlotWillTerminate = Notification.Name("PipePlotWillTerminate")
}
