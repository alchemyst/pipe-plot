import Foundation
import Darwin

@main struct UndoHistoryBenchmark {
    static func rss() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: UndoHistoryBenchmark COPY_OF_TEST_DATABASE") }
        let store = try PipePlotStore(databaseURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let session = try store.listSessions().first { $0.charts.flatMap(\.streams).count == 10 }!
        let streams = session.charts.flatMap(\.streams), id = streams[0].id
        let counts = try streams.map { try store.samples.count(streamID: $0.id) }
        let initial = rss(), began = Date()
        var sampledPeak = initial, checkpoints: [[String: UInt64]] = []
        for i in 0..<1000 {
            if i % 2 == 0 { try store.renameStream(id, to: "Undo acceptance \(i)") }
            else { try store.setStreamLayoutHidden(i % 4 == 1, streamID: id) }
            sampledPeak = max(sampledPeak, rss())
            if i == 199 || i == 499 || i == 999 { checkpoints.append(["edits": UInt64(i + 1), "rss": rss()]) }
        }
        var undone = 0
        while try store.undo(sessionID: session.id) { undone += 1; sampledPeak = max(sampledPeak, rss()) }
        guard undone == 200 else { fatalError("Expected bounded 200-action undo history, got \(undone)") }
        var redone = 0
        while try store.redo(sessionID: session.id) { redone += 1; sampledPeak = max(sampledPeak, rss()) }
        guard redone == 200, try streams.map({ try store.samples.count(streamID: $0.id) }) == counts else { fatalError("Undo/redo changed raw history") }
        let finalRSS = rss(); sampledPeak = max(sampledPeak, finalRSS)
        let result: [String: Any] = ["retainedRows": counts.reduce(0,+), "streams": streams.count, "edits": 1000,
            "editKinds": ["rename", "hide from layout", "restore layout"],
            "undoActions": undone, "redoActions": redone, "initialRSS": initial, "maxSampledRSS": sampledPeak,
            "finalRSS": finalRSS, "checkpoints": checkpoints, "elapsedSeconds": Date().timeIntervalSince(began)]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
    }
}
