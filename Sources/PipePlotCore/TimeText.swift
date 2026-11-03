import Foundation

public enum TimeText {
    private static let clockStyle = Date.VerbatimFormatStyle(
        format:
            "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        locale: Locale(identifier: "en_GB"), timeZone: .gmt, calendar: Calendar(identifier: .gregorian))
    private static let datedClockStyle = Date.VerbatimFormatStyle(
        format:
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        locale: Locale(identifier: "en_GB"), timeZone: .gmt, calendar: Calendar(identifier: .gregorian))

    /// Formats an absolute local/UTC clock time, or a signed elapsed time from `reference`.
    public static func format(_ date: Date, zone: PlotTimeZone, reference: Date? = nil, includeDate: Bool = false)
        -> String
    {
        if let reference { return elapsed(date.timeIntervalSince(reference)) }
        var style = includeDate ? datedClockStyle : clockStyle
        style.timeZone = zone == .utc ? .gmt : .current
        return date.formatted(style) + (zone == .utc ? " UTC" : "")
    }

    public static func elapsed(_ interval: TimeInterval) -> String {
        let sign = interval < 0 ? "−" : "+"
        let total = Int(abs(interval).rounded())
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        if hours > 0 { return "\(sign)\(hours):\(String(format: "%02d:%02d", minutes, seconds))" }
        if minutes > 0 { return "\(sign)\(minutes):\(String(format: "%02d", seconds))" }
        return "\(sign)\(seconds)s"
    }
}
