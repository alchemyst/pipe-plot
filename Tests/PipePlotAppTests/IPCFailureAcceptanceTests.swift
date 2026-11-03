import Foundation
import XCTest
import PipePlotCore
import PipePlotTransport
@testable import PipePlotApp

@MainActor private final class IngestionBatchRecorder {
    var batches: [IngestionEventBatch] = []
}

@MainActor final class IPCFailureAcceptanceTests: XCTestCase {
    func testMailboxBoundsRegistrationsAndCoalescesFirstSampleEvents() async throws {
        let recorder = IngestionBatchRecorder()
        let delivered = expectation(description: "one bounded batch")
        let mailbox = IngestionEventMailbox { batch in
            recorder.batches.append(batch)
            delivered.fulfill()
        }
        let first = UUID()
        for _ in 0..<50 { mailbox.post(.firstSample(first)) }
        for _ in 0..<200 { mailbox.post(.registered(UUID())) }
        for n in 0..<20 { mailbox.post(.error("error \(n)")) }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(recorder.batches.count, 1)
        let batch = try XCTUnwrap(recorder.batches.first)
        XCTAssertEqual(batch.firstSamples, [first])
        XCTAssertEqual(batch.registered.count, 128)
        XCTAssertTrue(batch.reconcileRegistrations)
        XCTAssertEqual(batch.errors.count, 16)
        XCTAssertEqual(batch.errors.last, "error 19")
        XCTAssertEqual(batch.omittedErrors, 4)
    }

