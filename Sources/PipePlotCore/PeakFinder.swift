import Foundation

/// Ranks observed turning points by topographic prominence within each visible segment.
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
        let span = visibleRange.upperBound.timeIntervalSince(visibleRange.lowerBound)
        guard span > 0 else { return [] }
        let spacing = span * 56 / plotWidth
        var candidates: [Extremum] = []
        var start = 0
        while start < samples.count {
            guard samples[start].timestamp >= visibleRange.lowerBound,
                  samples[start].timestamp <= visibleRange.upperBound, samples[start].value.isFinite else {
                start += 1; continue
            }
            var end = start + 1
            while end < samples.count, samples[end].timestamp <= visibleRange.upperBound,
                  samples[end].timestamp >= visibleRange.lowerBound, samples[end].value.isFinite,
                  samples[end].segmentID == samples[end - 1].segmentID { end += 1 }
            let count = end - start
            if count >= 3 {
                for kind in [Kind.peak, .trough] {
                    let values = (start..<end).map { kind == .peak ? samples[$0].value : -samples[$0].value }
                    // Nearest strictly higher samples bound each prominence basin.
                    var left = Array(repeating: 0, count: count)
                    var right = Array(repeating: count - 1, count: count)
                    var stack: [Int] = []
                    for i in 0..<count {
                        while let last = stack.last, values[last] <= values[i] { stack.removeLast() }
                        left[i] = stack.last ?? 0
                        stack.append(i)
                    }
                    stack.removeAll(keepingCapacity: true)
                    for i in (0..<count).reversed() {
                        while let last = stack.last, values[last] <= values[i] { stack.removeLast() }
                        right[i] = stack.last ?? (count - 1)
                        stack.append(i)
                    }
                    // Range-minimum tree keeps prominence calculations O(n log n).
                    var tree = Array(repeating: Double.infinity, count: count * 2)
                    for i in 0..<count { tree[count + i] = values[i] }
                    if count > 1 { for i in (1..<count).reversed() { tree[i] = min(tree[i * 2], tree[i * 2 + 1]) } }
                    func minimum(_ lo: Int, _ hi: Int) -> Double {
                        var l = lo + count, r = hi + count + 1, result = Double.infinity
                        while l < r {
                            if l % 2 == 1 { result = min(result, tree[l]); l += 1 }
                            if r % 2 == 1 { r -= 1; result = min(result, tree[r]) }
                            l /= 2; r /= 2
                        }
                        return result
                    }
                    var i = 1
                    while i < count - 1 {
                        var plateauEnd = i
                        while plateauEnd + 1 < count && values[plateauEnd + 1] == values[i] { plateauEnd += 1 }
                        if plateauEnd < count - 1, values[i] > values[i - 1], values[i] > values[plateauEnd + 1] {
                            let middle = (i + plateauEnd) / 2
                            let prominence = values[i] - max(minimum(left[i], i), minimum(plateauEnd, right[plateauEnd]))
                            if prominence > 0 { candidates.append(Extremum(sampleIndex: start + middle, kind: kind, prominence: prominence)) }
                        }
                        i = plateauEnd + 1
                    }
                }
            }
            start = end
        }
        let ranked = candidates.sorted {
            if $0.prominence != $1.prominence { return $0.prominence > $1.prominence }
            return $0.sampleIndex < $1.sampleIndex
        }
        var selected: [Extremum] = []
        for candidate in ranked {
            let date = samples[candidate.sampleIndex].timestamp
            guard selected.allSatisfy({ abs(date.timeIntervalSince(samples[$0.sampleIndex].timestamp)) >= spacing }) else { continue }
            selected.append(candidate)
            if selected.count == maximumCount { break }
        }
        return selected.sorted { $0.sampleIndex < $1.sampleIndex }
    }
}
