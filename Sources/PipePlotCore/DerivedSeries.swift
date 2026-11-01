import Foundation
import Accelerate

public enum SmoothingKernel: String, Codable, CaseIterable, Sendable {
    case savitzkyGolay, weightedSavitzkyGolay
    public var title: String { self == .savitzkyGolay ? "Savitzky–Golay" : "Weighted Savitzky–Golay" }
}
public enum ResamplingPolicy: String, Codable, CaseIterable, Sendable { case linear, observedOnly }
public enum DerivedSeriesError: Error, LocalizedError {
    case invalidSettings, downsampling, outOfOrder
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: return "Use a positive interval, a window of 4–2048 intervals, and a gap limit at least as large as the interval."
        case .downsampling: return "Downsampling is not supported: choose a finer interval no larger than the input cadence. An antialiasing stage is required before decimation."
        case .outOfOrder: return "Derived analysis requires samples in timestamp order."
        }
    }
}

/// Fixed until explicitly edited. No adaptive cadence changes or provisional edges.
public struct DerivedSeriesConfiguration: Codable, Equatable, Sendable {
    public var referenceCadence: TimeInterval?
    public var interval: TimeInterval
    public var window: TimeInterval
    public var maximumGap: TimeInterval
    public var kernel: SmoothingKernel
    public var resampling: ResamplingPolicy
    public init(interval: TimeInterval, window: TimeInterval, maximumGap: TimeInterval,
                kernel: SmoothingKernel = .weightedSavitzkyGolay, resampling: ResamplingPolicy = .linear, referenceCadence: TimeInterval? = nil) {
        self.referenceCadence = referenceCadence; self.interval = interval; self.window = window; self.maximumGap = maximumGap
        self.kernel = kernel; self.resampling = resampling
    }
    public func validate(cadence: TimeInterval? = nil) throws {
        guard interval.isFinite, interval >= 0.001, window.isFinite,
              (4...2048).contains(window / interval), maximumGap.isFinite,
              maximumGap >= interval, maximumGap <= 86400 * 7, maximumGap / interval <= 10000 else { throw DerivedSeriesError.invalidSettings }
        if let referenceCadence, !referenceCadence.isFinite || referenceCadence <= 0 { throw DerivedSeriesError.invalidSettings }
        if let cadence = cadence ?? referenceCadence, interval > cadence * (1 + 1e-6) { throw DerivedSeriesError.downsampling }
    }
    public var radius: Int { max(2, min(1024, Int((window / interval / 2).rounded()))) }
    public var effectiveWindow: TimeInterval { Double(2 * radius) * interval }
    public var delay: TimeInterval { Double(radius) * interval }
}

public struct DerivedPoint: Equatable, Sendable {
    public let timestamp: Date
    public let smoothed: Double
    public let derivative: Double
    /// Count of grid values reconstructed by interpolation in this estimate's support.
    public let interpolatedCount: Int
    public let run: Int
}

/// Cubic local polynomial kernels, including first derivative in value/second.
/// Weighted orthogonal polynomials avoid normal-equation matrix inversion.
public struct PolynomialKernel: Sendable {
    public let smoothing: [Double]
    public let derivative: [Double]
    public init(configuration c: DerivedSeriesConfiguration) throws {
        try c.validate()
        let m = c.radius, n = 2 * m + 1
        let x = (-m...m).map { Double($0) / Double(m) }
        let weights = (-m...m).map { i in
            c.kernel == .savitzkyGolay ? 1 : pow(cos(Double.pi * Double(i) / (2 * Double(m + 1))), 4)
        }
        var polynomials: [[Double]] = [], evaluations: [[Double]] = []
        var smooth = [Double](repeating: 0, count: n), deriv = smooth
        for degree in 0...3 {
            var coefficients = [Double](repeating: 0, count: 4); coefficients[degree] = 1
            var values = x.map { pow($0, Double(degree)) }
            // Reorthogonalize for stable coefficient construction.
            for _ in 0..<2 {
                for j in polynomials.indices {
                    let projection = zip(zip(values, evaluations[j]), weights).reduce(0) { $0 + $1.0.0 * $1.0.1 * $1.1 }
                    for k in 0..<4 { coefficients[k] -= projection * polynomials[j][k] }
                    for k in 0..<n { values[k] -= projection * evaluations[j][k] }
                }
            }
            let norm = sqrt(zip(values, weights).reduce(0) { $0 + $1.0 * $1.0 * $1.1 })
            guard norm > 1e-12 else { throw DerivedSeriesError.invalidSettings }
            coefficients = coefficients.map { $0 / norm }; values = values.map { $0 / norm }
            polynomials.append(coefficients); evaluations.append(values)
            for k in 0..<n {
                smooth[k] += weights[k] * coefficients[0] * values[k]
                deriv[k] += weights[k] * coefficients[1] * values[k] / (Double(m) * c.interval)
            }
        }
        smoothing = smooth; derivative = deriv
    }
}

