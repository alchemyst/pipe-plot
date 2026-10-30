import Foundation
import Darwin
import PipePlotCore
import PipePlotTransport

private struct Options {
    var sink: ParsedSink = .target
    var names: [String]? = nil
    var unit: String? = nil
    var sourceLabel: String? = nil
    var fresh = false
    var listing = false
    var testColumns: Int?
    var event = false
}

private enum CLIError: Error, LocalizedError {
    case usage(String)
    case protocolFailure(String)
    var errorDescription: String? {
        switch self {
        case .usage(let message), .protocolFailure(let message): return message
        }
    }
}

private func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var positional: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help": throw CLIError.usage(usage)
        case "-c", "--new-chart": options.sink = .newChart
        case "-s", "--new-session": options.sink = .newSession
        case "--fresh", "--new-lines": options.fresh = true
        case "-n", "--name":
            index += 1
            guard index < arguments.count else { throw CLIError.usage("\(argument) needs a name\n\(usage)") }
            options.names = [arguments[index]]
        case "-u", "--unit":
            index += 1
            guard index < arguments.count else { throw CLIError.usage("\(argument) needs a unit\n\(usage)") }
            options.unit = arguments[index]
        case "--label":
            index += 1
            guard index < arguments.count else { throw CLIError.usage("--label needs a source label\n\(usage)") }
            options.sourceLabel = arguments[index]
        case "--test":
            var columns = 1
            if index + 1 < arguments.count, let parsed = Int(arguments[index + 1]) {
                columns = parsed
                index += 1
            }
            guard (1...32).contains(columns) else { throw CLIError.usage("--test column count must be between 1 and 32\n\(usage)") }
            options.testColumns = columns
        case "--event": options.event = true
        default:
            if argument == "ls" && arguments.count == 1 { options.listing = true }
            else if argument.hasPrefix("-") { throw CLIError.usage("unknown option: \(argument)\n\(usage)") }
            else { positional.append(argument) }
        }
        index += 1
    }
    if !positional.isEmpty {
        guard let number = Int(positional[0]), number > 0, (options.event ? positional.count == 1 : positional.count > 1) else {
            throw CLIError.usage("expected `pp <session-number> <line-name> [line-name ...]`\n\(usage)")
        }
        options.sink = .sessionNumber(number, lineNames: Array(positional.dropFirst()))
        if !options.event { options.names = Array(positional.dropFirst()) }
    }
    if options.event && (options.testColumns != nil || options.names != nil || options.unit != nil) {
        throw CLIError.usage("--event cannot be combined with numeric test, line naming, or unit options\n\(usage)")
    }
    return options
}

private let usage = """
Usage:
  sampler | pp                         attach to the target chart
  sampler | pp -n memory -u MiB        name a single line and set its unit hint
  sampler | pp -c                      create and target a chart
  sampler | pp -s                      create and target a session
  producer | pp --event                add each input line as a session time guide
  producer | pp --event 2              attach events to session 2
  sampler | pp 2 memory [free ...]     attach named lines in session 2
  pp ls                                list sessions, charts and lines
  pp --test [columns]                  generate one sine sample per second (default 1)
  Options: --fresh starts a new group; --label LABEL describes the sampler.
"""

// The server answers hello immediately, but valid sampler registration can wait
// behind serialized store work. Bound the wait without treating a quiet live
// producer as a timeout (the sampler's idle loop does not call this helper).
private let samplerReadyTimeout: TimeInterval = 30

