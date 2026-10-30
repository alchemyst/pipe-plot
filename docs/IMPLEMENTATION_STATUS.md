# Specification follow-up — 2026-10-30

This follows the historical [specification audit](SPEC_AUDIT.md). The specification has not been weakened or rewritten to match the implementation. The user's line default, selection snap, stable hover space, stopped-session clock and sine-generator changes remain intact.

## Implemented corrections

- Registration checks current ownership before continuing a group, selects the most recently used visible chart for missing named lines, and rolls back failed compound requests. Cold CLI bootstrap waits for registration; listing does not create a session, and cold `-c` creates just the initial chart.
- Undo/redo preserves later producers, sample history, chart settings and unrelated target changes. Splitting into a new chart is one action. Metadata write failures restore semantic edits; reassociation failures also reverse sample remapping. Raw samples already committed to SQLite and actual connection shutdowns remain facts even if snapshot persistence fails.
- Charts can be renamed, reordered, hidden and restored. Sessions can be renamed, moved to recoverable Trash and restored. Deleted sessions cannot become capture targets or be silently reopened. Restoration opens a window and does not restart producers.
- Entire active or ended sampler groups can be reassociated through a column mapping sheet. Attachment bookkeeping is bounded by active/latest stream groups and retained edit history, rather than number of reruns; raw history stays in SQLite.
- Stream colours and line/dot settings survive moves; chart controls apply to the chart's streams. A unit hint initializes an unset chart label without overriding configured units. Incompatible unit hints do not implicitly continue an old group.
- Pan/zoom, selection and time-guide previews share session state. The shared ruler stays visible. Ordinary vertical scrolling scrolls the stack; Ctrl-wheel/pinch zooms, Shift/horizontal scrolling pans. A/D pan, W/S zoom, F fits the selection and Escape clears it without intercepting text editing.
- Now-linked selections have the direct left-edge duration-follow button. A fixed-height shared inspector exposes stream inclusion and raw statistics, including first/last values, duration, extrema, sample-weighted mean and change. Hover keeps its reserved height.
- Guide menus support exact values/local times, labels, colours, deletion and accessible creation. Legend drag/drop complements move/merge/split menu actions.
- Multiple linear forecasts share the furthest future horizon. Forecasts show crossing, countdown, slope, count and training duration; target values participate in automatic Y scaling. Fixed selections keep their fit; live selections refit. Undo/removal while calculation is pending cannot resurrect an overlay.
- Reduction, statistics, nearest-sample lookup and fits use a background queue and a separate read-only WAL connection. Results are keyed to their requested interval and data version; stale selection statistics are not displayed as current. Navigation history is capped.
- Transport caps accepted clients and applies whole-frame receive/send deadlines where a reply is expected. Quiet live producers remain valid indefinitely. Leading rejected input is counted exactly with bounded diagnostic detail. Initial storage failure displays an error rather than replacing saved data.

## Evidence and limits

The five standalone audit reproductions now produce:

```text
LIVE_OWNER_HIJACK false continued false
EXPLICIT_USES_LAST_NOT_MRU false
REDO_HIDES_LATER_PRODUCER false
REJECTED_REQUEST_CREATED_SESSION 0 CHANGED_TARGET false
UNIT_HINT_NOT_APPLIED false
```

See [core benchmark](CORE_BENCHMARK.md) for the controlled SQLite measurement and its hardware/build context. It is not a UI latency measurement. Existing prior interactive observations remain in [VALIDATION.md](VALIDATION.md).

Physical sleep/wake, a controlled hour-long paused-view run, week-scale resource use and precise cold/warm latency budgets still require measurement. These are validation limits, not completed acceptance claims. The fault tests exercise failed metadata writes and rollback, rather than filling the user's real disk. No claim is made that two independent files have a single crash-atomic transaction: SQLite holds raw data and atomic JSON snapshots hold presentation metadata, with count/bounds recovery at startup.

## Final checks in this follow-up

- Full `swift test`: **44 XCTest cases passed** (33 core/storage, 8 transport, 3 app/background-analysis), zero failures. App tests include pending-fit Undo and multiple fixed forecasts sharing a future horizon.
- Release build, ad-hoc signing and local app/CLI installation succeeded.
- Installed cold `pp -c`: one new session, one chart, two columns with exactly three observations each.
- Cold `pp ls`: saved-session count unchanged (12 before and after).
- Two simultaneous short cold pipelines initially exposed a delayed-registration race. The handshake now carries the sampler invocation start time; a producer that started before the previous attachment ended cannot implicitly continue it. Re-running `scripts/check-cold-pipelines.py` passed: one new session, one chart, two distinct streams with two observations each.
- Native startup exposed two additional issues: automatic SwiftUI window restoration could bypass CLI startup semantics, and `open -gj` hid the launched app. PipePlot now owns restoration explicitly and launches without the hidden flag. The final cold launch produced a normal visible window for the new session.
- The installed sine sampler continued a group, collected both streams and stopped cleanly on Ctrl-C. No test producers were left running.
- Native screenshots verified the corrected shared ruler, line plots and frozen end-of-capture clock. A pointer selection snapped to now and displayed the shared statistics inspector; its left-edge button changed the selection to fixed-duration following. Cmd-Shift-D created/targeted a second chart. A stream rename sheet was cancelled without changing its name.
- Interactive validation stopped when the user noticed the menus. The complete drag/drop, multiwindow, forecast/guide and sleep/wake acceptance matrix remains unverified; automated tests and source implementation do not substitute for those checks.

## First-use feedback — 2026-10-30

Implemented the dated SPEC amendment: SI/IEC axis labels and postfix guide entry;
zero and guide-aware automatic bounds; editable/deletable labelled time guides;
stable guide and forecast managers; independent triangular selection-end tracking;
observed extrema and latest-value labels; relative time/value origins; Local/UTC;
session rename/trash controls; and newline-delimited `pp --event` capture.
Horizontal-guide alarms evaluate accepted raw samples with directional hysteresis
and cooldown, then request ordinary macOS notification delivery. Enable an alarm
to request notification permission. Incoming events remain external captured facts;
manual guide additions and deletions are undoable.

Automated regression suite: 63 XCTest cases pass (50 core, 8 transport, 5 app).
Coverage includes guide command invalidation and undo/redo, event-only history and
saved display preferences, event validation/rollback, numeric parsing, extrema,
and crossing direction/deadband/cooldown. New native gesture rendering, menu
stability and delivered notification banners have not been manually verified.
Desktop interaction remains paused following the user's report of menus opening.
