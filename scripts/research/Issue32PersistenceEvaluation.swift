import Darwin
import Foundation

// Experimental issue #32 harness. Invoke through evaluate-issue32.sh; all stores are temporary.

@main
struct PipePlot32Evaluation {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        precondition(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.sqlite")
        switch mode {
        case "measure":
            let rows = Int(CommandLine.arguments[3])!
            let extra = Int(CommandLine.arguments[4])!
            let width = CommandLine.arguments.count > 5 ? Int(CommandLine.arguments[5])! : 1
            let split = try PipePlotStore(databaseURL: url)
            let base = try split.createSession()
            for _ in 0..<extra { _ = try split.createSession() }
            let ready = try split.registerSampler(
                intent: .session(sessionID: base.id, lineNames: []), sampler: SamplerIntent(columnCount: width))
            let metadata = url.appendingPathExtension("metadata.json")
            let initialBytes = (try Data(contentsOf: metadata)).count
            let start = ContinuousClock.now
            for index in 0..<rows {
                let values = (0..<width).map { Double(index + $0) }
                try split.append(
                    SampleRow(
                        timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), values: values),
                    to: ready.attachmentID)
            }
            let elapsed = start.duration(to: .now)
            let finalBytes = (try Data(contentsOf: metadata)).count
            let count = try split.samples.count(streamID: ready.streams[0].id)
            print(
                "split rows=\(rows) sessions=\(extra + 1) charts=\(extra + 1) streams=\(width) guides=0 elapsed=\(elapsed) metadata_initial=\(initialBytes) metadata_final=\(finalBytes) sample_count_per_stream=\(count)"
            )
            let coreURL = directory.appendingPathComponent("core.sqlite")
            let core = try SampleStore(databaseURL: coreURL)
            let ids = (0..<width).map { _ in UUID() }
            let coreStart = ContinuousClock.now
            for index in 0..<rows {
                let values = (0..<width).map { Double(index + $0) }
                _ = try core.append(
                    values: values, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                    to: ids, segmentID: "segment")
            }
            print(
                "core rows=\(rows) streams=\(width) elapsed=\(coreStart.duration(to: .now)) sample_count_per_stream=\(try core.count(streamID: ids[0]))"
            )
        case "events":
            let eventCount = Int(CommandLine.arguments[3])!
            let store = try PipePlotStore(databaseURL: url)
            let session = try store.createSession()
            let numeric = try store.registerSampler(
                intent: .session(sessionID: session.id, lineNames: []), sampler: SamplerIntent(columnCount: 1))
            let events = try store.registerEventConnection(intent: .session(sessionID: session.id, lineNames: []))
            let metadata = url.appendingPathExtension("metadata.json")
            let initialBytes = (try Data(contentsOf: metadata)).count
            let eventStart = ContinuousClock.now
            for index in 0..<eventCount {
                try store.appendEvent(
                    "event \(index)", at: Date(timeIntervalSince1970: Double(index)), to: events.attachmentID)
            }
            let eventElapsed = eventStart.duration(to: .now)
            let eventBytes = (try Data(contentsOf: metadata)).count
            let numericStart = ContinuousClock.now
            for index in 0..<1000 {
                try store.append(
                    SampleRow(
                        timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), values: [Double(index)]),
                    to: numeric.attachmentID)
            }
            print(
                "events guides=\(eventCount) initial_bytes=\(initialBytes) guide_bytes=\(eventBytes) final_bytes=\((try Data(contentsOf: metadata)).count) event_elapsed=\(eventElapsed) numeric_1000_elapsed=\(numericStart.duration(to: .now))"
            )
        case "crash-raw", "crash-ack":
            let split = try PipePlotStore(databaseURL: url)
            let ready = try split.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
            try split.append(SampleRow(timestamp: Date(timeIntervalSince1970: 1), values: [1]), to: ready.attachmentID)
            if mode == "crash-raw" {
                _ = try split.samples.append(
                    values: [2], timestamp: Date(timeIntervalSince1970: 2), to: [ready.streams[0].id],
                    segmentID: ready.attachmentID.uuidString.lowercased())
            } else {
                try split.append(
                    SampleRow(timestamp: Date(timeIntervalSince1970: 2), values: [2]), to: ready.attachmentID)
                try Data("accepted sequence 1".utf8).write(to: directory.appendingPathComponent("ack.marker"))
            }
            _exit(0)
        case "reopen":
            let metadata = url.appendingPathExtension("metadata.json")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
            let sessions = json["sessions"] as! [[String: Any]]
            let charts = sessions[0]["charts"] as! [[String: Any]]
            let streams = charts[0]["streams"] as! [[String: Any]]
            let diskCount = streams[0]["sampleCount"] as! Int
            let store = try PipePlotStore(databaseURL: url)
            let session = try store.listSessions()[0]
            let stream = session.charts[0].streams[0]
            print(
                "reopen ack_marker=\(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ack.marker").path)) metadata_json_count=\(diskCount) repaired_count=\(stream.sampleCount) raw_count=\(try store.samples.count(streamID: stream.id)) stream_state=\(stream.state) is_open=\(session.isOpen)"
            )
        default: fatalError("unknown mode")
        }
    }
}
