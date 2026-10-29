import Foundation

public struct SelectionStatistics: Codable, Equatable, Sendable {
    public var count: Int
    public var minimum: Double
    public var maximum: Double
    public var mean: Double
    public var populationStandardDeviation: Double
    public var median: Double
    public var firstSampleAt: Date
    public var lastSampleAt: Date
    public var firstValue: Double
    public var lastValue: Double
    public var change: Double { lastValue - firstValue }
}
public enum ForecastResult: Equatable, Sendable { case insufficientData, flatSlope, crossingAlreadyPassed, crossing(time: Date) }
public enum Analysis {
    public static func statistics(samples: [StoredSample], in range: ClosedRange<Date>? = nil) -> SelectionStatistics? {
        let selected = samples.filter { sample in range.map { $0.contains(sample.timestamp) } ?? true }.sorted { ($0.timestamp,$0.sequence) < ($1.timestamp,$1.sequence) }
        guard let first=selected.first, let last=selected.last else { return nil }
        let values=selected.map(\.value).sorted()
        let n=Double(values.count), mean=values.reduce(0,+)/n
        let variance=values.reduce(0.0) { $0 + ($1-mean)*($1-mean) } / n
        let middle=values.count/2
        let median=values.count.isMultiple(of:2) ? (values[middle-1]+values[middle])/2 : values[middle]
        return SelectionStatistics(count:values.count, minimum:values[0], maximum:values[values.count-1], mean:mean,
            populationStandardDeviation:sqrt(variance), median:median, firstSampleAt:first.timestamp, lastSampleAt:last.timestamp, firstValue:first.value, lastValue:last.value)
    }
    public static func linearForecast(samples: [StoredSample], guideValue: Double) -> ForecastResult {
        let sorted=samples.sorted { ($0.timestamp,$0.sequence) < ($1.timestamp,$1.sequence) }
        guard sorted.count >= 2, guideValue.isFinite else { return .insufficientData }
        let origin=sorted[0].timestamp.timeIntervalSince1970
        let points=sorted.map { ($0.timestamp.timeIntervalSince1970-origin,$0.value) }
        let mx=points.reduce(0.0){$0+$1.0}/Double(points.count), my=points.reduce(0.0){$0+$1.1}/Double(points.count)
        let denominator=points.reduce(0.0){$0+($1.0-mx)*($1.0-mx)}
        guard denominator > 0 else { return .insufficientData }
        let slope=points.reduce(0.0){$0+($1.0-mx)*($1.1-my)}/denominator
        guard abs(slope) > 1e-15 else { return .flatSlope }
        let intercept=my-slope*mx
        let seconds=(guideValue-intercept)/slope
        let current=points.last!.0
        guard seconds.isFinite, abs(origin + seconds) < 8.64e12 else { return .flatSlope }
        if seconds <= current { return .crossingAlreadyPassed }
        return .crossing(time:Date(timeIntervalSince1970:origin+seconds))
    }
}
