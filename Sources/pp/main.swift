import Foundation
import PipePlotCore
import PipePlotTransport

private struct Options {
    var sink: ParsedSink = .target
    var names: [String]? = nil
    var unit: String? = nil
    var sourceLabel: String? = nil
    var fresh = false
    var listing = false
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
        default:
            if argument == "ls" && arguments.count == 1 { options.listing = true }
            else if argument.hasPrefix("-") { throw CLIError.usage("unknown option: \(argument)\n\(usage)") }
            else { positional.append(argument) }
        }
        index += 1
    }
    if !positional.isEmpty {
        guard let number = Int(positional[0]), number > 0, positional.count > 1 else {
            throw CLIError.usage("expected `pp <session-number> <line-name> [line-name ...]`\n\(usage)")
        }
        options.sink = .sessionNumber(number, lineNames: Array(positional.dropFirst()))
        options.names = Array(positional.dropFirst())
    }
    return options
}

private let usage = """
Usage:
  sampler | pp                         attach to the target chart
  sampler | pp -n memory -u MiB        name a single line and set its unit hint
  sampler | pp -c                      create and target a chart
  sampler | pp -s                      create and target a session
  sampler | pp 2 memory [free ...]     attach named lines in session 2
  pp ls                                list sessions, charts and lines
  Options: --fresh starts a new group; --label LABEL describes the sampler.
"""

private func connectOrLaunch() throws -> SocketConnection {
    do { return try PipePlotLocations.connect(timeout: 0.35) }
    catch {
        try PipePlotLocations.launchInstalledApp()
        return try PipePlotLocations.connect(timeout: 12)
    }
}

private func readServerMessage(_ connection: SocketConnection) throws -> ServerMessage {
    guard let message = try connection.receive(ServerMessage.self) else { throw CLIError.protocolFailure("PipePlot closed the connection unexpectedly") }
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
    if options.listing { try sendCommand(.list); return }
    let parser = InputParser()
    var readyConnection: SocketConnection? = nil
    var columnCount: Int? = nil
    var messageCount = 0
    var diagnostics = 0

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
        let request = SamplerIntent(columnCount: width, sourceLabel: options.sourceLabel, requestedNames: names, unitHint: options.unit)
        try connection.send(ClientMessage.hello(HelloRequest(clientLabel: "pp", sink: options.sink.asSinkIntent(fresh: options.fresh), sampler: request)))
        var gotHello = false
        while true {
            switch try readServerMessage(connection) {
            case .hello: gotHello = true
            case .ready(let ready):
                guard gotHello else { throw CLIError.protocolFailure("PipePlot sent ready before protocol hello") }
                if ready.streams.count != width { throw CLIError.protocolFailure("PipePlot acknowledged \(ready.streams.count) streams for \(width) columns") }
                if ready.continued { fputs("pp: continuing previous stream group\n", stderr) }
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
            case .rejected(let issue): reportBounded(issue)
            }
        }
    }

    let input = FileHandle.standardInput
    while let chunk = try input.read(upToCount: 16 * 1024), !chunk.isEmpty {
        try consume(parser.append(chunk))
    }
    try consume(parser.finish())
    guard let connection = readyConnection else { return }
    defer { connection.close() }
    try connection.send(ClientMessage.finish(.eof))
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
        explicit.sink = .explicitSession(session.id, lineNames: names)
        try runSampler(explicit)
    } else {
        try runSampler(options)
    }
} catch {
    fputs("pp: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