    func testQuietClientLeavesMainActorResponsiveAndCommandFinalizesAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8)).sock")
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("quiet.sqlite"), socketURL: socket)
        let connection = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        defer { connection.close() }
        try connection.send(
            ClientMessage.hello(HelloRequest(sink: .newSession, sampler: SamplerIntent(columnCount: 1))))
        guard case .hello? = try connection.receive(ServerMessage.self, timeout: 2),
            case .ready(let ready)? = try connection.receive(ServerMessage.self, timeout: 2)
        else { return XCTFail("Sampler registration failed") }
        // The worker is waiting for this client; the actor can still process UI work.
        let progress = expectation(description: "main actor progress while client is quiet")
        Task { @MainActor in
            model.createSessionWindow()
            progress.fulfill()
        }
        await fulfillment(of: [progress], timeout: 2)
        XCTAssertGreaterThanOrEqual(model.sessions.count, 2)
        try connection.send(ClientMessage.command(.snapshot(sessionID: ready.sessionID)))
        guard case .snapshot(let snapshot)? = try connection.receive(ServerMessage.self, timeout: 2) else {
            return XCTFail("Missing snapshot")
        }
        XCTAssertEqual(snapshot.charts[0].streams[0].state, .disconnected)
        for _ in 0..<100 {
            if model.sessions[ready.sessionID]?.charts[0].streams[0].state == .disconnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sessions[ready.sessionID]?.charts[0].streams[0].state, .disconnected)
    }

    func testClosedSessionCanBeExplicitlyRegisteredAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8)).sock")
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("reopen.sqlite"), socketURL: socket)
        let first = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        defer { first.close() }
        try first.send(ClientMessage.hello(HelloRequest(sink: .newSession, sampler: SamplerIntent(columnCount: 1))))
        guard case .hello? = try first.receive(ServerMessage.self, timeout: 2),
            case .ready(let ready)? = try first.receive(ServerMessage.self, timeout: 2)
        else { return XCTFail("First registration failed") }
        model.windowClosed(ready.sessionID)
        let reopened = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        defer { reopened.close() }
        try reopened.send(
            ClientMessage.hello(
                HelloRequest(
                    sink: .session(sessionID: ready.sessionID, lineNames: ["next"]),
                    sampler: SamplerIntent(columnCount: 1))))
        guard case .hello? = try reopened.receive(ServerMessage.self, timeout: 2),
            case .ready(let second)? = try reopened.receive(ServerMessage.self, timeout: 2)
        else { return XCTFail("Explicit registration after close failed") }
        XCTAssertEqual(second.sessionID, ready.sessionID)
        XCTAssertTrue(try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID)).isOpen)
        try reopened.send(ClientMessage.row(SampleRow(values: [42])))
        guard case .accepted? = try reopened.receive(ServerMessage.self, timeout: 2) else {
            return XCTFail("Missing resumed capture acknowledgement")
        }
    }

    func testAcceptedRowsCrossTypedEventBoundaryInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PipePlotStore(databaseURL: directory.appendingPathComponent("crossing.sqlite"))
        let socket = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8)).sock")
        let recorder = IngestionBatchRecorder()
        let crossed = expectation(description: "crossing delivered to actor")
        let mailbox = IngestionEventMailbox { batch in
            recorder.batches.append(batch)
            if recorder.batches.flatMap(\.crossings).count == 2 { crossed.fulfill() }
        }
        let service = IngestionService(store: store, socketURL: socket) { mailbox.post($0) }
        try service.start()
        defer { service.stop() }
        let connection = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        defer { connection.close() }
        try connection.send(
            ClientMessage.hello(HelloRequest(sink: .newSession, sampler: SamplerIntent(columnCount: 1))))
        guard case .hello? = try connection.receive(ServerMessage.self, timeout: 2),
            case .ready(let ready)? = try connection.receive(ServerMessage.self, timeout: 2)
        else { return XCTFail("Registration failed") }
        let chartID = try XCTUnwrap(store.snapshot(sessionID: ready.sessionID)?.charts.first?.id)
        try store.upsertGuide(
            Guide(orientation: .horizontalValue, value: 1, alert: GuideAlert(direction: .rising, cooldown: 0)),
            chartID: chartID)
        for value in [0.0, 2.0, 0.0, 3.0] {
            try connection.send(ClientMessage.row(SampleRow(values: [value])))
            guard case .accepted? = try connection.receive(ServerMessage.self, timeout: 2) else {
                return XCTFail("Missing row acknowledgement")
            }
        }
        await fulfillment(of: [crossed], timeout: 2)
        let events = recorder.batches.flatMap(\.crossings)
        XCTAssertEqual(events.map(\.value), [2, 3])
        let crossing = try XCTUnwrap(events.first)
        XCTAssertEqual(crossing.sessionID, ready.sessionID)
        XCTAssertEqual(crossing.streamID, ready.streams[0].id)
        XCTAssertEqual(crossing.value, 2)

        let overflowRecorder = IngestionBatchRecorder()
        let overflow = expectation(description: "bounded crossing batch")
        let overflowMailbox = IngestionEventMailbox { batch in
            overflowRecorder.batches.append(batch)
            overflow.fulfill()
        }
        for _ in 0..<130 { overflowMailbox.post(.crossing(crossing)) }
        await fulfillment(of: [overflow], timeout: 2)
        XCTAssertEqual(overflowRecorder.batches.count, 1)
        XCTAssertEqual(overflowRecorder.batches[0].crossings.count, 128)
        XCTAssertEqual(overflowRecorder.batches[0].omittedCrossings, 2)
    }

    func testClientLossAndSessionCloseRetainAcknowledgedRowsAndOtherSessionCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pp-ipc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("test.sqlite")
        // Short path stays below sockaddr_un's limit on macOS.
        let socket = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8)).sock")
        let model = PipePlotAppModel(databaseURL: database, socketURL: socket)
        func register(_ intent: SinkIntent) throws -> (SocketConnection, ReadyReply) {
            let connection = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
            try connection.send(ClientMessage.hello(HelloRequest(sink: intent, sampler: SamplerIntent(columnCount: 1))))
            guard case .hello? = try connection.receive(ServerMessage.self, timeout: 2),
                case .ready(let ready)? = try connection.receive(ServerMessage.self, timeout: 2)
            else { throw NSError(domain: "acceptance", code: 1) }
            return (connection, ready)
        }
        func append(_ value: Double, to connection: SocketConnection) throws {
            try connection.send(ClientMessage.row(SampleRow(values: [value])))
            guard case .accepted? = try connection.receive(ServerMessage.self, timeout: 2) else {
                return XCTFail("Missing row acknowledgement")
            }
        }
        let (first, a) = try register(.newSession), (second, b) = try register(.newSession)
        defer {
            first.close()
            second.close()
        }
        try await Task.sleep(for: .milliseconds(20))  // Registration refresh is complete.
        XCTAssertEqual(model.sessions[a.sessionID]?.charts[0].streams[0].sampleCount, 0)
        model.tick(a.sessionID, now: Date().addingTimeInterval(-60))
        try append(11, to: first)
        for _ in 0..<20 {
            if model.sessions[a.sessionID]?.charts[0].streams[0].sampleCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // No SessionWindow timer is subscribed in this isolated model. First-row
        // presentation therefore depends on the immediate ingestion refresh.
        XCTAssertEqual(model.sessions[a.sessionID]?.charts[0].streams[0].sampleCount, 1)
        let firstVisible = try XCTUnwrap(model.sessions[a.sessionID])
        XCTAssertGreaterThanOrEqual(
            model.domain(for: firstVisible).upperBound, try XCTUnwrap(firstVisible.charts[0].streams[0].lastSampleAt))
        try append(22, to: second)
        first.close()  // Abrupt EOF, no finish message.
        for _ in 0..<100 {
            if try model.store.snapshot(sessionID: a.sessionID)?.charts[0].streams[0].state == .disconnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ended = try XCTUnwrap(model.store.snapshot(sessionID: a.sessionID))
        XCTAssertEqual(ended.charts[0].streams[0].state, .disconnected)
        XCTAssertNotNil(ended.timeline.clockStoppedAt)
        XCTAssertEqual(try model.store.samples.query(streamID: a.streams[0].id).map(\.value), [11])
        try append(23, to: second)
        let (third, c) = try register(.newSession)
        defer { third.close() }
        try append(33, to: third)
        model.windowClosed(c.sessionID)
        if case .error(let closed)? = try third.receive(ServerMessage.self, timeout: 2) {
            XCTAssertEqual(closed.code, "session_closed")
        } else {
            XCTFail("Session close must identify why capture stopped")
        }
        XCTAssertEqual(try model.store.samples.query(streamID: c.streams[0].id).map(\.value), [33])
        try append(24, to: second)
        XCTAssertEqual(try model.store.samples.query(streamID: b.streams[0].id).map(\.value), [22, 23, 24])
        // Malformed protocol must return an error, never an acknowledgement.
        let invalid = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        defer { invalid.close() }
        try invalid.send(ClientMessage.row(SampleRow(values: [99])))
        guard case .error(let error)? = try invalid.receive(ServerMessage.self, timeout: 2) else {
            return XCTFail("Missing protocol error")
        }
        XCTAssertTrue(error.message.contains("hello"))
        let reopened = try PipePlotStore(databaseURL: database)
        XCTAssertEqual(try reopened.samples.count(streamID: a.streams[0].id), 1)
        XCTAssertEqual(try reopened.samples.count(streamID: b.streams[0].id), 3)
        XCTAssertEqual(try reopened.samples.count(streamID: c.streams[0].id), 1)
        print(
            "IPC_ACCEPTANCE abruptClientLoss=retained sessionClose=EOF otherSession=continued protocolError=truthful restart=retained"
        )
    }
    func testRealEventProtocolCreatesGuidesWithoutNumericStreams() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("events.sqlite")
        let socket = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8)).sock")
        let model = PipePlotAppModel(databaseURL: database, socketURL: socket)
        let connection = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        defer { connection.close() }
        try connection.send(ClientMessage.hello(HelloRequest(sink: .newSession, eventMode: true)))
        guard case .hello? = try connection.receive(ServerMessage.self, timeout: 2),
            case .ready(let ready)? = try connection.receive(ServerMessage.self, timeout: 2)
        else { return XCTFail("Event registration failed") }
        XCTAssertTrue(ready.streams.isEmpty)
        for text in ["Started α", "Pressure stable"] {
            try connection.send(ClientMessage.event(EventRow(text: text)))
            guard case .eventAccepted? = try connection.receive(ServerMessage.self, timeout: 2) else {
                return XCTFail("Missing event acknowledgement")
            }
        }
        let live = try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID))
        XCTAssertNil(live.timeline.clockStoppedAt)
        XCTAssertEqual(live.timeGuides.map(\.label), ["Started α", "Pressure stable"])
        XCTAssertTrue(live.charts.flatMap(\.streams).isEmpty)
        try connection.send(ClientMessage.finish(.eof))
        guard case .closed? = try connection.receive(ServerMessage.self, timeout: 2) else {
            return XCTFail("Missing EOF acknowledgement")
        }
        let reopened = try PipePlotStore(databaseURL: database)
        let saved = try XCTUnwrap(reopened.snapshot(sessionID: ready.sessionID))
        XCTAssertNotNil(saved.timeline.clockStoppedAt)
        XCTAssertEqual(saved.timeGuides.map(\.label), ["Started α", "Pressure stable"])
        XCTAssertTrue(saved.charts.flatMap(\.streams).isEmpty)
    }

    func testIsolatedServerStopsWhenItsModelIsReleased() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8)).sock")
        var model: PipePlotAppModel? = PipePlotAppModel(
            databaseURL: directory.appendingPathComponent("release.sqlite"), socketURL: socket)
        weak var reference = model
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        model = nil
        XCTAssertNil(reference)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

}
