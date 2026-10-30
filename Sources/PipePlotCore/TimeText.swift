import Foundation

public enum TimeText {
    /// Formats an absolute local/UTC clock time, or a signed elapsed time from `reference`.
    public static func format(_ date: Date, zone: PlotTimeZone, reference: Date? = nil, includeDate: Bool = false) -> String {
        if let reference {
            let interval = date.timeIntervalSince(reference)
            let sign = interval < 0 ? "−" : "+"
            let total = Int(abs(interval).rounded())
            let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
            if hours > 0 { return "\(sign)\(hours):\(String(format: "%02d:%02d", minutes, seconds))" }
            if minutes > 0 { return "\(sign)\(minutes):\(String(format: "%02d", seconds))" }
            return "\(sign)\(seconds)s"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone == .utc ? TimeZone(secondsFromGMT: 0) : .current
        formatter.dateFormat = includeDate ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss"
        return formatter.string(from: date) + (zone == .utc ? " UTC" : "")
    }
}