/// Streaming resampler and delayed centered FIR. O(window) memory, no retained history.
/// Duplicate times use the last observation; one input is held until its timestamp
/// is closed by the next timestamp (or finish). Reconnects and long gaps reset FIR.
public struct DerivedSeriesProcessor {
    public let configuration: DerivedSeriesConfiguration
    private let kernel: PolynomialKernel
    private let origin: Date
    private var pending: StoredSample?
    private var previous: StoredSample?
    private var nextGrid: Double = 0
    private var values: [Double]
    private var centered: [Double]
    private var imputed: [Int]
    private var cursor = 0, count = 0, imputedCount = 0, run = 0
    public private(set) var emittedCount = 0
    public var workingCapacity: Int { values.count + imputed.count + centered.count + kernel.smoothing.count + kernel.derivative.count }
    public init(configuration: DerivedSeriesConfiguration, origin: Date) throws {
        kernel = try PolynomialKernel(configuration: configuration)
        self.configuration = configuration; self.origin = origin
        values = .init(repeating: 0, count: kernel.smoothing.count * 2)
        centered = .init(repeating: 0, count: kernel.smoothing.count)
        imputed = .init(repeating: 0, count: kernel.smoothing.count)
    }
    public mutating func append(_ sample: StoredSample, emit: (DerivedPoint) -> Void) throws {
        guard sample.timestamp.timeIntervalSince1970.isFinite, sample.value.isFinite else { throw DerivedSeriesError.invalidSettings }
        if let pending {
            guard sample.timestamp >= pending.timestamp else { throw DerivedSeriesError.outOfOrder }
            if sample.timestamp == pending.timestamp && sample.segmentID == pending.segmentID { self.pending = sample; return }
            consume(pending, emit: emit)
        }
        pending = sample
    }
    public mutating func finish(emit: (DerivedPoint) -> Void) {
        if let pending { consume(pending, emit: emit) }
        pending = nil
    }
    private mutating func reset() { cursor = 0; count = 0; imputedCount = 0; imputed = .init(repeating: 0, count: imputed.count); run += 1 }
    private mutating func consume(_ sample: StoredSample, emit: (DerivedPoint) -> Void) {
        let c = configuration, time = sample.timestamp.timeIntervalSince(origin)
        let tolerance = min(1e-6, c.interval * 1e-5)
        if let left = previous {
            let gap = sample.timestamp.timeIntervalSince(left.timestamp)
            if sample.segmentID != left.segmentID || gap > c.maximumGap || gap <= 0 {
                reset(); nextGrid = ceil((time - tolerance) / c.interval)
            }
        } else { nextGrid = ceil((time - tolerance) / c.interval) }
        let left = previous
        while nextGrid * c.interval <= time + tolerance {
            let t = nextGrid * c.interval
            var value: Double?, interpolated = false
            if abs(t - time) <= tolerance { value = sample.value }
            else if let left, sample.segmentID == left.segmentID,
                    sample.timestamp.timeIntervalSince(left.timestamp) <= c.maximumGap,
                    t >= left.timestamp.timeIntervalSince(origin) - tolerance, c.resampling == .linear {
                let fraction = (t - left.timestamp.timeIntervalSince(origin)) / sample.timestamp.timeIntervalSince(left.timestamp)
                value = (1 - fraction) * left.value + fraction * sample.value
                interpolated = true
            }
            if let value, value.isFinite { add(value, interpolated: interpolated, at: origin.addingTimeInterval(t), emit: emit) }
            else { reset() }
            nextGrid += 1
        }
        previous = sample
    }
    private mutating func add(_ value: Double, interpolated: Bool, at time: Date, emit: (DerivedPoint) -> Void) {
        let n = kernel.smoothing.count
        imputedCount -= imputed[cursor]; imputed[cursor] = interpolated ? 1 : 0; imputedCount += imputed[cursor]
        values[cursor] = value; values[cursor + n] = value
        cursor = (cursor + 1) % n; count = min(n, count + 1)
        guard count == n else { return }
        var smooth = 0.0, derivative = 0.0
        let baseline = values[(cursor + configuration.radius) % n]
        values.withUnsafeBufferPointer { buffer in
            var offset = -baseline
            centered.withUnsafeMutableBufferPointer { target in
                vDSP_vsaddD(buffer.baseAddress! + cursor, 1, &offset, target.baseAddress!, 1, vDSP_Length(n))
            }
        }
        centered.withUnsafeBufferPointer { buffer in
            kernel.smoothing.withUnsafeBufferPointer { coefficients in
                vDSP_dotprD(buffer.baseAddress!, 1, coefficients.baseAddress!, 1, &smooth, vDSP_Length(n))
            }
            kernel.derivative.withUnsafeBufferPointer { coefficients in
                vDSP_dotprD(buffer.baseAddress!, 1, coefficients.baseAddress!, 1, &derivative, vDSP_Length(n))
            }
        }
        smooth += baseline
        guard smooth.isFinite, derivative.isFinite else { reset(); return }
        emittedCount += 1
        emit(DerivedPoint(timestamp: time.addingTimeInterval(-configuration.delay), smoothed: smooth,
                          derivative: derivative, interpolatedCount: imputedCount, run: run))
    }
}
