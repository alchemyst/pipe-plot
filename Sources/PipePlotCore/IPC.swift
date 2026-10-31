import Foundation

public typealias SessionID = UUID
public typealias ChartID = UUID
public typealias StreamID = UUID
public typealias AttachmentID = UUID

public struct SampleRow: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var values: [Double]
    public var sequence: UInt64
    public init(timestamp: Date = Date(), values: [Double], sequence: UInt64 = 0) {
        self.timestamp = timestamp; self.values = values; self.sequence = sequence
    }
}
public struct EventRow: Codable, Equatable, Sendable {
    public var text: String
    public var timestamp: Date
    public init(text: String, timestamp: Date = Date()) { self.text = text; self.timestamp = timestamp }
}

public enum SinkIntent: Codable, Equatable, Sendable {
    case target
    case fresh
    case newChart
    case newSession
    case session(sessionID: UUID, lineNames: [String])
    case chart(chartID: UUID, lineNames: [String])
}
public struct SamplerIntent: Codable, Equatable, Sendable {
    public var columnCount: Int
    public var sourceLabel: String?
    public var startedAt: Date?
    public var requestedNames: [String]?
    public var unitHint: String?
    public init(columnCount: Int, sourceLabel: String? = nil, requestedNames: [String]? = nil, unitHint: String? = nil, startedAt: Date? = nil) {
        self.columnCount = columnCount; self.sourceLabel = sourceLabel; self.startedAt = startedAt; self.requestedNames = requestedNames; self.unitHint = unitHint
    }
}
public struct HelloRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var clientLabel: String?
    public var sink: SinkIntent
    public var sampler: SamplerIntent?
    public var eventMode: Bool
    public init(protocolVersion: Int = 1, clientLabel: String? = nil, sink: SinkIntent = .target, sampler: SamplerIntent? = nil, eventMode: Bool = false) {
        self.protocolVersion = protocolVersion; self.clientLabel = clientLabel; self.sink = sink; self.sampler = sampler; self.eventMode = eventMode
    }
    private enum CodingKeys: String, CodingKey { case protocolVersion, clientLabel, sink, sampler, eventMode }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        clientLabel = try container.decodeIfPresent(String.self, forKey: .clientLabel)
        sink = try container.decodeIfPresent(SinkIntent.self, forKey: .sink) ?? .target
        sampler = try container.decodeIfPresent(SamplerIntent.self, forKey: .sampler)
        eventMode = try container.decodeIfPresent(Bool.self, forKey: .eventMode) ?? false
    }
}
public enum FinishReason: String, Codable, Sendable { case eof, interrupted, clientDisconnected, sessionClosed, error }
public enum AppCommand: Codable, Sendable { case list, snapshot(sessionID: UUID), setTarget(chartID: UUID), createChartAndTarget }
public enum ClientMessage: Codable, Sendable { case hello(HelloRequest), row(SampleRow), event(EventRow), rejected(InputRejection), finish(FinishReason), command(AppCommand) }

public struct HelloReply: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var appInstanceID: UUID
    public init(protocolVersion: Int = 1, appInstanceID: UUID) { self.protocolVersion = protocolVersion; self.appInstanceID = appInstanceID }
}
public enum StreamState: String, Codable, Sendable { case live, quiet, ended, disconnected, errored }
public struct StreamDescriptor: Codable, Equatable, Sendable {
    public var id: StreamID
    public var name: String
    public var state: StreamState
    public var sampleCount: Int64
    public var firstSampleAt: Date?
    public var lastSampleAt: Date?
    public var unitHint: String?
    public var colorHex: String?
    public var dotsVisible: Bool?
    public var linesVisible: Bool?
    public var isLayoutHidden: Bool?
    public init(id: StreamID, name: String, state: StreamState = .disconnected, sampleCount: Int64 = 0,
                firstSampleAt: Date? = nil, lastSampleAt: Date? = nil, unitHint: String? = nil, colorHex: String? = nil, dotsVisible: Bool? = nil, linesVisible: Bool? = nil, isLayoutHidden: Bool? = nil) {
        self.id=id; self.name=name; self.state=state; self.sampleCount=sampleCount
        self.firstSampleAt=firstSampleAt; self.lastSampleAt=lastSampleAt; self.unitHint=unitHint
        self.colorHex=colorHex; self.dotsVisible=dotsVisible; self.linesVisible=linesVisible; self.isLayoutHidden=isLayoutHidden
    }
}
public struct ReadyReply: Codable, Equatable, Sendable {
    public var sessionID: SessionID
    public var chartID: ChartID
    public var attachmentID: AttachmentID
    public var streams: [StreamDescriptor]
    public var continued: Bool
    public init(sessionID: SessionID, chartID: ChartID, attachmentID: AttachmentID, streams: [StreamDescriptor], continued: Bool) {
        self.sessionID=sessionID; self.chartID=chartID; self.attachmentID=attachmentID; self.streams=streams; self.continued=continued
    }
}
public struct AcceptedRow: Codable, Equatable, Sendable { public var sequence: UInt64; public init(sequence: UInt64) { self.sequence=sequence } }
public struct ProtocolError: Codable, Equatable, Sendable { public var code: String; public var message: String; public init(code: String, message: String) { self.code=code; self.message=message } }
public enum ServerMessage: Codable, Sendable {
    case hello(HelloReply), ready(ReadyReply), accepted(AcceptedRow), eventAccepted, snapshot(SessionSnapshot), listing(Listing), error(ProtocolError), closed
}

public struct Listing: Codable, Equatable, Sendable { public var sessions: [SessionSnapshot]; public var targetChartID: ChartID?; public init(sessions:[SessionSnapshot], targetChartID:ChartID?) { self.sessions=sessions; self.targetChartID=targetChartID } }
