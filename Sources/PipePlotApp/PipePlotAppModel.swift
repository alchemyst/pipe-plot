import Foundation
import SwiftUI
import Observation
import PipePlotCore
import PipePlotTransport

@MainActor
@Observable
final class PipePlotAppModel {
    let store: PipePlotStore
    private var server: UnixSocketServer?
    private let connectionRegistry = ConnectionRegistry()
    private let appInstanceID = UUID()
    private var openWindowAction: ((SessionID) -> Void)?
    private var openSessionPickerAction: (() -> Void)?
    private var didBootstrap = false
    private var serverStarted = false
    private(set) var sessions: [SessionID: SessionSnapshot] = [:]
    private(set) var errorMessage: String?
    private(set) var activeSessionID: SessionID?
    private(set) var forecastStatuses: [SessionID: ForecastStatus] = [:]
    private(set) var openedSessionIDs: Set<SessionID> = []
    private(set) var clockPulse = Date()
    private var terminating = false
    private var navigationBack: [SessionID: [TimelineState]] = [:]
    private var navigationForward: [SessionID: [TimelineState]] = [:]
    @ObservationIgnored private var displayCache: [StreamID: (key: DisplayCacheKey, rows: [StoredSample])] = [:]
    let refreshTimer = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    init() {
        do {
            let database = PipePlotLocations.supportDirectory.appendingPathComponent("pipeplot.sqlite")
            store = try PipePlotStore(databaseURL: database)
        } catch {
            fatalError("Could not open PipePlot's local store: \(error.localizedDescription)")
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
        guard !didBootstrap else { return sessions.values.sorted { $0.number < $1.number }.first?.id }
        didBootstrap = true
        do {
            let all = try store.listSessions()
            for session in all { sessions[session.id] = session }
            let cliLaunch = ProcessInfo.processInfo.arguments.contains("--pipeplot-launched-by-cli")
            if cliLaunch {
                let fresh = try store.createSession()
                refresh(fresh.id)
                startServer()
                return fresh.id
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
        do { let session = try store.createSession(); refresh(session.id); openWindowAction?(session.id) }
        catch { errorMessage = error.localizedDescription }
    }

    func createChart(in sessionID: SessionID, after chartID: ChartID?) {
        do { _ = try store.createChart(in: sessionID, after: chartID); refresh(sessionID) }
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
        do { try store.upsertGuide(guide, chartID: chartID); refresh(sessionID) }
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
    func reassociate(_ source: StreamID, with destination: StreamID, sessionID: SessionID) {
        do { try store.reassociateStreams([source], to: [destination]); refresh(sessionID) }
        catch { errorMessage = error.localizedDescription }
    }
    func undo(_ sessionID: SessionID) { do { _ = try store.undo(sessionID: sessionID); refresh(sessionID) } catch { errorMessage = error.localizedDescription } }
    func redo(_ sessionID: SessionID) { do { _ = try store.redo(sessionID: sessionID); refresh(sessionID) } catch { errorMessage = error.localizedDescription } }

    func refresh(_ id: SessionID) {
        do { if let value = try store.snapshot(sessionID: id) { sessions[id] = value; refreshForecast(value) } }
        catch { errorMessage = error.localizedDescription }
    }
    func tick(_ id: SessionID) { clockPulse = Date(); refresh(id) }
    func sessionNow(_ session: SessionSnapshot) -> Date { session.timeline.clockStoppedAt ?? clockPulse }
    private func sessionNow(for streamID: StreamID) -> Date {
        sessions.values.first(where: { $0.charts.contains(where: { $0.streams.contains(where: { $0.id == streamID }) }) }).map(sessionNow) ?? clockPulse
    }
    func refreshAll() { do { for session in try store.listSessions() { sessions[session.id] = session; refreshForecast(session) } } catch { errorMessage = error.localizedDescription } }

    func visibleSamples(for chart: ChartSnapshot, session: SessionSnapshot) -> [StreamID: [StoredSample]] {
        let range = domain(for: session)
        let start = range.lowerBound
        let end = range.upperBound
        var result: [StreamID: [StoredSample]] = [:]
        for stream in chart.streams {
            let endBucket = Date(timeIntervalSince1970: floor(end.timeIntervalSince1970))
            let key = DisplayCacheKey(start: start, end: endBucket, sampleCount: stream.sampleCount, lastSampleAt: stream.lastSampleAt, bucketCount: 800)
            if let cached = displayCache[stream.id], cached.key == key { result[stream.id] = cached.rows; continue }
            do {
                let rows = try store.samples.displaySamples(streamID: stream.id, from: start, to: end, bucketCount: 800)
                displayCache[stream.id] = (key, rows)
                result[stream.id] = rows
            }
            catch { errorMessage = error.localizedDescription }
        }
        if displayCache.count > 256 {
            let active = Set(session.charts.flatMap(\.streams).map(\.id))
            displayCache = displayCache.filter { active.contains($0.key) }
        }
        return result
    }
    func domain(for session: SessionSnapshot) -> ClosedRange<Date> {
        let now = sessionNow(session)
        let start = session.timeline.visibleStart ?? defaultStart(session, now: now)
        var end = session.timeline.followNow ? max(now, session.timeline.visibleEnd ?? now) : (session.timeline.visibleEnd ?? now)
        if session.timeline.followNow, let crossing = forecastStatuses[session.id]?.crossing, crossing > now {
            end = max(end, crossing.addingTimeInterval(max(15, crossing.timeIntervalSince(now) * 0.05)))
        }
        return start < end ? start...end : now.addingTimeInterval(-60)...now
    }
    func pan(_ deltaX: CGFloat, width: CGFloat, session: SessionSnapshot) {
        let now = sessionNow(session)
        let end = session.timeline.visibleEnd ?? now
        let start = session.timeline.visibleStart ?? defaultStart(session, now: end)
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
        let earliest = session.charts.flatMap(\.streams).compactMap(\.firstSampleAt).min()
        let span = session.timeline.historySpan ?? 15 * 60
        return max(earliest ?? now.addingTimeInterval(-span), now.addingTimeInterval(-span))
    }

    func stats(for stream: StreamID, in selection: TimeSelection) -> SelectionStatistics? {
        let range = resolvedRange(selection, now: sessionNow(for: stream))
        do { return try store.samples.statistics(streamID: stream, from: range.lowerBound, to: range.upperBound) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func nearestSample(_ stream: StreamID, at date: Date) -> StoredSample? {
        do { return try store.samples.nearestSample(streamID: stream, at: date) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func fit(for stream: StreamID, selection: TimeSelection) -> LinearFit? {
        let range = resolvedRange(selection, now: sessionNow(for: stream))
        do { return try store.samples.linearFit(streamID: stream, from: range.lowerBound, to: range.upperBound) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    private func resolvedRange(_ selection: TimeSelection, now: Date? = nil) -> ClosedRange<Date> {
        let now = now ?? clockPulse
        switch selection.mode {
        case .fixed: return min(selection.start, selection.end)...max(selection.start, selection.end)
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
        var starts: [Date] = []
        for chart in session.charts { for stream in chart.streams { if let first = stream.firstSampleAt { starts.append(first) } } }
        let now = sessionNow(session)
        var timeline = session.timeline; timeline.followNow = false; timeline.visibleStart = starts.min() ?? now.addingTimeInterval(-15 * 60); timeline.visibleEnd = now; timeline.historySpan = nil
        navigate(timeline, session: session)
    }
    func setSelection(_ selection: TimeSelection?, session: SessionSnapshot) {
        do { try store.setSelection(selection, sessionID: session.id); refresh(session.id) }
        catch { errorMessage = error.localizedDescription }
    }
    func setForecast(_ forecast: ForecastConfiguration?, session: SessionSnapshot) {
        do {
            try store.setForecast(forecast, sessionID: session.id)
            refresh(session.id)
        }
        catch { errorMessage = error.localizedDescription }
    }
    func refreshForecast(_ session: SessionSnapshot) {
        guard let configuration = session.timeline.forecast else { forecastStatuses[session.id] = nil; return }
        guard let chart = session.charts.first(where: { $0.streams.contains(where: { $0.id == configuration.streamID }) }),
              let guide = chart.guides.first(where: { $0.id == configuration.guideID && $0.orientation == .horizontalValue }) else {
            forecastStatuses[session.id] = ForecastStatus(configuration: configuration, fit: nil, guide: nil, crossing: nil, message: "Target guide is missing")
            return
        }
        let oldStatus = forecastStatuses[session.id]
        let sampleCount = chart.streams.first(where: { $0.id == configuration.streamID })?.sampleCount ?? 0
        let fitted: LinearFit?
        if oldStatus?.configuration == configuration, oldStatus?.fitSampleCount == sampleCount, let oldFit = oldStatus?.fit { fitted = oldFit }
        else if configuration.selection.mode == .fixed, oldStatus?.configuration.id == configuration.id, let oldFit = oldStatus?.fit { fitted = oldFit }
        else { fitted = fit(for: configuration.streamID, selection: configuration.selection) }
        let crossing = fitted?.crossing(value: guide.value)
        let message: String
        let now = sessionNow(session)
        if let fitted, let crossing {
            let rate = fitted.slope.formatted(.number.precision(.significantDigits(3)))
            message = crossing > now ? "Crossing \(crossing.formatted(date: .abbreviated, time: .shortened)) · slope \(rate)/s" : "Crossing is in the past · slope \(rate)/s"
        } else {
            message = fitted == nil ? "Not enough distinct sample times" : "No finite crossing predicted"
        }
        forecastStatuses[session.id] = ForecastStatus(configuration: configuration, fit: fitted, guide: guide, crossing: crossing, message: message, fitSampleCount: sampleCount)
    }
    func forecastDrawing(for chart: ChartSnapshot, session: SessionSnapshot) -> ForecastDrawing? {
        guard let status = forecastStatuses[session.id],
              chart.streams.contains(where: { $0.id == status.configuration.streamID }),
              let fit = status.fit, let crossing = status.crossing, let guide = status.guide else { return nil }
        return ForecastDrawing(streamID: status.configuration.streamID, fit: fit,
                              range: resolvedRange(status.configuration.selection, now: sessionNow(session)), crossing: crossing, value: guide.value)
    }
    private func saveTimeline(_ timeline: TimelineState, _ id: SessionID) {
        do { try store.updateTimeline(timeline, sessionID: id); refresh(id) } catch { errorMessage = error.localizedDescription }
    }
    func navigate(_ timeline: TimelineState, session: SessionSnapshot) {
        navigationBack[session.id, default: []].append(session.timeline)
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
    func zoom(_ factor: Double, anchor: Date, session: SessionSnapshot) {
        guard factor.isFinite, factor > 0 else { return }
        let now = sessionNow(session); let domainEnd = session.timeline.visibleEnd ?? now
        let domainStart = session.timeline.visibleStart ?? defaultStart(session, now: domainEnd)
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
        openedSessionIDs.remove(id)
        connectionRegistry.closeConnections(for: id)
        do { try store.setSessionOpen(false, sessionID: id); refresh(id); if activeSessionID == id { activeSessionID = nil } }
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
        defer { connectionRegistry.remove(connectionKey); connection.close() }
        do {
            guard let first = try connection.receive(ClientMessage.self) else { return }
            guard case let .hello(request) = first else { throw protocolFailure("handshake", "Expected hello") }
            try connection.send(ServerMessage.hello(HelloReply(appInstanceID: appInstanceID)))
            guard request.protocolVersion == 1 else { throw protocolFailure("protocol_version", "Unsupported PipePlot protocol version") }
            if let sampler = request.sampler {
                let ready = try store.registerSampler(intent: request.sink, sampler: sampler, owner: owner)
                attachment = ready.attachmentID
                connectionRegistry.add(connectionKey, sessionID: ready.sessionID, connection: connection)
                try connection.send(ServerMessage.ready(ready))
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.refresh(ready.sessionID)
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
                case .row(let row):
                    guard let attachmentID = attachment else { throw protocolFailure("not_ready", "No sampler was registered") }
                    let seq = try store.append(row, to: attachmentID).first ?? row.sequence
                    try connection.send(ServerMessage.accepted(AcceptedRow(sequence: seq)))
                case .finish(let reason):
                    if let attachmentID = attachment { try store.finishAttachment(attachmentID, reason: reason); attachment = nil }
                    try connection.send(ServerMessage.closed); return
                case .command(let command): try serve(command, over: connection)
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
        case .list: try connection.send(ServerMessage.listing(Listing(sessions: store.listSessions(), targetChartID: store.currentTarget())))
        case .snapshot(let sessionID): if let snapshot = try store.snapshot(sessionID: sessionID) { try connection.send(ServerMessage.snapshot(snapshot)) } else { throw protocolFailure("unknown_session", "Unknown session") }
        case .setTarget(let chartID): _ = try store.setTarget(chartID); try connection.send(ServerMessage.listing(Listing(sessions: store.listSessions(), targetChartID: store.currentTarget())))
        case .createChartAndTarget: throw protocolFailure("unsupported", "Use the atomic --new-chart sampler request")
        }
    }

    private func protocolFailure(_ code: String, _ message: String) -> NSError {
        NSError(domain: "PipePlotIPC.\(code)", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct DisplayCacheKey: Equatable {
    let start: Date
    let end: Date
    let sampleCount: Int64
    let lastSampleAt: Date?
    let bucketCount: Int
}

struct ForecastStatus {
    let configuration: ForecastConfiguration
    let fit: LinearFit?
    let guide: Guide?
    let crossing: Date?
    let message: String
    let fitSampleCount: Int64
    init(configuration: ForecastConfiguration, fit: LinearFit?, guide: Guide?, crossing: Date?, message: String, fitSampleCount: Int64 = 0) {
        self.configuration = configuration; self.fit = fit; self.guide = guide
        self.crossing = crossing; self.message = message; self.fitSampleCount = fitSampleCount
    }
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
