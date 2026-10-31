# Feature completion audit — 2026-10-31

GitHub tracking issue: [Full coverage audit #15](https://github.com/alchemyst/pipe-plot/issues/15).

## Scope and method

Audit date: **2026-10-31**. Code basis: local revision `d5f70b28ff3a54cf65ae69b20c3c95915199834e`. Compared the original `SPEC.md`, the five earlier implementation changes, and **all 23 bullets in the user's original first-use message**, recovered from this chat's history. The later implementation amendment/completion reports were not treated as proof of working behavior.

The repository was newly created and contained no existing issues. Source paths in the child tickets refer to the local checkout, not yet-hosted source links. No application code was changed during this audit.

**13 implementation/completion tickets** are below; [#14](https://github.com/alchemyst/pipe-plot/issues/14) separately tracks acceptance evidence. “Present” below means a reachable implementation was found, not a claim that every native scenario was retested today. Previously reported failures in `docs/SPEC_AUDIT.md` refer to an old revision and were not blindly refiled.

## Implementation backlog

- [ ] [#1](https://github.com/alchemyst/pipe-plot/issues/1) — Make local peak and trough callouts appear for smooth signals
- [ ] [#2](https://github.com/alchemyst/pipe-plot/issues/2) — Complete right-side latest-value labels when chart space is available
- [ ] [#3](https://github.com/alchemyst/pipe-plot/issues/3) — Finish Ableton-inspired loop and time-locator presentation
- [ ] [#4](https://github.com/alchemyst/pipe-plot/issues/4) — Show exact guide coordinates during dragging
- [ ] [#5](https://github.com/alchemyst/pipe-plot/issues/5) — Keep out-of-range horizontal guides and their labels readable under auto-scale
- [ ] [#6](https://github.com/alchemyst/pipe-plot/issues/6) — Create an exact-value forecast target from selection analysis
- [ ] [#7](https://github.com/alchemyst/pipe-plot/issues/7) — Keep each forecast's training interval visible independently of the current selection
- [ ] [#8](https://github.com/alchemyst/pipe-plot/issues/8) — Add chart merge and insertion feedback for stream drag-and-drop
- [ ] [#9](https://github.com/alchemyst/pipe-plot/issues/9) — Add reversible per-stream removal from the visible layout
- [ ] [#10](https://github.com/alchemyst/pipe-plot/issues/10) — Preserve per-stream mark overrides when changing chart units or axis settings
- [ ] [#11](https://github.com/alchemyst/pipe-plot/issues/11) — Separate timeline display preferences from viewport navigation and undo
- [ ] [#12](https://github.com/alchemyst/pipe-plot/issues/12) — Suspend unnecessary chart work for hidden and minimised windows
- [ ] [#13](https://github.com/alchemyst/pipe-plot/issues/13) — Avoid refitting live forecasts when selected sample membership is unchanged

- [ ] [#14](https://github.com/alchemyst/pipe-plot/issues/14) — Native, lifecycle and resource acceptance. This is validation work, explicitly distinguished from missing source implementation.

## Later numerical-analysis work

- [ ] [#19](https://github.com/alchemyst/pipe-plot/issues/19) — Add kernel-based derivative estimates and smoothing with explicit time resampling, bounded gap imputation and defined filter latency.

## First-use message: complete coverage

| ID | Original request | Current disposition / evidence |
|---|---|---|
| F01 | SI Y-axis prefixes and simple binary Ki/Mi/Gi/Ti option | Present: NumericText, SettingsAndCommands numeric-scale picker. Setting interaction fix [#10](https://github.com/alchemyst/pipe-plot/issues/10); visual checks [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F02 | Postfix guide entry such as 10 Gi | Present: NumericText.parse and guide editors. New in-flow forecast target entry remains [#6](https://github.com/alchemyst/pipe-plot/issues/6). |
| F03 | Keep zero on chart | Present: includeZero setting and auto Y range. Readable bounds/guide edges [#5](https://github.com/alchemyst/pipe-plot/issues/5). Fixed explicit limits remain deliberate. |
| F04 | Cmd-Z time guide and discoverable deletion | Present: model time-guide actions, command invalidation and Guide manager trash buttons. Native Cmd-Z/text focus acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F05 | Expand range for horizontal guides outside data, including zero | Partial: values enter range, but boundary labels can clip. [#5](https://github.com/alchemyst/pipe-plot/issues/5). |
| F06 | Forecast menu disappears during navigation | Nested hierarchy replaced by flat stream/guide entries. Native stability acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). Creating a missing target in the flow remains [#6](https://github.com/alchemyst/pipe-plot/issues/6). |
| F07 | Triangular endpoint markers; outline fixed / filled tracking; independent double-click modes; drag right to now | Core gestures and triangle rendering present; broader requested loop/locator presentation [#3](https://github.com/alchemyst/pipe-plot/issues/3), native gesture acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F08 | Local peak/minimum numeric indicators | Partial with reproduced smooth-signal suppression: [#1](https://github.com/alchemyst/pipe-plot/issues/1). |
| F09 | pp --event, including newline streaming | Present: EventInputParser, IPC event mode, event-only attachment/store and CLI. Retains text as time guides, no numeric streams. Native streaming acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F10 | Text labels at top of vertical guides | Present: top guide badges in PlotCanvas. Locator presentation [#3](https://github.com/alchemyst/pipe-plot/issues/3) and crowded-label acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F11 | Delete old sessions | Present: reversible Trash/Recently Deleted/restore. Irreversible cleanup was deferred by original spec; not silently added. |
| F12 | Name sessions | Present: Rename Session UI and undoable store action. |
| F13 | Double-click background adds vertical guide | Present in PlotGestures and model callbacks; native acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F14 | X offset from chosen vertical guide | Present but preference/navigation interaction incomplete: [#11](https://github.com/alchemyst/pipe-plot/issues/11). |
| F15 | Y offset from chosen horizontal guide | Present in AxisSettings/PlotCanvas. Preserve stream marks while editing it: [#10](https://github.com/alchemyst/pipe-plot/issues/10). |
| F16 | Desktop alerts on horizontal crossings; rising/falling/both; chatter correction | Present: GuideCrossings detector, GuideAlert settings, permission request and native notification delivery. Actual banners and permission states remain [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F17 | Single background click clears highlight | Present in PlotGestures; native click versus double-click/drag acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| F18 | Rename Target sink to Target | Present in chart control; historical wording in spec is not a missing UI feature. |
| F19 | Clock icon for Follow Now | Present in timeline controls. |
| F20 | Right-side latest-value labels with shortening/name when space exists | Partial and user-reported absent: [#2](https://github.com/alchemyst/pipe-plot/issues/2). |
| F21 | Bottom local/UTC switcher | Present in bottom time options; navigation interaction [#11](https://github.com/alchemyst/pipe-plot/issues/11). |
| F22 | Ableton-inspired time locators and loop selection, preserving double-click tracking | Partially implemented as bottom triangles/shading/badges: [#3](https://github.com/alchemyst/pipe-plot/issues/3). |
| F23 | Discoverable, stable guide editing instead of cycling nested dropdowns | Present: flat manager sheet with Edit/Delete and direct guide selection. Native sheet/menu stability remains [#14](https://github.com/alchemyst/pipe-plot/issues/14); drag feedback [#4](https://github.com/alchemyst/pipe-plot/issues/4). |

## Earlier chat changes: complete coverage

| Request | Disposition |
|---|---|
| Lines default instead of dots | Present in new chart defaults; saved explicit settings retained. [#10](https://github.com/alchemyst/pipe-plot/issues/10) protects independent stream choices. |
| Fix selection snap to current time | Present screen-coordinate/session-clock gesture path; [#14](https://github.com/alchemyst/pipe-plot/issues/14) native acceptance. |
| Stop hover readout from changing chart height | Present reserved readout space; [#14](https://github.com/alchemyst/pipe-plot/issues/14) native acceptance. |
| Freeze session time on last terminal-side pipe break | Present attachment finish/final-producer clock handling; silent connected producers remain live. |
| pp --test and pp --test 2 at one row per second | Present in CLI normal routing, one/two-column synthetic sine producer. |

## Original specification: functional coverage

| Area | Source inspected | Disposition |
|---|---|---|
| Native app/CLI, pipeline-first launch, first-row preservation | pp/main.swift, IPC.swift, UnixSocket.swift, PipePlotAppModel.swift | Present; full cold/warm acceptance remains [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| Stable session IDs, chart-level Target, explicit naming, MRU fallback, concurrent registration | PipePlotStore.swift, PipePlotAppModel.swift | Present; no new ownership/MRU defect established. |
| Rerun continuation, explicit addressing, group reassociation, attachment segments | PipePlotStore.swift, SessionWindow.swift | Present, including group mapping and reversible history. |
| Finite numeric rows, irregular timestamps, width validation, malformed-input limits, EOF, stdout/stderr | InputParser.swift, pp/main.swift, IPC/transport | Present; no source-timestamp mode added. |
| Growing then rolling span, quiet-live clock, stopped clock, history navigation and sample age | PipePlotAppModel.swift, SessionWindow.swift | Present; long-run/sleep validation [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| Independent marks, chart units and auto/fixed scale, reconnection gaps | DomainModels.swift, PipePlotStore.swift, PlotCanvas.swift | Present with mark-state and auto-bound completion gaps [#10](https://github.com/alchemyst/pipe-plot/issues/10), [#5](https://github.com/alchemyst/pipe-plot/issues/5). |
| Stacked charts, stream moves, new rows, collapse, styling, hidden-chart restore | SessionWindow.swift, PipePlotStore.swift | Core present; drag previews/insertion [#8](https://github.com/alchemyst/pipe-plot/issues/8); reversible individual removal [#9](https://github.com/alchemyst/pipe-plot/issues/9). |
| Shared hover/ruler/time guides, per-stream real-sample offsets, synchronized domains | SessionWindow.swift, PlotCanvas.swift, RangeQueries.swift | Present. Nearest actual sample plus explicit time offset is the current policy; threshold refinement was open, not filed as missing. |
| Pan/zoom, pinch/scroll, WASD/F/Escape, Back/Forward, stable inspector | PlotGestures.swift, SessionWindow.swift, PipePlotAppModel.swift | Present; viewport history must preserve display preferences [#11](https://github.com/alchemyst/pipe-plot/issues/11). |
| Guide create/edit/recolour/delete, exact values, text notes via labels, undo | SessionWindow.swift, PipePlotStore.swift | Present; live coordinate feedback [#4](https://github.com/alchemyst/pipe-plot/issues/4) and loop/locator affordances [#3](https://github.com/alchemyst/pipe-plot/issues/3). |
| Raw selection count/duration/first/last/min/max/mean/change and stream inclusion | SelectionInspector, RangeQueries.swift | Present; no missing-statistics ticket. |
| Fixed/end-now/both-now/start-follows-end selection modes and one-action edits | DomainModels.swift, PlotGestures.swift, store actions | Present; native gesture/undo acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| OLS forecast, actual timestamps, status/detail/countdown, multiple horizons, missing-guide states | RangeQueries.swift, PipePlotAppModel.swift, PlotCanvas.swift | Core present; target creation [#6](https://github.com/alchemyst/pipe-plot/issues/6), visible training range [#7](https://github.com/alchemyst/pipe-plot/issues/7), membership-based refit cache [#13](https://github.com/alchemyst/pipe-plot/issues/13). |
| Semantic per-session undo, compound moves, preserving later producer samples, async analysis invalidation | PipePlotStore.swift, BackgroundQueries.swift, SettingsAndCommands.swift, tests | Present; time-reference configuration history [#11](https://github.com/alchemyst/pipe-plot/issues/11) and native text/drag acceptance [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| Local automatic saving, restart recovery, reversible session deletion, visible storage errors | SampleStore.swift, PipePlotStore.swift, app lifecycle | Present. Atomic snapshot rollback exists; stronger cross-file crash transactions were not an agreed feature. Failure/restart evidence [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| Bounded parser/transport/render working sets, raw-data retention, background analysis | InputParser/UnixSocket, SampleStore/RangeQueries, BackgroundQueries | Core present; hidden-window work [#12](https://github.com/alchemyst/pipe-plot/issues/12) and unnecessary refits [#13](https://github.com/alchemyst/pipe-plot/issues/13). Resource budgets still need measurement [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| EOF, close one session, app termination, IPC loss, startup ordering, sleep/wake, small windows | CLI/server, store and window lifecycle | Implemented paths present; remaining physical/native/failure scenarios [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| Local build/install on current Apple Silicon/macOS | Package.swift, scripts, justfile | Present; no public-distribution ticket. |

## Original numbered acceptance scenarios: all 40 accounted for

These are coverage classifications, not a fresh pass certificate. [#14](https://github.com/alchemyst/pipe-plot/issues/14) must record the final executable/manual evidence.

| Scenario | Coverage / remaining work |
|---|---|
| 1 | Cold finite pipeline: implemented, prior evidence; [#14](https://github.com/alchemyst/pipe-plot/issues/14) records current acceptance. |
| 2 | Multiwindow routing/focus/Target: implemented; [#14](https://github.com/alchemyst/pipe-plot/issues/14) native check. |
| 3 | Simultaneous cold producers: implemented and prior cold-script evidence; [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 4 | Sparse quiet connected producer: implemented; [#14](https://github.com/alchemyst/pipe-plot/issues/14) timing/quiet check. |
| 5 | Hour-long paused capture and bounded memory: [#12](https://github.com/alchemyst/pipe-plot/issues/12), [#13](https://github.com/alchemyst/pipe-plot/issues/13), [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 6 | Retained history beyond viewport: disk-backed implementation present. |
| 7 | Independent lines/dots and hidden state: [#9](https://github.com/alchemyst/pipe-plot/issues/9), [#10](https://github.com/alchemyst/pipe-plot/issues/10); capture continues. |
| 8 | Zero/limit guides and precise edits: [#4](https://github.com/alchemyst/pipe-plot/issues/4), [#5](https://github.com/alchemyst/pipe-plot/issues/5), [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 9 | Numeric/parser edge cases: implemented and test coverage present; [#14](https://github.com/alchemyst/pipe-plot/issues/14) visual edge cases. |
| 10 | EOF/close/termination/IPC/disk errors: implemented paths; [#14](https://github.com/alchemyst/pipe-plot/issues/14) fault acceptance. |
| 11 | Sleep/wake/minimum window: [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 12 | Raw selection statistics: RangeQueries implementation/tests present. |
| 13 | Saved names/guides/settings/deletion: implemented; [#11](https://github.com/alchemyst/pipe-plot/issues/11) preferences and [#14](https://github.com/alchemyst/pipe-plot/issues/14) restart acceptance. |
| 14 | Overlay/move/split/collapse/undo: core present; [#8](https://github.com/alchemyst/pipe-plot/issues/8) interaction, [#10](https://github.com/alchemyst/pipe-plot/issues/10) style. |
| 15 | Shared geometry, hover, zoom and irregular sample meaning: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 16 | Session guides across reorder/merge/remove/scroll: present; [#3](https://github.com/alchemyst/pipe-plot/issues/3)/[#14](https://github.com/alchemyst/pipe-plot/issues/14) marker acceptance. |
| 17 | Fluid long-history navigation and idle resource use: [#12](https://github.com/alchemyst/pipe-plot/issues/12), [#13](https://github.com/alchemyst/pipe-plot/issues/13), [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 18 | Chart-owned units/annotations across stream moves: present; [#10](https://github.com/alchemyst/pipe-plot/issues/10) protects styles. |
| 19 | Single-action guide drag/undo and Escape: present; [#4](https://github.com/alchemyst/pipe-plot/issues/4) feedback, [#14](https://github.com/alchemyst/pipe-plot/issues/14) native verification. |
| 20 | Move last stream and restore atomically during capture: implemented/tests; [#14](https://github.com/alchemyst/pipe-plot/issues/14) native check. |
| 21 | Preserve redo across new samples/producers and navigation: model support present; [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 22 | Independent session/text undo: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14) native multiwindow check. |
| 23 | Async analysis Undo/Redo without resurrected overlays: implementation and app regression present. |
| 24 | Bounded metadata-only undo and reversible removals: core present; individual removal [#9](https://github.com/alchemyst/pipe-plot/issues/9), workload [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 25 | Target selection and Cmd-Shift-D in active session: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 26 | Atomic new-chart registration and concurrent commands: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 27 | Multicolumn shared row timestamps and atomic width rejection: present. |
| 28 | Immediate rerun with retained line identities/breaks: present. |
| 29 | Concurrent groups and group-level reassociation/undo: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14) UI acceptance. |
| 30 | Target epochs and named MRU attachment: present. |
| 31 | Stable small IDs, rename and listing: present. |
| 32 | Growing/rolling history with receipt timestamps: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14) timed acceptance. |
| 33 | Now snap and fixed-duration follow across rows: present; [#3](https://github.com/alchemyst/pipe-plot/issues/3)/[#14](https://github.com/alchemyst/pipe-plot/issues/14) presentation. |
| 34 | Linked statistics without clock undo spam/drift: present; [#13](https://github.com/alchemyst/pipe-plot/issues/13) fitting workload, [#14](https://github.com/alchemyst/pipe-plot/issues/14) sustained run. |
| 35 | Linked/fixed forecast and shared future domain: present; [#6](https://github.com/alchemyst/pipe-plot/issues/6), [#7](https://github.com/alchemyst/pipe-plot/issues/7), [#13](https://github.com/alchemyst/pipe-plot/issues/13) completion. |
| 36 | Degenerate/past crossings, guide lifecycle and recoverable references: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14) UI lifecycle checks. |
| 37 | Undo selection links versus Back/Forward navigation: present; [#11](https://github.com/alchemyst/pipe-plot/issues/11) isolates preferences, [#14](https://github.com/alchemyst/pipe-plot/issues/14). |
| 38 | Close targeted session, preserve others, fallback/new pipeline: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14) native check. |
| 39 | Undo populated chart creation with capture and exact redo membership: present in model/tests. |
| 40 | Manual restore versus CLI fresh launch and explicit missing lines: present; [#14](https://github.com/alchemyst/pipe-plot/issues/14) records current acceptance. |

## Deliberately not filed as missing features

Source timestamps/historical imports, periodicity or richer forecasting, general CSV/JSON/XY input, remote hosting/sharing, older macOS/Intel, notarisation/public distribution, permanent trash cleanup, and a stronger crash-atomic storage architecture are deferred or excluded in the original spec. A new onboarding/tutorial product was not requested. Forecast sample count, training duration and slope already appear in the model status message.

## Evidence and limits

- Read actual user messages from chat history and current source, using independent UI/core audits.
- Reproduced PeakFinder smooth-sine suppression by compiling the current implementation in a disposable harness.
- Reviewed existing tests and recorded validation; did not rerun the full suite or drive the user's desktop.
- Earlier “implemented” reports were too broad to establish visible completion. Child issues state what exists, the precise gap, and testable acceptance criteria.

