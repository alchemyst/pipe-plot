# PipePlot

Status: implementation-ready product direction after interview, round 11. Updated 2026-10-29. Proposed details remain subject to implementation judgment and prototype feedback.

This is a working product specification, not an implementation commitment. **Confirmed** records the user's decisions. **Proposed** identifies defaults and behaviour to refine together. **Open** identifies unresolved choices. Research observations are evidence about other tools; the resulting PipePlot requirements are our design inferences.

## Purpose

PipePlot is a native macOS application for watching temporary numeric streams and investigating them interactively. Its primary case is a long-running process sampled every few seconds or minutes, observed over hours or days. It must make the first chart essentially effortless, then offer useful interactions directly on that chart.

The motivating example is container memory: pipe a remote sampler into a local command, watch memory against a machine limit, mark events, and inspect selected intervals. Other measurements need not approach a target or follow a linear trend. No observability stack, database configuration, query language, account, or dashboard construction is required.

Local resource use matters: the user already watches laptop memory closely. Prefer native system frameworks and small bounded working sets. Sharing is not a primary workflow; Done-when separately serves shared forecasts.

## Confirmed product decisions

- Native Mac app named PipePlot, with a companion CLI named `pp`.
- `New Session` creates a session and opens a new window.
- Cmd-N creates a new session/window with an initial chart and makes that chart the default **Target sink**.
- Each chart has a coordinated `Target sink` button. Exactly one chart across open sessions/windows is the default destination for new plain `pp` connections. Focusing a window or selecting a chart does not by itself change the target sink.
- Cmd-Shift-D creates a chart below the current chart and makes the new chart the target sink. This shortcut follows the user's iTerm interaction preference.
- Sessions and their data are automatically saved locally across app restarts, until explicitly deleted.
- Optimise ergonomics for a small number of sessions and charts. Session IDs are small integers; common CLI operations use short forms and require no flags.
- Plain `pp` attaches one sampler to the target chart. One whitespace-separated input row can contain multiple floats, creating one plotted stream per column.
- A simple interrupt/rerun resumes the previous disconnected set of streams when the target is unchanged and the continuation is unambiguous. Another concurrent `pp` creates a new set. Ambiguous reruns create new streams that are cheap to associate with older disconnected ones in the UI; explicit session ID and line names allow direct attachment.
- Existing producers remain attached to their streams/session when the target sink changes. Multiple windows continue receiving data simultaneously; explicit layout moves can change which chart displays a stream.
- If PipePlot is not running, `pp` launches it and transparently creates a session. The basic pipeline must be especially fast and require no intervening interaction.
- First-round input consists of floating-point measurements over time. Sampling intervals may be irregular.
- Default representation is connecting lines, with dots off. Users can toggle lines and dots independently.
- Multiple charts use a stacked layout. Creating a chart is explicit through the UI or CLI, rather than automatic for every stream. Moving a stream into another chart must be trivial; removing the last stream from a source axis automatically collapses that empty axis.
- The stack shares a single time context: coordinated hover time, time guides spanning all axes, and coordinated horizontal zoom/navigation.
- Datadog's coordinated hover and Perfetto's fluid timeline navigation are interaction references.
- Units, Y-scale configuration, and value annotations belong to the chart/axis, not to individual streams. Moving a stream does not carry its source chart's annotations into the destination chart.
- Robust undo/redo is a foundational interaction and architecture requirement, designed before editing features are implemented. Persistence remains required, but its detailed implementation is not a priority for these exploration rounds.
- Charts track current time and incoming data while at least one producer remains connected. Slow and temporarily silent producers are normal. Once the final producer disconnects, the session clock stops at disconnect time; a subsequent connection resumes it.
- Guides are draggable line annotations pulled from chart edges, analogous to guides in presentation software.
- Standard interactions include bounds, annotations, navigation, interval selection, and analysis. First-release analysis is specified below; forecast interaction details remain to be refined.
- First-release analysis includes selection statistics and an optional linear forecast. Periodicity/period estimation is deferred.
- The default live time range grows initially, then becomes a rolling 15-minute window. The span remains adjustable in the UI.
- In v1, every observation is timestamped when `pp` receives its complete input row; no explicit source-timestamp mode.
- A selection's right edge can link to now through proximity during selection, with a colour cue. When the end follows now, a button on the left edge can also make the start track now, preserving the selected duration.
- Enabled forecasts refit automatically for now-linked selections; fixed selections keep a fixed fit. Forecasts extend to a chosen horizontal guide and show the estimated crossing time. Extend the shared timeline into the future while retaining a visible now marker.
- Deliberate selection edits use Cmd-Z; pan/zoom uses separate Back/Forward navigation. Automatic clock-driven movement never adds undo steps.
- If the target chart disappears or its session closes, target the most recently used remaining chart; if none remain, create a session and initial chart for the next pipeline.
- The first implementation targets the user's current Mac and installed macOS only, with local app build and CLI installation. Public distribution, notarisation and older macOS support are not first-release requirements.
- Undoing creation of a populated chart moves its lines into the preceding chart and keeps collecting. Undo must preserve all samples and chart-owned annotations/configuration for redo.
- Explicit attachment by session ID and line name creates a missing line in that session's most recently used chart.
- Manual app launch restores the previously open sessions/windows. Previously disconnected samplers are not restarted by restoring windows.
- Closing a session window disconnects its samplers and retains all captured data; it does not continue hidden/background capture for that session.
- Prefer SwiftUI and native charting support where suitable; no embedded browser is required.

## Implementation feedback (2026-10-29)

- Lines replace dots as the default representation; existing explicit mark settings remain intact.
- Selection snapping must use the same session clock and screen coordinates as the visible now marker, with an explicit linked boundary mode on release.
- Hover readouts reserve their layout space so entering/leaving the plot does not resize its chart.
- The session clock stops when its final producer disconnects, including terminal-side pipe breaks. A silent connected producer keeps time advancing.

## Core workflows

### Pipeline first

```sh
remote_memory_sampler | pp
```

1. `pp` locates the installed app and connects, launching it if necessary.
2. The app resolves the target chart, creating a session and initial chart if necessary, and registers a sampler attachment.
3. The first valid input row establishes the number of columns; the app creates or resumes the matching set of stream identities and acknowledges them before accepting their samples. Registration/readiness and column negotiation must not lose the first row.
4. The first valid sample appears automatically, without a query, template, settings dialog, or chart creation step.
5. Subsequent rows extend those streams until stdin closes or the connection fails. A basic interrupt/rerun can resume them as described below.

Proposed: a cold launch presents the new session. Adding another stream to an already running app must not repeatedly steal focus from the terminal. A quiet app/CLI connection is the normal experience.

### App first, multiple sessions

