import Foundation

@main struct DerivedSeriesBenchmark {
    static func main() throws {
        let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 120961
        guard (100...10000000).contains(count) else { fatalError("Use 100–10000000 rows per stream") }
        let origin = Date(timeIntervalSince1970: 1700000000)
        let c = DerivedSeriesConfiguration(interval: 5, window: 500, maximumGap: 16)
        var processors = try (0..<10).map { _ in try DerivedSeriesProcessor(configuration: c, origin: origin) }
        var emitted = 0, checksum = 0.0
        let start = Date()
        for i in 0..<count {
            let t = Double(i) * 5.0003 + 0.03 * sin(Double(i) * 1.7)
            for stream in processors.indices {
                try processors[stream].append(.init(timestamp: origin.addingTimeInterval(t), sequence: UInt64(i), value: Double(stream) + sin(t / 300), segmentID: "a")) {
                    emitted += 1; checksum += $0.derivative
                }
            }
        }
        for i in processors.indices { processors[i].finish { emitted += 1; checksum += $0.derivative } }
        let elapsed = Date().timeIntervalSince(start)
        print("streams=10 rows_per_stream=\(count) simulated_days=\(Double(count) * 5 / 86400)")
        print("window_points=101 retained_numeric_slots=\(processors.reduce(0) { $0 + $1.workingCapacity }) output_count=\(emitted) checksum=\(checksum)")
        print("elapsed_seconds=\(elapsed) input_rows_per_second=\(Double(count * 10) / elapsed)")
    }
}
