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
    private(set) var displayActive = true
    private(set) var clockPulse = Date()
    private(set) var forecastStatuses: [ForecastStatus] = []
    private var navigationBack: [TimelineState] = []
    private var navigationForward: [TimelineState] = []

    init(id: SessionID) { self.id = id }

    func update(_ value: SessionSnapshot) -> Bool {
        guard snapshot != value else { return false }
        snapshot = value
        return true
    }

    func setDisplayActive(_ active: Bool) -> Bool {
        guard displayActive != active else { return false }
        displayActive = active
        return true
    }

    func advanceClock(to now: Date) { clockPulse = now }
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