private func runEvents(_ options: Options) throws {
    let connection = try connectOrLaunch()
    defer { connection.close() }
    let intent = options.sink.asSinkIntent(fresh: options.fresh)
    try connection.send(ClientMessage.hello(HelloRequest(clientLabel: "pp --event", sink: intent, eventMode: true)))
    var attachment: AttachmentID?
    while attachment == nil {
        switch try readServerMessage(connection, timeout: samplerReadyTimeout) {
        case .hello: continue
        case .ready(let reply): attachment = reply.attachmentID
        case .error(let error): throw CLIError.protocolFailure(error.message)
        case .closed: throw CLIError.protocolFailure("PipePlot closed the event connection")
        default: continue
        }
    }
    var parser = EventInputParser()
    func consume(_ results: [EventParseResult]) throws {
        for result in results {
            switch result {
            case .rejected(let message): fputs("pp: rejected event: \(message)\n", stderr)
            case .event(let text):
                try connection.send(ClientMessage.event(EventRow(text: text, timestamp: Date())))
                switch try readServerMessage(connection) {
                case .eventAccepted: break
                case .error(let error): throw CLIError.protocolFailure(error.message)
                case .closed: throw CLIError.protocolFailure("event session closed")
                default: throw CLIError.protocolFailure("unexpected response to event")
                }
            }
        }
    }
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        var descriptors = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: connection.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
        ]
        let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
        if ready < 0 { if errno == EINTR { continue }; throw SocketError.system("poll", errno) }
        let socketEvents = descriptors[1].revents
        if socketEvents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            guard let message = try connection.receive(ServerMessage.self, timeout: 0.1) else {
                throw CLIError.protocolFailure("PipePlot disconnected while reading events")
            }
            switch message {
            case .closed: throw CLIError.protocolFailure("event session closed")
            case .error(let error): throw CLIError.protocolFailure(error.message)
            case .hello, .ready, .eventAccepted, .accepted, .snapshot, .listing: break
            }
        }
        if descriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) == 0 { continue }
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 { if errno == EINTR { continue }; throw SocketError.system("read stdin", errno) }
        if count == 0 { break }
        try consume(parser.append(Data(buffer[..<count])))
    }
    try consume(parser.finish())
    try connection.send(ClientMessage.finish(.eof))
    while true {
        switch try readServerMessage(connection) {
        case .closed: return
        case .eventAccepted, .accepted: continue
        default: return
        }
    }
}

private struct SineSampler {
    let columns: Int
    let start = Date()

    func row() -> String {
        let elapsed = Date().timeIntervalSince(start)
        let values = (0..<columns).map { index -> String in
            let period = 18.0 + Double(index) * 7.0
            let phase = Double(index) * .pi / 4
            let offset = Double(index) * 1.5
            let value = offset + sin(2 * .pi * elapsed / period + phase)
            return String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return values.joined(separator: " ") + "\n"
    }
}

private final class InterruptMonitor {
    private let lock = NSLock()
    private var didInterrupt = false
    private let source: DispatchSourceSignal

    init() {
        _ = Darwin.signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source = signalSource
        signalSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.didInterrupt = true; self.lock.unlock()
        }
        signalSource.resume()
    }

    var interrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return didInterrupt
    }

    deinit {
        source.cancel()
        _ = Darwin.signal(SIGINT, SIG_DFL)
    }
}

private func connectOrLaunch() throws -> SocketConnection {
    do { return try PipePlotLocations.connect(timeout: 0.35) }
    catch {
        try PipePlotLocations.launchInstalledApp()
        return try PipePlotLocations.connect(timeout: 12)
    }
}

private func readServerMessage(_ connection: SocketConnection, timeout: TimeInterval = 30) throws -> ServerMessage {
    guard let message = try connection.receive(ServerMessage.self, timeout: timeout) else { throw CLIError.protocolFailure("PipePlot closed the connection unexpectedly") }
    if case .error(let problem) = message { throw CLIError.protocolFailure(problem.message) }
    return message
}

private func sendCommand(_ command: AppCommand) throws {
    let connection = try connectOrLaunch()
    defer { connection.close() }
    try connection.send(ClientMessage.hello(HelloRequest(clientLabel: "pp")))
    try connection.send(ClientMessage.command(command))
    while true {
        switch try readServerMessage(connection) {
        case .hello: continue
        case .listing(let listing): printListing(listing); return
        case .snapshot(let snapshot): printSnapshot(snapshot); return
        case .closed: return
        default: throw CLIError.protocolFailure("Unexpected response to command")
        }
    }
}

private func fetchListing() throws -> Listing {
    let connection = try connectOrLaunch()
    defer { connection.close() }
    try connection.send(ClientMessage.hello(HelloRequest(clientLabel: "pp")))
    try connection.send(ClientMessage.command(.list))
    while true {
        switch try readServerMessage(connection) {
        case .hello: continue
        case .listing(let listing): return listing
        default: throw CLIError.protocolFailure("Unexpected response to list command")
        }
    }
}

