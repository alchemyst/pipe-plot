import Foundation

public enum YScale: Codable, Equatable, Sendable { case automatic, fixed(min: Double, max: Double) }
public enum GuideOrientation: String, Codable, Sendable { case horizontalValue, verticalTime }
public struct Guide: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var orientation: GuideOrientation
    public var value: Double
    public var label: String?
    public var color: String
    public init(id: UUID = UUID(), orientation: GuideOrientation, value: Double, label: String? = nil, color: String = "#ffb000") {
        self.id=id; self.orientation=orientation; self.value=value; self.label=label; self.color=color
    }
}
public struct AxisSettings: Codable, Equatable, Sendable {
    public var unit: String?
    public var yScale: YScale
    public var dotsVisible: Bool
    public var linesVisible: Bool
    public init(unit: String? = nil, yScale: YScale = .automatic, dotsVisible: Bool = false, linesVisible: Bool = true) {
        self.unit=unit; self.yScale=yScale; self.dotsVisible=dotsVisible; self.linesVisible=linesVisible
    }
}
public enum SelectionMode: Codable, Equatable, Sendable { case fixed, endFollowsNow, bothFollowNow(duration: TimeInterval) }
public struct TimeSelection: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var mode: SelectionMode
    public var selectedStreamIDs: Set<StreamID>
    public init(start: Date, end: Date, mode: SelectionMode = .fixed, selectedStreamIDs: Set<StreamID> = []) {
        self.start=start; self.end=end; self.mode=mode; self.selectedStreamIDs=selectedStreamIDs
    }
}
public struct ForecastConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var streamID: StreamID
    public var guideID: UUID
    public var selection: TimeSelection
    public init(id: UUID = UUID(), streamID: StreamID, guideID: UUID, selection: TimeSelection) {
        self.id = id; self.streamID = streamID; self.guideID = guideID; self.selection = selection
    }
}
public struct TimelineState: Codable, Equatable, Sendable {
    public var visibleStart: Date?
    public var visibleEnd: Date?
    public var followNow: Bool
    public var selection: TimeSelection?
    public var forecast: ForecastConfiguration?
    /// Frozen when the final attachment ends; nil while capture is live.
    public var clockStoppedAt: Date?
    public var historySpan: TimeInterval?
    public init(visibleStart: Date? = nil, visibleEnd: Date? = nil, followNow: Bool = true, selection: TimeSelection? = nil, forecast: ForecastConfiguration? = nil, clockStoppedAt: Date? = nil, historySpan: TimeInterval? = nil) {
        self.visibleStart=visibleStart; self.visibleEnd=visibleEnd; self.followNow=followNow; self.selection=selection; self.forecast=forecast; self.clockStoppedAt=clockStoppedAt; self.historySpan=historySpan
    }
}
public struct ChartSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: ChartID
    public var title: String
    public var streams: [StreamDescriptor]
    public var settings: AxisSettings
    public var guides: [Guide]
    public var isTarget: Bool
    public var isVisible: Bool
    public init(id: ChartID, title: String, streams: [StreamDescriptor], settings: AxisSettings = AxisSettings(), guides: [Guide] = [], isTarget: Bool = false, isVisible: Bool = true) {
        self.id=id; self.title=title; self.streams=streams; self.settings=settings; self.guides=guides; self.isTarget=isTarget; self.isVisible=isVisible
    }
}
public struct SessionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: SessionID
    public var number: Int
    public var title: String
    public var charts: [ChartSnapshot]
    public var timeGuides: [Guide]
    public var timeline: TimelineState
    public var isOpen: Bool
    public var rejectedLineCount: Int
    public init(id: SessionID, number: Int, title: String, charts: [ChartSnapshot], timeGuides:[Guide] = [], timeline: TimelineState = TimelineState(), isOpen: Bool = true, rejectedLineCount: Int = 0) {
        self.id=id; self.number=number; self.title=title; self.charts=charts; self.timeGuides=timeGuides; self.timeline=timeline; self.isOpen=isOpen; self.rejectedLineCount=rejectedLineCount
    }
}
public struct SampleBounds: Codable, Equatable, Sendable { public var first: Date?; public var last: Date?; public init(first:Date?,last:Date?){self.first=first;self.last=last} }
