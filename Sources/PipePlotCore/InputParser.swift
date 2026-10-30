import Foundation

public struct ParseIssue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case tooLong, nulByte, invalidNumber, nonFinite, wrongColumnCount }
    public let kind: Kind
    public let lineNumber: UInt64
    public let message: String
    public init(kind:Kind,lineNumber:UInt64,message:String) { self.kind=kind; self.lineNumber=lineNumber; self.message=String(message.prefix(240)) }
}
public struct InputRejection: Codable, Equatable, Sendable {
    public var kind: ParseIssue.Kind
    public var lineNumber: UInt64
    public var message: String
    /// Number of rejected input rows represented by this bounded diagnostic.
    public var rejectedCount: UInt64
    public init(_ issue: ParseIssue) { kind=issue.kind; lineNumber=issue.lineNumber; message=String(issue.message.prefix(240)); rejectedCount=1 }
    public init(kind:ParseIssue.Kind,lineNumber:UInt64,message:String,rejectedCount:UInt64=1) { self.kind=kind;self.lineNumber=lineNumber;self.message=String(message.prefix(240));self.rejectedCount=max(1,rejectedCount) }
    private enum CodingKeys: String, CodingKey { case kind, lineNumber, message, rejectedCount }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(ParseIssue.Kind.self, forKey: .kind)
        lineNumber = try values.decode(UInt64.self, forKey: .lineNumber)
        message = String(try values.decode(String.self, forKey: .message).prefix(240))
        rejectedCount = max(1, try values.decodeIfPresent(UInt64.self, forKey: .rejectedCount) ?? 1)
    }
}
public enum ParseEvent: Equatable, Sendable { case row(SampleRow), rejected(ParseIssue) }

/// Bounded, incremental parser for whitespace-separated finite decimal measurements.
public final class InputParser {
    public static let maximumLineBytes = 64 * 1024
    private var pending = Data()
    private var lineNumber: UInt64 = 0
    private var rowSequence: UInt64 = 0
    public var expectedColumnCount: Int?
    public init(expectedColumnCount: Int? = nil) { self.expectedColumnCount = expectedColumnCount }

    public func append(_ data: Data, timestamp: Date? = nil) -> [ParseEvent] {
        var out: [ParseEvent] = []
        for byte in data {
            if byte == 10 {
                lineNumber &+= 1
                out.append(contentsOf: parseLine(pending, timestamp: timestamp ?? Date()))
                pending.removeAll(keepingCapacity: true)
            } else if pending.count < Self.maximumLineBytes + 1 {
                pending.append(byte)
            }
        }
        return out
    }
    public func finish(timestamp: Date? = nil) -> [ParseEvent] {
        guard !pending.isEmpty else { return [] }
        lineNumber &+= 1
        defer { pending.removeAll(keepingCapacity: false) }
        return parseLine(pending, timestamp: timestamp ?? Date())
    }
    private func parseLine(_ data: Data, timestamp: Date) -> [ParseEvent] {
        if data.count > Self.maximumLineBytes { return [.rejected(ParseIssue(kind: .tooLong, lineNumber: lineNumber, message: "input row exceeds 64 KiB"))] }
        if data.contains(0) { return [.rejected(ParseIssue(kind: .nulByte, lineNumber: lineNumber, message: "input row contains a NUL byte"))] }
        guard let text = String(data: data, encoding: .utf8) else { return [.rejected(ParseIssue(kind: .invalidNumber, lineNumber: lineNumber, message: "input row is not valid UTF-8"))] }
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
        if fields.isEmpty { return [] }
        var values: [Double] = []; values.reserveCapacity(fields.count)
        for field in fields {
            guard let value = Double(field) else { return [.rejected(ParseIssue(kind: .invalidNumber, lineNumber: lineNumber, message: "invalid number in input row"))] }
            guard value.isFinite else { return [.rejected(ParseIssue(kind: .nonFinite, lineNumber: lineNumber, message: "NaN and infinity are not accepted"))] }
            values.append(value)
        }
        if let expectedColumnCount, values.count != expectedColumnCount {
            return [.rejected(ParseIssue(kind: .wrongColumnCount, lineNumber: lineNumber, message: "expected \(expectedColumnCount) columns, got \(values.count)"))]
        }
        if expectedColumnCount == nil { expectedColumnCount = values.count }
        rowSequence &+= 1
        return [.row(SampleRow(timestamp: timestamp, values: values, sequence: rowSequence))]
    }
}
