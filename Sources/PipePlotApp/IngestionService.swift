import Foundation
import PipePlotCore
import PipePlotTransport

enum IngestionEvent: Sendable {
    case registered(SessionID)
    case firstSample(SessionID)
    case lifecycleChanged(SessionID)
    case metadataChanged
    case crossing(GuideCrossing)
    case error(String)
}

struct IngestionEventBatch: Sendable {
    let registered: [SessionID]
    let firstSamples: [SessionID]
    let lifecycleChanges: [SessionID]
    let metadataChanged: Bool
    let crossings: [GuideCrossing]
    let errors: [String]
    let reconcileRegistrations: Bool
    let refreshAll: Bool
    let omittedCrossings: Int
    let omittedErrors: Int
}

/// The lock owns all pending fields. At most one MainActor drain is scheduled;
/// session changes coalesce, and fixed caps bound crossing/error payloads.
/// Registration overflow requests a store reconciliation instead of losing windows.
final class IngestionEventMailbox: @unchecked Sendable {
    private static let maximumPendingSessions = 128
    private static let maximumPendingCrossings = 128
    private static let maximumPendingErrors = 16
    private let lock = NSLock()
    private let deliver: @MainActor @Sendable (IngestionEventBatch) -> Void
    private var registered: [SessionID] = []
    private var firstSamples: [SessionID] = []
    private var lifecycleChanges: [SessionID] = []
    private var metadataChanged = false
    private var crossings: [GuideCrossing] = []
    private var errors: [String] = []
    private var reconcileRegistrations = false
    private var refreshAll = false
    private var omittedCrossings = 0
    private var omittedErrors = 0
    private var scheduled = false

    init(deliver: @escaping @MainActor @Sendable (IngestionEventBatch) -> Void) { self.deliver = deliver }

    func post(_ event: IngestionEvent) {
        lock.lock()
        switch event {
        case .registered(let id):
            if !registered.contains(id) {
                if registered.count < Self.maximumPendingSessions {
                    registered.append(id)
                } else {
                    reconcileRegistrations = true
                }
            }
        case .firstSample(let id):
            if !firstSamples.contains(id) {
                if firstSamples.count < Self.maximumPendingSessions {
                    firstSamples.append(id)
                } else {
                    refreshAll = true
                }
            }
        case .lifecycleChanged(let id):
            if !lifecycleChanges.contains(id) {
                if lifecycleChanges.count < Self.maximumPendingSessions {
                    lifecycleChanges.append(id)
                } else {
                    refreshAll = true
                }
            }
        case .metadataChanged:
            metadataChanged = true
        case .crossing(let crossing):
            if crossings.count < Self.maximumPendingCrossings {
                crossings.append(crossing)
            } else {
                omittedCrossings += 1
            }
        case .error(let message):
            if errors.count < Self.maximumPendingErrors {
                errors.append(message)
            } else {
                errors[errors.count - 1] = message
                omittedErrors += 1
            }
        }
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule { Task { @MainActor [weak self] in self?.drain() } }
    }

    @MainActor private func drain() {
        lock.lock()
        let batch = IngestionEventBatch(
            registered: registered, firstSamples: firstSamples, lifecycleChanges: lifecycleChanges,
            metadataChanged: metadataChanged, crossings: crossings, errors: errors,
            reconcileRegistrations: reconcileRegistrations, refreshAll: refreshAll,
            omittedCrossings: omittedCrossings, omittedErrors: omittedErrors)
        registered.removeAll()
        firstSamples.removeAll()
        lifecycleChanges.removeAll()
        metadataChanged = false
        crossings.removeAll()
        errors.removeAll()
        reconcileRegistrations = false
        refreshAll = false
        omittedCrossings = 0
        omittedErrors = 0
        scheduled = false
        lock.unlock()
        deliver(batch)
    }
}