1. Open PipePlot and choose `New Session`; its initial chart becomes the target sink.
2. Run one or more pipelines; their streams overlay in that chart.
3. Press Cmd-Shift-D to create and target a chart below the current chart. The next pipeline goes there.
4. Choose `New Session` again; its initial chart becomes the target sink in a second window.
5. Return to either window and click any chart's `Target sink` button before running another command. All previously connected streams continue independently.

Confirmed: target selection is chart-level and app-wide. Selecting a chart's `Target sink` button updates all open windows so exactly one chart is marked. Focus alone never changes routing. Cmd-N targets the new window's initial chart; Cmd-Shift-D creates and targets a chart below the current chart in the active window. Proposed: `current chart` means the selected chart in that window, distinct from the app-wide target sink; when none is selected, use that window's last chart. Explicit chart arguments override default routing for that invocation.

### Investigate without losing collection

1. Inspect a sample by hovering or selecting it.
2. Pull a horizontal guide from an edge, position it at the memory limit, and label it.
3. Mark an event such as “started workload” with a vertical guide and note.
4. Select a time interval; see statistics and available analysis actions without configuring a separate dashboard.
5. Pan or zoom into history while acquisition continues.
6. Choose `Follow Now` to return to the live view.

Proposed: inspecting history suspends automatic scrolling, not collection. Current wall-clock time, connection state, and sample age remain visible. Selection must not slide away underneath the pointer.

## Sessions, windows, and stream routing

Proposed model:

- **Session:** stable small positive integer ID, editable title, streams, guides, notes, chart/view settings, and lifecycle state. One session per window. Proposed: allocate 1, 2, 3… and do not renumber when windows reorder/close or reuse deleted IDs while references may survive. Internal storage identifiers may differ but are not required in normal CLI use.
- **Stream:** stable ID, display name, source metadata, samples, and connection state. Proposed: an optional source-unit hint may help initialise a new chart, but does not own the displayed axis unit.
- **Sampler attachment:** one `pp` connection supplying an ordered set of streams, one per input column. Transport lifetime differs from stream/history lifetime; a subsequent attachment can continue the same streams.
- **Chart/axis row:** an ordered plot in the session stack, containing one or more streams and its own configured unit, Y scale, and value annotations. Proposed first-round terminology: one Y axis per chart row; moving a stream changes presentation membership, not its capture/session identity.
- **Target sink:** one app-wide reference to a stable chart ID and its owning session ID. It is neither a window-focus flag nor a per-session default. A freshly created, intentionally empty chart can be a valid target.
- **Timeline state:** one session-level visible time interval, Follow Now/inspection mode, hover timestamp, and selected interval. Chart rows must not maintain competing independent X ranges.
- **Sample:** timestamp, finite Float64 value, and stream-local sequence number.
- **Guide:** stable ID, orientation, numeric value or absolute timestamp, optional label, and visual style.
- **Selection:** selected stream IDs and explicit boundary semantics: fixed start/end, fixed start with end linked to now, or both boundaries tracking now at a fixed duration. Distinct from the visible range.

Resolve the implicit target chart once, during the connection handshake. Never continuously route samples according to the frontmost window or current target button. Window focus, chart creation and target changes cannot move an attached stream. Samples address their stream identity; explicit user layout moves can relocate its plotted representation independently of capture.

Concurrent plain `pp` launches must use a single running application and an atomic get-or-create operation for the initial session/chart. They must not accidentally create one app, session or chart per producer: the initial streams overlay in the same target chart. Sessions and charts retain stable identities even if renamed. Registration and target changes must be serialized: each new stream is registered in the target chart selected at the instant its registration is accepted. Later target changes do not affect it.

Confirmed target fallback: when the target chart is removed/collapsed or its window closes, mark the most recently used remaining chart in an open session as target. If none remain, the next plain `pp` creates a session and initial chart. Never route into a closed session or leave an invisible invalid target. Proposed recency definition: most recent explicit target selection, chart creation, or accepted new sampler attachment; incoming sample updates and incidental hover do not reorder the list. Ordinary window focus does not itself select a sink. Update target indicators atomically with fallback and invalidate the previous continuation epoch.

Confirmed startup distinction: a manual app launch restores the sessions/windows that were open when the app quit. Restore their chart layout, data and settings, and the previous target if still valid; use the fallback rule otherwise. Restoration does not rerun external commands or make ended attachments appear live. A launch triggered by plain `pp` with no app running creates the fresh session/initial chart required by the pipeline-first workflow; saved sessions remain available, but do not delay first plotting with restoration UI. Reopening saved windows manually is independent of the new producer registration.

Proposed short CLI surface, subject to naming refinement:

```sh
sampler | pp                    # automatic columns; current target; simple reruns resume
sampler | pp -n memory -u MiB    # name a new single stream
sampler | pp -c                 # create and target a chart
sampler | pp 2 memory           # attach to existing line memory in session 2
sampler | pp 2 used free        # map two columns to these existing named lines
pp ls                          # small session/chart/line listing with current target
```

Confirmed: provide a CLI option to create a chart and move the target sink. Proposed spelling: `-c` / `--new-chart`; atomically create a chart below the current target chart, mark it as the new app-wide target, and attach this invocation's sampler to it. The command receives the created chart's identity even if another invocation subsequently changes the target. With no app/session, create only the initial chart, avoiding an extra empty one. A less-common new-session option creates a window/initial chart and targets it; exact spelling is deferred. Explicit chart selection can remain available as a less-common option. Long aliases are discoverability aids, not the primary examples.

Confirmed: explicit session ID plus line name attaches directly to that line, independent of the target sink, creating it if missing in the named session's most recently used chart. Proposed `pp 2 memory` resumes or creates that line, while `pp 2 used free` maps columns in the specified order, resolving existing names and creating missing ones. Existing lines keep their chart membership; new lines use that session's most recently used chart. Ambiguous names, unknown session IDs, width mismatches, or already attached lines fail clearly before writing samples. Validate and register a multi-line request atomically so failure cannot attach only some columns. Never steal an active attachment or silently redirect to another session. Explicit attachment does not move the app-wide sink. Proposed: reopen a saved closed session for explicit attachment and create its initial chart if it has none; do not restart any other samplers.

Proposed: give unnamed streams short, unique session-local names and expose them in chart legends and `pp ls`. User-assigned CLI names must resolve unambiguously; duplicate friendly display labels must not make explicit attachment ambiguous. Stream identity survives renaming and remains distinct from its displayed name. Detailed naming syntax for multiple newly created columns can be refined without adding flags to the automatic case.

### Interrupt, rerun, and reassociate

Confirmed intended cases:

- `process | pp`, Ctrl-C, then the same pipeline again: continue the same one or more lines while keeping all earlier samples.
- Start another `pp` while the first is active: create another set of lines, even if its column count matches.
- After interleaving several producers, a plain rerun may lack enough identity to find the original lines. Create a new set, retain the older disconnected lines, and make repair cheap.
- Selecting another target or opening a new session invalidates automatic continuation of the old target. Explicit session/line addressing remains available.

