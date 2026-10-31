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
    private let crossings = GuideCrossingDetector()
    private let notifications: GuideNotifications
    private var server: UnixSocketServer?
    private let connectionRegistry = ConnectionRegistry()
    private let appInstanceID = UUID()
    private var openWindowAction: ((SessionID) -> Void)?
    private var openSessionPickerAction: (() -> Void)?
    private var didBootstrap = false
    private var serverStarted = false
    private(set) var sessions: [SessionID: SessionSnapshot] = [:]
    private(set) var errorMessage: String?
    private(set) var editRevision = 0
    private(set) var activeSessionID: SessionID?
    private(set) var selectedChartIDs: [SessionID: ChartID] = [:]
    private(set) var forecastStatuses: [SessionID: ForecastStatus] = [:]
    private(set) var allForecastStatuses: [SessionID: [ForecastStatus]] = [:]
    private(set) var openedSessionIDs: Set<SessionID> = []
    private(set) var clockPulse = Date()
    private var terminating = false
    private var navigationBack: [SessionID: [TimelineState]] = [:]
    private var navigationForward: [SessionID: [TimelineState]] = [:]
    // Unknown state allows model-only clients; attached windows immediately report
    // their actual state. Suspension never changes capture or persistent session state.
    private var suspendedDisplays: Set<SessionID> = []
    @ObservationIgnored private(set) var displayRefreshCount = 0
    let queries = BackgroundQueries()
    let refreshTimer = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    init(databaseURL: URL? = nil) {
        notifications = GuideNotifications(enabled: databaseURL == nil)
        do {
            let database = databaseURL ?? PipePlotLocations.supportDirectory.appendingPathComponent("pipeplot.sqlite")
            store = try PipePlotStore(databaseURL: database)
            queryStore = try SampleStore(readOnlyDatabaseURL: database)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "PipePlot could not open its saved data"
            alert.informativeText = "\(error.localizedDescription)\nYour saved files have not been replaced. Check available disk space and access to Application Support/PipePlot, then reopen the app."
            alert.runModal()
            exit(EXIT_FAILURE)
        }
        let listener = UnixSocketServer { [weak self] connection in self?.handle(connection) }
        server = listener
        refreshAll()
    }

    func installOpenWindow(_ action: @escaping (SessionID) -> Void) { openWindowAction = action }
    func installOpenSessionPicker(_ action: @escaping () -> Void) { openSessionPickerAction = action }
    func presentSessionPicker() { openSessionPickerAction?() }
    func becameActive(_ id: SessionID) { activeSessionID = id; openedSessionIDs.insert(id); refresh(id) }

    /// Returns the session to show in the initial WindowGroup. CLI launches deliberately start fresh.
    func bootstrap() -> SessionID? {
        guard !didBootstrap else { return nil }
        didBootstrap = true
        do {
            let all = try store.listSessions()
            for session in all { sessions[session.id] = session }
            let cliLaunch = ProcessInfo.processInfo.arguments.contains("--pipeplot-launched-by-cli")
            if cliLaunch {
                // Registration atomically creates the requested destination. Listing and
                // explicit-session lookup must not create an empty bootstrap session.
                startServer()
                return nil
            }
            let prior = store.previouslyOpenSessionIDs
            if !prior.isEmpty {
                for id in prior { try store.setSessionOpen(true, sessionID: id); refresh(id) }
                let ids = prior.compactMap { id in sessions[id]?.number == nil ? nil : id }.sorted { (sessions[$0]?.number ?? 0) < (sessions[$1]?.number ?? 0) }
                for id in ids.dropFirst() { openWindowAction?(id) }
                startServer()
                return ids.first
            }
            if !all.isEmpty { startServer(); return nil }
            let created = try store.createSession()
            refresh(created.id)
            startServer()
            return created.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    private func startServer() {
        guard !serverStarted else { return }
        do { try server?.start(); serverStarted = true }
        catch { errorMessage = error.localizedDescription }
    }

    func createSessionWindow() {
        do { let session = try store.createSession(); refreshAll(); openWindowAction?(session.id) }
        catch { errorMessage = error.localizedDescription }
    }

    func createChart(in sessionID: SessionID, after chartID: ChartID?) {
        do { let chart = try store.createChart(in: sessionID, after: chartID); selectedChartIDs[sessionID] = chart.id; refreshAll() }
        catch { errorMessage = error.localizedDescription }
    }

    func selectChart(_ chartID: ChartID, sessionID: SessionID) { selectedChartIDs[sessionID] = chartID }

    func addTimeGuide(at date: Date, sessionID: SessionID) {
        updateTimeGuide(Guide(orientation: .verticalTime, value: date.timeIntervalSince1970), sessionID: sessionID)
    }

    func updateTimeGuide(_ guide: Guide, sessionID: SessionID) {
        do { try store.upsertTimeGuide(guide, sessionID: sessionID); refresh(sessionID) }
        catch { errorMessage = error.localizedDescription }
    }
    func removeTimeGuide(_ guide: Guide, sessionID: SessionID) {
        do { try store.removeTimeGuide(guide.id, sessionID: sessionID); refresh(sessionID) }
        catch { errorMessage = error.localizedDescription }
    }

    func setTarget(_ chartID: ChartID) {
        do { _ = try store.setTarget(chartID); refreshAll() }
        catch { errorMessage = error.localizedDescription }
    }

    func toggleDots(_ chart: ChartSnapshot) { var value = chart.settings; value.dotsVisible.toggle(); update(value, chart.id) }
    func toggleLines(_ chart: ChartSnapshot) { var value = chart.settings; value.linesVisible.toggle(); update(value, chart.id) }
    func update(_ settings: AxisSettings, _ chartID: ChartID) {
        do { try store.updateSettings(settings, chartID: chartID); refreshAll() }
        catch { errorMessage = error.localizedDescription }
    }
    func updateUnit(_ unit: String, chart: ChartID) {
        guard let snapshot = sessions.values.first(where: { $0.charts.contains(where: { $0.id == chart }) }), let item = snapshot.charts.first(where: { $0.id == chart }) else { return }
        var settings = item.settings; settings.unit = unit.isEmpty ? nil : unit; update(settings, chart)
    }
    func updateScale(min: Double, max: Double, chart: ChartID) {
        guard let snapshot = sessions.values.first(where: { $0.charts.contains(where: { $0.id == chart }) }), let item = snapshot.charts.first(where: { $0.id == chart }) else { return }
        var settings = item.settings; settings.yScale = min < max ? .fixed(min: min, max: max) : .automatic; update(settings, chart)
    }
    func addGuide(value: Double, chart: ChartSnapshot, session: SessionSnapshot, label: String? = nil) {
        do { try store.upsertGuide(Guide(orientation: .horizontalValue, value: value, label: label), chartID: chart.id); refresh(session.id) }
        catch { errorMessage = error.localizedDescription }
    }
    func updateGuide(_ guide: Guide, chartID: ChartID, sessionID: SessionID) {
        do {
            try store.upsertGuide(guide, chartID: chartID); refresh(sessionID)
            if guide.alert != nil { notifications.requestAuthorization { [weak self] message in
                DispatchQueue.main.async { if let message { self?.errorMessage = message } }
            } }
        }
        catch { errorMessage = error.localizedDescription }
    }
    func removeGuide(_ guide: Guide, chartID: ChartID, sessionID: SessionID) {
        do { try store.removeGuide(guide.id, chartID: chartID); refresh(sessionID) }
        catch { errorMessage = error.localizedDescription }
    }
    func rename(_ stream: StreamID, to name: String) {
        do { try store.renameStream(stream, to: name); refreshAll() }
        catch { errorMessage = error.localizedDescription }
    }
    func move(_ stream: StreamID, to chart: ChartID) {
        do { try store.moveStream(stream, to: chart); refreshAll() }
        catch { errorMessage = error.localizedDescription }
    }
    func moveToNewChart(_ stream: StreamID, sessionID: SessionID, after chartID: ChartID?) {
        do {
            _ = try store.moveStreamToNewChart(stream, after: chartID)
            refreshAll()
        } catch { errorMessage = error.localizedDescription; refresh(sessionID) }
    }
    func dropStream(_ items: [String], sessionID: SessionID, onto destination: ChartID? = nil, before: ChartID? = nil, after: ChartID? = nil) -> Bool {
        guard items.count == 1, let id = UUID(uuidString: items[0]),
              let session = try? store.snapshot(sessionID: sessionID),
              let source = session.charts.first(where: { $0.streams.contains(where: { $0.id == id }) }) else { return false }
        do {
            if let destination {
                guard destination != source.id, session.charts.contains(where: { $0.id == destination && $0.isVisible }) else { return false }
                try store.moveStream(id, to: destination)
            } else {
                _ = try store.moveStreamToNewChart(id, after: after, before: before)
            }
            refreshAll()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func renameSession(_ id: SessionID, to title: String) { perform { try store.renameSession(id, to: title) } }
    func renameChart(_ id: ChartID, to title: String) { perform { try store.renameChart(id, to: title) } }
    func reorderChart(_ id: ChartID, to index: Int) { perform { try store.reorderChart(id, to: index) } }
    func deleteChart(_ id: ChartID) { perform { try store.deleteChart(id) } }
    func restoreChart(_ id: ChartID) { perform { try store.restoreChart(id) } }
    func deleteSession(_ id: SessionID) {
        do {
            try store.deleteSession(sessionID: id)
            connectionRegistry.closeConnections(for: id)
            refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }
    func restoreSession(_ id: SessionID) {
        do {
            try store.restoreSession(sessionID: id); refreshAll()
            if !openedSessionIDs.contains(id) { openWindowAction?(id) }
        } catch { errorMessage = error.localizedDescription }
    }
    func setStreamLayoutHidden(_ hidden: Bool, streamID: StreamID) {
        perform { try store.setStreamLayoutHidden(hidden, streamID: streamID) }
    }
    func updateStreamStyle(_ id: StreamID, colorHex: String?, dotsVisible: Bool?, linesVisible: Bool?) {
        perform { try store.updateStreamStyle(id, colorHex: colorHex, dotsVisible: dotsVisible, linesVisible: linesVisible) }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); refreshAll() } catch { errorMessage = error.localizedDescription }
    }
    func samplerGroup(containing stream: StreamID, sessionID: SessionID) -> [StreamID] { store.samplerGroup(containing: stream) ?? [stream] }
    func reassociate(_ sources: [StreamID], with destinations: [StreamID], sessionID: SessionID) {
        perform { try store.reassociateStreams(sources, to: destinations) }
    }
    func reassociate(_ source: StreamID, with destination: StreamID, sessionID: SessionID) {
        do { try store.reassociateStreams([source], to: [destination]); refresh(sessionID) }
        catch { errorMessage = error.localizedDescription }
    }
    func undo(_ sessionID: SessionID) { do { _ = try store.undo(sessionID: sessionID); refreshAll() } catch { errorMessage = error.localizedDescription } }
    func redo(_ sessionID: SessionID) { do { _ = try store.redo(sessionID: sessionID); refreshAll() } catch { errorMessage = error.localizedDescription } }

    func refresh(_ id: SessionID) {
        do {
            if let value = try store.snapshot(sessionID: id) {
                if sessions[id] != value { sessions[id] = value; editRevision &+= 1 }
                refreshForecast(value)
            }
        }
        catch { errorMessage = error.localizedDescription }
    }
    func isDisplayActive(_ id: SessionID) -> Bool { !suspendedDisplays.contains(id) }

    func setDisplayActive(_ active: Bool, for id: SessionID) {
        if active {
            guard suspendedDisplays.remove(id) != nil else { return }
            // One current snapshot, never replay samples or alter navigation modes.
            tick(id)
        } else {
            suspendedDisplays.insert(id)
        }
    }

    private func isDisplayActive(for stream: StreamID) -> Bool {
        guard let session = sessions.values.first(where: { $0.charts.contains(where: { $0.streams.contains(where: { $0.id == stream }) }) }) else { return true }
        return isDisplayActive(session.id)
    }

    func tick(_ id: SessionID) {
        guard isDisplayActive(id) else { return }
        displayRefreshCount &+= 1
        if sessions[id]?.timeline.clockStoppedAt == nil { clockPulse = Date() }
        refresh(id)
    }
    func sessionNow(_ session: SessionSnapshot) -> Date { session.timeline.clockStoppedAt ?? clockPulse }
    private func sessionNow(for streamID: StreamID) -> Date {
        sessions.values.first(where: { $0.charts.contains(where: { $0.streams.contains(where: { $0.id == streamID }) }) }).map(sessionNow) ?? clockPulse
    }
    func refreshAll() {
        do {
            let all = try store.listSessions() + store.listDeletedSessions()
            let updated = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            if sessions != updated { sessions = updated; editRevision &+= 1 }
            for session in all { refreshForecast(session) }
            queries.retain(Set(all.filter { $0.isOpen && !$0.isDeleted }.flatMap(\.charts).flatMap(\.streams).map(\.id)))
        } catch { errorMessage = error.localizedDescription }
    }

    func visibleSamples(for chart: ChartSnapshot, session: SessionSnapshot, range requestedRange: ClosedRange<Date>? = nil) -> (samples: [StreamID: [StoredSample]], current: Set<StreamID>) {
        guard isDisplayActive(session.id) else { return ([:], []) }
        let range = requestedRange ?? domain(for: session)
        var current: Set<StreamID> = []
        let samples = Dictionary(uniqueKeysWithValues: chart.streams.filter { $0.isLayoutHidden != true }.map { stream in
            let key = BackgroundQueries.QueryKey(start: range.lowerBound, end: range.upperBound, count: stream.sampleCount, last: stream.lastSampleAt)
            let rows = queries.display(stream.id, key: key, store: queryStore) { [weak self] in self?.errorMessage = $0.localizedDescription }
            if queries.isCurrentDisplay(stream.id, key: key) { current.insert(stream.id) }
            return (stream.id, rows)
        })
        return (samples, current)
    }
    private func queryKey(_ stream: StreamID, range: ClosedRange<Date>) -> BackgroundQueries.QueryKey {
        let descriptor = sessions.values.lazy.flatMap(\.charts).flatMap(\.streams).first { $0.id == stream }
        return .init(start: range.lowerBound, end: range.upperBound, count: descriptor?.sampleCount ?? 0, last: descriptor?.lastSampleAt)
    }
    func domain(for session: SessionSnapshot) -> ClosedRange<Date> {
        let now = sessionNow(session)
        let start = session.timeline.visibleStart ?? defaultStart(session, now: now)
        var end = session.timeline.followNow ? max(now, session.timeline.visibleEnd ?? now) : (session.timeline.visibleEnd ?? now)
        if session.timeline.followNow, let crossing = allForecastStatuses[session.id]?.compactMap(\.crossing).max(), crossing > now {
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
        let earliest = (session.charts.flatMap(\.streams).compactMap(\.firstSampleAt) + session.timeGuides.map { Date(timeIntervalSince1970: $0.value) }).min()
        let span = session.timeline.historySpan ?? 15 * 60
        return max(earliest ?? now.addingTimeInterval(-span), now.addingTimeInterval(-span))
    }

    func isCalculatingStats(_ stream: StreamID) -> Bool { queries.isCalculatingStatistics(stream) }
    func stats(for stream: StreamID, in selection: TimeSelection) -> SelectionStatistics? {
        guard isDisplayActive(for: stream) else { return nil }
        let range = resolvedRange(selection, now: sessionNow(for: stream))
        return queries.stats(stream, key: queryKey(stream, range: range), store: queryStore) { [weak self] in self?.errorMessage = $0.localizedDescription }
    }
    func setTimeZone(_ zone: PlotTimeZone, session: SessionSnapshot) {
        do { try store.setTimeZone(zone, sessionID: session.id); refresh(session.id) }
        catch { errorMessage = error.localizedDescription }
    }
    func setTimeReference(_ guide: UUID?, session: SessionSnapshot) {
        do { try store.setTimeReference(guide, sessionID: session.id); refresh(session.id) }
        catch { errorMessage = error.localizedDescription }
    }
    func resolvedSelectionBounds(_ selection: TimeSelection, session: SessionSnapshot) -> ClosedRange<Date> {
        switch selection.mode {
        case .fixed:
            return min(selection.start, selection.end)...max(selection.start, selection.end)
        case .startFollowsEnd(let duration):
            return selection.end.addingTimeInterval(-duration)...selection.end
        case .endFollowsNow:
            let now = sessionNow(session)
            return min(selection.start, now)...max(selection.start, now)
        case .bothFollowNow(let duration):
            let now = sessionNow(session)
            return now.addingTimeInterval(-duration)...now
        }
    }
    func nearestSample(_ stream: StreamID, at date: Date) -> StoredSample? {
        guard isDisplayActive(for: stream) else { return nil }
        return queries.nearestSample(stream, key: queryKey(stream, range: date...date), store: queryStore)
    }
    func fit(for stream: StreamID, selection: TimeSelection, cacheID: UUID? = nil) -> LinearFit? {
        guard isDisplayActive(for: stream) else { return nil }
        let range = resolvedRange(selection, now: sessionNow(for: stream))
        return queries.fit(stream, cacheID: cacheID ?? stream, key: queryKey(stream, range: range), store: queryStore, completed: { [weak self] in
            guard let self else { return }
            // Read current configurations, never the configuration that launched a
            // query: Undo/removal while work is running cannot resurrect an overlay.
            for session in self.sessions.values { self.refreshForecast(session) }
        }, failed: { [weak self] in self?.errorMessage = $0.localizedDescription })
    }
    private func resolvedRange(_ selection: TimeSelection, now: Date? = nil) -> ClosedRange<Date> {
        let now = now ?? clockPulse
        switch selection.mode {
        case .fixed: return min(selection.start, selection.end)...max(selection.start, selection.end)
        case .startFollowsEnd(let duration): return selection.end.addingTimeInterval(-duration)...selection.end
        case .endFollowsNow: return min(selection.start, now)...max(selection.start, now)
        case .bothFollowNow(let duration): return now.addingTimeInterval(-duration)...now
        }
    }

    func followNow(_ session: SessionSnapshot) {
        var timeline = session.timeline; timeline.followNow = true; timeline.visibleEnd = nil; timeline.visibleStart = nil; timeline.historySpan = nil
        navigate(timeline, session: session)
    }
    func setSpan(_ seconds: TimeInterval, session: SessionSnapshot) {
        var timeline = session.timeline; timeline.followNow = true; timeline.visibleEnd = nil; timeline.visibleStart = nil; timeline.historySpan = seconds
        navigate(timeline, session: session)
    }
    func showAllHistory(_ session: SessionSnapshot) {
        var starts = session.timeGuides.map { Date(timeIntervalSince1970: $0.value) }
        for chart in session.charts { for stream in chart.streams { if let first = stream.firstSampleAt { starts.append(first) } } }
        let now = sessionNow(session)
        var timeline = session.timeline; timeline.followNow = false; timeline.visibleStart = starts.min() ?? now.addingTimeInterval(-15 * 60); timeline.visibleEnd = now; timeline.historySpan = nil
        navigate(timeline, session: session)
    }
    func setSelection(_ selection: TimeSelection?, session: SessionSnapshot) {
        do { try store.setSelection(selection, sessionID: session.id); refresh(session.id) }
        catch { errorMessage = error.localizedDescription }
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
        selection.start = bounds.lowerBound; selection.end = bounds.upperBound
        setSelection(selection, session: session)
    }

    func setForecast(_ forecast: ForecastConfiguration?, session: SessionSnapshot) {
        do {
            var configurations = session.timeline.forecasts ?? session.timeline.forecast.map { [$0] } ?? []
            if let forecast {
                configurations.removeAll { $0.streamID == forecast.streamID && $0.guideID == forecast.guideID }
                configurations.append(forecast)
            } else { configurations = [] }
            try store.setForecasts(configurations, sessionID: session.id)
            refresh(session.id)
        }
        catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func createForecastTarget(value: Double, label: String?, streamID: StreamID, selection: TimeSelection) -> Bool {
        do {
            try store.createForecastTarget(value: value, label: label, streamID: streamID, selection: selection)
            refreshAll()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func removeForecast(_ id: UUID, session: SessionSnapshot) {
        let configurations = (session.timeline.forecasts ?? session.timeline.forecast.map { [$0] } ?? []).filter { $0.id != id }
        perform { try store.setForecasts(configurations, sessionID: session.id) }
    }
    func refreshForecast(_ session: SessionSnapshot) {
        guard isDisplayActive(session.id) else { return }
        let configurations = session.isDeleted ? [] : (session.timeline.forecasts ?? session.timeline.forecast.map { [$0] } ?? [])
        let previous = allForecastStatuses[session.id] ?? []
        let statuses = configurations.map { configuration -> ForecastStatus in
            guard let chart = session.charts.first(where: { $0.streams.contains(where: { $0.id == configuration.streamID }) }),
                  let guide = chart.guides.first(where: { $0.id == configuration.guideID && $0.orientation == .horizontalValue }) else {
                return ForecastStatus(configuration: configuration, fit: nil, guide: nil, crossing: nil, message: "Target guide is missing")
            }
            let old = previous.first { $0.configuration.id == configuration.id }
            let count = chart.streams.first(where: { $0.id == configuration.streamID })?.sampleCount ?? 0
            let range = resolvedRange(configuration.selection, now: sessionNow(session))
            let fitted: LinearFit?
            if old?.configuration.selection == configuration.selection,
               (configuration.selection.mode == .fixed || (old?.fitSampleCount == count && old?.fitRange == range)), let existing = old?.fit {
                fitted = existing
            } else { fitted = fit(for: configuration.streamID, selection: configuration.selection, cacheID: configuration.id) }
            let crossing = fitted?.crossing(value: guide.value)
            let now = sessionNow(session)
            let message: String
            if let fitted, let crossing {
                let slope = fitted.slope.formatted(.number.precision(.significantDigits(3)))
                let detail = "n \(fitted.count) · \(Int(range.upperBound.timeIntervalSince(range.lowerBound)))s training · slope \(slope)/s"
                let remaining = crossing.timeIntervalSince(now)
                let countdown = remaining < 60 ? String(format: "%.0f s", remaining) : (remaining < 3600 ? String(format: "%.1f min", remaining / 60) : (remaining < 86400 ? String(format: "%.1f h", remaining / 3600) : String(format: "%.1f days", remaining / 86400)))
                message = crossing > now ? "Crossing \(TimeText.format(crossing, zone: session.timeline.timeZone ?? .local, includeDate: true)) · in \(countdown) · \(detail)" : "No future crossing · \(detail)"
            } else { message = fitted == nil ? (queries.isFitting(configuration.id) ? "Calculating…" : "Not enough distinct sample times") : "No finite crossing predicted" }
            return ForecastStatus(configuration: configuration, fit: fitted, guide: guide, crossing: crossing, message: message, fitSampleCount: count, fitRange: range)
        }
        allForecastStatuses[session.id] = statuses
        forecastStatuses[session.id] = statuses.first
    }
    func forecastTrainingRanges(for chart: ChartSnapshot, session: SessionSnapshot) -> [ForecastTrainingRange] {
        let configurations = session.timeline.forecasts ?? session.timeline.forecast.map { [$0] } ?? []
        return configurations.compactMap { configuration in
            guard let stream = chart.streams.first(where: { $0.id == configuration.streamID }) else { return nil }
            let guide = chart.guides.first { $0.id == configuration.guideID }
            let target = guide?.label.flatMap { $0.isEmpty ? nil : $0 }
                ?? guide.map { NumericText.format($0.value, scale: chart.settings.numericScale ?? .decimal, unit: chart.settings.unit) }
                ?? "missing target"
            return ForecastTrainingRange(id: configuration.id, streamID: stream.id,
                label: "\(stream.name) → \(target) · training",
                range: resolvedRange(configuration.selection, now: sessionNow(session)),
                linked: configuration.selection.mode != .fixed)
        }
    }
    func forecastDrawings(for chart: ChartSnapshot, session: SessionSnapshot) -> [ForecastDrawing] {
        (allForecastStatuses[session.id] ?? []).compactMap { status in
            guard chart.streams.contains(where: { $0.id == status.configuration.streamID }),
                  let fit = status.fit, let crossing = status.crossing, crossing > sessionNow(session), let guide = status.guide else { return nil }
            return ForecastDrawing(streamID: status.configuration.streamID, fit: fit,
                                   range: resolvedRange(status.configuration.selection, now: sessionNow(session)), crossing: crossing, value: guide.value)
        }
    }
    func forecastDrawing(for chart: ChartSnapshot, session: SessionSnapshot) -> ForecastDrawing? { forecastDrawings(for: chart, session: session).first }
    private func saveTimeline(_ timeline: TimelineState, _ id: SessionID) {
        do {
            // Navigation restores only viewport fields, using current persisted preferences.
            guard var current = try store.snapshot(sessionID: id)?.timeline else { return }
            current.visibleStart = timeline.visibleStart; current.visibleEnd = timeline.visibleEnd
            current.followNow = timeline.followNow; current.historySpan = timeline.historySpan
            try store.updateTimeline(current, sessionID: id); refresh(id)
        } catch { errorMessage = error.localizedDescription }
    }
    func navigate(_ timeline: TimelineState, session: SessionSnapshot) {
        navigationBack[session.id, default: []].append(session.timeline)
        navigationBack[session.id] = Array(navigationBack[session.id, default: []].suffix(200))
        navigationForward[session.id] = []
        saveTimeline(timeline, session.id)
    }
    func navigateBack(_ session: SessionSnapshot) {
        guard var stack = navigationBack[session.id], let previous = stack.popLast() else { return }
        navigationBack[session.id] = stack; navigationForward[session.id, default: []].append(session.timeline); saveTimeline(previous, session.id)
    }
    func navigateForward(_ session: SessionSnapshot) {
        guard var stack = navigationForward[session.id], let next = stack.popLast() else { return }
        navigationForward[session.id] = stack; navigationBack[session.id, default: []].append(session.timeline); saveTimeline(next, session.id)
    }
    func canNavigateBack(_ sessionID: SessionID) -> Bool { !(navigationBack[sessionID] ?? []).isEmpty }
    func canNavigateForward(_ sessionID: SessionID) -> Bool { !(navigationForward[sessionID] ?? []).isEmpty }
    func zoom(_ factor: Double, anchor: Date, session: SessionSnapshot, from baseRange: ClosedRange<Date>? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let now = sessionNow(session); let domainEnd = baseRange?.upperBound ?? session.timeline.visibleEnd ?? now
        let domainStart = baseRange?.lowerBound ?? session.timeline.visibleStart ?? defaultStart(session, now: domainEnd)
        let oldSpan = max(1, domainEnd.timeIntervalSince(domainStart))
        let newSpan = min(7 * 24 * 3600, max(5, oldSpan / factor))
        let anchorFraction = min(1, max(0, anchor.timeIntervalSince(domainStart) / oldSpan))
        var timeline = session.timeline; timeline.followNow = false
        timeline.visibleStart = anchor.addingTimeInterval(-newSpan * anchorFraction)
        timeline.visibleEnd = anchor.addingTimeInterval(newSpan * (1 - anchorFraction))
        navigate(timeline, session: session)
    }
    func clearError() { errorMessage = nil }

    func openSession(_ id: SessionID) { do { try store.setSessionOpen(true, sessionID: id); openedSessionIDs.insert(id); refresh(id) } catch { errorMessage = error.localizedDescription } }
    func windowClosed(_ id: SessionID) {
        guard !terminating else { return }
        suspendedDisplays.remove(id)
        openedSessionIDs.remove(id)
        defer { connectionRegistry.closeConnections(for: id) }
        do {
            try store.setSessionOpen(false, sessionID: id)
            refreshAll(); if activeSessionID == id { activeSessionID = nil }
        }
        catch { errorMessage = error.localizedDescription }
    }
    func applicationWillTerminate() { terminating = true }
    func prepareForTermination() {
        do { try store.recordTerminationOpenSessions(openedSessionIDs) }
        catch { errorMessage = error.localizedDescription }
        terminating = true
    }

    private func handle(_ connection: SocketConnection) {
        let owner = UUID()
        let connectionKey = UUID()
        var attachment: AttachmentID?
        var eventMode = false
        var registered: ReadyReply?
        defer {
            if let id = registered?.attachmentID { crossings.finish(attachment: id) }
            connectionRegistry.remove(connectionKey); connection.close()
        }
        do {
            guard let first = try connection.receive(ClientMessage.self, timeout: 5) else { return }
            guard case let .hello(request) = first else { throw protocolFailure("handshake", "Expected hello") }
            try connection.send(ServerMessage.hello(HelloReply(appInstanceID: appInstanceID)))
            guard request.protocolVersion == 1 else { throw protocolFailure("protocol_version", "Unsupported PipePlot protocol version") }
            if request.eventMode == true || request.sampler != nil {
                eventMode = request.eventMode == true
                guard !(eventMode && request.sampler != nil) else { throw protocolFailure("handshake", "Choose events or numeric samples") }
                let ready: ReadyReply
                if eventMode { ready = try store.registerEventConnection(intent: request.sink, owner: owner) }
                else { ready = try store.registerSampler(intent: request.sink, sampler: request.sampler!, owner: owner) }
                attachment = ready.attachmentID
                registered = ready
                connectionRegistry.add(connectionKey, sessionID: ready.sessionID, connection: connection)
                try connection.send(ServerMessage.ready(ready))
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.refreshAll()
                    if !self.openedSessionIDs.contains(ready.sessionID) { self.openWindowAction?(ready.sessionID) }
                }
            }
            if case .command(let command) = first { try serve(command, over: connection) }
            while let message = try connection.receive(ClientMessage.self) {
                switch message {
                case .hello: throw protocolFailure("protocol", "hello can only be sent once")
                case .rejected(let rejection):
                    guard let attachmentID = attachment else { throw protocolFailure("not_ready", "No sampler was registered") }
                    try store.recordRejectedInput(rejection, to: attachmentID)
                case .event(let event):
                    guard eventMode, let attachmentID = attachment else { throw protocolFailure("not_ready", "No event connection was registered") }
                    try store.appendEvent(event.text, at: event.timestamp, to: attachmentID)
                    try connection.send(ServerMessage.eventAccepted)
                case .row(let row):
                    guard !eventMode, let attachmentID = attachment else { throw protocolFailure("not_ready", "No sampler was registered") }
                    let seq = try store.append(row, to: attachmentID).first ?? row.sequence
                    if let ready = registered, let session = try store.snapshot(sessionID: ready.sessionID) {
                        let events = crossings.evaluate(row, streams: store.currentAttachmentStreamIDs(attachmentID), attachment: attachmentID, session: session)
                        if !events.isEmpty { DispatchQueue.main.async { [weak self] in
                            for event in events { self?.notifications.deliver(event) }
                        } }
                    }
                    try connection.send(ServerMessage.accepted(AcceptedRow(sequence: seq)))
                case .finish(let reason):
                    if let attachmentID = attachment { try store.finishAttachment(attachmentID, reason: reason); attachment = nil }
                    try connection.send(ServerMessage.closed); return
                case .command(let command): try serve(command, over: connection); return
                }
            }
            if let attachment { try store.finishAttachment(attachment, reason: .clientDisconnected) }
        } catch {
            let protocolError = ProtocolError(code: "app_error", message: error.localizedDescription)
            try? connection.send(ServerMessage.error(protocolError))
            if let attachment { try? store.finishAttachment(attachment, reason: .error) }
        }
        Task { @MainActor in self.refreshAll() }
    }

    private func serve(_ command: AppCommand, over connection: SocketConnection) throws {
        switch command {
        case .list: try connection.send(ServerMessage.listing(Listing(sessions: store.listSessions(), targetChartID: store.currentTarget())), timeout: 5)
        case .snapshot(let sessionID): if let snapshot = try store.snapshot(sessionID: sessionID) { try connection.send(ServerMessage.snapshot(snapshot), timeout: 5) } else { throw protocolFailure("unknown_session", "Unknown session") }
        case .setTarget(let chartID): _ = try store.setTarget(chartID); try connection.send(ServerMessage.listing(Listing(sessions: store.listSessions(), targetChartID: store.currentTarget())), timeout: 5)
        case .createChartAndTarget: throw protocolFailure("unsupported", "Use the atomic --new-chart sampler request")
        }
    }

    private func protocolFailure(_ code: String, _ message: String) -> NSError {
        NSError(domain: "PipePlotIPC.\(code)", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct ForecastStatus {
    let configuration: ForecastConfiguration
    let fit: LinearFit?
    let guide: Guide?
    let crossing: Date?
    let message: String
    let fitSampleCount: Int64
    let fitRange: ClosedRange<Date>?
    init(configuration: ForecastConfiguration, fit: LinearFit?, guide: Guide?, crossing: Date?, message: String, fitSampleCount: Int64 = 0, fitRange: ClosedRange<Date>? = nil) {
        self.configuration = configuration; self.fit = fit; self.guide = guide
        self.crossing = crossing; self.message = message; self.fitSampleCount = fitSampleCount; self.fitRange = fitRange
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

private final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: (SessionID, SocketConnection)] = [:]
    func add(_ key: UUID, sessionID: SessionID, connection: SocketConnection) {
        lock.lock(); defer { lock.unlock() }; items[key] = (sessionID, connection)
    }
    func remove(_ key: UUID) { lock.lock(); defer { lock.unlock() }; items.removeValue(forKey: key) }
    func closeConnections(for sessionID: SessionID) {
        lock.lock(); let selected = items.filter { $0.value.0 == sessionID }.map(\.value.1); lock.unlock()
        for connection in selected {
            try? connection.send(ServerMessage.error(ProtocolError(code: "session_closed", message: "The PipePlot session window was closed.")))
            connection.close()
        }
    }
}

extension Notification.Name {
    static let pipePlotWillTerminate = Notification.Name("PipePlotWillTerminate")
}
