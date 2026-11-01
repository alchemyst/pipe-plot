import Foundation
import XCTest
import PipePlotCore
import PipePlotTransport
@testable import PipePlotApp

@MainActor final class IPCFailureAcceptanceTests: XCTestCase {
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
                  case .ready(let ready)? = try connection.receive(ServerMessage.self, timeout: 2) else { throw NSError(domain: "acceptance", code: 1) }
            return (connection, ready)
        }
        func append(_ value: Double, to connection: SocketConnection) throws {
            try connection.send(ClientMessage.row(SampleRow(values: [value])))
            guard case .accepted? = try connection.receive(ServerMessage.self, timeout: 2) else { return XCTFail("Missing row acknowledgement") }
        }
        let (first, a) = try register(.newSession), (second, b) = try register(.newSession)
        defer { first.close(); second.close() }
        try await Task.sleep(for: .milliseconds(20)) // Registration refresh is complete.
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
        XCTAssertGreaterThanOrEqual(model.domain(for: firstVisible).upperBound, try XCTUnwrap(firstVisible.charts[0].streams[0].lastSampleAt))
        try append(22, to: second)
        first.close() // Abrupt EOF, no finish message.
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
        } else { XCTFail("Session close must identify why capture stopped") }
        XCTAssertEqual(try model.store.samples.query(streamID: c.streams[0].id).map(\.value), [33])
        try append(24, to: second)
        XCTAssertEqual(try model.store.samples.query(streamID: b.streams[0].id).map(\.value), [22,23,24])
        // Malformed protocol must return an error, never an acknowledgement.
        let invalid = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        defer { invalid.close() }
        try invalid.send(ClientMessage.row(SampleRow(values: [99])))
        guard case .error(let error)? = try invalid.receive(ServerMessage.self, timeout: 2) else { return XCTFail("Missing protocol error") }
        XCTAssertTrue(error.message.contains("hello"))
        let reopened = try PipePlotStore(databaseURL: database)
        XCTAssertEqual(try reopened.samples.count(streamID: a.streams[0].id), 1)
        XCTAssertEqual(try reopened.samples.count(streamID: b.streams[0].id), 3)
        XCTAssertEqual(try reopened.samples.count(streamID: c.streams[0].id), 1)
        print("IPC_ACCEPTANCE abruptClientLoss=retained sessionClose=EOF otherSession=continued protocolError=truthful restart=retained")
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
              case .ready(let ready)? = try connection.receive(ServerMessage.self, timeout: 2) else { return XCTFail("Event registration failed") }
        XCTAssertTrue(ready.streams.isEmpty)
        for text in ["Started α", "Pressure stable"] {
            try connection.send(ClientMessage.event(EventRow(text: text)))
            guard case .eventAccepted? = try connection.receive(ServerMessage.self, timeout: 2) else { return XCTFail("Missing event acknowledgement") }
        }
        let live = try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID))
        XCTAssertNil(live.timeline.clockStoppedAt)
        XCTAssertEqual(live.timeGuides.map(\.label), ["Started α", "Pressure stable"])
        XCTAssertTrue(live.charts.flatMap(\.streams).isEmpty)
        try connection.send(ClientMessage.finish(.eof))
        guard case .closed? = try connection.receive(ServerMessage.self, timeout: 2) else { return XCTFail("Missing EOF acknowledgement") }
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
        var model: PipePlotAppModel? = PipePlotAppModel(databaseURL: directory.appendingPathComponent("release.sqlite"), socketURL: socket)
        weak var reference = model
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        model = nil
        XCTAssertNil(reference)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

}
