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
    private var terminating = false
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
            if let first = all.sorted(by: { $0.number < $1.number }).first {
                try store.setSessionOpen(true, sessionID: first.id); refresh(first.id); startServer(); return first.id
            }
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
    func undo(_ sessionID: SessionID) { do { _ = try store.undo(sessionID: sessionID); refresh(sessionID) } catch { errorMessage = error.localizedDescription } }
    func redo(_ sessionID: SessionID) { do { _ = try store.redo(sessionID: sessionID); refresh(sessionID) } catch { errorMessage = error.localizedDescription } }

    func refresh(_ id: SessionID) {
        do { if let value = try store.snapshot(sessionID: id) { sessions[id] = value; refreshForecast(value) } }
        catch { errorMessage = error.localizedDescription }
    }
    func refreshAll() { do { for session in try store.listSessions() { sessions[session.id] = session; refreshForecast(session) } } catch { errorMessage = error.localizedDescription } }

    func visibleSamples(for chart: ChartSnapshot, session: SessionSnapshot) -> [StreamID: [StoredSample]] {
        let now = Date()
        let end = session.timeline.followNow ? max(now, session.timeline.visibleEnd ?? now) : (session.timeline.visibleEnd ?? now)
        let start = session.timeline.visibleStart ?? end.addingTimeInterval(-15 * 60)
        var result: [StreamID: [StoredSample]] = [:]
        for stream in chart.streams {
            do { result[stream.id] = try store.samples.displaySamples(streamID: stream.id, from: start, to: end, bucketCount: 800) }
            catch { errorMessage = error.localizedDescription }
        }
        return result
    }

    func stats(for stream: StreamID, in selection: TimeSelection) -> SelectionStatistics? {
        let range = resolvedRange(selection)
        do { return try store.samples.statistics(streamID: stream, from: range.lowerBound, to: range.upperBound) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func fit(for stream: StreamID, selection: TimeSelection) -> LinearFit? {
        let range = resolvedRange(selection)
        do { return try store.samples.linearFit(streamID: stream, from: range.lowerBound, to: range.upperBound) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    private func resolvedRange(_ selection: TimeSelection) -> ClosedRange<Date> {
        let now = Date()
        switch selection.mode {
        case .fixed: return min(selection.start, selection.end)...max(selection.start, selection.end)
        case .endFollowsNow: return min(selection.start, now)...max(selection.start, now)
        case .bothFollowNow(let duration): return now.addingTimeInterval(-duration)...now
        }
    }

    func followNow(_ session: SessionSnapshot) {
        var timeline = session.timeline; timeline.followNow = true; timeline.visibleEnd = nil
        let span = max(60, (timeline.visibleEnd ?? Date()).timeIntervalSince(timeline.visibleStart ?? Date().addingTimeInterval(-15 * 60)))
        timeline.visibleStart = Date().addingTimeInterval(-min(span, 15 * 60))
        saveTimeline(timeline, session.id)
    }
    func setSpan(_ seconds: TimeInterval, session: SessionSnapshot) {
        var timeline = session.timeline; timeline.followNow = true; timeline.visibleEnd = nil; timeline.visibleStart = Date().addingTimeInterval(-seconds)
        saveTimeline(timeline, session.id)
    }
    func showAllHistory(_ session: SessionSnapshot) {
        var starts: [Date] = []
        for chart in session.charts { for stream in chart.streams { if let first = stream.firstSampleAt { starts.append(first) } } }
        var timeline = session.timeline; timeline.followNow = false; timeline.visibleStart = starts.min() ?? Date().addingTimeInterval(-15 * 60); timeline.visibleEnd = Date()
        saveTimeline(timeline, session.id)
    }
    func setSelection(_ selection: TimeSelection?, session: SessionSnapshot) {
        do { try store.setSelection(selection, sessionID: session.id); refresh(session.id) }
        catch { errorMessage = error.localizedDescription }
    }
    func setForecast(_ forecast: ForecastConfiguration?, session: SessionSnapshot) {
        do { try store.setForecast(forecast, sessionID: session.id); refresh(session.id) }
        catch { errorMessage = error.localizedDescription }
    }
    func refreshForecast(_ session: SessionSnapshot) {
        guard let configuration = session.timeline.forecast else { forecastStatuses[session.id] = nil; return }
        guard let guide = session.charts.flatMap(\.guides).first(where: { $0.id == configuration.guideID }) else {
            forecastStatuses[session.id] = ForecastStatus(configuration: configuration, fit: nil, guide: nil, crossing: nil, message: "Target guide is missing")
            return
        }
        let fitted = fit(for: configuration.streamID, selection: configuration.selection)
        let crossing = fitted?.crossing(value: guide.value)
        let message: String
        if let fitted, let crossing {
            let rate = fitted.slope.formatted(.number.precision(.significantDigits(3)))
            message = crossing > Date() ? "Crossing \(crossing.formatted(date: .abbreviated, time: .shortened)) · slope \(rate)/s" : "Crossing is in the past · slope \(rate)/s"
        } else {
            message = fitted == nil ? "Not enough distinct sample times" : "No finite crossing predicted"
        }
        forecastStatuses[session.id] = ForecastStatus(configuration: configuration, fit: fitted, guide: guide, crossing: crossing, message: message)
        if configuration.selection.mode != .fixed, session.timeline.followNow, let crossing, crossing > Date() {
            let end = crossing.addingTimeInterval(max(15, crossing.timeIntervalSinceNow * 0.05))
            if session.timeline.visibleEnd == nil || abs(session.timeline.visibleEnd!.timeIntervalSince(end)) > 5 {
                var timeline = session.timeline; timeline.visibleEnd = end
                try? store.updateTimeline(timeline, sessionID: session.id)
            }
        }
    }
    func forecastDrawing(for chart: ChartSnapshot, session: SessionSnapshot) -> ForecastDrawing? {
        guard let status = forecastStatuses[session.id],
              chart.streams.contains(where: { $0.id == status.configuration.streamID }),
              let fit = status.fit, let crossing = status.crossing, let guide = status.guide else { return nil }
        return ForecastDrawing(streamID: status.configuration.streamID, fit: fit,
                              range: resolvedRange(status.configuration.selection), crossing: crossing, value: guide.value)
    }
    private func saveTimeline(_ timeline: TimelineState, _ id: SessionID) {
        do { try store.updateTimeline(timeline, sessionID: id); refresh(id) } catch { errorMessage = error.localizedDescription }
    }

    func openSession(_ id: SessionID) { do { try store.setSessionOpen(true, sessionID: id); openedSessionIDs.insert(id); refresh(id) } catch { errorMessage = error.localizedDescription } }
    func windowClosed(_ id: SessionID) {
        guard !terminating else { return }
        openedSessionIDs.remove(id)
        connectionRegistry.closeConnections(for: id)
        do { try store.setSessionOpen(false, sessionID: id); refresh(id); if activeSessionID == id { activeSessionID = nil } }
        catch { errorMessage = error.localizedDescription }
    }
    func applicationWillTerminate() { terminating = true }

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

struct ForecastStatus {
    let configuration: ForecastConfiguration
    let fit: LinearFit?
    let guide: Guide?
    let crossing: Date?
    let message: String
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
