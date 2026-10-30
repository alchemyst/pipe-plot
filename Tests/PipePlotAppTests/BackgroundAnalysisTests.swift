import XCTest
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
        for i in 0..<100 { _ = try model.store.append(SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID) }
        let guide = Guide(orientation: .horizontalValue, value: 200)
        try model.store.upsertGuide(guide, chartID: ready.chartID)
        model.refreshAll()
        let session = try XCTUnwrap(model.sessions[ready.sessionID])
        let configuration = ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id, selection: TimeSelection(start: start, end: start.addingTimeInterval(99)))
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
        for i in 0..<10 { _ = try model.store.append(SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID) }
        let firstGuide = Guide(orientation: .horizontalValue, value: 100)
        let secondGuide = Guide(orientation: .horizontalValue, value: 200)
        try model.store.upsertGuide(firstGuide, chartID: ready.chartID)
        try model.store.upsertGuide(secondGuide, chartID: ready.chartID)
        let selection = TimeSelection(start: start, end: start.addingTimeInterval(9))
        model.refreshAll()
        for guide in [firstGuide, secondGuide] {
            let session = try XCTUnwrap(model.sessions[ready.sessionID])
            model.setForecast(ForecastConfiguration(streamID: ready.streams[0].id, guideID: guide.id, selection: selection), session: session)
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
        _ = try model.store.append(SampleRow(timestamp: start.addingTimeInterval(10), values: [-1000]), to: ready.attachmentID)
        model.refreshAll()
        XCTAssertEqual(model.allForecastStatuses[ready.sessionID]?.compactMap(\.crossing), before.compactMap(\.crossing))
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
        for i in 0..<4 { _ = try store.append(SampleRow(timestamp: start.addingTimeInterval(Double(i)), values: [Double(i)]), to: ready.attachmentID) }
        let queries = BackgroundQueries()
        let id = ready.streams[0].id
        let first = BackgroundQueries.QueryKey(start: start, end: start.addingTimeInterval(1), count: 4, last: nil)
        let second = BackgroundQueries.QueryKey(start: start.addingTimeInterval(2), end: start.addingTimeInterval(3), count: 4, last: nil)
        XCTAssertNil(queries.stats(id, key: first, store: store.samples) { XCTFail("\($0)") })
        var result: SelectionStatistics?
        for _ in 0..<50 {
            result = queries.stats(id, key: first, store: store.samples) { XCTFail("\($0)") }
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(result).mean, 0.5)
        XCTAssertNil(queries.stats(id, key: second, store: store.samples) { XCTFail("\($0)") })
        for _ in 0..<50 {
            result = queries.stats(id, key: second, store: store.samples) { XCTFail("\($0)") }
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(result).mean, 2.5)
    }
}
