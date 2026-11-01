import Foundation

/// Explicit, process-local acceptance instrumentation. Disabled unless the app
/// receives --acceptance-trace PATH; no preferences or normal capture are changed.
enum AcceptanceTrace {
    private static let lock = NSLock()
    private static var lastRendered: [UUID: Date] = [:]
    private static let destination: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--acceptance-trace"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }()
    static func record(_ event: String, stream: UUID? = nil, sample: Date? = nil) {
        guard let destination else { return }
        lock.lock(); defer { lock.unlock() }
        if event == "visible-sample-render", let stream, let sample {
            guard lastRendered[stream] != sample else { return }
            lastRendered[stream] = sample
        }
        var record: [String: Any] = ["event": event, "wall": Date().timeIntervalSince1970,
                                   "uptimeNanoseconds": DispatchTime.now().uptimeNanoseconds,
                                   "pid": ProcessInfo.processInfo.processIdentifier]
        if let stream { record["stream"] = stream.uuidString.lowercased() }
        if let sample { record["sampleWall"] = sample.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: destination.path) { _ = FileManager.default.createFile(atPath: destination.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: destination) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10])) } catch { /* diagnostics never affect capture */ }
    }
}
