import Darwin
import Foundation
import PipePlotCore
import PipePlotTransport
import XCTest

final class CLIContractTests: XCTestCase {
    func testNumericRoutingAndLineNames() throws {
        let fixture = try CLIFixture()
        let first = try fixture.store.createSession()
        try assertCapture(fixture.run(["-n", "memory", "-u", "MiB"], input: "-2e1\n3.5\n"))
        try assertCapture(fixture.run(["-c", "-n", "pressure"], input: "2\n"))
        try assertCapture(fixture.run(["--new-session", "--name", "flow"], input: "5\n"))
        try assertCapture(fixture.run(["\(first.number)", "used space", "free"], input: "1\t2\n"))

        let sessions = try fixture.store.listSessions()
        XCTAssertEqual(sessions.count, 2)
        let original = try XCTUnwrap(sessions.first { $0.id == first.id })
        XCTAssertEqual(original.charts.count, 2)
        XCTAssertEqual(original.charts[0].streams.map(\.name), ["memory"])
        XCTAssertEqual(original.charts[0].streams.first?.unitHint, "MiB")
        XCTAssertEqual(original.charts[0].streams.first?.sampleCount, 2)
        XCTAssertEqual(original.charts[1].streams.map(\.name), ["pressure", "used space", "free"])
        XCTAssertEqual(original.charts[1].streams.map(\.sampleCount), [1, 1, 1])
        let second = try XCTUnwrap(sessions.first { $0.id != first.id })
        XCTAssertEqual(second.charts.flatMap(\.streams).map(\.name), ["flow"])

        let listing = try fixture.run(["ls"])
        XCTAssertEqual(listing.status, 0)
        XCTAssertEqual(listing.stderr, "")
        XCTAssertTrue(listing.stdout.contains("used space  1 samples  ended"), listing.stdout)
    }

    func testEventRoutingCreatesGuidesWithoutStreams() throws {
        let fixture = try CLIFixture()
        let first = try fixture.store.createSession()
        try assertCapture(fixture.run(["--event"], input: "started\n"))
        try assertCapture(fixture.run(["--event", "--new-chart"], input: "pressure stable\r\n"))
        try assertCapture(fixture.run(["--event", "-s"], input: "new session"))
        try assertCapture(fixture.run(["--event", "\(first.number)"], input: "explicit session\n"))

        let sessions = try fixture.store.listSessions()
        XCTAssertEqual(sessions.count, 2)
        let original = try XCTUnwrap(sessions.first { $0.id == first.id })
        XCTAssertEqual(original.charts.count, 2)
        XCTAssertEqual(Set(original.timeGuides.map(\.label)), ["started", "pressure stable", "explicit session"])
        let second = try XCTUnwrap(sessions.first { $0.id != first.id })
        XCTAssertEqual(second.timeGuides.map(\.label), ["new session"])
        XCTAssertTrue(sessions.flatMap(\.charts).flatMap(\.streams).isEmpty)
    }

    func testBuiltInNumericProducers() throws {
        let fixture = try CLIFixture()
        try assertCapture(
            fixture.run(
                ["--test", "2", "-s"],
                interruptWhen: {
                    try fixture.store.listSessions().first?.charts.first?.streams.last?.sampleCount == 1
                }))
        try assertCapture(
            fixture.run(
                ["--watch", "printf 42", "--interval", "5", "--new-chart", "-n", "watched"],
                interruptWhen: {
                    let stream = try fixture.store.listSessions().first?.charts.last?.streams.first
                    return stream?.name == "watched" && stream?.sampleCount == 1
                }))
        let session = try XCTUnwrap(fixture.store.listSessions().first)
        XCTAssertEqual(session.charts.map { $0.streams.map(\.sampleCount) }, [[1, 1], [1]])
        XCTAssertEqual(session.charts.last?.streams.first?.name, "watched")
    }

    func testHelpAndInvalidArgumentsWithoutServer() throws {
        let fixture = try CLIFixture(startServer: false)
        for flag in ["-h", "--help"] {
            let result = try fixture.run([flag])
            XCTAssertEqual(result.status, 0)
            XCTAssertTrue(result.stdout.hasPrefix("Usage:"))
            XCTAssertEqual(result.stderr, "")
        }
        let invalid: [([String], String)] = [
            (["--bad-option"], "unknown option"),
            (["-n"], "needs a name"), (["--name", "-s"], "needs a name"),
            (["-u"], "needs a unit"), (["--unit", "-c"], "needs a unit"),
            (["--label"], "needs a source label"), (["--label", "--fresh"], "needs a source label"),
            (["--watch"], "needs a shell command"), (["--watch", "--fresh"], "needs a shell command"),
            (["--watch", "true", "--interval"], "--interval must be"),
            (["--test", "33"], "--test column count"),
            (["--event", "--test"], "--event cannot be combined"),
            (["--event", "2", "line"], "expected `pp"),
            (["2"], "expected `pp"),
            (["2", "one", "two"], "provided 2 line name(s), but input has 1 columns"),
        ]
        for (arguments, diagnostic) in invalid {
            let result = try fixture.run(arguments, input: "1\n")
            XCTAssertEqual(result.status, 1, "\(arguments)")
            XCTAssertEqual(result.stdout, "", "\(arguments)")
            XCTAssertTrue(result.stderr.contains(diagnostic), "\(arguments): \(result.stderr)")
        }
        XCTAssertTrue(try fixture.store.listSessions().isEmpty)
    }