Proposed minimal continuation rule, not an attempt to identify shell commands:

1. Each target epoch has one most-recent sampler group eligible for a plain rerun. An epoch changes when the target changes, including away and back, or a new session/chart becomes target.
2. The latest group is reusable only after its prior attachment has disconnected and the new row width matches. It is not enough to find any old disconnected group with the same number of columns.
3. Registering a second live sampler creates a new group and supersedes the previous group's implicit continuation slot. If the first sampler later stops and is rerun while the second remains active, it gets new lines. No scanning/guessing among older groups.
4. An explicit create-chart/session request always takes its requested path rather than continuing the old group. Name overrides or incompatible metadata must not silently rename an existing group during continuation.
5. Release attachment ownership promptly on EOF, pipe/IPC disconnect, and process termination. If an immediate rerun races delayed disconnect detection, wait briefly for the old owner to be confirmed gone; do not steal a live producer or create avoidable duplicate lines. The exact ownership/liveness mechanism is an implementation detail.

This heuristic cannot infer whether two unrelated sequential commands are the same sampler. Document its predictable latest-group rule briefly, provide explicit addressing for disambiguation, and make mistaken association reversible. A short new-lines option may be useful for the uncommon intentional fresh run; its spelling remains open.

UI repair requirement: a new line/group can be associated with an older disconnected one through a direct `Continue/Reassociate With…` action, ideally also by dragging its legend chip onto the older line. Proposed: for multiple columns, offer one group-level repair with an editable column mapping, not one mandatory dialog per sample/line. Preserve both sets of observations, keep a visible break at the connection boundary, retain the older line's identity/style, and transfer the new producer attachment. Never fuse two currently live producers or discard either history silently. Association is distinct from moving a line between charts.

Reassociation must be one undoable edit. Subsequent samples are attributed to attachment segments so undo can restore the original histories and live routing without losing samples received after association; do not implement it as an irreversible destructive merge. The precise treatment of later explicit attachments during undo needs a defined conflict rule before implementation.

## Input contract

Proposed first-release contract:

- One or more whitespace-separated floating-point values per input row. Spaces and tabs are separators; leading/trailing whitespace is allowed. A single float remains the simplest case. Each column becomes a separate plotted line/stream.
- Accept zero, negative values, decimal values, and scientific notation using a locale-independent decimal point.
- Timestamp each complete row when `pp` reads it, before UI batching. All values in that row share that receipt timestamp. Default timestamps represent local receipt, not remote measurement time.
- Preserve irregular intervals and arrival order; never substitute a sample index or guessed constant sampling interval for time.
- Empty lines can be ignored. Malformed lines, NaN, infinity, embedded NUL bytes, and oversized lines must have defined handling. Proposed default: skip invalid lines, report a bounded diagnostic on stderr, and expose a rejected-line count in the app.
- Parse a final valid line at EOF even without a terminating newline.
- Bound parser and transport buffers; an arbitrarily long line must not allocate unbounded memory.
- The first valid row establishes a fixed column count for the attachment. Proposed: reject an entire later row if its width changes or any field is invalid, with a bounded diagnostic; do not shift columns or partially advance streams. Dynamic columns, CSV/JSON extraction, implicit unit parsing and general XY plotting are deferred.
- `pp` keeps stdout free of status messages; diagnostics go to stderr. A future explicit tee mode may reproduce input on stdout.

Confirmed: v1 has no explicit sample-timestamp mode. All input columns are measurements and each complete row receives a timestamp at `pp` receipt, before batching. Never guess that the first numeric column is a timestamp. Historical imports and remote measurement timestamps are later work.

An upstream program may buffer its own stdout. PipePlot cannot recover timestamps or samples that have not yet been emitted; troubleshooting should explain this only when relevant.

## Time behaviour and chart representation

### Follow Now

Confirmed: a live chart must advance with wall-clock time while a producer remains connected, including when no new sample arrives. When the final pipe disconnects, the session clock freezes at that disconnect instant and resumes upon a new attachment. Without a forecast, its right edge ends at now rather than the last sample timestamp. With a forecast, the shared timeline extends beyond now to the predicted guide crossing; a visible now marker separates observed and future time.

Proposed:

- Confirmed: initially grow the historical time range with the session; once it reaches 15 minutes, retain a rolling 15-minute historical span. Users can adjust the span. The historical portion ends at now; an enabled forecast adds a future extent rather than counting future time against the selected history span. Proposed: a small initial minimum span keeps the first points readable rather than starting with a zero-width axis; its exact value is an implementation/tuning choice.
- Provide simple recent-span controls and `Show All History`; neither discards data.
- Display elapsed time since the last sample for each stream. Silence is distinct from EOF and connection failure.
- Do not invent points, silently interpolate missing observations, or extend the latest value to now.
- Keep the clock-driven axis and data ingestion independent. A sparse stream must not wait for another sample to flush the previous one.
- Display local calendar time; store absolute instants. Optional elapsed-since-session-start labels are useful later. Clock changes and wake from sleep must not crash or reorder the raw record silently.

### Inspecting history

- Panning, zooming, and interval selection continue to work during acquisition.
- Proposed: these interactions enter inspection mode with a fixed historical viewport. The toolbar shows current time and a prominent `Follow Now` action.
- The default live state always shows now in the plot; forecast mode may place it inside the viewport with future space to its right. Inspection is an explicit exception to live auto-scrolling.
- Pausing the view never drops input. Resume catches up from stored samples without a burst of per-sample animation.

### Marks and scales

- Lines on, dots off by default. Dots and connecting lines are independent switches, yielding dots-only, lines-only, or both. If both are off, keep acquisition active and make the hidden state obvious.
- Connecting lines use actual timestamps and straight segments; no smoothing by default.
- EOF/reconnection boundaries, including automatic continuation and UI reassociation, must not be connected as if sampling were continuous. Whether to break lines across long time gaps needs a rule that does not assume a fixed cadence.
- Provide automatic and explicit Y limits. Zero, negative-only, mixed-sign, constant-value, single-point, and empty streams must all render sensibly.
- Guides are annotations, separate from axis limits. A memory bound must not clamp or discard out-of-bound measurements.
- Automatic scaling must not erase manually selected limits on each update. `Reset View` has an explicit, consistent meaning.

### Stacked charts and moving streams

Confirmed: charts stack vertically, but every newly attached stream goes into the currently targeted chart by default. Cmd-Shift-D or the CLI create-chart option creates a separate row and moves the target. Users can easily combine streams into one chart or split them back out.

Proposed interaction:

- Drag a stream's labelled legend chip/header onto another chart to overlay it there. The drag source remains available when dots or lines are hidden.
- Drop between rows or into a `New Chart` target to give the stream its own row. Show a clear insertion/merge preview during the drag.
- Also offer `Move to Chart…` and `Move to New Chart` actions for keyboard/accessibility use.
- Remove the source axis/row immediately when its last stream moves away. Never leave a blank chart requiring cleanup.
- Moving a stream preserves its identity, captured history, producer connection, name, colour and mark settings; it does not reconnect `pp` or copy history. Target selection is unchanged unless the move collapses the targeted source chart, which requires the explicit fallback rule above.
- Layout moves and automatic empty-axis removal are one undoable operation. Persist the resulting layout.
- The destination chart retains its configured unit, Y scale, and value annotations when a stream is moved into it. Moving a stream never silently changes its numeric samples, converts units, or replaces the destination axis configuration.
- Proposed: `--unit` is a convenience for initialising a newly created chart; the chart's unit is editable in the UI. It is not required for `sampler | pp`. Handling conflicting source-unit hints remains open, but never silently normalize unlike units.

Confirmed: horizontal value guides, bounds, and other value annotations belong to the chart/axis. They stay with the source chart when a stream moves, and retain their meaning in that chart's configured units. Time guides remain session-wide.

Proposed empty-axis lifecycle: when the last stream leaves, collapse the axis out of the visible stack but retain its configuration and annotations for undo/restoration. A newly created empty chart awaiting its first producer stays visible and targetable; automatic collapse applies to vacated charts, not intentionally created empty sinks. Explicit chart deletion, rather than stream movement, removes that configuration. Detailed persistence/restoration UI remains deferred.

### One coordinated timeline

Confirmed: users are normally examining one time across the entire stack. All chart plot areas must align horizontally, despite different Y-label widths, and share the same time-to-screen mapping.

- One hover timestamp produces a vertical crosshair through every visible axis, with a readable timestamp on the shared ruler. Moving the pointer between chart rows must not change the time merely because their local geometry differs.
- Show coordinated per-stream readouts for that timestamp. Proposed: identify the nearest actual observation, with its timestamp/offset where it differs from the hover time. Never imply that irregularly sampled streams were measured simultaneously or interpolate values silently. A sensible proximity threshold/readout rule needs refinement.
- Time guides are session-wide vertical annotations spanning every axis, including after rows are added, merged, reordered or removed. Horizontal value guides remain specific to a Y scale.
- Horizontal zoom, pan, fit-to-selection, Show All History, and Follow Now update the whole stack together. Changing a Y scale remains local to its chart.
- A time-range selection is shown at the same bounds across rows. Proposed: the interval is shared, while stream inclusion for analysis can be selected independently.
- Keep hover, persistent time guides, selection boundaries, and the current-time indicator visually distinct. Moving the hover cursor does not move saved guides or the selection. A boundary explicitly linked to now advances on clock ticks.
- A shared time ruler stays visible while vertically scrolling a long stack. Charts that become visible adopt the current shared timeline state immediately.

### Perfetto-inspired navigation

