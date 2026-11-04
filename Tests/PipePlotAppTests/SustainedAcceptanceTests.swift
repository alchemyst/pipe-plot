import AppKit
import SwiftUI
import XCTest
import SQLite3
import Darwin
import PipePlotCore
import PipePlotTransport
@testable import PipePlotApp

/// Opt-in real-time application workload; all data is isolated in a temporary store.
@MainActor final class SustainedAcceptanceTests: XCTestCase {
    func testWeekHistoryAndPausedViewSoak() throws {
        guard let duration = ProcessInfo.processInfo.environment["PIPEPLOT_SOAK_SECONDS"].flatMap(Double.init),
            duration > 0
        else {
            throw XCTSkip("Set PIPEPLOT_SOAK_SECONDS=3600 for the hour-long acceptance workload")
        }
        try runVisibleWindowTest { try await self.runSoak(seconds: duration) }
    }

    func testVisibleConcurrentCaptureResponsiveness() throws {
        guard let trace = ProcessInfo.processInfo.environment["PIPEPLOT_ACCEPTANCE_TRACE"] else {
            throw XCTSkip("Set PIPEPLOT_ACCEPTANCE_TRACE to a fresh file to measure visible concurrent capture")
        }
        try runVisibleWindowTest {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            print("VISIBLE_CAPTURE pid=\(ProcessInfo.processInfo.processIdentifier)")
            fflush(stdout)
            for chartCount in [1, 3] {
                try await self.measureVisibleCapture(chartCount: chartCount, trace: URL(fileURLWithPath: trace))
            }
        }
    }