    func testSilentPipeRecoversWhenFirstRowArrives() throws {
        let fixture = try CLIFixture()
        let result = try fixture.runPipe(["-n", "late"]) { input, readStderr, _ in
            try waitForDiagnostic("no bytes have arrived", readStderr)
            XCTAssertTrue(try fixture.store.listSessions().isEmpty)
            try input.write(contentsOf: Data("42\n".utf8))
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 1)
        XCTAssertEqual(try fixture.store.listSessions().first?.charts.first?.streams.first?.sampleCount, 1)
    }

    func testPartialLineWaitsForCompletion() throws {
        let fixture = try CLIFixture()
        let result = try fixture.runPipe([]) { input, readStderr, _ in
            try input.write(contentsOf: Data("4".utf8))
            try waitForDiagnostic("data has arrived", readStderr)
            XCTAssertTrue(try fixture.store.listSessions().isEmpty)
            try input.write(contentsOf: Data("2\n".utf8))
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 1)
        XCTAssertEqual(try fixture.store.listSessions().first?.charts.first?.streams.first?.sampleCount, 1)
    }

    func testRejectedInputWhilePipeRemainsOpen() throws {
        let fixture = try CLIFixture()
        let result = try fixture.runPipe([]) { input, readStderr, _ in
            try input.write(contentsOf: Data(String(repeating: "bad\n", count: 100).utf8))
            try waitForDiagnostic("input rows have been rejected", readStderr)
            XCTAssertTrue(try fixture.store.listSessions().isEmpty)
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 11)
        XCTAssertTrue(result.stderr.contains("further invalid rows suppressed"))
        XCTAssertTrue(result.stderr.contains("stdin ended without a usable numeric row"))
    }

    func testEmptyEOF() throws {
        let fixture = try CLIFixture(startServer: false)
        let result = try fixture.runPipe([]) { _, _, _ in }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "pp: stdin ended without any input\n")
    }

    func testHealthyPipeDoesNotReportWaiting() throws {
        let fixture = try CLIFixture()
        try assertCapture(
            fixture.runPipe([]) { input, _, _ in
                try input.write(contentsOf: Data("1\n".utf8))
                Thread.sleep(forTimeInterval: 2.5)
                XCTAssertEqual(try fixture.store.listSessions().first?.charts.first?.streams.first?.sampleCount, 1)
            })
    }

    func testMalformedNumericRowsAcrossWrites() throws {
        let fixture = try CLIFixture()
        let mib = 1024 * 1024
        let result = try fixture.runPipe([]) { input, readStderr, pid in
            func write(_ text: String) throws { try input.write(contentsOf: Data(text.utf8)) }
            try write("1\t2\r")
            Thread.sleep(forTimeInterval: 0.03)
            XCTAssertTrue(try fixture.store.listSessions().isEmpty)
            try write("\n3")
            try write("\0 4\nNa")
            try write("N 6\n7 in")
            try write("f\n")
            try waitForDiagnostic("row 4: NaN and infinity", readStderr)

            // Keep the row open after writing far more than the parser limit.
            // The producer reuses its block, and the child must discard excess bytes.
            let before = try residentBytes(pid)
            let block = Data(repeating: 0x20, count: 64 * 1024)
            try write("8 9")
            for _ in 0..<(32 * mib / block.count) { try input.write(contentsOf: block) }
            let after = try residentBytes(pid)
            XCTAssertLessThan(after, before + UInt64(8 * mib))
            try write("\n10 11 12\n13")
            try write(" 14\n15 16")
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(
            result.stderr.split(separator: "\n").map(String.init),
            [
                "pp: row 2: input row contains a NUL byte",
                "pp: row 3: NaN and infinity are not accepted",
                "pp: row 4: NaN and infinity are not accepted",
                "pp: row 5: input row exceeds 64 KiB",
                "pp: row 6: expected 2 columns, got 3",
            ])

        let session = try XCTUnwrap(fixture.store.listSessions().first)
        XCTAssertEqual(session.rejectedLineCount, 5)
        let streams = try XCTUnwrap(session.charts.first).streams
        XCTAssertEqual(streams.map(\.state), [.ended, .ended])
        let stored = try streams.map { try fixture.store.samples.query(streamID: $0.id) }
        XCTAssertEqual(stored.map { $0.map(\.value) }, [[1, 13, 15], [2, 14, 16]])
    }

    private func residentBytes(_ pid: pid_t) throws -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return try XCTUnwrap(read == size ? info.pti_resident_size : nil, "Could not read pp resident memory")
    }

    private func waitForDiagnostic(_ diagnostic: String, _ readStderr: () throws -> String) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            if try readStderr().contains(diagnostic) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Missing diagnostic: \(diagnostic). Got: \(try readStderr())")
    }

    private func assertCapture(_ result: CLIResult) {
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }
}

private struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class CLIFixture {
    private let directory: URL
    private let server: UnixSocketServer
    let store: PipePlotStore

    init(startServer: Bool = true) throws {
        directory = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let store = try PipePlotStore(databaseURL: directory.appending(path: "test.sqlite"))
            self.store = store
            server = UnixSocketServer(socketURL: directory.appending(path: "pp.sock")) { connection in
                do { try Self.handle(connection, store: store) } catch {
                    try? connection.send(
                        ServerMessage.error(ProtocolError(code: "test", message: error.localizedDescription)))
                }
            }
            if startServer { try server.start() }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func run(_ arguments: [String], input: String = "", interruptWhen: (() throws -> Bool)? = nil) throws -> CLIResult {
        let inputURL = directory.appending(path: "stdin")
        try Data(input.utf8).write(to: inputURL)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        defer { try? stdin.close() }
        return try runProcess(arguments, stdin: stdin, interruptWhen: interruptWhen) { _, _ in }
    }

    func runPipe(
        _ arguments: [String], produce: (FileHandle, () throws -> String, pid_t) throws -> Void
    ) throws -> CLIResult {
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return try runProcess(arguments, stdin: input) { stderrURL, pid in
            try produce(input.fileHandleForWriting, { try String(contentsOf: stderrURL, encoding: .utf8) }, pid)
            try input.fileHandleForWriting.close()
        }
    }

    private func runProcess(
        _ arguments: [String], stdin: Any, interruptWhen: (() throws -> Bool)? = nil,
        afterLaunch: (URL, pid_t) throws -> Void
    ) throws -> CLIResult {
        let stdoutURL = directory.appending(path: "stdout")
        let stderrURL = directory.appending(path: "stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        func readStderr() throws -> String { try String(contentsOf: stderrURL, encoding: .utf8) }
        let process = Process()
        process.executableURL = Bundle(for: CLIContractTests.self).bundleURL.deletingLastPathComponent()
            .appending(path: "pp")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PIPEPLOT_SOCKET": server.socketURL.path], uniquingKeysWith: { _, isolated in isolated })
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Bound fixture writes too, even if a regressed child stops draining its pipe.
        let watchdog = DispatchWorkItem {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try afterLaunch(stderrURL, process.processIdentifier)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var interruptSent = false
        while process.isRunning && clock.now < deadline {
            if !interruptSent, try interruptWhen?() == true {
                process.interrupt()
                interruptSent = true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            XCTFail("pp subprocess timed out: \(arguments)")
        }
        process.waitUntilExit()
        return CLIResult(
            status: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8), stderr: try readStderr())
    }

    private static func handle(_ connection: SocketConnection, store: PipePlotStore) throws {
        guard case .hello(let request) = try connection.receive(ClientMessage.self, timeout: 5) else { return }
        try connection.send(ServerMessage.hello(HelloReply(appInstanceID: UUID())))
        let ready: ReadyReply?
        if request.eventMode {
            ready = try store.registerEventConnection(intent: request.sink)
        } else if let sampler = request.sampler {
            ready = try store.registerSampler(intent: request.sink, sampler: sampler)
        } else {
            ready = nil
        }
        if let ready { try connection.send(ServerMessage.ready(ready)) }
        while let message = try connection.receive(ClientMessage.self, timeout: 10) {
            switch message {
            case .command(.list):
                try connection.send(
                    ServerMessage.listing(
                        Listing(sessions: store.listSessions(), targetChartID: store.currentTarget())))
                return
            case .row(let row):
                _ = try store.append(row, to: XCTUnwrap(ready).attachmentID)
                try connection.send(ServerMessage.accepted(AcceptedRow(sequence: row.sequence)))
            case .event(let row):
                try store.appendEvent(row.text, at: row.timestamp, to: XCTUnwrap(ready).attachmentID)
                try connection.send(ServerMessage.eventAccepted)
            case .rejected(let rejection):
                try store.recordRejectedInput(rejection, to: XCTUnwrap(ready).attachmentID)
            case .finish(let reason):
                let attachment = try XCTUnwrap(ready).attachmentID
                if request.eventMode {
                    try store.finishEventConnection(attachment, reason: reason)
                } else {
                    try store.finishAttachment(attachment, reason: reason)
                }
                try connection.send(ServerMessage.closed)
                return
            default:
                XCTFail("Unexpected fixture message: \(message)")
                return
            }
        }
    }
}
