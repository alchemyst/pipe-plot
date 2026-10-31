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
        var moments = SampleMoments()
        for sample in selected { moments.append(time: 0, value: sample.value) }
        moments.flush()
        let mean = moments.meanValue
        let variance = max(0, moments.valueSquares / Double(moments.count))
        let middle=values.count/2
        let median=values.count.isMultiple(of:2) ? (values[middle-1]+values[middle])/2 : values[middle]
        return SelectionStatistics(count:values.count, minimum:moments.minimum, maximum:moments.maximum, mean:mean,
            populationStandardDeviation:sqrt(variance), median:median, firstSampleAt:first.timestamp, lastSampleAt:last.timestamp, firstValue:first.value, lastValue:last.value)
    }
    public static func linearForecast(samples: [StoredSample], guideValue: Double) -> ForecastResult {
        let sorted=samples.sorted { ($0.timestamp,$0.sequence) < ($1.timestamp,$1.sequence) }
        guard sorted.count >= 2, guideValue.isFinite else { return .insufficientData }
        let origin=sorted[0].timestamp.timeIntervalSince1970
        let points=sorted.map { ($0.timestamp.timeIntervalSince1970-origin,$0.value) }
        var moments = SampleMoments()
        for point in points { moments.append(time: point.0, value: point.1) }
        moments.flush()
        guard let slope = moments.slope else { return .insufficientData }
        let mx = moments.meanTime, my = moments.meanValue
        guard abs(slope) > 1e-15 else { return .flatSlope }
        let intercept=my-slope*mx
        let seconds=(guideValue-intercept)/slope
        let current=points.last!.0
        guard seconds.isFinite, abs(origin + seconds) < 8.64e12 else { return .flatSlope }
        if seconds <= current { return .crossingAlreadyPassed }
        return .crossing(time:Date(timeIntervalSince1970:origin+seconds))
    }
}
