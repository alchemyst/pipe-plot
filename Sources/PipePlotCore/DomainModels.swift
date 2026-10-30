import Foundation

public enum NumericScale: String, Codable, CaseIterable, Sendable { case decimal, binary }
public enum PlotTimeZone: String, Codable, CaseIterable, Sendable { case local, utc }
public enum CrossingDirection: String, Codable, CaseIterable, Sendable { case rising, falling, both }
public struct GuideAlert: Codable, Equatable, Sendable {
    public var direction: CrossingDirection
    public var hysteresis: Double
    public var cooldown: TimeInterval
    public init(direction: CrossingDirection = .both, hysteresis: Double = 0, cooldown: TimeInterval = 10) {
        self.direction=direction; self.hysteresis=hysteresis; self.cooldown=cooldown
    }
}
public enum YScale: Codable, Equatable, Sendable { case automatic, fixed(min: Double, max: Double) }
public enum GuideOrientation: String, Codable, Sendable { case horizontalValue, verticalTime }
public struct Guide: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var orientation: GuideOrientation
    public var value: Double
    public var label: String?
    public var color: String
    public var alert: GuideAlert?
    public init(id: UUID = UUID(), orientation: GuideOrientation, value: Double, label: String? = nil, color: String = "#ffb000", alert: GuideAlert? = nil) {
        self.id=id; self.orientation=orientation; self.value=value; self.label=label; self.color=color; self.alert=alert
    }
}
public struct AxisSettings: Codable, Equatable, Sendable {
    public var unit: String?
    public var yScale: YScale
    public var dotsVisible: Bool
    public var linesVisible: Bool
    public var numericScale: NumericScale?
    public var includeZero: Bool?
    public var referenceGuideID: UUID?
    public var showExtrema: Bool?
    public init(unit: String? = nil, yScale: YScale = .automatic, dotsVisible: Bool = false, linesVisible: Bool = true, numericScale: NumericScale? = nil, includeZero: Bool? = nil, referenceGuideID: UUID? = nil, showExtrema: Bool? = nil) {
        self.unit=unit; self.yScale=yScale; self.dotsVisible=dotsVisible; self.linesVisible=linesVisible; self.numericScale=numericScale; self.includeZero=includeZero; self.referenceGuideID=referenceGuideID; self.showExtrema=showExtrema
    }
}
public enum SelectionMode: Codable, Equatable, Sendable { case fixed, endFollowsNow, bothFollowNow(duration: TimeInterval), startFollowsEnd(duration: TimeInterval) }
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
    public var forecasts: [ForecastConfiguration]?
    /// Frozen when the final attachment ends; nil while capture is live.
    public var clockStoppedAt: Date?
    public var historySpan: TimeInterval?
    public var timeZone: PlotTimeZone?
    public var referenceTimeGuideID: UUID?
    public init(visibleStart: Date? = nil, visibleEnd: Date? = nil, followNow: Bool = true, selection: TimeSelection? = nil, forecast: ForecastConfiguration? = nil, forecasts:[ForecastConfiguration]? = nil, clockStoppedAt: Date? = nil, historySpan: TimeInterval? = nil, timeZone: PlotTimeZone? = nil, referenceTimeGuideID: UUID? = nil) {
        self.visibleStart=visibleStart; self.visibleEnd=visibleEnd; self.followNow=followNow; self.selection=selection; self.forecast=forecast; self.forecasts=forecasts; self.clockStoppedAt=clockStoppedAt; self.historySpan=historySpan; self.timeZone=timeZone; self.referenceTimeGuideID=referenceTimeGuideID
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
    public var isDeleted: Bool
    public init(id: SessionID, number: Int, title: String, charts: [ChartSnapshot], timeGuides:[Guide] = [], timeline: TimelineState = TimelineState(), isOpen: Bool = true, rejectedLineCount: Int = 0, isDeleted:Bool = false) {
        self.id=id; self.number=number; self.title=title; self.charts=charts; self.timeGuides=timeGuides; self.timeline=timeline; self.isOpen=isOpen; self.rejectedLineCount=rejectedLineCount;self.isDeleted=isDeleted
    }
    private enum CodingKeys:String,CodingKey {case id,number,title,charts,timeGuides,timeline,isOpen,rejectedLineCount,isDeleted}
    public init(from decoder:Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(SessionID.self,forKey:.id);number=try c.decode(Int.self,forKey:.number);title=try c.decode(String.self,forKey:.title);charts=try c.decode([ChartSnapshot].self,forKey:.charts);timeGuides=try c.decodeIfPresent([Guide].self,forKey:.timeGuides) ?? [];timeline=try c.decode(TimelineState.self,forKey:.timeline);isOpen=try c.decode(Bool.self,forKey:.isOpen);rejectedLineCount=try c.decodeIfPresent(Int.self,forKey:.rejectedLineCount) ?? 0;isDeleted=try c.decodeIfPresent(Bool.self,forKey:.isDeleted) ?? false}
}
public struct SampleBounds: Codable, Equatable, Sendable { public var first: Date?; public var last: Date?; public init(first:Date?,last:Date?){self.first=first;self.last=last} }
