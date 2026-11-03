import Foundation
import Observation
import Synchronization
import XCTest
@testable import PipePlotApp
import PipePlotCore

@MainActor
final class SessionModelTests: XCTestCase {
    private func makeModel() throws -> PipePlotAppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PipePlotAppModel(databaseURL: directory.appendingPathComponent("sessions.sqlite"))
    }

    func testOneSessionTickSelectionAndNavigationDoNotInvalidateAnotherSession() async throws {
        let model = try makeModel()
        let first = try model.store.createSession()
        let second = try model.store.createSession()
        let a = try model.store.registerSampler(
            intent: .session(sessionID: first.id, lineNames: []), sampler: SamplerIntent(columnCount: 1))
        let b = try model.store.registerSampler(
            intent: .session(sessionID: second.id, lineNames: []), sampler: SamplerIntent(columnCount: 1))
        let start = Date().addingTimeInterval(-10)
        for index in 0..<3 {
            _ = try model.store.append(
                SampleRow(timestamp: start.addingTimeInterval(Double(index)), values: [Double(index)]),
                to: b.attachmentID)
        }
        model.refreshAll()
        let aModel = model.sessionModel(for: first.id)
        let bModel = model.sessionModel(for: second.id)
        let bSnapshot = try XCTUnwrap(bModel.snapshot)
        let bClock = bModel.clockPulse
        let selection = TimeSelection(start: start, end: start.addingTimeInterval(2))
        model.requestStats(for: b.streams[0].id, in: selection)
        for _ in 0..<50 {
            if model.stats(for: b.streams[0].id, in: selection) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.stats(for: b.streams[0].id, in: selection))

        let invalidations = Mutex(0)
        withObservationTracking {
            _ = bModel.snapshot?.timeline.selection
            _ = bModel.clockPulse
            _ = bModel.selectedChartID
            _ = bModel.canNavigateBack
            _ = bModel.forecastStatuses
            _ = model.sessionNow(bSnapshot)
            _ = model.stats(for: b.streams[0].id, in: selection)
        } onChange: {
            invalidations.withLock { $0 += 1 }
        }
        let catalogInvalidations = Mutex(0)
        withObservationTracking {
            _ = model.sessionCatalog
        } onChange: {
            catalogInvalidations.withLock { $0 += 1 }
        }

        _ = try model.store.append(SampleRow(timestamp: start, values: [42]), to: a.attachmentID)
        model.tick(first.id, now: bClock.addingTimeInterval(30))
        model.selectChart(a.chartID, sessionID: first.id)
        let aSnapshot = try XCTUnwrap(aModel.snapshot)
        var timeline = aSnapshot.timeline
        timeline.followNow = false
        timeline.visibleStart = start
        timeline.visibleEnd = start.addingTimeInterval(2)
        model.navigate(timeline, session: aSnapshot)
        model.setSelection(selection, session: try XCTUnwrap(aModel.snapshot))
        model.refreshAll()

        XCTAssertEqual(bModel.clockPulse, bClock)
        XCTAssertEqual(bModel.snapshot, bSnapshot)
        XCTAssertNil(bModel.selectedChartID)
        XCTAssertFalse(bModel.canNavigateBack)
        XCTAssertEqual(invalidations.withLock { $0 }, 0)
        XCTAssertEqual(catalogInvalidations.withLock { $0 }, 0)
        XCTAssertTrue(aModel.canNavigateBack)
        XCTAssertEqual(aModel.selectedChartID, a.chartID)
    }

    func testSessionObjectSurvivesRefreshCloseReopenTrashAndRestore() throws {
        let model = try makeModel()
        let created = try model.store.createSession()
        model.refreshAll()
        let presentation = model.sessionModel(for: created.id)
        XCTAssertTrue(presentation.snapshot?.isOpen == true)
        model.refresh(created.id)
        XCTAssertTrue(model.sessionModel(for: created.id) === presentation)

        model.windowClosed(created.id)
        XCTAssertFalse(presentation.snapshot?.isOpen ?? true)
        model.openSession(created.id)
        XCTAssertTrue(presentation.snapshot?.isOpen == true)
        model.deleteSession(created.id)
        XCTAssertTrue(presentation.snapshot?.isDeleted == true)
        model.restoreSession(created.id)
        XCTAssertFalse(presentation.snapshot?.isDeleted ?? true)
        XCTAssertTrue(model.sessionModel(for: created.id) === presentation)
    }
}
