import AppKit
import SwiftUI
import XCTest
@testable import PipePlotApp
import PipePlotCore

@MainActor
final class WindowVisibilityTests: XCTestCase {
    func testWindowVisibilityPolicy() {
        XCTAssertTrue(WindowStateView.displayIsActive(visible: true, miniaturized: false, occluded: false, appHidden: false))
        for state in [(false, false, false, false), (true, true, false, false),
                      (true, false, true, false), (true, false, false, true)] {
            XCTAssertFalse(WindowStateView.displayIsActive(visible: state.0, miniaturized: state.1,
                                                          occluded: state.2, appHidden: state.3))
        }
    }

    func testSuspensionGatesQueriesAndTicksButPreservesCaptureAndTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date().addingTimeInterval(-100)
        _ = try model.store.append(SampleRow(timestamp: start, values: [0]), to: ready.attachmentID)
        model.refreshAll()
        let initial = try XCTUnwrap(model.sessions[ready.sessionID])
        var timeline = initial.timeline
        timeline.followNow = false
        timeline.visibleStart = start
        timeline.visibleEnd = start.addingTimeInterval(100)
        timeline.selection = TimeSelection(start: start, end: start.addingTimeInterval(100), mode: .endFollowsNow)
        model.navigate(timeline, session: initial)
        model.selectChart(ready.chartID, sessionID: ready.sessionID)
        let before = try XCTUnwrap(model.sessions[ready.sessionID])
        model.setDisplayActive(false, for: ready.sessionID)
        let pulse = model.clockPulse
        let refreshes = model.displayRefreshCount
        let queries = model.queries.submittedQueryCount
        for i in 1...10 {
            _ = try model.store.append(SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID)
            model.tick(ready.sessionID)
            XCTAssertTrue(model.visibleSamples(for: before.charts[0], session: before).samples.isEmpty)
            XCTAssertNil(model.stats(for: ready.streams[0].id, in: timeline.selection!))
            XCTAssertNil(model.nearestSample(ready.streams[0].id, at: start))
            XCTAssertNil(model.fit(for: ready.streams[0].id, selection: timeline.selection!))
        }
        XCTAssertEqual(model.displayRefreshCount, refreshes)
        XCTAssertEqual(model.clockPulse, pulse)
        XCTAssertEqual(model.queries.submittedQueryCount, queries)
        XCTAssertEqual(model.sessions[ready.sessionID], before)
        // Even an unrelated command refreshing all snapshots must not start hidden fits.
        model.refreshAll()
        XCTAssertEqual(model.queries.submittedQueryCount, queries)
        model.setDisplayActive(true, for: ready.sessionID)
        let revealed = try XCTUnwrap(model.sessions[ready.sessionID])
        XCTAssertEqual(revealed.charts[0].streams[0].sampleCount, 11)
        XCTAssertEqual(revealed.timeline, before.timeline)
        XCTAssertEqual(model.selectedChartIDs[ready.sessionID], ready.chartID)
        XCTAssertEqual(model.displayRefreshCount, refreshes + 1)
        model.setDisplayActive(true, for: ready.sessionID)
        XCTAssertEqual(model.displayRefreshCount, refreshes + 1)
        var caughtUp = false
        for _ in 0..<50 {
            let display = model.visibleSamples(for: revealed.charts[0], session: revealed)
            if display.current.contains(ready.streams[0].id) {
                XCTAssertEqual(display.samples[ready.streams[0].id]?.last?.value, 10)
                caughtUp = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(caughtUp)
        XCTAssertGreaterThan(model.queries.submittedQueryCount, queries)
        // Deliberate close still disconnects producers and retains their data.
        model.windowClosed(ready.sessionID)
        XCTAssertFalse(try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID)).isOpen)
        XCTAssertThrowsError(try model.store.append(SampleRow(values: [99]), to: ready.attachmentID))
        XCTAssertEqual(try model.store.samples.count(streamID: ready.streams[0].id), 11)
    }

    func testHiddenForecastDoesNotScheduleFits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date().addingTimeInterval(-10)
        for i in 0..<5 {
            _ = try model.store.append(SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID)
        }
        model.refreshAll()
        model.setDisplayActive(false, for: ready.sessionID)
        let guide = Guide(orientation: .horizontalValue, value: 100)
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        let configuration = ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id,
                                                  selection: TimeSelection(start: start, end: start.addingTimeInterval(4)))
        try model.store.setForecasts([configuration], sessionID: ready.sessionID)
        model.refreshAll()
        XCTAssertEqual(model.queries.submittedQueryCount, 0)
        model.setDisplayActive(true, for: ready.sessionID)
        for _ in 0..<50 {
            if model.forecastStatuses[ready.sessionID]?.fit != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.forecastStatuses[ready.sessionID]?.fit)
        XCTAssertEqual(model.sessions[ready.sessionID]?.timeline.forecasts, [configuration])
    }

    /// Opt-in native window/SwiftUI measurement, separate from routine unit tests.
    func testNativeWindowWorkMeasurement() throws {
        guard ProcessInfo.processInfo.environment["PIPEPLOT_MEASURE_WINDOWS"] == "1" else {
            throw XCTSkip("Set PIPEPLOT_MEASURE_WINDOWS=1 for native CPU/query measurements")
        }
        _ = NSApplication.shared
        var failure: Error?
        Task { @MainActor in
            do { try await measureNativeWindows() } catch { failure = error }
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: true)
            }
        }
        // XCTest's async executor does not run AppKit's window event loop.
        NSApp.run()
        if let failure { throw failure }
    }

    private func measureNativeWindows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("measure.sqlite"))
        var windows: [NSWindow] = []
        var producers: [ReadyReply] = []
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        for index in 0..<4 {
            let session = try model.store.createSession()
            let ready = try model.store.registerSampler(intent: .session(sessionID: session.id, lineNames: []), sampler: SamplerIntent(columnCount: 1))
            producers.append(ready)
            let window = NSWindow(contentRect: NSRect(x: 40 + index * 40, y: 40 + index * 40, width: 850, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SessionWindow(sessionID: session.id, model: model))
            windows.append(window)
            window.orderFrontRegardless()
        }
        defer { windows.forEach { $0.close() } }
        windows[0].makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1))
        for minimized in [false, true] {
            if minimized { windows.dropFirst().forEach { $0.miniaturize(nil) } }
            for _ in 0..<100 {
                if producers.enumerated().allSatisfy({ model.isDisplayActive($0.element.sessionID) == (!minimized || $0.offset == 0) }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            for (index, ready) in producers.enumerated() {
                print("WINDOW_STATE index=\(index) visible=\(windows[index].isVisible) mini=\(windows[index].isMiniaturized) occlusion=\(windows[index].occlusionState.rawValue) hidden=\(NSApp.isHidden)")
                XCTAssertEqual(model.isDisplayActive(ready.sessionID), !minimized || index == 0)
            }
            for ingest in [false, true] {
                let queries = model.queries.submittedQueryCount
                let refreshes = model.displayRefreshCount
                let cpu = clock()
                let began = Date()
                var rows = 0
                while Date().timeIntervalSince(began) < 4 {
                    if ingest {
                        for ready in producers {
                            _ = try model.store.append(SampleRow(values: [Double(rows)]), to: ready.attachmentID)
                        }
                        rows += 1
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let wall = Date().timeIntervalSince(began)
                let cpuSeconds = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
                print("WINDOW_MEASUREMENT minimized=\(minimized ? 3 : 0) ingest=\(ingest) wall=\(wall) cpuSeconds=\(cpuSeconds) cpuPercent=\(100 * cpuSeconds / wall) queries=\(model.queries.submittedQueryCount - queries) refreshes=\(model.displayRefreshCount - refreshes) rowsPerSession=\(rows)")
            }
        }
        for ready in producers {
            XCTAssertGreaterThan(try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID)).charts[0].streams[0].sampleCount, 0)
        }
        windows.dropFirst().forEach { $0.deminiaturize(nil) }
        for _ in 0..<100 {
            if producers.allSatisfy({ model.isDisplayActive($0.sessionID) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for ready in producers {
            XCTAssertTrue(model.isDisplayActive(ready.sessionID))
            XCTAssertTrue(try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID)).isOpen)
        }
        windows[1].orderOut(nil)
        for _ in 0..<100 {
            if !model.isDisplayActive(producers[1].sessionID) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.isDisplayActive(producers[1].sessionID))
        NSApp.hide(nil)
        for _ in 0..<100 {
            if producers.allSatisfy({ !model.isDisplayActive($0.sessionID) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for ready in producers {
            XCTAssertFalse(model.isDisplayActive(ready.sessionID))
            _ = try model.store.append(SampleRow(values: [999]), to: ready.attachmentID)
        }
        NSApp.unhide(nil)
        windows.forEach { $0.orderFrontRegardless() }
        for _ in 0..<100 {
            if producers.allSatisfy({ model.isDisplayActive($0.sessionID) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for ready in producers { XCTAssertTrue(model.isDisplayActive(ready.sessionID)) }
    }
}
