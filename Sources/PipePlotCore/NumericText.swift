import Foundation

public enum NumericText {
    private static let decimalPrefixes: [(Double, String)] = [
        (1e18, "E"), (1e15, "P"), (1e12, "T"), (1e9, "G"), (1e6, "M"), (1e3, "k"),
        (1, ""), (1e-3, "m"), (1e-6, "µ"), (1e-9, "n"), (1e-12, "p")
    ]
    private static let binaryPrefixes: [(Double, String)] = [
        (1_152_921_504_606_846_976, "Ei"), (1_125_899_906_842_624, "Pi"),
        (1_099_511_627_776, "Ti"), (1_073_741_824, "Gi"),
        (1_048_576, "Mi"), (1_024, "Ki"), (1, "")
    ]

    /// Returns evenly spaced 1/2/5-decade ticks spanning the requested range.
    public static func ticks(in range: ClosedRange<Double>, scale: NumericScale = .decimal, targetCount: Int = 5) -> [Double] {
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound < range.upperBound else { return [] }
        let rawStep = (range.upperBound - range.lowerBound) / Double(max(2, targetCount))
        let radix = scale == .binary ? 1024.0 : 10.0
        let exponent = floor(log(rawStep) / log(radix))
        let magnitude = pow(radix, exponent)
        let fraction = rawStep / magnitude
        let nice: Double
        if scale == .binary {
            nice = [1.0, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024].first(where: { fraction <= $0 }) ?? 1024
        } else {
            nice = fraction <= 1 ? 1.0 : (fraction <= 2 ? 2.0 : (fraction <= 5 ? 5.0 : 10.0))
        }
        let step = nice * magnitude
        guard step.isFinite, step > 0 else { return [] }
        var result: [Double] = []
        var value = ceil(range.lowerBound / step) * step
        while value <= range.upperBound && result.count < 128 {
            result.append(value == 0 ? 0 : value)
            let next = value + step
            if next <= value { break }
            value = next
        }
        return result
    }

    /// Formats using a readable 3-significant-digit mantissa and an optional unit.
    public static func format(_ value: Double, scale: NumericScale = .decimal, unit: String? = nil, significantDigits: Int = 3) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value.sign == .minus ? "−∞" : "∞") }
        if value == 0 { return unit.map { $0.isEmpty ? "0" : "0 \($0)" } ?? "0" }
        let prefixes = scale == .binary ? binaryPrefixes : decimalPrefixes
        let magnitude = abs(value)
        let prefix = prefixes.first(where: { magnitude >= $0.0 }) ?? prefixes.last!
        let scaled = value / prefix.0
        let number = scaled.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.significantDigits(1...max(1, significantDigits))))
        let suffix = prefix.1 + (unit ?? "")
        return number + (suffix.isEmpty ? "" : " \(suffix)")
    }

    /// Parses a locale-independent number with an optional SI/binary prefix and unit.
    /// For example, `10 Gi` is exactly 10 × 1024³.
    public static func parse(_ text: String, unit expectedUnit: String? = nil) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let token = String(parts[0])
        let pattern = #"^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
              let numberRange = Range(match.range(at: 1), in: token),
              let number = Double(token[numberRange]), number.isFinite,
              let suffixRange = Range(match.range(at: 2), in: token) else { return nil }
        let tail = String(token[suffixRange]) + parts.dropFirst().joined()
        if tail.isEmpty { return number }
        let factors: [String: Double] = [
            "p": 1e-12, "n": 1e-9, "µ": 1e-6, "u": 1e-6, "m": 1e-3,
            "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15, "E": 1e18,
            "Ki": 1_024, "Mi": 1_048_576, "Gi": 1_073_741_824, "Ti": 1_099_511_627_776,
            "Pi": 1_125_899_906_842_624, "Ei": 1_152_921_504_606_846_976
        ]
        let commonUnits: Set<String> = ["B", "byte", "bytes", "b", "bit", "bits", "W", "V", "A", "s", "Hz", "J", "Pa", "F", "C", "K", "mol", "g", "L", "l", "N", "Wh", "W/h"]
        if tail == expectedUnit || (expectedUnit == nil && commonUnits.contains(tail)) { return number }
        guard let prefix = factors.keys.sorted(by: { $0.count > $1.count }).first(where: { tail.hasPrefix($0) }) else { return nil }
        let unit = String(tail.dropFirst(prefix.count))
        guard unit.isEmpty || unit == expectedUnit || commonUnits.contains(unit) else { return nil }
        let result = number * factors[prefix]!
        return result.isFinite ? result : nil
    }
}