private func printListing(_ listing: Listing) {
    if listing.sessions.isEmpty { print("No sessions."); return }
    for session in listing.sessions {
        print("Session \(session.number): \(session.title)\(session.isOpen ? "" : " [closed]")")
        for (position, chart) in session.charts.enumerated() {
            let target = chart.id == listing.targetChartID ? "  [target]" : ""
            print("  Chart \(position + 1): \(chart.title)\(target)")
            for stream in chart.streams {
                print("    \(stream.name)  \(stream.sampleCount) samples  \(stream.state.rawValue)")
            }
        }
    }
}

private func printSnapshot(_ session: SessionSnapshot) {
    printListing(Listing(sessions: [session], targetChartID: session.charts.first(where: \.isTarget)?.id))
}

private func runSampler(_ options: Options) throws {
    let startedAt = Date()
    if options.listing { try sendCommand(.list); return }
    let parser = InputParser()
    let interrupt = InterruptMonitor()
    let sine = options.testColumns.map(SineSampler.init(columns:))
    var readyConnection: SocketConnection? = nil
    var columnCount: Int? = nil
    var messageCount = 0
    var diagnostics = 0
    // Invalid input can arrive before the parser has enough information to
    // register an attachment. Retain only a small prefix until registration.
    var pendingRejections: [InputRejection] = []
    var pendingRejectionTotals: [String: (kind: ParseIssue.Kind, count: UInt64, lastLine: UInt64)] = [:]

    func reportBounded(_ issue: ParseIssue) {
        reportBounded(message: issue.message, lineNumber: issue.lineNumber)
    }

    func reportBounded(message: String, lineNumber: UInt64) {
        if diagnostics < 8 { fputs("pp: row \(lineNumber): \(message)\n", stderr) }
        diagnostics += 1
        if diagnostics == 9 { fputs("pp: further invalid rows suppressed\n", stderr) }
    }

    func connectForRows(_ width: Int) throws -> SocketConnection {
        guard options.names == nil || options.names!.count == width else {
            throw CLIError.usage("provided \(options.names!.count) line name(s), but input has \(width) columns")
        }
        let connection = try connectOrLaunch()
        let names = options.names
        let request = SamplerIntent(columnCount: width, sourceLabel: options.sourceLabel, requestedNames: names, unitHint: options.unit, startedAt: startedAt)
        try connection.send(ClientMessage.hello(HelloRequest(clientLabel: "pp", sink: options.sink.asSinkIntent(fresh: options.fresh), sampler: request)))
        var gotHello = false
        while true {
            switch try readServerMessage(connection, timeout: samplerReadyTimeout) {
            case .hello: gotHello = true
            case .ready(let ready):
                guard gotHello else { throw CLIError.protocolFailure("PipePlot sent ready before protocol hello") }
                if ready.streams.count != width { throw CLIError.protocolFailure("PipePlot acknowledged \(ready.streams.count) streams for \(width) columns") }
                if ready.continued { fputs("pp: continuing previous stream group\n", stderr) }
                for rejection in pendingRejections { try connection.send(ClientMessage.rejected(rejection)) }
                for total in pendingRejectionTotals.values {
                    let summary = InputRejection(kind: total.kind,
                                                 lineNumber: total.lastLine,
                                                 message: "\(total.count) additional \(total.kind.rawValue) input rows rejected before registration",
                                                 rejectedCount: total.count)
                    try connection.send(ClientMessage.rejected(summary))
                }
                pendingRejections.removeAll(keepingCapacity: true)
                pendingRejectionTotals.removeAll(keepingCapacity: true)
                return connection
            case .closed: throw CLIError.protocolFailure("PipePlot closed during sampler registration")
            default: throw CLIError.protocolFailure("Unexpected response during sampler registration")
            }
        }
    }

    func sendRow(_ row: SampleRow) throws {
        if columnCount == nil {
            columnCount = row.values.count
            readyConnection = try connectForRows(row.values.count)
            parser.expectedColumnCount = row.values.count
        }
        guard row.values.count == columnCount else {
            reportBounded(message: "expected \(columnCount!) columns, got \(row.values.count)", lineNumber: row.sequence)
            if let connection = readyConnection {
                try connection.send(ClientMessage.rejected(InputRejection(kind: .wrongColumnCount,
                                                                            lineNumber: row.sequence,
                                                                            message: "expected \(columnCount!) columns, got \(row.values.count)")))
            }
            return
        }
        guard let connection = readyConnection else { return }
        try connection.send(ClientMessage.row(row))
        switch try readServerMessage(connection) {
        case .accepted: messageCount += 1
        case .closed: throw CLIError.protocolFailure("PipePlot closed before accepting a sample")
        default: throw CLIError.protocolFailure("Unexpected response while sending a sample")
        }
    }

    func consume(_ events: [ParseEvent]) throws {
        for event in events {
            switch event {
            case .row(let row): try sendRow(row)
            case .rejected(let issue):
                reportBounded(issue)
                let rejection = InputRejection(issue)
                if let connection = readyConnection { try connection.send(ClientMessage.rejected(rejection)) }
                else if pendingRejections.count < 8 { pendingRejections.append(rejection) }
                else {
                    let key = issue.kind.rawValue
                    let prior = pendingRejectionTotals[key]
                    pendingRejectionTotals[key] = (issue.kind, (prior?.count ?? 0) + 1, issue.lineNumber)
                }
            }
        }
    }

    let inputDescriptor = FileHandle.standardInput.fileDescriptor
    var inputEnded = false
    var nextTestSample = Date()
    while !inputEnded && !interrupt.interrupted {
        if let sine, Date() >= nextTestSample {
            try consume(parser.append(Data(sine.row().utf8)))
            nextTestSample = Date().addingTimeInterval(1)
            continue
        }
        var descriptors: [pollfd] = []
        let inputIndex: Int? = sine == nil ? descriptors.count : nil
        if inputIndex != nil { descriptors.append(pollfd(fd: inputDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
        let socketIndex: Int?
        if let connection = readyConnection {
            socketIndex = descriptors.count
            descriptors.append(pollfd(fd: connection.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
        } else {
            socketIndex = nil
        }
        let timeout: Int32 = sine != nil ? 100 : (readyConnection == nil ? -1 : 250)
        let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), timeout)
        if result < 0 {
            if errno == EINTR { continue }
            throw SocketError.system("poll", errno)
        }
        if let socketIndex {
            let socketEvents = descriptors[socketIndex].revents
            if socketEvents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                guard let connection = readyConnection else { continue }
                let message = try readServerMessage(connection)
                switch message {
                case .accepted: break // no row is currently awaiting an acknowledgement
                case .closed: throw CLIError.protocolFailure("PipePlot disconnected while waiting for input")
                case .hello, .ready: break
                default: throw CLIError.protocolFailure("Unexpected PipePlot message while waiting for input")
                }
                if socketEvents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    throw CLIError.protocolFailure("PipePlot disconnected while waiting for input")
                }
            }
        }
        if let inputIndex, descriptors[inputIndex].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(inputDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("read stdin", errno)
            }
            if count == 0 { inputEnded = true }
            else { try consume(parser.append(Data(buffer[..<count]))) }
        }
    }
    try consume(parser.finish())
    guard let connection = readyConnection else { return }
    defer { connection.close() }
    try connection.send(ClientMessage.finish(interrupt.interrupted ? .interrupted : .eof))
    while true {
        switch try readServerMessage(connection) {
        case .closed: return
        case .accepted: continue
        default: throw CLIError.protocolFailure("Unexpected response while finishing sampler")
        }
    }
}

