import Foundation

@main
struct SampleStoreBenchmark {
    static func main() throws {
        let rows = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 100_000
        guard rows > 0 else { fatalError("row count must be positive") }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pipeplot-sample-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SampleStore(databaseURL: directory.appendingPathComponent("samples.sqlite"))
        let streams = [StreamID(), StreamID()]
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let insertStart = ContinuousClock.now
        for index in 0..<rows {
            let time = origin.addingTimeInterval(Double(index) * 0.01)
            try store.append(values: [sin(Double(index) / 50), cos(Double(index) / 50)], timestamp: time, to: streams)
        }
        let insertDuration = insertStart.duration(to: .now)

        let queryStart = ContinuousClock.now
        let result = try store.query(streamID: streams[0], limit: SampleStore.maximumQueryRows)
        let queryDuration = queryStart.duration(to: .now)
        let count = try store.count(streamID: streams[0])
        print("rows_per_stream=\(rows)")
        print("append_columns=2")
        print("append_elapsed=\(insertDuration)")
        print("query_limit=\(SampleStore.maximumQueryRows)")
        print("query_returned=\(result.count)")
        print("query_elapsed=\(queryDuration)")
        print("count_from_sqlite=\(count)")
    }
}
