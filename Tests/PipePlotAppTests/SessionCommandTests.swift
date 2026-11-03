import AppKit
import Foundation
import XCTest
@testable import PipePlotApp
import PipePlotCore
import SwiftUI

@MainActor
final class SessionCommandTests: XCTestCase {
    func testVisibleRangeCommandUsesFocusedSessionAndSemanticUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("selection-command.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        model.refreshAll()
        let presentation = model.sessionModel(for: ready.sessionID)
        let target = SessionCommandTarget(focused: presentation, editingText: false)
        XCTAssertTrue(target.canSelectVisibleRange)
        let range = model.domain(for: try XCTUnwrap(target.snapshot))
        target.selectVisibleRange(using: model)
        let selection = try XCTUnwrap(model.store.snapshot(sessionID: ready.sessionID)?.timeline.selection)
        XCTAssertEqual(selection.start.timeIntervalSince(range.lowerBound), 0, accuracy: 1)
        XCTAssertEqual(selection.end.timeIntervalSince(range.upperBound), 0, accuracy: 1)
        XCTAssertEqual(selection.selectedStreamIDs, [ready.streams[0].id])

        let textTarget = SessionCommandTarget(focused: presentation, editingText: true)
        XCTAssertFalse(textTarget.canSelectVisibleRange)
        textTarget.selectVisibleRange(using: model)
        XCTAssertEqual(try model.store.snapshot(sessionID: ready.sessionID)?.timeline.selection, selection)
        model.undoManager(for: ready.sessionID).undo()
        XCTAssertNil(try model.store.snapshot(sessionID: ready.sessionID)?.timeline.selection)
    }

