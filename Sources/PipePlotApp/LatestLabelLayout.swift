import CoreGraphics

/// Places a measured label to the right of its point, shifting vertically when needed.
enum LatestLabelLayout {
    static func place(point: CGPoint, size: CGSize, plot: CGRect, occupied: [CGRect]) -> CGRect? {
        let x = point.x + 6
        guard size.width > 0, size.height > 0, x >= plot.minX,
              x + size.width <= plot.maxX, size.height <= plot.height else { return nil }
        let minY = plot.minY, maxY = plot.maxY - size.height
        let preferred = min(max(point.y - size.height / 2, minY), maxY)
        let candidates = [preferred, minY, maxY] + occupied.flatMap { [$0.minY - size.height - 2, $0.maxY + 2] }
        for y in candidates.filter({ $0 >= minY && $0 <= maxY }).sorted(by: { abs($0 - preferred) < abs($1 - preferred) }) {
            let rect = CGRect(x: x, y: y, width: size.width, height: size.height)
            if !occupied.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(rect) }) { return rect }
        }
        return nil
    }
}
