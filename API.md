# PipePlotCore API contract (initial)

The core is a Foundation/SQLite library with no SwiftUI or AppKit imports. UI and CLI code should depend on this module. Identifiers cross IPC as lowercase UUID strings. Socket transport is newline-delimited UTF-8 JSON: one `ClientMessage` per line from CLI, one `ServerMessage` per line from app. Each JSON line is capped at 1 MiB; the sampler parser has a separate 64 KiB row cap.

## IPC

`ClientMessage` is a Codable tagged enum:

- `.hello(HelloRequest)` opens a connection. Request includes `protocolVersion: Int` (currently `1`), optional client label, `SinkIntent`, and optional `SamplerIntent`.
- `.row(SampleRow)` delivers one complete, validated row. Values share the row timestamp; the server assigns per-stream sequence numbers.
- `.finish(FinishReason)` closes the attachment after flushing all accepted rows.
- `.command(AppCommand)` supports `.list`, `.snapshot(sessionID:)`, `.setTarget(chartID:)`, and `.createChartAndTarget`.

`ServerMessage` is Codable and includes `.hello(HelloReply)`, `.ready(ReadyReply)`, `.accepted(AcceptedRow)`, `.snapshot(SessionSnapshot)`, `.listing(Listing)`, `.error(ProtocolError)`, and `.closed`. The app replies to hello with `HelloReply` (version, app instance ID), then `ReadyReply` after atomic stream registration and column negotiation. `ReadyReply` returns the session/chart IDs, attachment ID, ordered stream descriptors, and whether the group continued an earlier attachment. CLI must wait for readiness before sending the first row. First valid row establishes the column count; a later width mismatch rejects the whole row.

`SinkIntent`: `.target`, `.fresh`, `.newChart`, `.newSession`, `.session(sessionID: UUID, lineNames: [String])`, or `.chart(chartID: UUID, lineNames: [String])`. Plain target requests pass `.target`; `.fresh` bypasses continuation; an explicit session/chart request can provide ordered line names (empty names means create automatic names). Registration is atomic; active stream ownership conflicts fail the entire handshake. `.newChart` creates and targets a chart and registers this invocation in it atomically (unless the app has no chart, in which case use the initial chart); `.newSession` creates and targets a session and initial chart.

Use synthesized Codable enum representation for now; do not hand-roll incompatible wire formats. JSON encoder uses sorted keys. Transport agent owns socket framing and discovery/launch; this module owns message models and validation.

`InputParser` incrementally accepts `Data` chunks and emits `ParseEvent.row(SampleRow)` / `.rejected(ParseIssue)`. `finish()` parses a final unterminated row. `SampleRow` has `timestamp: Date`, `values: [Double]`, `sequence: UInt64` (row sequence is local to parser; store assigns stream-local sequence). Parser ignores blank rows, allows spaces/tabs and finite locale-independent doubles, establishes column count from the first valid row, rejects malformed/non-finite/NUL/over-width rows, and bounds row storage to 64 KiB. `expectedColumnCount` can be supplied for an explicit expectation.

## Domain and storage

`PipePlotStore` is the serialized domain boundary. Construct with `databaseURL: URL`; it opens/migrates SQLite and loads small metadata snapshots. Methods are synchronous and thread-safe (internally serialized): `createSession(title:)`, `createChart(in:after:)`, `setTarget(_:)`, `registerSampler(intent:columnCount:owner:)`, `append(_:to:)`, `finishAttachment(_:reason:)`, `moveStream(_:to:)`, `renameStream(_:to:)`, `snapshot(sessionID:)`, `listSessions()`, `undo(sessionID:)`, `redo(sessionID:)`. Registration returns `ReadyReply`. Each accepted row is stored transactionally and is never kept only in a UI queue. `SampleStore.query(streamID:from:to:limit:)` returns bounded raw samples ordered by time/sequence; queries require a positive limit and enforce a maximum of 50,000 rows. `count` and `bounds` are available without loading histories.

Domain identifiers are `SessionID`, `ChartID`, `StreamID`, `AttachmentID` typealiases of UUID. Session snapshot contains ordered chart snapshots; chart snapshot contains ordered stream descriptors, axis unit/scale/annotations and mark settings; stream descriptor contains identity, display name, connection state and sample bounds/count. Snapshots never embed complete histories.

Undo records semantic metadata/actions, not sample arrays. The initial implementation supports undo/redo for chart creation, stream moves, axis settings, guides, and renames. Target changes, incoming samples and attachment lifecycle changes are not edits and do not clear redo. Undoing populated chart creation moves its streams to the preceding chart while keeping their identities and ongoing attachments; redo restores the chart/membership without touching later samples. `UndoManager` integration is left to the UI.

## Analysis

`Analysis.statistics(samples:in:)` computes count, min, max, mean, population standard deviation, median, and first/last actual timestamps over the inclusive interval. `Analysis.linearForecast(samples:guideValue:)` fits value against elapsed seconds using least squares and returns `.insufficientData`, `.flatSlope`, `.crossingAlreadyPassed`, or `.crossing(time:)`; no interpolation of samples is implied. The UI should query exact raw samples for analysis, not display-reduced data.

## Current implementation boundary

Persistence is local SQLite. Raw samples are append-only except explicit session deletion; presentation metadata is stored separately. The core does not claim crash-proof durability beyond SQLite transaction semantics. Clock-driven follow-now, SwiftUI undo integration, socket server, app lifecycle/window restoration, drawing decimation and user-facing error presentation belong to app/transport layers.
