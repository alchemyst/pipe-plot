import XCTest
import Synchronization
@testable import PipePlotApp
import PipePlotCore

@MainActor
final class BackgroundAnalysisTests: XCTestCase {
    func testUndoWhileFitIsPendingDoesNotRestoreForecast() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date().addingTimeInterval(-100)
        for i in 0..<100 {
            _ = try model.store.append(
                SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID)
        }
        let guide = Guide(orientation: .horizontalValue, value: 200)
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        model.refreshAll()
        let session = try XCTUnwrap(model.sessions[ready.sessionID])
        let configuration = ForecastConfiguration(
            streamID: ready.streams[0].id, guideID: guide.id,
            selection: TimeSelection(start: start, end: start.addingTimeInterval(99)))
        model.setForecast(configuration, session: session)
        model.undo(session.id)
        // Allow the queued calculation and its main-thread completion to finish.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.allForecastStatuses[session.id]?.isEmpty ?? true)
        XCTAssertNil(model.sessions[session.id]?.timeline.forecast)
        model.redo(session.id)
        for _ in 0..<50 {
            if model.allForecastStatuses[session.id]?.first?.fit != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fit = try XCTUnwrap(model.allForecastStatuses[session.id]?.first?.fit)
        XCTAssertEqual(fit.slope, 1, accuracy: 1e-10)
        let crossing = try XCTUnwrap(model.allForecastStatuses[session.id]?.first?.crossing)
        XCTAssertEqual(crossing.timeIntervalSince(start), 200, accuracy: 1e-5)
    }