/// The lock serializes store registration plus registry admission against store
/// close/delete plus registry detachment. A later explicit registration can
/// reopen a closed session. No socket send runs while this lock is held.
private final class IngestionConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: (SessionID, SocketConnection)] = [:]

    func register(_ key: UUID, connection: SocketConnection, create: () throws -> ReadyReply) throws -> ReadyReply {
        lock.lock()
        defer { lock.unlock() }
        let ready = try create()
        items[key] = (ready.sessionID, connection)
        return ready
    }
    func remove(_ key: UUID) {
        lock.lock()
        items.removeValue(forKey: key)
        lock.unlock()
    }
    func closeConnections(for id: SessionID, mutation: () throws -> Bool) throws {
        lock.lock()
        do {
            guard try mutation() else {
                lock.unlock()
                return
            }
        } catch {
            lock.unlock()
            throw error
        }
        let keys = items.compactMap { $0.value.0 == id ? $0.key : nil }
        let selected = keys.compactMap { items.removeValue(forKey: $0)?.1 }
        lock.unlock()
        for connection in selected {
            // close() can interrupt a writer waiting for writeLock, so the
            // deadline is independent of the courtesy error send.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { connection.close() }
            DispatchQueue.global(qos: .utility).async {
                try? connection.send(
                    ServerMessage.error(
                        ProtocolError(code: "session_closed", message: "The PipePlot session window was closed.")),
                    timeout: 0.25)
                connection.close()
            }
        }
    }
}

private struct IngestionWorker: Sendable {
    let store: PipePlotStore
    let crossings: GuideCrossingDetector
    let registry: IngestionConnectionRegistry
    let appInstanceID: UUID
    let emit: @Sendable (IngestionEvent) -> Void

    func handle(_ connection: SocketConnection) {
        let owner = UUID()
        let connectionKey = UUID()
        var attachment: AttachmentID?
        var eventMode = false
        var registered: ReadyReply?
        var acceptedFirstRow = false
        var finishReason: FinishReason = .clientDisconnected

        func finishAttachment(_ reason: FinishReason) throws {
            guard let id = attachment else { return }
            try store.finishAttachment(id, reason: reason)
            attachment = nil
        }
        defer {
            if attachment != nil {
                do { try finishAttachment(finishReason) } catch { emit(.error(error.localizedDescription)) }
            }
            if let ready = registered {
                crossings.finish(attachment: ready.attachmentID)
                emit(.lifecycleChanged(ready.sessionID))
            }
            registry.remove(connectionKey)
            connection.close()
        }
        do {
            guard let first = try connection.receive(ClientMessage.self, timeout: 5) else { return }
            guard case let .hello(request) = first else { throw protocolFailure("handshake", "Expected hello") }
            try connection.send(ServerMessage.hello(HelloReply(appInstanceID: appInstanceID)))
            guard request.protocolVersion == 1 else {
                throw protocolFailure("protocol_version", "Unsupported PipePlot protocol version")
            }
            if request.eventMode == true || request.sampler != nil {
                eventMode = request.eventMode == true
                guard !(eventMode && request.sampler != nil) else {
                    throw protocolFailure("handshake", "Choose events or numeric samples")
                }
                let ready = try registry.register(connectionKey, connection: connection) {
                    if eventMode {
                        return try store.registerEventConnection(intent: request.sink, owner: owner)
                    }
                    return try store.registerSampler(intent: request.sink, sampler: request.sampler!, owner: owner)
                }
                attachment = ready.attachmentID
                registered = ready
                try connection.send(ServerMessage.ready(ready))
                emit(.registered(ready.sessionID))
            }
            if case .command(let command) = first { try serve(command, over: connection) }
            while let message = try connection.receive(ClientMessage.self) {
                switch message {
                case .hello: throw protocolFailure("protocol", "hello can only be sent once")
                case .rejected(let rejection):
                    guard let attachmentID = attachment else {
                        throw protocolFailure("not_ready", "No sampler was registered")
                    }
                    try store.recordRejectedInput(rejection, to: attachmentID)
                    if let ready = registered { emit(.lifecycleChanged(ready.sessionID)) }
                case .event(let event):
                    guard eventMode, let attachmentID = attachment else {
                        throw protocolFailure("not_ready", "No event connection was registered")
                    }
                    try store.appendEvent(event.text, at: event.timestamp, to: attachmentID)
                    try connection.send(ServerMessage.eventAccepted)
                    if let ready = registered { emit(.lifecycleChanged(ready.sessionID)) }
                case .row(let row):
                    guard !eventMode, let attachmentID = attachment else {
                        throw protocolFailure("not_ready", "No sampler was registered")
                    }
                    let seq = try store.append(row, to: attachmentID).first ?? row.sequence
                    if !acceptedFirstRow, let ready = registered {
                        acceptedFirstRow = true
                        emit(.firstSample(ready.sessionID))
                    }
                    if let ready = registered, let session = try store.snapshot(sessionID: ready.sessionID) {
                        let events = crossings.evaluate(
                            row, streams: store.currentAttachmentStreamIDs(attachmentID), attachment: attachmentID,
                            session: session)
                        for event in events { emit(.crossing(event)) }
                    }
                    try connection.send(ServerMessage.accepted(AcceptedRow(sequence: seq)))
                case .finish(let reason):
                    try finishAttachment(reason)
                    try connection.send(ServerMessage.closed, timeout: 5)
                    return
                case .command(let command):
                    try finishAttachment(.clientDisconnected)
                    try serve(command, over: connection)
                    return
                }
            }
        } catch {
            finishReason = .error
            do { try finishAttachment(.error) } catch { emit(.error(error.localizedDescription)) }
            try? connection.send(
                ServerMessage.error(ProtocolError(code: "app_error", message: error.localizedDescription)), timeout: 5)
        }
    }