Reference behaviour verified in the [Perfetto UI documentation](https://perfetto.dev/docs/visualization/perfetto-ui): WASD pans/zooms, Shift-drag pans, Ctrl-wheel zooms, dragging creates a range selection, range handles adjust boundaries, and F fits a selection.

Proposed PipePlot adaptations, to validate on a Mac trackpad:

- Smooth horizontal pan and pointer-anchored zoom across the entire stack, with immediate feedback during gestures.
- Drag to select an interval; Shift-drag to pan; support native trackpad pinch/scroll gestures without conflicting with vertical stack scrolling or guide handles.
- Offer W/S zoom, A/D pan, F fit selection, and Escape clear selection when the timeline has keyboard focus. Never intercept these while editing a stream name, guide label or numeric field.
- Keep selection details in a stable inspector/drawer; hover and incoming samples must not repeatedly open, close or steal focus between panels.
- Entering historical navigation suspends live auto-scroll for the whole session. `Follow Now` restores it for every chart together.

Fluidity is a requirement for interaction, even though source samples and the wall-clock display update slowly. Input gestures may render at display cadence while active; idle charts must not run a permanent high-frequency redraw loop. Benchmark this with long histories and multiple stacked rows. If separate Swift Charts views cannot maintain exact alignment and responsive shared gestures, evaluate a shared coordinate/gesture layer and native rendering alternatives before compromising the interaction model.

## Guides, notes, and selection

Proposed guide interaction:

- Drag from a narrow left/right edge strip to create a horizontal value guide; drag from a top/bottom strip to create a vertical time guide.
- Show the numeric value or timestamp while dragging. On release, retain it in data coordinates, so it stays meaningful under zoom, resizing, and live scrolling.
- Double-click or use the inspector to set an exact value and optional label such as “memory limit”.
- Select, move, rename, recolour, or delete a guide. Support undo/redo.
- Provide menu/keyboard equivalents; edge dragging is a shortcut, not the only creation method.
- Vertical guides can carry event notes. Marking a time range should be possible without turning it into a permanent analysis result.
- Time guides belong to the session and span the entire chart stack; creating one from any chart creates the same shared time annotation.
- Guide dragging, selection, panning, and zoom gestures must have distinct hit regions/modifiers. Selection must remain usable near guides and chart edges.

An interval selection should immediately show count, duration, first/last value, minimum, maximum, mean, and change for the selected stream. Proposed: report sample-weighted mean explicitly; irregular sampling does not justify presenting it as a time-weighted mean.

### Selection boundaries linked to now

Confirmed interaction:

- While creating or adjusting a region selection, bringing its right edge onto or near the current-time vertical indicator changes its colour to indicate a link to now.
- Once linked, the right edge follows current wall-clock time, including while the producer is silent. The left edge initially remains at its selected absolute time, so the selected interval grows.
- When the right edge is linked, show a button on the left edge that makes the left edge track now too, keeping the total selected time delta fixed. Capture that delta when the button is activated.
- A fixed-duration selection is represented as `[now - duration, now]`, not by repeatedly overwriting two absolute timestamps. The entire stack shares these boundary semantics.

Proposed details to make the interaction explicit and accessible:

- Near-now snapping uses a screen-space tolerance rather than a fixed number of seconds, so it remains usable at different zoom levels. The colour is a preview while dragging; releasing commits the link. Indicate the linked state with an icon/label as well as colour.
- Expose fixed end, end follows now, and fixed-duration follow as discoverable selection controls; edge proximity is the quick path. Dragging a linked edge away can detach it. Exact toggle/detach affordances need refinement.
- Hover remains independent of selection boundaries. Live-linked selections update statistics from actual samples currently in range, without inventing points at now.
- Selection follow and viewport Follow Now are separate states: inspecting history must not silently change the selection's meaning. If a linked selection advances offscreen, preserve its mode and expose a way to return to it.
- Confirmed: automatic boundary motion never registers undo steps. Deliberate creation/clearing of a selection, edge adjustments and boundary mode/duration changes use session Cmd-Z, grouped as one step per completed interaction. Undo restores the selected boundary semantics, so restoring a linked selection resumes following the current clock rather than freezing at the old execution time.
- Use one session clock snapshot for all rows/boundaries per update; the duration must not drift because rows update at different times.

Confirmed forecast coupling: now-linked selections provide growing or rolling training intervals and an enabled forecast automatically refits as that selection advances. Fixed selections retain their bounds and fit. Model fitting uses the actual selected observation timestamps, independent of the display's sample reduction.

Analysis direction to retain from prior discussion:

- Fit/extrapolate from the selected interval, with a visible training range and a separate forecast overlay.
- Time-to-guide estimates when a chosen model supports them.
- Investigate repeating patterns through period estimation or matching.

Confirmed first-release analysis: selection statistics plus an optional, explicitly requested linear forecast. Period estimation/matching and richer models are later work. Do not automatically assume a global linear trend. Fit actual sample timestamps without assuming a fixed cadence; a fitted line alone is not a calibrated uncertainty interval. For any later analysis requiring regular sampling, resampling must be explicit, including its interval and missing-data treatment.

### Linear forecast to a guide

Confirmed:

- Choose a horizontal value guide as the forecast target. Extrapolate the selected stream's linear fit to that guide and show the estimated crossing time.
- Extend the shared session timeline beyond now to show the future prediction. Keep a clear now line across the stack; prediction is visually distinct from observed dots/lines.
- Automatically refit while the training selection is linked to now, whether its start is fixed or following at a fixed duration. A fixed training selection keeps a fixed fit.

Proposed first-release details:

- From selection analysis, choose a stream, enable `Linear Forecast`, and select an existing horizontal guide on that stream's chart or create one with an exact value. Store guide/stream IDs and boundary semantics in the analysis configuration.
- Use ordinary least squares over actual timestamps and values, centering time numerically for stability. Require at least two distinct sample times; otherwise show `Not enough data`. State the sample count, training duration and estimated slope alongside crossing time and time remaining.
- For a finite future intersection, render the extrapolation to the crossing and add modest visual padding. All charts retain the same X domain. Multiple enabled forecasts use the furthest relevant crossing for the shared future extent; avoid repeated axis animation as estimates update.
- For a flat/undefined slope, non-finite result, or a trend with no intersection after now, show `No future crossing predicted` (or an estimated past crossing where useful), rather than inventing a horizon or misleading countdown. Keep the observations usable. Numerical tolerances and extreme-horizon presentation are implementation details to validate.
- Forecast calculation and viewport updates are coalesced at the normal visible update cadence; do not fit on every clock frame or block gestures. When input is silent, the selection still advances and sample membership can change; refit only when inputs/membership/settings change, while updating time-remaining text separately.
- Editing the target guide updates the crossing estimate using the fixed or current live fit. If the guide is deleted or no longer belongs to the stream's chart after a move, mark the analysis as needing a target; do not silently choose another guide. Undo restores valid references.
- A manually inspected viewport must not jump as a forecast changes. `Follow Now` returns to the coordinated historical-plus-future view. Dynamic forecasts may compress history when the crossing is very distant; the default fitting/padding policy should be tuned without changing the chosen history duration.
- A fixed forecast's crossing timestamp does not move merely because now advances. Its countdown and whether that crossing is still in the future can change.

## Undo and redo: foundational contract

Confirmed: undo must be designed into the model and interactions from the start; it is not a later interface enhancement.

### User-facing behaviour

Proposed first-release contract:

- Each session has an independent edit history. Cmd-Z and Shift-Cmd-Z act on the active session, with standard Edit menu commands and descriptive labels such as `Undo Move Stream` or `Redo Delete Guide`.
- Undoable edits include chart/stream renaming and styling, units and explicit scale settings, dots/lines visibility, guide/note creation and editing, chart ordering, stream movement/merging/splitting, removal from the layout, deliberate selection edits and creation/removal/configuration of analysis overlays.
- Every completed user action is one meaningful undo step. Creating a guide by dragging, or moving it continuously, records its final change once rather than once per pointer event. Repeated key nudges and text edits group into predictable editing transactions. A no-op creates no history entry.
- Compound actions are atomic. Moving the final stream out of a chart, collapsing that chart, and inserting the stream into its destination is one action. Undo restores the source chart's identity, unit, guides, scale, order and stream membership together; redo repeats the same layout change.
- Interactive edits preview immediately. Escape cancels the current drag/edit and restores the pre-gesture state without adding an undo step or destroying redo. Invalid field edits likewise do not become partially committed model changes.
- A new committed user edit after Undo clears redo for that session. Incoming samples, clock ticks, automatic continuation, stream connections/EOF and hover changes never clear redo or create undo entries. Explicit UI reassociation is an undoable edit.
- Native text fields retain normal local text undo while editing. Committing a field produces a coherent session edit; Cmd-Z must not undo an unrelated chart operation while a text editor owns the command.
- Edits in one window must not affect another session's undo history. Changing window focus does not itself create an edit.

### Capture and external side effects

- Undo/redo operates on user-authored configuration and presentation. It never rewinds sample arrival, restores an old copy of the entire session, discards samples captured since an edit, or changes a producer's assigned session. Explicit line reassociation has its own reversible attachment-segment mapping; undo may reverse that mapping within the session while preserving every received observation.
- Undoing a stream move while it continues receiving samples relocates that same stream and all its current history. Connections established after the original edit remain valid and their unrelated configuration is preserved.
- Proposed: removing a stream/chart from the visible layout is a reversible presentation action. Keep its identity and data available while undo can restore it. Removal must not implicitly terminate its producer.
- Stopping a producer connection and quitting the app are external lifecycle actions; Undo cannot restart an upstream shell process or recover samples it never emitted. Keep `Stop Capture` distinct from reversible layout removal and describe the consequence directly.
- Proposed: session/data deletion first removes access reversibly; irreversible file cleanup is separate from the edit transaction and must not destroy payloads still needed for Undo. The exact deletion/persistence mechanism can be settled later.
- Proposed: choosing `Target sink` is an explicit routing control outside session edit history. Cmd-Z must not silently redirect future CLI connections. Cmd-N likewise must not be undone by deleting a session that may already have accepted producers.
- New-chart actions (Cmd-Shift-D, UI button and `pp -c`) share semantic undo. Confirmed: undo creation of a populated chart moves its lines to the preceding chart and keeps collecting. Chart removal, line relocation and target fallback happen atomically; no samples or attachments are discarded. Preserve the removed chart's identity, configuration and annotations for redo, rather than carrying its value guides into the preceding chart.
- Proposed redo contract: restore that chart with the same identity/configuration/annotations and move back the exact stream IDs relocated by Undo, including all samples they received in the meantime. Do not sweep unrelated lines added to the preceding chart into the restored chart. Empty-chart creation is reversed by removing the empty chart. Apply the normal most-recently-used target fallback when removing a targeted chart, but do not overwrite a later explicit target selection merely to restore historical routing. The first chart of a newly created session is a bootstrap object rather than a removable create-chart undo step. Resolve a missing preceding chart deterministically (for example restore its recorded predecessor as the destination) without stopping capture.

### Navigation versus edits

Confirmed: deliberate selection edits (create/clear a range, move edges, link/unlink from now and set fixed-duration following) use session Cmd-Z. Hover and automatic boundary motion never create history. Pan/zoom uses separate Back/Forward navigation, preserving a useful way to undo an accidental viewport change without obscuring model edits. Proposed: Follow Now and fit-to-selection also belong to navigation history. Explicit numeric axis-limit edits remain configuration edits. Creating an analysis or guide from a selection is an edit.

### Model and implementation requirements

- All committed user edits pass through a shared model-level action/transaction boundary. Menu commands, drag/drop, inspectors and keyboard shortcuts invoke the same actions; view callbacks must not mutate durable configuration through a separate path.
- Actions address stable session/chart/stream/annotation IDs and retain the smallest before/after state needed to reverse their own changes. Avoid whole-session snapshots and history copies of raw sample arrays.
- Define operation preconditions, inverse behaviour and redo behaviour alongside each feature. Validate compound changes before committing them; failures leave both model and history unchanged. Replaying an inverse must not register a second unrelated edit.
- Serialize edits and external registration changes consistently. Undo restores only the fields and relationships owned by the action, preserving later unrelated producer activity. Cases where a new stream has attached to a chart that an inverse would otherwise remove need explicit conflict handling; never delete or detach that live stream as collateral.
- Long-running analyses use stable result/action IDs and cancellation or invalidation. If an analysis is undone before completion, a late result cannot resurrect its overlay. Redo uses the recorded boundary semantics (fixed timestamps or a now-linked mode/duration), input identity and parameters rather than whichever hover/selection happens to be current. Snapshot versus dynamic analysis behaviour must be explicit.
- Bound undo memory independently of sample retention. Retain IDs and small edit payloads; large existing datasets are referenced. If history is pruned, reclaim resources only when no current model or retained action needs them. Do not claim unlimited undo.
- Use the native UndoManager integration for macOS responder/menu behaviour where appropriate, with explicit grouping rather than accidental event-loop grouping. The model action layer owns semantic correctness.
- Undo history across app restarts is not a first-release requirement. Persisting the current session state is separate from serialising the command history.

## History, memory, and persistence

Confirmed: optimise for low laptop overhead and long observation periods, rather than oscilloscope refresh rates or a short rolling sample buffer.

Proposed architecture constraints:

- Distinguish **raw retained history**, **visible time span**, and **rendered representation**. A 15-minute view must not imply 15-minute retention.
- Automatically append samples to a local session store in bounded batches. The storage mechanism is deliberately deferred; it must support bounded-memory capture, restart recovery and efficient time-range queries without dictating the editing/undo model.
- Keep only a bounded working set and render cache in RAM. Do not retain all history in SwiftUI state or publish a complete sample array per observation.
- Render a viewport-dependent representation for long sessions, preserving extrema and gaps. Raw samples remain available for exact inspection and analysis; display reduction must not replace them.
- Hidden or minimised windows continue collecting with reduced or suspended drawing. No display-link/60 Hz loop for idle low-frequency streams.
- Independent ingestion and UI refresh. Proposed visible update cadence: about once per second while following now, with prompt first-sample presentation. Sparse input is flushed by a bounded timer, not a batch-size threshold alone.
- App and per-producer queues have explicit limits and backpressure. Never silently lose samples or grow a paused-view queue forever.
- Disk-full and write failures become visible errors. Do not claim successful capture when persistence has failed.

Confirmed: sessions, data, names, guides, and presentation settings are automatically saved locally and remain available across app restarts until explicitly deleted. Closing a window is distinct from deleting its session. No automatic expiry or silent history pruning. Keep this requirement lightweight for now: storage engine, cleanup UI and crash-durability details are deferred. Persistence must not imply keeping all saved sessions in RAM, and must respect undoable removal/deletion semantics.

Proposed performance evaluation, not measured promises:

- Measure cold launch to first visible point and warm attach to first visible point separately; initial target is under 2 seconds cold and under 500 ms warm on the user's Mac.
- Sparse input (one point/minute) must still show a newly received point within 1 second after attachment.
- Exercise 10 streams sampled every 5 seconds over a week of history, with one live window and several hidden ones. RAM should plateau with bounded caches, not grow with session duration.
- Report app RSS, CLI RSS, CPU/wakeups while idle and ingesting, disk growth, and interaction latency. Set numeric RAM/CPU budgets after a native prototype measurement rather than claiming SwiftUI guarantees low usage.

## Lifecycle and failure behaviour

- EOF flushes the last samples and marks the stream ended. The chart and history stay open and inspectable.
- Quiet-but-connected, ended, disconnected, and errored are distinct states. Show last sample time and a concise status.
- `pp` cannot infer the exit code of the upstream producer from ordinary stdin EOF. Do not display “producer succeeded” merely because stdin closed.
- Confirmed: closing a session window disconnects all its attached samplers and retains the captured data and configuration for reopening. No background collection for a closed session. Closing one window does not disconnect other sessions. Signal the disconnect promptly to `pp`, flush accepted samples, and show the session as closed/disconnected when reopened. `pp` cannot guarantee termination of an upstream producer that ignores a broken pipe; never claim it killed that process.
- App termination or IPC loss produces a useful stderr error and non-zero exit from `pp`. A new invocation can continue eligible disconnected streams under the rerun rules; a still-running client must not silently reconnect into a new session and split a capture invisibly.
- App startup, registration, first-sample delivery, EOF and shutdown have defined ordering. A producer that emits immediately and exits before the window appears still leaves a complete visible stream.
- After sleep/wake, time advances correctly and the display shows the real observation gap. Acquisition resumes where the underlying pipe remains connected.
- Resizing to a very small window, or receiving data before chart geometry exists, must never affect storage correctness or crash the app.

## Native implementation direction

Proposed, subject to a focused spike:

- SwiftUI application shell and multi-window session views; Swift Charts for point/line/rule marks and axes.
- ChartProxy and chart overlays for value/time coordinates, interactive guide placement, and interval brushing.
- Shared non-UI capture/session model; views consume reduced snapshots on a bounded cadence. Parsing, storage, and analysis run off the main actor.
- Implement the model action boundary, semantic undo/redo and compound transactions before building editable chart interactions. Native UndoManager is the UI integration point, not a substitute for reversible domain actions.
- Small Swift CLI and local IPC. Prefer an appropriate native/local mechanism over running a web server. Unix-domain sockets or XPC are candidates; launch, packaging and sandbox constraints must decide the mechanism.
- Connection handshake includes protocol version, intended session/chart or create-chart intent, sampler/column metadata, continuation or explicit-line intent, acknowledgement and stable identities. Negotiate column width without losing the first row. Chart creation, target update and sampler/stream registration are atomic when requested together. Data delivery does not depend on a chart view being mounted.
- Confirmed first-release delivery: local build/install of the native app and `pp` for the user's current Mac. Provide simple reproducible build/run/install instructions in the repository; no signing/notarisation/public-release work is required beyond what local execution needs. CLI/app discovery must work after local installation without a special development-shell environment.
- Use AppKit bridging where macOS window/focus management needs it; “native SwiftUI” is a product direction, not a prohibition on system APIs.
- Confirmed platform scope: current installed macOS only, Apple Silicon. Observed locally on 2026-10-29: macOS 27.0.1, build 26A434, arm64 (`sw_vers`, `uname -m`). Re-check installed SDK/toolchain at implementation time; do not add older-macOS or Intel compatibility work without a new requirement. Native chart APIs establish feasibility for marks, axes, coordinate mapping and brushing, not performance or complete built-in analysis.

Apple references: [Swift Charts](https://developer.apple.com/documentation/charts), [chart overlay](https://developer.apple.com/documentation/swiftui/view/chartoverlay(alignment:content:)), [interactive brushing example](https://developer.apple.com/videos/play/wwdc2022/10137/), [visible domain](https://developer.apple.com/documentation/swiftui/view/chartxvisibledomain(length:)).

## Research: lessons from existing implementations

Reviewed GitHub commit history on 2026-10-29: latest 100 wesplot commits, latest 300 ttyplot commits, plus selected patches. This is a targeted history review, not a complete source audit. Do not infer current bugs from historical fixes.

| Evidence | PipePlot implication (design inference) |
| --- | --- |
| wesplot [timeout flush fix](https://github.com/cactusdynamics/wesplot/commit/6cc2cbe698f1fbb373b4c28faf9926c44fa2cc36) and [configurable flush interval](https://github.com/cactusdynamics/wesplot/commit/f694a2a0782cd90fe24e5d2e11e83aef254602a6) | Flush sparse input on a timer; separate capture from render cadence. Optimising for high-rate batches must not delay a lone sample. |
| wesplot [connect after chart registration](https://github.com/cactusdynamics/wesplot/commit/11718de5346d7b0b7357eecbc263ab54cb4999fe) | Capture cannot depend on view readiness; test immediate finite producers during cold launch. |
| wesplot [pause buffer fix](https://github.com/cactusdynamics/wesplot/commit/4b2029b5b693f2dc41c63f825cf52897f4ba54c9) | Pausing navigation must retain incoming observations, with bounded RAM. |
| wesplot [flush when stream ends](https://github.com/cactusdynamics/wesplot/commit/b2721d0609b2d35056fcce7ca509889eccd201ee) | EOF must follow the final sample flush, and retain a useful completed chart. |
| wesplot [window/buffer sizing change](https://github.com/cactusdynamics/wesplot/commit/0ec04cbb466d5a232c2db9e795d6ba8eb365d128) | Audit batching and history boundaries together, but keep retained history independent of the viewport. |
| wesplot [timestamp limits and reset work](https://github.com/cactusdynamics/wesplot/commit/6eaee3c520ec49af9f8573b0301544eb2d9001e6) | Specify time units, time-zone display, auto/manual scales and reset behaviour explicitly. |
| ttyplot [non-finite input protection](https://github.com/tenox7/ttyplot/commit/bb5915e91037bdcb47caac55f78356835095e167) and [NUL input robustness](https://github.com/tenox7/ttyplot/commit/e53366d1ff75bfbbb949800c5d956be221e6e170) | Float parsing needs finite-value validation and bounded malformed-input handling. |
| ttyplot [buffer truncation ordering](https://github.com/tenox7/ttyplot/commit/4920b1dd988532111865b5e6263e5bcac21d8c18) | Exercise split input chunks, line boundaries, and parser capacity limits rather than assuming one read is one sample. |
| ttyplot [negative second-series fix](https://github.com/tenox7/ttyplot/commit/f3bfe02843c9e64ef8398a8c3f6399ba867ce6e2) | Test negative and overlapping streams from the start, not just positive memory values. |
| ttyplot [small-window divide-by-zero fix](https://github.com/tenox7/ttyplot/commit/c4e21c6e7eafd11e805b1cda4a17120bb9594ce6) | Degenerate geometry must not interfere with ingestion or chart stability. |
| ttyplot [subsecond rate resolution](https://github.com/tenox7/ttyplot/commit/21763760c09fa1fab529d196a435a899e2e21887) | If rate/derivative analysis is added, use actual time deltas; handle zero elapsed time and irregular observations. |

Maintenance observation: wesplot history includes substantial protocol/frontend work in late December 2025 and January 2026 after a long gap. “Unmaintained” would be too strong; popularity and suitability remain separate questions. This review does not rely on the earlier README as a full account of current implementation.

## Acceptance scenarios to carry into implementation

1. Cold-start `printf '1\n2\n3\n' | pp`: exactly three samples survive, the app shows them, and the stream is ended.
2. Open two sessions with multiple charts and attach producers in turn: each remains registered to its stream/session while focus and chart Target sink selection change. Focus alone leaves the target unchanged; Cmd-N targets its initial chart; target buttons agree across windows.
3. Two plain `pp` producers start simultaneously with no app running: one app instance, one initial session/chart, and two distinct overlaid streams in that chart.
4. Emit one value, remain quiet for two minutes, emit another: first point appears promptly; now continues moving; no fake observations appear in the gap.
5. Pause/inspect for an hour during acquisition: all observations remain available, view stays stable, RAM does not grow as a paused queue, and Follow Now catches up.
6. Observe beyond 60 seconds and beyond the selected viewport: old raw samples remain available according to the eventual history policy.
7. Toggle dots and lines, including hiding both: acquisition and history are unaffected.
8. Add a guide at exactly zero and another at a memory limit; pan/zoom/resize: guides stay at their data values and can be edited precisely.
9. Feed negative values, exponents, a constant series, malformed lines, NaN/Inf, split lines, NUL bytes, oversized lines, and a final unterminated valid line: deterministic outcomes, no crashes, bounded diagnostics.
10. Close stdin, close a session, terminate the app, and simulate IPC/disk failure: distinct states, no silent sample loss claims, meaningful CLI exit status.
11. Sleep/wake and resize to minimum window size during input: correct gaps, stable collection, responsive UI.
12. Compare raw selection statistics with reduced display data: calculations use actual selected raw samples.
13. Quit and reopen: saved session data, names, guides and settings remain available. Closing a window does not delete data, and only explicit deletion removes a saved session.
14. Attach three streams through plain `pp`: they overlay in the target chart. Create a chart with Cmd-Shift-D and attach another stream there. Move a stream between rows, then split it out again: producer identity and all history remain unchanged; vacated source axes collapse; undo restores the prior layout.
15. Hover, pan, zoom and select across rows with different Y-label widths and irregular sampling: one timestamp maps to exactly the same horizontal position everywhere. Per-stream values retain their actual sample-time meaning.
16. Add a time guide, then reorder/merge/remove rows and scroll the stack: the guide remains aligned across every axis. Shared zoom and Follow Now remain coordinated.
17. Navigate rapidly through a long capture while new data arrives: pointer feedback remains fluid, selection and viewport do not jump, and idle CPU use falls again when interaction ends.
18. Configure a source chart in MiB with a memory-limit guide, then move its stream: the destination retains its own unit/scale/annotations and receives unchanged sample values; the source retains its guide. If emptied, the source axis disappears from the stack while its configuration remains recoverable under the proposed collapsed-chart policy.
19. Drag a guide through many positions, release, then Undo/Redo: exactly one action restores/reapplies the final position. Escape during a second drag restores the previous position without touching redo history.
20. Move the last stream out of an annotated chart while samples arrive, then Undo/Redo: chart structure and annotations restore atomically, capture never stops, and all newly received samples remain available.
21. Undo an edit, then receive samples, attach another producer, hover and zoom: redo remains available and replay preserves that producer and its samples. A new committed edit clears redo.
22. Edit sessions in two windows and use Cmd-Z in each: histories are independent, menu labels are meaningful, and text-field undo remains local while editing.
23. Start an asynchronous analysis and undo it before completion: no late overlay reappears. Redo refers to the original interval and parameters.
24. Exercise long edit histories and reversible removals with large captures: undo memory depends on edit metadata rather than duplicated sample history; pruning does not invalidate current data or retained actions.
25. Select an existing chart as target, then run plain `pp` from a terminal: its stream joins that chart with its existing unit/annotations. Cmd-Shift-D in another session creates and targets a chart below that session's current chart without moving existing streams.
26. Run `pp --new-chart`: exactly one chart is created and targeted and this command's stream attaches to it atomically. Concurrent create-chart commands each receive their own created chart identity; later plain `pp` uses the last accepted target change.
27. Pipe `1 2`, then `3 4`: two lines receive two samples each at the corresponding shared row timestamps. Spaces, tabs and scientific notation work; changing width or a malformed field cannot swap or partially update columns.
28. Interrupt and immediately rerun a one- or two-column sampler without changing the target: the same line identities continue, earlier data remains, and a connection break is visible. Repeated reruns do not accumulate duplicate legends.
29. Start samplers A and B concurrently, stop A, then rerun A plainly while B remains active: new lines appear instead of hijacking B or guessing among old groups. Reassociate the new group with A through one UI operation; undo preserves all old/new samples and current capture.
30. Switch targets away and back, or create a session, then rerun: no implicit continuation of the old epoch. `pp 2 memory` attaches to that specific disconnected line, or creates it in session 2's most recently used chart if missing; an occupied line or unknown session fails clearly.
31. Session IDs remain small integers across close/reopen and listing; renamed/reordered sessions retain their IDs. Common small-session workflows require no UUID copying or routing flags.
32. Start a fresh live session: the view grows with time, then rolls at 15 minutes without deleting earlier data. No input column is interpreted as a timestamp.
33. Drag a selection end near the now indicator: the colour previews linking. After linking, the end follows now even with silent input; the start remains fixed. Activate the left-edge tracking button: both boundaries move with exactly the chosen duration across all rows.
34. Update a linked selection for an extended period: selection statistics reflect actual in-range samples, duration does not drift, and automatic clock motion does not fill undo history. Hover and viewport navigation do not silently alter boundary modes.
35. Enable a guide-targeted forecast on a linked selection: new selected samples update the fit/crossing automatically, all rows extend to the same future domain, and now remains visible. A fixed selection preserves its fit and crossing timestamp as unrelated samples arrive.
36. Exercise insufficient distinct times, flat/opposing slopes and already-past intersections: clear non-forecastable states, no infinite axis or fabricated countdown. Edit/delete/undo the guide and move the stream between charts: analysis references remain explicit and recoverable.
37. Create a range, link its end to now, enable fixed-duration following, and undo each user interaction: one meaningful step each, restored live modes follow current time, and automatic movement adds no steps. Pan/zoom navigates independently through Back/Forward.
38. Close the targeted session: its samplers disconnect and data remains saved; another session keeps collecting. The most recently used remaining chart becomes the visible target. If all windows are closed, the next pipeline creates a new session/chart.
39. Create a chart below another, attach several columns, and undo creation: its streams move into the preceding chart and keep receiving samples. Redo restores the created chart, its annotations and those stream identities without moving unrelated subsequently added lines.
40. Manually quit/relaunch: restore the previously open windows, data, layout and valid target with samplers disconnected. Launch via a fresh pipeline instead: show a new session/chart promptly. Explicit named attachment creates missing lines in the specified existing session rather than failing or using another session's sink.

## Implementation handoff and remaining discretion

The product interview has settled the primary workflows. An implementing agent can begin without another general requirements interview. Confirmed decisions take precedence over proposals; historical research describes evidence, not a requirement to copy another tool's architecture.

Recommended implementation order: establish the model/action boundary and reversible edits; prove `sampler | pp` launch/registration/column handling and continuation; build coordinated native chart interaction; add guide-targeted forecasts; complete local saving/restoration and installation. Validate undo and live acquisition together from the beginning. Build a usable vertical slice before polishing secondary screens.

Implementation discretion includes native IPC/storage choices, initial minimum time span, gesture hit tolerances, chart rendering reduction, short automatic line names, additional CLI aliases, collapsed-chart recovery UI and forecast layout tuning. Choose simple consistent defaults, document them, and preserve the flag-free ordinary pipeline path. More complicated continuation/reassociation conflicts need concrete safe behaviour and tests, not heuristic data loss.

Do not expand v1 to source timestamps, periodicity analysis, general data formats, remote hosting/sharing, older-platform compatibility or public distribution. Do not spend disproportionate effort designing persistence before first-chart ergonomics and robust undo work. Ask a focused question only if a confirmed requirement conflicts with a concrete implementation constraint or a choice would change the user's visible workflow materially.
