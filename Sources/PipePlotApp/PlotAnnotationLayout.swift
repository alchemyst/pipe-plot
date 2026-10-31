import Foundation

/// Normalizing before padding avoids overflowing the span of mixed-sign values.
enum PlotValueRange {
    static func automatic(_ values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let minimum = finite.min(), let maximum = finite.max() else { return 0...1 }
        let scale = max(abs(minimum), abs(maximum), 1)
        let low = minimum / scale, high = maximum / scale
        let padding = high > low ? (high - low) * 0.08 : max(abs(low) * 0.08, 0.02)
        func finiteBound(_ normalized: Double) -> Double {
            let result = normalized * scale
            return result.isFinite ? result : (normalized < 0 ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude)
        }
        return finiteBound(low - padding)...finiteBound(high + padding)
    }
}

enum PlotAnnotationLayout {
    /// Keeps measured badges inside the plot even when finite limits prevent axis padding.
    static func badge(size: CGSize, preferredOrigin: CGPoint, plot: CGRect) -> CGRect {
        let width = min(plot.width, size.width + 10)
        let height = min(plot.height, size.height + 4)
        return CGRect(x: max(plot.minX, min(preferredOrigin.x, plot.maxX - width)),
                      y: max(plot.minY, min(preferredOrigin.y, plot.maxY - height)),
                      width: width, height: height)
    }
}
