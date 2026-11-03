import XCTest
@testable import PipePlotApp
import PipePlotCore

@MainActor
final class ScaleTests: XCTestCase {
    func testExplicitScaleRejectsInvalidFixedRangesWithoutSwitchingToAutomatic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PipePlotAppModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try model.store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 1))
        model.refreshAll()
        func scale() throws -> YScale {
            try XCTUnwrap(model.sessions[ready.sessionID]?.charts.first?.settings.yScale)
        }
        XCTAssertEqual(try scale(), .automatic)
        model.updateScale(.fixed(min: -2, max: 8), chart: ready.chartID)
        XCTAssertEqual(try scale(), .fixed(min: -2, max: 8))
        let undoName = model.store.undoActionName(sessionID: ready.sessionID)
        for invalid in [
            YScale.fixed(min: 1, max: 1), .fixed(min: 2, max: 1),
            .fixed(min: .nan, max: 1), .fixed(min: 0, max: .infinity),
        ] {
            model.clearError()
            model.updateScale(invalid, chart: ready.chartID)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try scale(), .fixed(min: -2, max: 8))
            XCTAssertEqual(model.store.undoActionName(sessionID: ready.sessionID), undoName)
        }
        model.clearError()
        model.updateScale(.automatic, chart: ready.chartID)
        XCTAssertEqual(try scale(), .automatic)
        XCTAssertNil(model.errorMessage)
    }
}
