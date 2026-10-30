import Foundation

/// Finds actual observed local extrema in a screen-sized neighbourhood.
/// It never interpolates or manufactures points; only indices from `samples` are returned.
public enum PeakFinder {
    public enum Kind: Equatable, Sendable { case peak, trough }
    public struct Extremum: Sendable {
        public let sampleIndex: Int
        public let kind: Kind
        public let prominence: Double
    }

    public static func extrema(samples: [StoredSample], visibleRange: ClosedRange<Date>, plotWidth: Double,
                               valueRange: ClosedRange<Double>, maximumCount: Int = 3) -> [Extremum] {
        guard samples.count >= 3, plotWidth > 1, maximumCount > 0 else { return [] }
        let span = max(visibleRange.upperBound.timeIntervalSince(visibleRange.lowerBound), .leastNonzeroMagnitude)
        let neighborhood = max(1.0, span * 14.0 / plotWidth)
        let minSpacing = span * 56.0 / plotWidth
        let valueSpan = max(valueRange.upperBound - valueRange.lowerBound, .leastNonzeroMagnitude)
        var candidates: [Extremum] = []
        for index in samples.indices where index > 0 && index + 1 < samples.count {
            let sample = samples[index]
            guard sample.timestamp >= visibleRange.lowerBound, sample.timestamp <= visibleRange.upperBound,
                  sample.value.isFinite else { continue }
            var leftStart = index - 1
            while leftStart > 0 && sample.timestamp.timeIntervalSince(samples[leftStart - 1].timestamp) <= neighborhood { leftStart -= 1 }
            var rightEnd = index + 1
            while rightEnd + 1 < samples.count && samples[rightEnd + 1].timestamp.timeIntervalSince(sample.timestamp) <= neighborhood { rightEnd += 1 }
            guard leftStart < index, rightEnd > index else { continue }
            let left = samples[leftStart..<index].map(\.value)
            let right = samples[(index + 1)...rightEnd].map(\.value)
            guard let leftMin = left.min(), let leftMax = left.max(),
                  let rightMin = right.min(), let rightMax = right.max() else { continue }
            let leftLocalMax = leftMax <= sample.value
            let rightLocalMax = rightMax <= sample.value
            let leftLocalMin = leftMin >= sample.value
            let rightLocalMin = rightMin >= sample.value
            if leftLocalMax && rightLocalMax {
                let prominence = max(0, sample.value - max(leftMin, rightMin))
                if prominence >= valueSpan * 0.035 { candidates.append(Extremum(sampleIndex: index, kind: .peak, prominence: prominence)) }
            } else if leftLocalMin && rightLocalMin {
                let prominence = max(0, min(leftMax, rightMax) - sample.value)
                if prominence >= valueSpan * 0.035 { candidates.append(Extremum(sampleIndex: index, kind: .trough, prominence: prominence)) }
            }
        }
        let ranked = candidates.sorted { $0.prominence > $1.prominence }
        var selected: [Extremum] = []
        for candidate in ranked {
            let date = samples[candidate.sampleIndex].timestamp
            guard selected.allSatisfy({ abs(date.timeIntervalSince(samples[$0.sampleIndex].timestamp)) >= minSpacing }) else { continue }
            selected.append(candidate)
            if selected.count == maximumCount { break }
        }
        return selected.sorted { samples[$0.sampleIndex].timestamp < samples[$1.sampleIndex].timestamp }
    }
}
