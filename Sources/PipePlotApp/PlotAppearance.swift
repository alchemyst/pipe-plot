import AppKit
import SwiftUI
import PipePlotCore

enum PlotAppearance {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static let background = Color(
        nsColor: NSColor(name: nil) { appearance in
            let level = isDark(appearance) ? 30.0 / 255 : 1.0
            return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
        })

    /// Preserve hue while moving toward black/white until the plot's opaque
    /// background has sufficient contrast. Custom saved colors use this too.
    static func components(hex: String, dark: Bool, increasedContrast: Bool) -> [Double] {
        let number = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        let original = [
            Double((number >> 16) & 255) / 255,
            Double((number >> 8) & 255) / 255, Double(number & 255) / 255,
        ]
        let background = dark ? 30.0 / 255 : 1.0
        let target = increasedContrast ? 7.0 : 5.0
        for step in 0...100 {
            let fraction = Double(step) / 100
            let color = original.map { $0 * (1 - fraction) + (dark ? fraction : 0) }
            if contrast(color, [background, background, background]) >= target { return color }
        }
        return [Double](repeating: dark ? 1 : 0, count: 3)
    }

    static func contrast(_ first: [Double], _ second: [Double]) -> Double {
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func color(hex: String) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let high =
                    appearance.name == .accessibilityHighContrastAqua
                    || appearance.name == .accessibilityHighContrastDarkAqua
                let rgb = components(hex: hex, dark: isDark(appearance), increasedContrast: high)
                return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            })
    }
}

/// Non-color identity follows a stream when it moves or changes color.
struct PlotSeriesStyle {
    let index: Int
    init(_ stream: StreamDescriptor) {
        let hash = withUnsafeBytes(of: stream.id.uuid) { bytes in
            bytes.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        }
        index = Int(hash % 32)
    }
    var dash: [CGFloat] {
        [[], [8, 4], [2, 4], [10, 3, 2, 3], [12, 5], [4, 3], [8, 3, 2, 3, 2, 3], [2, 3, 6, 3]][index % 8]
    }
    var markerName: String { ["circle", "square", "triangle", "diamond"][index / 8] }
    func marker(in rect: CGRect) -> Path {
        switch index / 8 {
        case 0: return Path(ellipseIn: rect)
        case 1: return Path(rect)
        default:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            if index / 8 == 2 {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            } else {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            }
            path.closeSubpath()
            return path
        }
    }
}

struct StreamStyleKey: View {
    let stream: StreamDescriptor
    var body: some View {
        Canvas { context, size in
            let style = PlotSeriesStyle(stream)
            let color = PlotCanvas.color(for: stream, fallback: 0)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: style.dash))
            context.fill(
                style.marker(in: CGRect(x: size.width / 2 - 4, y: size.height / 2 - 4, width: 8, height: 8)),
                with: .color(color))
        }.frame(width: 38, height: 20).background(PlotAppearance.background, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
    }
}
