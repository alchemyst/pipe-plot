import Foundation

public enum EventParseResult: Equatable, Sendable {
    case event(String)
    case rejected(String)
}

/// Bounded newline-delimited UTF-8 text parser for `pp --event`.
public struct EventInputParser {
    public static let maximumLineBytes = 64 * 1024
    private var pending = Data()
    private var discardingOversize = false

    public init() {}

    public mutating func append(_ bytes: Data) -> [EventParseResult] {
        var results: [EventParseResult] = []
        for byte in bytes {
            if byte == 0x0a {
                if discardingOversize {
                    results.append(.rejected("event exceeds 65536 UTF-8 bytes"))
                } else {
                    emitPending(into: &results)
                }
                pending.removeAll(keepingCapacity: true)
                discardingOversize = false
            } else if !discardingOversize {
                if pending.count == Self.maximumLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversize = true
                } else {
                    pending.append(byte)
                }
            }
        }
        return results
    }

    /// Accept a final unterminated line at EOF.
    public mutating func finish() -> [EventParseResult] {
        defer { pending.removeAll(keepingCapacity: true); discardingOversize = false }
        if discardingOversize { return [.rejected("event exceeds 65536 UTF-8 bytes")] }
        var results: [EventParseResult] = []
        emitPending(into: &results)
        return results
    }

    private mutating func emitPending(into results: inout [EventParseResult]) {
        guard !pending.isEmpty else { return }
        if pending.last == 0x0d { pending.removeLast() }
        guard !pending.isEmpty else { return }
        guard !pending.contains(0) else { results.append(.rejected("event contains a NUL byte")); return }
        guard let text = String(data: pending, encoding: .utf8) else { results.append(.rejected("event is not valid UTF-8")); return }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { results.append(.event(text)) }
    }
}
