import Foundation

public struct GuideCrossing: Sendable {
    public let sessionID: SessionID
    public let streamID: StreamID
    public let guideID: UUID
    public let streamName: String
    public let guideLabel: String
    public let value: Double
    public let threshold: Double
    public let direction: CrossingDirection
    public let timestamp: Date
}

/// Evaluates every accepted raw row, not reduced display samples. A new producer
/// or edited alarm establishes a baseline; no notification is invented across gaps.
public final class GuideCrossingDetector: @unchecked Sendable {
    private struct Key: Hashable { let stream: StreamID; let guide: UUID }
    private struct State {
        let attachment: AttachmentID
        let threshold: Double
        let configuration: GuideAlert
        var high: Bool
        var previous: Double
        var lastAlert: Date?
    }
    private let lock = NSLock()
    private var states: [Key: State] = [:]
    public init() {}

    public func evaluate(_ row: SampleRow, streams: [StreamID], attachment: AttachmentID, session: SessionSnapshot) -> [GuideCrossing] {
        lock.lock(); defer { lock.unlock() }
        var crossings: [GuideCrossing] = []
        for (streamID, value) in zip(streams, row.values) {
            guard value.isFinite, let chart = session.charts.first(where: { $0.streams.contains(where: { $0.id == streamID }) }),
                  let stream = chart.streams.first(where: { $0.id == streamID }) else { continue }
            let guides = chart.guides.filter { $0.orientation == .horizontalValue && $0.alert != nil }
            let valid = Set(guides.map { Key(stream: streamID, guide: $0.id) })
            states = states.filter { $0.key.stream != streamID || valid.contains($0.key) }
            for guide in guides {
                guard let configuration = guide.alert else { continue }
                let key = Key(stream: streamID, guide: guide.id)
                guard var state = states[key], state.attachment == attachment,
                      state.threshold == guide.value, state.configuration == configuration else {
                    states[key] = State(attachment: attachment, threshold: guide.value, configuration: configuration,
                                        high: value >= guide.value, previous: value, lastAlert: nil)
                    continue
                }
                // Schmitt trigger: a transition requires traversing the configured
                // deadband. Exact repeated threshold values cannot alternate sides.
                let upper = guide.value + configuration.hysteresis
                let lower = guide.value - configuration.hysteresis
                let crossed = state.high ? value <= lower && value < state.previous : value >= upper && value > state.previous
                if crossed {
                    let direction: CrossingDirection = state.high ? .falling : .rising
                    state.high.toggle()
                    let permitted = configuration.direction == .both || configuration.direction == direction
                    let cooledDown = state.lastAlert.map { row.timestamp.timeIntervalSince($0) >= configuration.cooldown } ?? true
                    if permitted && cooledDown {
                        state.lastAlert = row.timestamp
                        crossings.append(GuideCrossing(sessionID: session.id, streamID: streamID, guideID: guide.id,
                            streamName: stream.name, guideLabel: guide.label ?? "Guide", value: value, threshold: guide.value,
                            direction: direction, timestamp: row.timestamp))
                    }
                }
                state.previous = value
                states[key] = state
            }
        }
        return crossings
    }
    public func finish(attachment: AttachmentID) {
        lock.lock(); defer { lock.unlock() }
        states = states.filter { $0.value.attachment != attachment }
    }
}