    private func runVisibleWindowTest(_ run: @escaping @MainActor () async throws -> Void) throws {
        _ = NSApplication.shared
        var failure: Error?
        Task { @MainActor in
            do { try await run() } catch { failure = error }
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, subtype: 0, data1: 0, data2: 0)
            {
                NSApp.postEvent(event, atStart: true)
            }
        }
        NSApp.run()
        if let failure { throw failure }
    }

    private struct TraceRow: Decodable {
        let event: String
        let stream: UUID?
        let sampleWall: Double?
        let uptimeNanoseconds: UInt64
    }

    private struct ProducerMeasurement: Sendable {
        let stream: StreamID
        let sends: [Int64: UInt64]
        let endedAt: UInt64
    }

    private nonisolated static let historyRows = 6_000
    private nonisolated static let bursts = 80
    private nonisolated static let rowsPerBurst = 8
    private nonisolated static let burstInterval = Duration.milliseconds(50)

    private func measureVisibleCapture(chartCount: Int, trace: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "visible-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8)).sock")
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("capture.sqlite"), socketURL: socket)
        defer { model.applicationWillTerminate() }
        let sessionID = try model.store.createSession(title: "Visible capture · \(chartCount) charts").id
        let first = try XCTUnwrap(model.store.snapshot(sessionID: sessionID)?.charts.first)
        var chartIDs = [first.id]
        for _ in 1..<chartCount { chartIDs.append(try model.store.createChart(in: sessionID).id) }
        let producers = try chartIDs.map { try Self.connectProducer(socket: socket, chart: $0) }
        defer { producers.forEach { $0.connection.close() } }

        let now = Date()
        let historyStart = now - 60
        let selection = TimeSelection(start: now - 45, end: now - 25)
        for (index, producer) in producers.enumerated() {
            for row in 0..<Self.historyRows {
                try model.store.append(
                    SampleRow(
                        timestamp: historyStart + Double(row) / 100,
                        values: [Self.historyValue(row, chart: index)]),
                    to: producer.ready.attachmentID)
            }
        }
        try model.store.setSelection(selection, sessionID: sessionID)
        model.refreshAll()
        let presentation = model.sessionModel(for: sessionID)
        let seeded = try XCTUnwrap(presentation.snapshot)
        var timeline = seeded.timeline
        timeline.followNow = false
        timeline.visibleStart = historyStart
        timeline.visibleEnd = Date() + 30
        model.navigate(timeline, session: seeded)

        let screen = try XCTUnwrap(NSScreen.main)
        let desktop = screen.visibleFrame
        let window = NSWindow(
            contentRect: NSRect(x: desktop.minX + 20, y: desktop.minY + 20, width: 1_000, height: 1_300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionWindow(sessionID: sessionID, model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        let hosting = try XCTUnwrap(window.contentView)
        let plots = chartPlots(in: hosting)
        print(
            "VISIBLE_GEOMETRY charts=\(chartCount) desktop=\(desktop) window=\(window.frame) chartBounds=\(plots.map(\.bounds)) visibleBounds=\(plots.map(\.visibleRect))"
        )
        XCTAssertTrue(desktop.contains(window.frame), "Use a display large enough for the complete benchmark window")
        XCTAssertTrue(window.occlusionState.contains(.visible))
        XCTAssertTrue(model.isDisplayActive(sessionID))
        XCTAssertEqual(plots.count, chartCount)
        for plot in plots {
            let visible = plot.visibleRect
            let bounds = plot.bounds
            guard visible.insetBy(dx: -1, dy: -1).contains(bounds) else {
                return XCTFail("Chart bounds \(bounds) extend outside visible region \(visible)")
            }
        }
        let initialQueries = model.queries.submittedQueryCount
        let initialRefreshes = model.displayRefreshCount
        let started = DispatchTime.now().uptimeNanoseconds
        print("VISIBLE_BEGIN charts=\(chartCount) startUptimeNanoseconds=\(started)")
        fflush(stdout)
        let producersWork = producers.enumerated().map { index, producer in
            Task.detached {
                try await Self.runProducer(connection: producer.connection, ready: producer.ready, chart: index)
            }
        }
        // Match the navigation menu's model entry points, keeping the live edge
        // in view so an exact row-to-render match remains possible throughout.
        for step in 0..<6 {
            try await Task.sleep(for: .milliseconds(600))
            let current = try XCTUnwrap(presentation.snapshot)
            let domain = model.domain(for: current)
            if step.isMultiple(of: 2) {
                model.pan(10, width: 800, session: current, from: domain)
            } else {
                let midpoint = domain.lowerBound + domain.upperBound.timeIntervalSince(domain.lowerBound) / 2
                model.zoom(1.025, anchor: midpoint, session: current, from: domain)
            }
            XCTAssertNotEqual(model.domain(for: try XCTUnwrap(presentation.snapshot)), domain)
        }
        var measurements: [ProducerMeasurement] = []
        for task in producersWork { measurements.append(try await task.value) }
        // Allow the last coalesced refresh and the Canvas render to land.
        try await Task.sleep(for: .seconds(1))
        let queryCount = model.queries.submittedQueryCount - initialQueries
        let refreshCount = model.displayRefreshCount - initialRefreshes
        let snapshot = try XCTUnwrap(presentation.snapshot)
        XCTAssertEqual(snapshot.timeline.selection, selection)
        XCTAssertNil(model.errorMessage)

        for (index, producer) in producers.enumerated() {
            let stream = producer.ready.streams[0].id
            let expectedHistory = (0..<Self.historyRows).map { Self.historyValue($0, chart: index) }
            let expectedLive = (0..<(Self.bursts * Self.rowsPerBurst)).map { Self.liveValue($0, chart: index) }
            let stored = try model.store.samples.query(streamID: stream).map(\.value)
            XCTAssertEqual(stored.count, Self.historyRows + Self.bursts * Self.rowsPerBurst)
            XCTAssertTrue(stored == expectedHistory + expectedLive, "Stored sequence differs for chart \(index + 1)")
            let chart = try XCTUnwrap(snapshot.charts.first { $0.id == producer.ready.chartID })
            let display = model.visibleSamples(for: chart, session: snapshot)
            XCTAssertTrue(display.ready.contains(stream))
            XCTAssertTrue(display.samples[stream, default: []].contains { $0.value == 1_000 + Double(index) })
            XCTAssertTrue(display.samples[stream, default: []].contains { $0.value == -1_000 - Double(index) })
            let stats = try XCTUnwrap(model.stats(for: stream, in: selection))
            XCTAssertEqual(stats.maximum, 1_000 + Double(index))
            XCTAssertEqual(stats.minimum, -1_000 - Double(index))
        }

        let rows = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").compactMap {
            try? JSONDecoder().decode(TraceRow.self, from: Data($0.utf8))
        }.filter { $0.event == "visible-sample-render" && $0.uptimeNanoseconds >= started }
        var latency: [Double] = []
        for measurement in measurements {
            var streamLatency: [Double] = []
            var liveMatches = 0
            var matched: Set<Int64> = []
            for row in rows where row.stream == measurement.stream {
                guard let sample = row.sampleWall else { continue }
                let key = Self.timestampKey(sample)
                guard let sentAt = measurement.sends[key], row.uptimeNanoseconds >= sentAt,
                    matched.insert(key).inserted
                else { continue }
                streamLatency.append(Double(row.uptimeNanoseconds - sentAt) / 1_000_000)
                if row.uptimeNanoseconds <= measurement.endedAt { liveMatches += 1 }
            }
            XCTAssertGreaterThan(liveMatches, 0, "Every chart must render a live sample during capture")
            print(
                "VISIBLE_STREAM charts=\(chartCount) id=\(measurement.stream) matches=\(streamLatency.count) duringCapture=\(liveMatches)"
            )
            latency += streamLatency
        }
        let sorted = latency.sorted()
        let ingestSeconds = Double(try XCTUnwrap(measurements.map(\.endedAt).max()) - started) / 1e9
        let accepted = measurements.reduce(0) { $0 + $1.sends.count }
        XCTAssertEqual(accepted, chartCount * Self.bursts * Self.rowsPerBurst)
        let median =
            sorted.isEmpty ? 0 : (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        let p95 = sorted.isEmpty ? 0 : sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        print(
            "VISIBLE_RESULT charts=\(chartCount) accepted=\(accepted) ingestSeconds=\(ingestSeconds) rowsPerSecond=\(Double(accepted) / ingestSeconds) renderedMatches=\(sorted.count) latencyMedianMs=\(median) latencyP95Ms=\(p95) latencyMaxMs=\(sorted.last ?? 0) queries=\(queryCount) refreshes=\(refreshCount)"
        )
        fflush(stdout)
    }

    private func chartPlots(in view: NSView) -> [PlotInteractionView] {
        if let plot = view as? PlotInteractionView {
            // Chart overlays are 210 points tall. The shared ruler is 78 points.
            return plot.bounds.height > 100 ? [plot] : []
        }
        return view.subviews.flatMap { chartPlots(in: $0) }
    }

    private nonisolated static func connectProducer(socket: URL, chart: ChartID) throws
        -> (connection: SocketConnection, ready: ReadyReply)
    {
        let connection = try PipePlotLocations.connect(socketURL: socket, timeout: 2)
        try connection.send(
            ClientMessage.hello(
                HelloRequest(sink: .chart(chartID: chart, lineNames: []), sampler: SamplerIntent(columnCount: 1))))
        guard case .hello? = try connection.receive(ServerMessage.self, timeout: 2),
            case .ready(let ready)? = try connection.receive(ServerMessage.self, timeout: 2)
        else { throw SampleStoreError.sql("Producer registration failed") }
        return (connection, ready)
    }

    private nonisolated static func runProducer(connection: SocketConnection, ready: ReadyReply, chart: Int)
        async throws -> ProducerMeasurement
    {
        let clock = ContinuousClock()
        var nextBurst = clock.now
        var sends: [Int64: UInt64] = [:]
        for burst in 0..<bursts {
            try await clock.sleep(until: nextBurst)
            nextBurst += burstInterval
            for row in 0..<rowsPerBurst {
                let time = Date()
                let start = DispatchTime.now().uptimeNanoseconds
                try connection.send(
                    ClientMessage.row(
                        SampleRow(timestamp: time, values: [liveValue(burst * rowsPerBurst + row, chart: chart)])))
                guard case .accepted? = try connection.receive(ServerMessage.self, timeout: 3) else {
                    throw SampleStoreError.sql("Missing acceptance acknowledgement")
                }
                sends[timestampKey(time.timeIntervalSince1970)] = start
            }
        }
        return ProducerMeasurement(
            stream: ready.streams[0].id, sends: sends, endedAt: DispatchTime.now().uptimeNanoseconds)
    }

    private nonisolated static func historyValue(_ row: Int, chart: Int) -> Double {
        if row == 2_345 { return 1_000 + Double(chart) }
        if row == 2_346 { return -1_000 - Double(chart) }
        return Double(row % 25)
    }

    private nonisolated static func liveValue(_ row: Int, chart: Int) -> Double {
        Double(100 * (chart + 1) + row % 50)
    }

    private nonisolated static func timestampKey(_ timestamp: Double) -> Int64 {
        Int64((timestamp * 1e6).rounded())
    }

    private func runSoak(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PipePlot-acceptance-\(UUID().uuidString)")
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
        let producer = try model.store.registerSampler(
            intent: .session(sessionID: ready.sessionID, lineNames: ready.streams.map(\.name)),
            sampler: SamplerIntent(columnCount: 10))
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
        model.setForecast(
            ForecastConfiguration(streamID: ids[0], guideID: guide.id, selection: timeline.selection!), session: session
        )
        model.refreshAll()
        let window = NSWindow(
            contentRect: NSRect(x: 30, y: 30, width: 850, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PipePlot isolated hour acceptance"
        window.contentView = NSHostingView(rootView: SessionWindow(sessionID: ready.sessionID, model: model))
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.close() }
        var hiddenWindows: [NSWindow] = [], hiddenProducers: [ReadyReply] = []
        for _ in 0..<3 {
            let hidden = try model.store.createSession()
            let attached = try model.store.registerSampler(
                intent: .session(sessionID: hidden.id, lineNames: []), sampler: SamplerIntent(columnCount: 1))
            hiddenProducers.append(attached)
            let hiddenWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 850, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            hiddenWindow.isReleasedWhenClosed = false
            hiddenWindow.contentView = NSHostingView(rootView: SessionWindow(sessionID: hidden.id, model: model))
            hiddenWindow.orderOut(nil)
            hiddenWindows.append(hiddenWindow)
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
        print(
            "ACCEPTANCE_BEGIN pid=\(ProcessInfo.processInfo.processIdentifier) seconds=\(seconds) historyRows=1209610 streams=10 interval=5 rss=\(initialRSS) database=\(database.path)"
        )
        fflush(stdout)
        while Date().timeIntervalSince(began) < seconds {
            let now = Date()
            if !model.isDisplayActive(ready.sessionID) { inactiveSeconds += now.timeIntervalSince(previousTick) }
            previousTick = now
            if now >= nextSample {
                try model.store.append(
                    SampleRow(timestamp: now, values: ids.indices.map { 1_000_000 + Double($0 * 1000 + appended) }),
                    to: producer.attachmentID)
                for hidden in hiddenProducers {
                    try model.store.append(
                        SampleRow(timestamp: now, values: [Double(appended)]), to: hidden.attachmentID)
                }
                appended += 1
                nextSample = now.addingTimeInterval(5)
            }
            let memory = Self.rss()
            peakRSS = max(peakRSS, memory)
            if now >= nextReport {
                let elapsed = now.timeIntervalSince(began), cpu = Double(clock() - initialCPU) / Double(CLOCKS_PER_SEC)
                let row = [
                    "elapsed": elapsed, "rss": Double(memory), "cpuSeconds": cpu,
                    "queries": Double(model.queries.submittedQueryCount - initialQueries),
                    "rawFits": Double(model.queries.rawFitCount - initialFits), "appendedRows": Double(appended),
                    "inactiveSeconds": inactiveSeconds,
                ]
                samples.append(row)
                if let path = ProcessInfo.processInfo.environment["PIPEPLOT_SOAK_REPORT"] {
                    try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(
                        to: URL(fileURLWithPath: path + ".progress.json"), options: .atomic)
                }
                print(
                    "ACCEPTANCE_PROGRESS \(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)"
                )
                fflush(stdout)
                nextReport = now.addingTimeInterval(60)
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
        XCTAssertEqual(
            model.queries.rawFitCount, initialFits, "Fixed training data must not refit on out-of-range live arrivals")
        let beforeNavigation = model.queries.submittedQueryCount
        let navigationStart = Date()
        for offset in [Double](arrayLiteral: 0, 172800, 518400, 259200, 0) {
            var current = try XCTUnwrap(model.sessions[ready.sessionID])
            var nav = current.timeline
            nav.visibleStart = start.addingTimeInterval(offset)
            nav.visibleEnd = start.addingTimeInterval(offset + 900)
            model.navigate(nav, session: current)
            current = try XCTUnwrap(model.sessions[ready.sessionID])
            model.requestVisibleSamples(for: current.charts[0], session: current)
            var loaded = false
            for _ in 0..<300 {
                let display = model.visibleSamples(for: current.charts[0], session: current)
                if display.samples.count == ids.count
                    && display.samples.values.allSatisfy({ rows in
                        guard let first = rows.first, let last = rows.last else { return false }
                        return first.timestamp >= nav.visibleStart! && last.timestamp <= nav.visibleEnd!
                    })
                {
                    loaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(loaded, "Historical viewport did not load within three seconds")
        }
        let result: [String: Any] = [
            "elapsedSeconds": elapsed, "cpuSeconds": cpu, "cpuPercentOneCore": 100 * cpu / elapsed,
            "initialRSS": initialRSS, "finalRSS": Self.rss(), "peakRSS": peakRSS, "appendedRowsPerStream": appended,
            "inactiveSeconds": inactiveSeconds, "queries": model.queries.submittedQueryCount - initialQueries,
            "rawFits": model.queries.rawFitCount - initialFits,
            "navigationSeconds": Date().timeIntervalSince(navigationStart),
            "navigationQueries": model.queries.submittedQueryCount - beforeNavigation, "samples": samples,
        ]
        let output = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["PIPEPLOT_SOAK_REPORT"]
                ?? directory.appendingPathComponent("report.json").path)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print(
            "ACCEPTANCE_COMPLETE report=\(output.path) elapsed=\(elapsed) peakRSS=\(peakRSS) cpuPercent=\(100 * cpu / elapsed)"
        )
        fflush(stdout)
    }

    private nonisolated static func rss() -> UInt64 {
        var info = mach_task_basic_info(),
            count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return code == KERN_SUCCESS ? info.resident_size : 0
    }
    private nonisolated static func seedWeek(database: URL, ids: [StreamID], start: Date) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw SampleStoreError.open("seed open failed") }
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
        try execute("BEGIN IMMEDIATE")
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "INSERT INTO samples(stream_id,timestamp,sequence,value,segment_id) VALUES(?,?,?,?,?)", -1, &stmt,
                nil) == SQLITE_OK
        else { throw SampleStoreError.sql("seed prepare failed") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() {
            for row in 0...120960 {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, id.uuidString.lowercased(), -1, transient)
                sqlite3_bind_double(stmt, 2, start.addingTimeInterval(Double(row) * 5).timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, Int64(row))
                sqlite3_bind_double(stmt, 4, 1_000_000 + Double(index * 1000 + row))
                sqlite3_bind_text(stmt, 5, "seed", -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw SampleStoreError.sql(String(cString: sqlite3_errmsg(db)))
                }
            }
            try execute(
                "INSERT INTO stream_meta(stream_id,sample_count,first_time,last_time,next_sequence) VALUES('\(id.uuidString.lowercased())',120961,\(start.timeIntervalSince1970),\(start.addingTimeInterval(604800).timeIntervalSince1970),120961) ON CONFLICT(stream_id) DO UPDATE SET sample_count=120961,first_time=excluded.first_time,last_time=excluded.last_time,next_sequence=120961"
            )
        }
        try execute("COMMIT")
    }
}
