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

    func testTimeNavigationPreservesFixedChartRangesDuringCaptureAndAfterReopen() throws {
        let model = try makeModel()
        let session = try model.store.createSession()
        let first = try XCTUnwrap(session.charts.first)
        let second = try model.store.createChart(in: session.id)
        let firstRange = YScale.fixed(min: -10, max: 20)
        let secondRange = YScale.fixed(min: 100, max: 250)
        try model.store.updateSettings(AxisSettings(yScale: firstRange), chartID: first.id)
        try model.store.updateSettings(AxisSettings(yScale: secondRange), chartID: second.id)
        let producers = try [first.id, second.id].map { chartID in
            try model.store.registerSampler(
                intent: .chart(chartID: chartID, lineNames: []), sampler: SamplerIntent(columnCount: 1))
        }
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        let selection = TimeSelection(start: start + 5, end: start + 10)
        try model.store.setSelection(selection, sessionID: session.id)
        let undo = model.undoManager(for: session.id)
        let undoBeforeNavigation = undo.undoActionName
        XCTAssertFalse(undoBeforeNavigation.isEmpty)
        let presentation = model.sessionModel(for: session.id)

        func capture(_ index: Int) throws -> SessionSnapshot {
            for (chartIndex, producer) in producers.enumerated() {
                try model.store.append(
                    SampleRow(timestamp: start + Double(index), values: [Double(index + 100 * chartIndex)]),
                    to: producer.attachmentID)
            }
            model.refresh(session.id)
            return try XCTUnwrap(presentation.snapshot)
        }

        func checkState(_ snapshot: SessionSnapshot, sampleCount: Int64) {
            XCTAssertEqual(snapshot.charts.map(\.settings.yScale), [firstRange, secondRange])
            XCTAssertEqual(snapshot.timeline.selection, selection)
            XCTAssertEqual(snapshot.charts.flatMap(\.streams).map(\.sampleCount), [sampleCount, sampleCount])
            XCTAssertEqual(undo.undoActionName, undoBeforeNavigation)
            XCTAssertFalse(undo.canRedo)
        }

        model.showAllHistory(try capture(0))
        let allHistory = try capture(1)
        XCTAssertFalse(allHistory.timeline.followNow)
        XCTAssertEqual(allHistory.timeline.visibleStart, start)
        checkState(allHistory, sampleCount: 2)

        model.followNow(allHistory)
        let following = try capture(2)
        XCTAssertTrue(following.timeline.followNow)
        checkState(following, sampleCount: 3)

        model.navigateBack(following)
        let back = try capture(3)
        XCTAssertEqual(back.timeline, allHistory.timeline)
        checkState(back, sampleCount: 4)

        model.navigateForward(back)
        let forward = try capture(4)
        XCTAssertEqual(forward.timeline, following.timeline)
        checkState(forward, sampleCount: 5)

        XCTAssertTrue(model.frameSelection(forward))
        let framed = try capture(5)
        XCTAssertFalse(framed.timeline.followNow)
        XCTAssertEqual(framed.timeline.visibleStart, selection.start)
        XCTAssertEqual(framed.timeline.visibleEnd, selection.end)
        checkState(framed, sampleCount: 6)

        model.windowClosed(session.id)
        XCTAssertFalse(try XCTUnwrap(presentation.snapshot).isOpen)
        model.openSession(session.id)
        let reopened = try XCTUnwrap(presentation.snapshot)
        XCTAssertTrue(reopened.isOpen)
        checkState(reopened, sampleCount: 6)
        for (chartIndex, producer) in producers.enumerated() {
            XCTAssertEqual(
                try model.store.samples.query(streamID: producer.streams[0].id).map(\.value),
                (0..<6).map { Double($0 + 100 * chartIndex) })
        }
        undo.undo()
        XCTAssertNil(presentation.snapshot?.timeline.selection)
        XCTAssertEqual(presentation.snapshot?.charts.map(\.settings.yScale), [firstRange, secondRange])
    }

    func testBulkTrashAndCleanupRespectTheClosedSessionCutoff() throws {
        let model = try makeModel()
        let old = try model.store.createSession()
        let reopened = try model.store.createSession()
        let boundary = try model.store.createSession()
        let other = try model.store.createSession()
        try model.store.setSessionOpen(false, sessionID: old.id)
        try model.store.setSessionOpen(false, sessionID: reopened.id)
        try model.store.setSessionOpen(false, sessionID: boundary.id)
        let oldSnapshot = try XCTUnwrap(model.store.snapshot(sessionID: old.id))
        let boundarySnapshot = try XCTUnwrap(model.store.snapshot(sessionID: boundary.id))
        let cutoff = try XCTUnwrap(boundarySnapshot.lastClosedAt)
        XCTAssertLessThan(try XCTUnwrap(oldSnapshot.lastClosedAt), cutoff)
        model.refreshAll()

        // An explicit producer registration can reopen a session while the picker still shows it as closed.
        _ = try model.store.registerSampler(
            intent: .session(sessionID: reopened.id, lineNames: []), sampler: SamplerIntent(columnCount: 1))
        model.deleteSessions([old.id, reopened.id, boundary.id], closedBefore: cutoff)
        XCTAssertEqual(Set(try model.store.listDeletedSessions().map(\.id)), [old.id])
        XCTAssertEqual(model.sessionCatalog[reopened.id]?.isOpen, true)

        model.deleteSessions([boundary.id, other.id])
        XCTAssertEqual(Set(try model.store.listDeletedSessions().map(\.id)), [old.id, boundary.id, other.id])
        model.restoreSession(boundary.id)
        XCTAssertEqual(model.sessionCatalog[boundary.id]?.isDeleted, false)
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
