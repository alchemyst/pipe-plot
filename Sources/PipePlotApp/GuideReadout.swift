import Foundation
import PipePlotCore

enum GuideReadout {
    static func horizontal(_ guide: Guide, settings: AxisSettings, dragging: Bool) -> String {
        let value = NumericText.format(guide.value, scale: settings.numericScale ?? .decimal,
                                       unit: settings.unit, significantDigits: dragging ? 12 : 3)
        return guide.label.flatMap { $0.isEmpty ? nil : $0 + "  " + value } ?? value
    }
    static func vertical(_ guide: Guide, timeline: TimelineState, reference: Date?, dragging: Bool, includeDate: Bool) -> String {
        let value = TimeText.format(Date(timeIntervalSince1970: guide.value), zone: timeline.timeZone ?? .local,
                                    reference: reference, includeDate: includeDate)
        guard let label = guide.label, !label.isEmpty else { return value }
        return dragging ? label + "  " + value : label
    }
}
