import XCTest
@testable import PipePlotCore

final class GuideCrossingTests: XCTestCase {
    private let streamID = UUID(), chartID = UUID(), sessionID = UUID(), attachment = UUID()
    private func session(_ guide: Guide) -> SessionSnapshot {
        SessionSnapshot(id: sessionID, number: 1, title: "Test", charts: [
            ChartSnapshot(id: chartID, title: "Chart", streams: [StreamDescriptor(id: streamID, name: "memory")], guides: [guide])
        ])
    }
    func testDirectionDeadbandAndCooldownUseEveryRawRow() {
        let detector = GuideCrossingDetector()
        let guide = Guide(orientation: .horizontalValue, value: 10, alert: GuideAlert(direction: .both, hysteresis: 1, cooldown: 10))
        let samples: [(Double, Double)] = [(0, 8), (1, 10.5), (2, 11), (3, 10), (4, 9), (5, 11), (14, 9)]
        let events = samples.flatMap { time, value in
            detector.evaluate(SampleRow(timestamp: Date(timeIntervalSince1970: time), values: [value]), streams: [streamID], attachment: attachment, session: session(guide))
        }
        XCTAssertEqual(events.map(\.direction), [.rising, .falling])
        XCTAssertEqual(events.map(\.timestamp), [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 14)])
    }
    func testRepeatedThresholdDoesNotChatterAndDirectionFilterWorks() {
        let detector = GuideCrossingDetector()
        let guide = Guide(orientation: .horizontalValue, value: 0, alert: GuideAlert(direction: .rising, hysteresis: 0, cooldown: 0))
        let values = [-1.0, 0, 0, 0, 1, 0, -1, 0]
        let events = values.enumerated().flatMap { index, value in
            detector.evaluate(SampleRow(timestamp: Date(timeIntervalSince1970: Double(index)), values: [value]), streams: [streamID], attachment: attachment, session: session(guide))
        }
        XCTAssertEqual(events.map(\.direction), [.rising, .rising])
    }
    func testEditingGuideOrReconnectEstablishesBaseline() {
        let detector = GuideCrossingDetector()
        var guide = Guide(orientation: .horizontalValue, value: 5, alert: GuideAlert(cooldown: 0))
        func feed(_ value: Double, _ attachment: UUID) -> [GuideCrossing] {
            detector.evaluate(SampleRow(values: [value]), streams: [streamID], attachment: attachment, session: session(guide))
        }
        XCTAssertTrue(feed(1, attachment).isEmpty)
        XCTAssertTrue(feed(10, UUID()).isEmpty)
        guide.value = 20
        XCTAssertTrue(feed(25, attachment).isEmpty)
        XCTAssertEqual(feed(1, attachment).first?.direction, .falling)
        guide.alert = nil
        XCTAssertTrue(feed(30, attachment).isEmpty)
    }
}
