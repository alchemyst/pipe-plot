import AppKit
import SwiftUI
import XCTest
import SQLite3
import Darwin
import PipePlotCore
@testable import PipePlotApp

/// Opt-in real-time application workload; all data is isolated in a temporary store.
@MainActor final class SustainedAcceptanceTests: XCTestCase {
    func testWeekHistoryAndPausedViewSoak() throws {
        guard let duration = ProcessInfo.processInfo.environment["PIPEPLOT_SOAK_SECONDS"].flatMap(Double.init), duration > 0 else {
            throw XCTSkip("Set PIPEPLOT_SOAK_SECONDS=3600 for the hour-long acceptance workload")
        }
        _ = NSApplication.shared
        var failure: Error?
        Task { @MainActor in
            do { try await runSoak(seconds: duration) } catch { failure = error }
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
        }
        NSApp.run()
        if let failure { throw failure }
    }

    private func runSoak(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PipePlot-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("week.sqlite")
        let seed = try PipePlotStore(databaseURL: database)
        let ready = try seed.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 10))
        let start = Date().addingTimeInterval(-7 * 86400)
        let ids = ready.streams.map(\.id)
        // Bulk preparation is intentionally separate from measured live ingestion.
        // The normal store is reconstructed afterwards to reconcile persisted counts.
        try await Task.detached {
            try Self.seedWeek(database: database, ids: ids, start: start)
        }.value
        let model = PipePlotAppModel(databaseURL: database)
        let producer = try model.store.registerSampler(intent: .session(sessionID: ready.sessionID, lineNames: ready.streams.map(\.name)), sampler: SamplerIntent(columnCount: 10))
        model.refreshAll()
        var session = try XCTUnwrap(model.sessions[ready.sessionID])
        for stream in session.charts[0].streams { XCTAssertEqual(stream.sampleCount, 120961) }
        var timeline = session.timeline
        timeline.followNow = false
        timeline.visibleStart = start.addingTimeInterval(86400)
        timeline.visibleEnd = start.addingTimeInterval(86400 + 900)
        timeline.selection = TimeSelection(start: timeline.visibleStart!, end: timeline.visibleEnd!)
        model.navigate(timeline, session: session)
        session = try XCTUnwrap(model.sessions[ready.sessionID])
        let guide = Guide(orientation: .horizontalValue, value: 2_000_000, label: "Acceptance target")
        try model.store.upsertGuide(guide, chartID: producer.chartID)
        model.setForecast(ForecastConfiguration(streamID: ids[0], guideID: guide.id, selection: timeline.selection!), session: session)
        model.refreshAll()
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 850, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PipePlot isolated hour acceptance"
        window.contentView = NSHostingView(rootView: SessionWindow(sessionID: ready.sessionID, model: model))
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.close() }
        var hiddenWindows: [NSWindow] = [], hiddenProducers: [ReadyReply] = []
        for _ in 0..<3 {
            let hidden = try model.store.createSession()
            let attached = try model.store.registerSampler(intent: .session(sessionID: hidden.id, lineNames: []), sampler: SamplerIntent(columnCount: 1))
            hiddenProducers.append(attached)
            let hiddenWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            hiddenWindow.isReleasedWhenClosed = false
            hiddenWindow.contentView = NSHostingView(rootView: SessionWindow(sessionID: hidden.id, model: model))
            hiddenWindow.orderOut(nil); hiddenWindows.append(hiddenWindow)
        }
        defer { hiddenWindows.forEach { $0.close() } }
        model.refreshAll()
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(model.isDisplayActive(ready.sessionID))
        let originalTimeline = try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID)).timeline
        let began = Date(), initialCPU = clock(), initialRSS = Self.rss()
        var peakRSS = initialRSS, appended = 0, nextSample = Date(), nextReport = Date()
        let initialQueries = model.queries.submittedQueryCount, initialFits = model.queries.rawFitCount
        var samples: [[String: Double]] = [], inactiveSeconds = 0.0, previousTick = Date()
        print("ACCEPTANCE_BEGIN pid=\(ProcessInfo.processInfo.processIdentifier) seconds=\(seconds) historyRows=1209610 streams=10 interval=5 rss=\(initialRSS) database=\(database.path)")
        fflush(stdout)
        while Date().timeIntervalSince(began) < seconds {
            let now = Date()
            if !model.isDisplayActive(ready.sessionID) { inactiveSeconds += now.timeIntervalSince(previousTick) }
            previousTick = now
            if now >= nextSample {
                try model.store.append(SampleRow(timestamp: now, values: ids.indices.map { 1_000_000 + Double($0 * 1000 + appended) }), to: producer.attachmentID)
                for hidden in hiddenProducers { try model.store.append(SampleRow(timestamp: now, values: [Double(appended)]), to: hidden.attachmentID) }
                appended += 1; nextSample = now.addingTimeInterval(5)
            }
            let memory = Self.rss(); peakRSS = max(peakRSS, memory)
            if now >= nextReport {
                let elapsed = now.timeIntervalSince(began), cpu = Double(clock() - initialCPU) / Double(CLOCKS_PER_SEC)
                let row = ["elapsed": elapsed, "rss": Double(memory), "cpuSeconds": cpu,
                           "queries": Double(model.queries.submittedQueryCount - initialQueries), "rawFits": Double(model.queries.rawFitCount - initialFits), "appendedRows": Double(appended), "inactiveSeconds": inactiveSeconds]
                samples.append(row)
                if let path = ProcessInfo.processInfo.environment["PIPEPLOT_SOAK_REPORT"] {
                    try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path + ".progress.json"), options: .atomic)
                }
                print("ACCEPTANCE_PROGRESS \(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)")
                fflush(stdout); nextReport = now.addingTimeInterval(60)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let elapsed = Date().timeIntervalSince(began), cpu = Double(clock() - initialCPU) / Double(CLOCKS_PER_SEC)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.timeline, originalTimeline)
        for hidden in hiddenProducers {
            XCTAssertFalse(model.isDisplayActive(hidden.sessionID))
            XCTAssertEqual(try model.store.samples.count(streamID: hidden.streams[0].id), Int64(appended))
        }
        for id in ids { XCTAssertEqual(try model.store.samples.count(streamID: id), 120961 + Int64(appended)) }
        XCTAssertLessThan(peakRSS - initialRSS, 128 * 1024 * 1024, "Retained paused-view memory grew beyond 128 MiB")
        XCTAssertEqual(model.queries.rawFitCount, initialFits, "Fixed training data must not refit on out-of-range live arrivals")
        let beforeNavigation = model.queries.submittedQueryCount
        let navigationStart = Date()
        for offset in [Double](arrayLiteral: 0, 172800, 518400, 259200, 0) {
            var current = try XCTUnwrap(model.sessions[ready.sessionID])
            var nav = current.timeline; nav.visibleStart = start.addingTimeInterval(offset); nav.visibleEnd = start.addingTimeInterval(offset + 900)
            model.navigate(nav, session: current)
            current = try XCTUnwrap(model.sessions[ready.sessionID])
            var loaded = false
            for _ in 0..<300 {
                let display = model.visibleSamples(for: current.charts[0], session: current)
                if display.samples.count == ids.count && display.samples.values.allSatisfy({ rows in
                    guard let first = rows.first, let last = rows.last else { return false }
                    return first.timestamp >= nav.visibleStart! && last.timestamp <= nav.visibleEnd!
                }) { loaded = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(loaded, "Historical viewport did not load within three seconds")
        }
        let result: [String: Any] = ["elapsedSeconds": elapsed, "cpuSeconds": cpu, "cpuPercentOneCore": 100 * cpu / elapsed,
            "initialRSS": initialRSS, "finalRSS": Self.rss(), "peakRSS": peakRSS, "appendedRowsPerStream": appended,
            "inactiveSeconds": inactiveSeconds, "queries": model.queries.submittedQueryCount - initialQueries,
            "rawFits": model.queries.rawFitCount - initialFits, "navigationSeconds": Date().timeIntervalSince(navigationStart),
            "navigationQueries": model.queries.submittedQueryCount - beforeNavigation, "samples": samples]
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PIPEPLOT_SOAK_REPORT"] ?? directory.appendingPathComponent("report.json").path)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("ACCEPTANCE_COMPLETE report=\(output.path) elapsed=\(elapsed) peakRSS=\(peakRSS) cpuPercent=\(100 * cpu / elapsed)")
        fflush(stdout)
    }

    private nonisolated static func rss() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return code == KERN_SUCCESS ? info.resident_size : 0
    }
    private nonisolated static func seedWeek(database: URL, ids: [StreamID], start: Date) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw SampleStoreError.open("seed open failed") }
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) } }
        try execute("BEGIN IMMEDIATE")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO samples(stream_id,timestamp,sequence,value,segment_id) VALUES(?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw SampleStoreError.sql("seed prepare failed") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() {
            for row in 0...120960 {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, id.uuidString.lowercased(), -1, transient)
                sqlite3_bind_double(stmt, 2, start.addingTimeInterval(Double(row) * 5).timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, Int64(row)); sqlite3_bind_double(stmt, 4, 1_000_000 + Double(index * 1000 + row))
                sqlite3_bind_text(stmt, 5, "seed", -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            }
            try execute("INSERT INTO stream_meta(stream_id,sample_count,first_time,last_time,next_sequence) VALUES('\(id.uuidString.lowercased())',120961,\(start.timeIntervalSince1970),\(start.addingTimeInterval(604800).timeIntervalSince1970),120961) ON CONFLICT(stream_id) DO UPDATE SET sample_count=120961,first_time=excluded.first_time,last_time=excluded.last_time,next_sequence=120961")
        }
        try execute("COMMIT")
    }
}