    private func serve(_ command: AppCommand, over connection: SocketConnection) throws {
        switch command {
        case .list:
            try connection.send(
                ServerMessage.listing(Listing(sessions: store.listSessions(), targetChartID: store.currentTarget())),
                timeout: 5)
        case .snapshot(let sessionID):
            if let snapshot = try store.snapshot(sessionID: sessionID) {
                try connection.send(ServerMessage.snapshot(snapshot), timeout: 5)
            } else {
                throw protocolFailure("unknown_session", "Unknown session")
            }
        case .setTarget(let chartID):
            _ = try store.setTarget(chartID)
            try connection.send(
                ServerMessage.listing(Listing(sessions: store.listSessions(), targetChartID: store.currentTarget())),
                timeout: 5)
            emit(.metadataChanged)
        case .createChartAndTarget: throw protocolFailure("unsupported", "Use the atomic --new-chart sampler request")
        }
    }

    private func protocolFailure(_ code: String, _ message: String) -> NSError {
        NSError(domain: "PipePlotIPC.\(code)", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class IngestionService: Sendable {
    private let store: PipePlotStore
    private let registry: IngestionConnectionRegistry
    private let server: UnixSocketServer

    init(store: PipePlotStore, socketURL: URL, emit: @escaping @Sendable (IngestionEvent) -> Void) {
        self.store = store
        let registry = IngestionConnectionRegistry()
        self.registry = registry
        let worker = IngestionWorker(
            store: store, crossings: GuideCrossingDetector(), registry: registry, appInstanceID: UUID(), emit: emit)
        server = UnixSocketServer(socketURL: socketURL) { connection in worker.handle(connection) }
    }

    func start() throws { try server.start() }
    func stop() { server.stop() }
    func closeSession(_ id: SessionID, delete: Bool = false, closedBefore cutoff: Date? = nil) throws {
        try registry.closeConnections(for: id) {
            if delete {
                return try store.deleteSession(sessionID: id, closedBefore: cutoff)
            }
            try store.setSessionOpen(false, sessionID: id)
            return true
        }
    }
}