    func testFocusedTargetsRouteOnceAcrossSessionsAndSelectedCharts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("commands.sqlite"))
        let first = try model.store.createSession()
        let second = try model.store.createSession()
        let firstChart = try XCTUnwrap(first.charts.first)
        let later = try model.store.createChart(in: first.id, after: firstChart.id)
        model.refreshAll()

        let a = model.sessionModel(for: first.id)
        let b = model.sessionModel(for: second.id)
        a.selectedChartID = firstChart.id
        let focusedA = SessionCommandTarget(focused: a, editingText: false)
        let focusedB = SessionCommandTarget(focused: b, editingText: false)

        focusedA.createChart(using: model)
        let aCharts = try XCTUnwrap(a.snapshot?.charts.map(\.id))
        XCTAssertEqual(aCharts.count, 3)
        XCTAssertEqual(aCharts.first, firstChart.id)
        XCTAssertEqual(aCharts.last, later.id)
        XCTAssertEqual(a.selectedChartID, aCharts[1])
        XCTAssertEqual(b.snapshot?.charts.count, 1)

        focusedB.createChart(using: model)
        XCTAssertEqual(b.snapshot?.charts.count, 2)
        XCTAssertEqual(a.snapshot?.charts.map(\.id), aCharts)
        XCTAssertEqual(b.selectedChartID, b.snapshot?.charts.last?.id)

        focusedB.requestValueGuide()
        XCTAssertEqual(b.valueGuideRequest?.chartID, b.selectedChartID)
        XCTAssertTrue(b.takeValueGuideRequest(for: try XCTUnwrap(b.selectedChartID)))
        XCTAssertFalse(b.takeValueGuideRequest(for: try XCTUnwrap(b.selectedChartID)))
        XCTAssertNil(a.valueGuideRequest)

        let expectedTimeGuide = model.sessionNow(try XCTUnwrap(a.snapshot))
        focusedA.addTimeGuide(using: model)
        XCTAssertEqual(a.snapshot?.timeGuides.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(a.snapshot?.timeGuides.first?.value), expectedTimeGuide.timeIntervalSince1970, accuracy: 0.001
        )
        XCTAssertEqual(b.snapshot?.timeGuides.count, 0)
        model.undoManager(for: first.id).undo()
        XCTAssertEqual(a.snapshot?.timeGuides.count, 0)
        model.undoManager(for: first.id).redo()
        XCTAssertEqual(a.snapshot?.timeGuides.count, 1)
        XCTAssertEqual(b.snapshot?.timeGuides.count, 0)
    }

    func testNoFocusedEditableSessionDisablesContextualCommands() throws {
        XCTAssertTrue(SessionWindow.acceptsNavigationModifiers([]))
        XCTAssertFalse(SessionWindow.acceptsNavigationModifiers([.command, .shift]))
        XCTAssertFalse(SessionWindow.acceptsNavigationModifiers([.command, .option]))
        XCTAssertTrue(SessionCommandTarget.isTextResponder(NSTextView()))
        XCTAssertTrue(SessionCommandTarget.isTextResponder(NSTextField()))
        XCTAssertFalse(SessionCommandTarget.isTextResponder(NSView()))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("availability.sqlite"))
        let created = try model.store.createSession()
        model.refreshAll()
        let session = model.sessionModel(for: created.id)
        let picker = SessionCommandTarget(focused: nil, editingText: false)
        let textEditor = SessionCommandTarget(focused: session, editingText: true)
        for target in [picker, textEditor] {
            XCTAssertNil(target.snapshot)
            XCTAssertFalse(target.canCreateChart)
            XCTAssertFalse(target.canAddGuide)
            XCTAssertFalse(target.canSelectVisibleRange)
            target.createChart(using: model)
            target.addTimeGuide(using: model)
            target.requestValueGuide()
            target.selectVisibleRange(using: model)
        }
        XCTAssertEqual(session.snapshot?.charts.count, 1)
        XCTAssertTrue(session.snapshot?.timeGuides.isEmpty == true)
        XCTAssertNil(session.valueGuideRequest)

        model.windowClosed(created.id)
        let closed = SessionCommandTarget(focused: session, editingText: false)
        XCTAssertFalse(closed.canCreateChart)
        XCTAssertFalse(closed.canAddGuide)
        XCTAssertFalse(closed.canSelectVisibleRange)
        model.openSession(created.id)
        model.deleteSession(created.id)
        let trashed = SessionCommandTarget(focused: session, editingText: false)
        XCTAssertFalse(trashed.canCreateChart)
        XCTAssertFalse(trashed.canAddGuide)
        XCTAssertFalse(trashed.canSelectVisibleRange)
        trashed.createChart(using: model)
        trashed.addTimeGuide(using: model)
        XCTAssertEqual(session.snapshot?.charts.count, 1)
        XCTAssertTrue(session.snapshot?.timeGuides.isEmpty == true)
    }

    func testPendingGuideRequestIsSingleUseAndClearsWithItsChartOrSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("guide-request.sqlite"))
        let created = try model.store.createSession()
        let firstChart = try XCTUnwrap(created.charts.first)
        let secondChart = try model.store.createChart(in: created.id, after: firstChart.id)
        model.refreshAll()
        let presentation = model.sessionModel(for: created.id)

        presentation.requestValueGuide(for: secondChart.id)
        XCTAssertFalse(presentation.takeValueGuideRequest(for: firstChart.id))
        XCTAssertEqual(presentation.valueGuideRequest?.chartID, secondChart.id)
        model.deleteChart(secondChart.id)
        XCTAssertNil(presentation.valueGuideRequest)
        presentation.requestValueGuide(for: secondChart.id)
        XCTAssertNil(presentation.valueGuideRequest)

        presentation.requestValueGuide(for: firstChart.id)
        model.windowClosed(created.id)
        XCTAssertNil(presentation.valueGuideRequest)
        presentation.requestValueGuide(for: firstChart.id)
        XCTAssertNil(presentation.valueGuideRequest)
        model.openSession(created.id)
        presentation.requestValueGuide(for: firstChart.id)
        model.deleteSession(created.id)
        XCTAssertNil(presentation.valueGuideRequest)
        presentation.requestValueGuide(for: firstChart.id)
        XCTAssertNil(presentation.valueGuideRequest)
    }
}
