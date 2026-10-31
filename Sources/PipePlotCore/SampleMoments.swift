import Accelerate

/// Accelerate computes centered moments in bounded batches; merging batches keeps
/// SQLite range analysis independent of history length. Times are relative seconds.
struct SampleMoments {
    private static let batchSize = 1024
    private var times: [Double] = []
    private var values: [Double] = []
    private(set) var count = 0
    private(set) var meanTime = 0.0
    private(set) var meanValue = 0.0
    private(set) var timeSquares = 0.0
    private(set) var valueSquares = 0.0
    private(set) var covariance = 0.0
    private(set) var minimum = Double.infinity
    private(set) var maximum = -Double.infinity

    mutating func append(time: Double, value: Double) {
        times.append(time)
        values.append(value)
        if values.count == Self.batchSize { flush() }
    }

    mutating func flush() {
        guard let firstTime = times.first, let firstValue = values.first else { return }
        // Offset before reducing so a large DC value does not dominate the mean.
        let relativeTimes = vDSP.add(-firstTime, times)
        let relativeValues = vDSP.add(-firstValue, values)
        let timeOffset = vDSP.mean(relativeTimes)
        let valueOffset = vDSP.mean(relativeValues)
        let centeredTimes = vDSP.add(-timeOffset, relativeTimes)
        let centeredValues = vDSP.add(-valueOffset, relativeValues)
        let batchMeanTime = firstTime + timeOffset
        let batchMeanValue = firstValue + valueOffset
        let batchCount = values.count
        let combinedCount = count + batchCount
        let weight = Double(batchCount) / Double(combinedCount)
        let crossWeight = Double(count) * weight
        let dx = batchMeanTime - meanTime
        let dy = batchMeanValue - meanValue
        timeSquares += vDSP.sumOfSquares(centeredTimes)
        valueSquares += vDSP.sumOfSquares(centeredValues)
        covariance += vDSP.dot(centeredTimes, centeredValues)
        if count == 0 {
            meanTime = batchMeanTime
            meanValue = batchMeanValue
        } else {
            timeSquares += dx * dx * crossWeight
            valueSquares += dy * dy * crossWeight
            covariance += dx * dy * crossWeight
            meanTime += dx * weight
            meanValue += dy * weight
        }
        count = combinedCount
        minimum = min(minimum, vDSP.minimum(values))
        maximum = max(maximum, vDSP.maximum(values))
        times.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
    }

    var slope: Double? {
        guard count >= 2, timeSquares > 0, timeSquares.isFinite, covariance.isFinite else { return nil }
        let result = covariance / timeSquares
        return result.isFinite ? result : nil
    }
}