private enum ParsedSink {
    case target, newChart, newSession
    case sessionNumber(Int, lineNames: [String])
    case explicitSession(UUID, lineNames: [String])
    func asSinkIntent(fresh: Bool = false) -> SinkIntent {
        switch self {
        case .target: return fresh ? .fresh : .target
        case .newChart: return .newChart
        case .newSession: return .newSession
        case .sessionNumber: return .target // resolved before sampler registration
        case .explicitSession(let id, let names): return .session(sessionID: id, lineNames: names)
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") { print(usage); exit(EXIT_SUCCESS) }
    let options = try parseOptions(arguments)
    if case .sessionNumber(let number, let names) = options.sink {
        let listing = try fetchListing()
        guard let session = listing.sessions.first(where: { $0.number == number }) else {
            throw CLIError.protocolFailure("unknown session \(number)")
        }
        // Resolve the public small integer to its stable UUID before registration.
        var explicit = options
        if options.event {
            explicit.sink = .explicitSession(session.id, lineNames: [])
            try runEvents(explicit)
        } else {
            explicit.sink = .explicitSession(session.id, lineNames: names)
            try runSampler(explicit)
        }
    } else if options.event {
        try runEvents(options)
    } else {
        try runSampler(options)
    }
} catch {
    fputs("pp: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