    func testMultipleForecastsShareFurthestHorizonAndFixedFit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date().addingTimeInterval(-10)
        for i in 0..<10 {
            _ = try model.store.append(
                SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID)
        }
        let firstGuide = Guide(orientation: .horizontalValue, value: 100)
        let secondGuide = Guide(orientation: .horizontalValue, value: 200)
        try model.store.upsertGuide(firstGuide, chartID: ready.chartID)
        try model.store.upsertGuide(secondGuide, chartID: ready.chartID)
        let selection = TimeSelection(start: start, end: start.addingTimeInterval(9))
        model.refreshAll()
        for guide in [firstGuide, secondGuide] {
            let session = try XCTUnwrap(model.sessions[ready.sessionID])
            model.setForecast(
                ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id, selection: selection),
                session: session)
        }
        for _ in 0..<50 {
            if model.allForecastStatuses[ready.sessionID]?.filter({ $0.fit != nil }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = try XCTUnwrap(model.allForecastStatuses[ready.sessionID])
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before.compactMap(\.fit).count, 2)
        let session = try XCTUnwrap(model.sessions[ready.sessionID])
        XCTAssertGreaterThan(model.domain(for: session).upperBound, start.addingTimeInterval(200))
        let fitsBeforeArrival = model.queries.rawFitCount
        _ = try model.store.append(
            SampleRow(timestamp: start.addingTimeInterval(10), values: [-1000]), to: ready.attachmentID)
        model.refreshAll()
        for _ in 0..<50 {
            if model.allForecastStatuses[ready.sessionID]?.compactMap(\.fit).count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            model.allForecastStatuses[ready.sessionID]?.compactMap(\.crossing), before.compactMap(\.crossing))
        XCTAssertEqual(model.queries.rawFitCount, fitsBeforeArrival)
        model.removeForecast(before[0].configuration.id, session: try XCTUnwrap(model.sessions[ready.sessionID]))
        XCTAssertEqual(model.allForecastStatuses[ready.sessionID]?.count, 1)
    }

    func testStatisticsNeverReturnPreviousSelectionAsCurrent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PipePlotStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date(timeIntervalSince1970: 1000)
        for i in 0..<4 {
            _ = try store.append(
                SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID)
        }
        let queries = BackgroundQueries()
        let id = ready.streams[0].id
        let first = BackgroundQueries.QueryKey(start: start, end: start.addingTimeInterval(1), count: 4, last: nil)
        let second = BackgroundQueries.QueryKey(
            start: start.addingTimeInterval(2), end: start.addingTimeInterval(3), count: 4, last: nil)
        queries.requestStats(id, key: first, store: store.samples) { XCTFail("\($0)") }
        XCTAssertNil(queries.stats(id, key: first))
        var result: SelectionStatistics?
        for _ in 0..<50 {
            result = queries.stats(id, key: first)
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(result).mean, 0.5)
        queries.requestStats(id, key: second, store: store.samples) { XCTFail("\($0)") }
        XCTAssertNil(queries.stats(id, key: second))
        for _ in 0..<50 {
            result = queries.stats(id, key: second)
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(result).mean, 2.5)
    }

    func testRapidRequestsAndRepeatedEvictionKeepOneRunningAndLatestDesired() async throws {
        let queue = DispatchQueue(label: "issue29-blocked-worker")
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let slot = BackgroundQueries.Slot<Int, Int>()
        var submissions = 0
        let operation: @Sendable (Int) -> Result<Int, Error> = { key in
            if key == 1 {
                started.signal()
                _ = gate.wait(timeout: .now() + 3)
            }
            return .success(key)
        }
        slot.request(1, on: queue, operation: operation, submitted: { submissions += 1 })
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        for key in 2...50 {
            slot.request(key, on: queue, operation: operation, submitted: { submissions += 1 })
        }
        XCTAssertEqual(submissions, 1)
        for _ in 0..<10 { slot.cancel() }
        slot.request(51, on: queue, operation: operation, submitted: { submissions += 1 })
        XCTAssertEqual(submissions, 1, "Eviction/re-request must reuse the in-flight scheduler slot")
        gate.signal()
        for _ in 0..<100 {
            if slot.exact(51) == 51 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(slot.exact(51), 51)
        XCTAssertEqual(submissions, 2)
        XCTAssertNil(slot.exact(1))
    }

    func testFailureNeedsExplicitRetry() async throws {
        enum ProbeError: Error { case failed }
        let queue = DispatchQueue(label: "issue29-retry-worker")
        let slot = BackgroundQueries.Slot<Int, Int>()
        let attempts = Mutex(0)
        var submissions = 0
        let operation: @Sendable (Int) -> Result<Int, Error> = { key in
            let attempt = attempts.withLock { value in
                value += 1
                return value
            }
            return attempt == 1 ? .failure(ProbeError.failed) : .success(key)
        }
        slot.request(7, on: queue, operation: operation, submitted: { submissions += 1 })
        for _ in 0..<100 {
            if case .failed = slot.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if case .failed = slot.state {} else { XCTFail("Expected a typed failure") }
        slot.request(7, on: queue, operation: operation, submitted: { submissions += 1 })
        XCTAssertEqual(submissions, 1)
        slot.retry(on: queue) { submissions += 1 }
        for _ in 0..<100 {
            if slot.exact(7) == 7 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(slot.exact(7), 7)
        XCTAssertEqual(submissions, 2)
    }

    func testCancelAndRequestSameKeyWaitsForOldScanThenRunsAgain() async throws {
        let queue = DispatchQueue(label: "issue29-same-key-worker")
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let attempts = Mutex(0)
        let slot = BackgroundQueries.Slot<Int, Int>()
        var submissions = 0
        let operation: @Sendable (Int) -> Result<Int, Error> = { key in
            let attempt = attempts.withLock { value in
                value += 1
                return value
            }
            if attempt == 1 {
                started.signal()
                _ = gate.wait(timeout: .now() + 3)
            }
            return .success(key)
        }
        slot.request(7, on: queue, operation: operation, submitted: { submissions += 1 })
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        slot.cancel()
        slot.request(7, on: queue, operation: operation, submitted: { submissions += 1 })
        XCTAssertEqual(submissions, 1)
        gate.signal()
        for _ in 0..<100 {
            if slot.exact(7) == 7 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(slot.exact(7), 7)
        XCTAssertEqual(submissions, 2)
    }

    func testClosedSessionRejectsDelayedRequestsAndReopenRetainsResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        let start = Date(timeIntervalSince1970: 1000)
        for i in 0..<4 {
            _ = try model.store.append(
                SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID)
        }
        model.refreshAll()
        let selection = TimeSelection(start: start, end: start.addingTimeInterval(3))
        let old = try XCTUnwrap(model.sessions[ready.sessionID])
        model.windowClosed(ready.sessionID)
        let baseline = model.queries.submittedQueryCount
        model.requestVisibleSamples(for: old.charts[0], session: old, range: start...start.addingTimeInterval(3))
        model.requestStats(for: ready.streams[0].id, in: selection)
        model.requestNearestSample(ready.streams[0].id, at: start)
        model.requestFit(for: ready.streams[0].id, selection: selection)
        model.requestDerivedSeries(
            StreamDescriptor(
                id: ready.streams[0].id, name: "test",
                derivedSeries: DerivedSeriesConfiguration(interval: 1, window: 3, maximumGap: 2, referenceCadence: 1)),
            range: start...start.addingTimeInterval(3), sessionID: ready.sessionID)
        XCTAssertEqual(model.queries.submittedQueryCount, baseline)
        model.openSession(ready.sessionID)
        let reopened = try XCTUnwrap(model.sessions[ready.sessionID])
        model.requestVisibleSamples(
            for: reopened.charts[0], session: reopened, range: start...start.addingTimeInterval(3))
        for _ in 0..<100 {
            if model.visibleSamples(
                for: reopened.charts[0], session: reopened, range: start...start.addingTimeInterval(3)
            ).samples[ready.streams[0].id]?.count == 4 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            model.visibleSamples(
                for: reopened.charts[0], session: reopened, range: start...start.addingTimeInterval(3)
            ).samples[ready.streams[0].id]?.count, 4)
        XCTAssertEqual(model.queries.submittedQueryCount, baseline + 1)
    }
}
