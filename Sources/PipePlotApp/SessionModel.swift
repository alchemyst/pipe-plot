import Foundation
import Observation
import PipePlotCore

/// Presentation state for one session. The app coordinator retains this object
/// through refresh, close/reopen, and trash/restore so its window keeps one identity.
@MainActor @Observable
final class SessionModel {
    let id: SessionID
    private(set) var snapshot: SessionSnapshot?
    var selectedChartID: ChartID?
    var chartAxisDrafts: [ChartID: ChartAxisDraft] = [:]
    var guideAlertDrafts: [UUID: GuideAlertDraft] = [:]
    private(set) var displayActive = true
    private(set) var clockPulse = Date()
    private(set) var forecastStatuses: [ForecastStatus] = []
    private(set) var valueGuideRequest: ValueGuideRequest?
    private var navigationBack: [TimelineState] = []
    private var navigationForward: [TimelineState] = []

    init(id: SessionID) { self.id = id }

    func update(_ value: SessionSnapshot) -> Bool {
        guard snapshot != value else { return false }
        if let request = valueGuideRequest,
            (!value.isOpen || value.isDeleted
                || !value.charts.contains(where: { $0.id == request.chartID && $0.isVisible }))
        {
            valueGuideRequest = nil
        }
        snapshot = value
        var normalized = chartAxisDrafts
        for chart in value.charts {
            guard var draft = normalized[chart.id] else { continue }
            draft.clearValuesMatching(chart)
            normalized[chart.id] = draft.hasChanges ? draft : nil
        }
        if normalized != chartAxisDrafts { chartAxisDrafts = normalized }
        return true
    }

    func setDisplayActive(_ active: Bool) -> Bool {
        guard displayActive != active else { return false }
        displayActive = active
        return true
    }

    func advanceClock(to now: Date) { clockPulse = now }
    func requestValueGuide(for chartID: ChartID) {
        guard let snapshot, snapshot.isOpen, !snapshot.isDeleted,
            snapshot.charts.contains(where: { $0.id == chartID && $0.isVisible })
        else { return }
        valueGuideRequest = ValueGuideRequest(chartID: chartID)
    }
    func takeValueGuideRequest(for chartID: ChartID) -> Bool {
        guard valueGuideRequest?.chartID == chartID else { return false }
        valueGuideRequest = nil
        return true
    }
    func setForecastStatuses(_ statuses: [ForecastStatus]) {
        if forecastStatuses != statuses { forecastStatuses = statuses }
    }

    func navigate(from current: TimelineState) {
        navigationBack.append(current)
        navigationBack = Array(navigationBack.suffix(200))
        navigationForward.removeAll()
    }
    func back(from current: TimelineState) -> TimelineState? {
        guard let previous = navigationBack.popLast() else { return nil }
        navigationForward.append(current)
        return previous
    }
    func forward(from current: TimelineState) -> TimelineState? {
        guard let next = navigationForward.popLast() else { return nil }
        navigationBack.append(current)
        return next
    }
    var canNavigateBack: Bool { !navigationBack.isEmpty }
    var canNavigateForward: Bool { !navigationForward.isEmpty }
}

struct ValueGuideRequest: Identifiable {
    let id = UUID()
    let chartID: ChartID
}

/// Picker data changes only when listing metadata changes, not on sample ticks.
struct SessionListing: Identifiable, Equatable {
    let id: SessionID
    let number: Int
    let title: String
    let isDeleted: Bool
    let isOpen: Bool
    let chartCount: Int
    let streamCount: Int

    init(_ snapshot: SessionSnapshot) {
        id = snapshot.id
        number = snapshot.number
        title = snapshot.title
        isDeleted = snapshot.isDeleted
        isOpen = snapshot.isOpen
        chartCount = snapshot.charts.count
        streamCount = snapshot.charts.reduce(0) { $0 + $1.streams.count }
    }
}
