# Native UI session — 2026-10-31

Release builds installed in `~/Applications/PipePlot.app` with the matching `~/.local/bin/pp`. Checks use fresh test sessions; existing captured sessions are retained.

## #16 — menus

Before the change, the original SwiftUI stream menu opened during `pp --test 2`, but clicking Color did not retain a visible submenu while live chart/clock updates continued. This reproduces the reported symptom; it does not isolate whether sample, clock, or hover invalidation was its sole cause.

Chart actions, stream actions/colors, guide creation/colors, selection boundaries, stream inclusion and forecast controls now materialize native NSMenu trees once per opening. View updates replace only the builder for the next opening. They cannot rebuild an already tracked menu. Capture and display refresh remain active. Stream secondary-click actions use the same snapshot policy.

Native observation: Color remained open and selected through at least ten seconds of live sample arrivals and advancing Now labels, then Color 7 could be activated. Keyboard navigation/activation was also exercised. Broader menu checks are recorded below as the associated controls are exercised.

Final menu build: secondary-click opened stream actions. With the menu open from 12:23:18 through 12:23:33, Down selected Rename, Up wrapped to Color, Right opened its submenu, Down twice selected Color 3, and Return activated it. Now advanced throughout. `swift test` passed (native window measurement opt-in skipped); release build/install passed.

## #6 — exact forecast targets

Selection → Forecast offers a flat Create target entry for each included stream, even with no chart guides. The sheet captures the stream and training selection when opened, validates finite postfix quantities, and creates the guide and forecast in one persisted metadata transaction/undo action.

Native release check, Session 24: dragged a 15-second fixed training interval; with no guides, opened Create target for Line 1. NaN left Create disabled; `10 Gi` and label `Native target` enabled it. Creation showed a forecast and preserved the training interval and raw statistics. The very large target legitimately extended the forecast horizon into the far future. Cmd-Z removed the forecast. A subsequent menu-bar inspection hit stale accessibility IDs in the automation bridge; full replay correctness is established by the targeted test rather than claimed from that failed interaction.

`ForecastTargetTests.testAtomicTargetValidationUndoAndCapture` passed: invalid input makes no mutation; target/forecast identities and training selection survive persistence and one-action undo/redo; later observations remain intact. Debug and release build/install passed.

## #9 — per-stream layout removal

Hide from Layout removes a stream's legend, marks, value labels, hover readout and forecast visuals, while retaining its chart ownership, data, capture and analysis configuration. Chart actions → Restore Hidden Stream restores it. Hiding the last stream retains the chart with an explicit restore instruction and keeps its Target unchanged. Whole-chart hiding remains separate. Turning both marks off is identified as Marks off; annotations remain until Hide from Layout is chosen.

Native release check, Session 26: hid Line 1 and Line 2 during `pp --test 2`, saw the all-hidden message, restored Line 1 through the nested chart menu, then Cmd-Z hid it and Cmd-Shift-Z restored it. Now advanced throughout (12:29:13–12:29:51). The restored plot includes samples captured during hiding.

`StreamLayoutTests.testHiddenLastStreamKeepsCaptureStylePersistenceAndReplay` passed, including legacy decoding, persistence, last-stream target/row retention, style and samples across undo/redo. Debug/release build and install passed.

## #8 — insertion and merge feedback (pointer acceptance outstanding)

Whole chart rows now accept merge drops with a highlighted outline and destination label. Separators before/between/after rows accept insertion drops with a New chart here preview; Add Chart remains a destination. Invalid/cancelled drops clear the preview. Stream menus retain Move to Chart/New Chart and now offer Insert as New Chart Before. The store accepts a before anchor and correctly resolves the source after inserting before it.

Native Session 32: Insert as New Chart Before → Chart 1 placed Line 1 in a new Chart 2 above Chart 1, retained live input in both, and Cmd-Z/Cmd-Shift-Z removed/restored the entire row move in one action. The targeted insertion regression passed, including source collapse, chart-owned unit/guide retention and later samples through replay.

Pointer limitation: repeated computer-use drags did not yield an accepted native drop. A temporary native grip diagnostic received down/drag events, but the native drag session did not finish until another click and ended with operation 0. This does not establish whether the bridge or application drop handling is responsible. The diagnostic grip and all instrumentation were removed; the existing SwiftUI stream drag source is retained. Hover preview, successful pointer merge/insertion and pointer cancellation therefore remain unverified. **Do not close #8 on this evidence.**

## #3 — loop brace and time locators

A shared ruler now carries a loop-style interval brace with duration, >/< endpoint triangles, and separate time-locator flags. Flags occupy two non-overlapping label lanes; crowded overflow retains stems and remains available in Manage Guides. Now is orange; hover is dashed; interval markers use the accent color; locators retain guide colors. The labelled flag itself and stem open an exact time/label editor. Ruler and chart endpoints share the same independent tracking-toggle implementation.

Native release Session 33: dragging a plot selection showed an 11.3-second brace aligned with the chart interval. F fitted the viewport. Double-clicking the left ruler triangle changed Fixed interval → Start follows end; double-clicking the right changed it to Fixed duration follows now, retaining 11.3 seconds as the live bounds advanced. Cmd-Z restored Start follows end. Double-clicking ruler background added a locator; its editor accepted Workload started, visible in both the flag and chart guide. Three nearby locators used two flag lanes and an overflow stem; a second chart retained the shared time geometry while the stack scrolled. After app quit/manual reopen the guides and two-row layout remained, with producers disconnected. In the final build, clicking the text of a flag (away from its stem) opened the precise editor.

The new presentation preserves the existing chart drag/snap implementation. Guide-drag replay could not be established through the same bridge limitations noted under #8; it is not claimed as passed here. The native text-field Undo check exposed a separate command-enablement problem after relaunch; tracked in the #14 follow-up below. Package tests (88 total, one opt-in measurement skipped) and release build/install passed before the final hover/hit-region adjustment; final full checks follow below.

## #14 — native acceptance follow-up

Hardware: M2 Pro MacBook Pro, 12 cores, 16 GB, macOS 27.2 (26B123). Native interactions used installed release builds; package and window-harness tests used debug builds. Test sessions created during this work are retained; only the new acceptance session 34 was temporarily trashed and then restored.

Two concrete defects found during acceptance were fixed:

- After a manual relaunch with no semantic edit history, native single-key text entry could not be undone in a locator sheet. Commands were not observing native field-editor/Undo changes. Commands now invalidate on text editing, focus and Undo notifications and resolve either the text view or a text field's current editor. Native retest: `xWorkload started` → Cmd-Z → `Workload started` → Cmd-Shift-Z → `xWorkload started`; Cancel discarded the test character without editing the guide.
- A cold finite pipeline failed with `pp: Unix socket connect failed: Connection refused`. The app was running at a saved-session picker; activating its window made `pp ls` succeed. Listener startup had depended on SwiftUI `onAppear`. Production models now start IPC before scene appearance and queue/deduplicate window requests until the scene installs its opener. The new startup regression verifies deferred requests, deduplication and retained producer data. After the fix, a cold three-row pipeline completed in 1.509 s and a warm new-session pipeline in 0.021 s, each with exactly three ended samples and clean stdout. These are **whole CLI completion times**, not measured first-visible-point latency. The simultaneous cold check passed again on the final installed build (session 38).

Additional observations:

- Session 34 held exactly one raw observation during a 120-second silent-but-connected interval, then accepted the second observation and EOF with exit 0 and empty stdout/stderr. Metadata first-point acknowledgement was observed after 0.440 s; the entire run took 121.022 s. Native Now advanced during silence and froze at 10:51:40 UTC after EOF. This does not measure display latency.
- Two newline text events appeared as labelled time guides without adding numeric streams. Session rename retained ID 34. Trash showed the retained-data/Restore state; Restore returned the same session and samples.
- Local → UTC moved the clock from 12:51 to 10:51 UTC. Selecting the 1.5 horizontal guide as value origin displayed raw values 1 and 2 at −0.5 and +0.5; selecting an event as time origin displayed signed elapsed times. Raw observations remained unchanged.
- Notification permission was initially off in System Settings, and enabling a guide alert produced the truthful native error “Notifications are not allowed for this application.” The user explicitly approved enabling PipePlot notifications; System Settings then showed Allow Notifications on, Desktop and Notification Centre checked, and Temporary alert style. Both-direction test streams crossed 1.5 as 1 → 2 → 1, with zero cooldown. The user first reported no banners, then confirmed the alerts were present in the tray and appeared to have been delivered silently. **Notification Centre delivery is user-observed; banner appearance and the reason for silent delivery are not established.** Global notification settings were not changed. Delivery API errors are now reported instead of discarded.
- Border-resize attempts did not change the window dimensions through the bridge. Physical sleep/wake was not performed. Pointer drag/drop and guide-drag acceptance remain limited as documented above.

### All 40 original scenarios: evidence and remaining work

“Automated” below means relevant assertions passed in this run, not that every clause of the scenario was exercised natively. No blanket acceptance certificate is claimed.

| # | Evidence in this session | Remaining / limit |
| --- | --- | --- |
| 1 | Cold finite pipeline: exactly three ended samples, clean CLI output after startup fix. | First-visible-point latency not instrumented. |
| 2 | Multiple native windows; Target and session IDs retained through edits/restoration. Core routing tests passed. | Full focus/Target producer matrix not replayed natively. |
| 3 | Simultaneous cold script passed before and after startup fix: one session/chart, two distinct streams, two samples each. Native ended legends checked. | No additional gap claimed. |
| 4 | Two-minute sparse input passed; one observation throughout silence; native Now advanced and froze after EOF. | Display latency not measured. |
| 5 | Capture survived paused historical selection in native sessions; visibility gating tests passed. | Hour-long paused-view soak and RAM budget outstanding. |
| 6 | Native histories over 60 seconds remained visible; storage/range tests passed. | Long-retention resource budget unmeasured. |
| 7 | Mark/style and layout-hiding regressions passed; native hide/restore/undo continued capture. | Full marks-only pointer matrix not repeated. |
| 8 | Exact guide entry, postfix parsing and relative-value origin checked; range/readout tests passed. | Full resize/pan/zoom guide matrix outstanding. |
| 9 | Parser, width, final-line, finite-value and transport regressions passed. | Not every malformed input rendered natively. |
| 10 | EOF, quit/restart, denied notifications and startup failure observed; persistence rollback and IPC regressions passed. | Physical disk-full fault not performed. |
| 11 | Native default window layout inspected. | Exact minimum-size resize and physical sleep/wake outstanding. |
| 12 | Raw-statistics/range tests passed; native interval cards retained their statistics through target creation. | No new gap established. |
| 13 | Native rename, Trash/Restore and manual relaunch checked. Metadata persistence tests passed. | No irreversible cleanup added. |
| 14 | Native Cmd-Shift-D created a row; menu insertion and single-step undo/redo checked. | Pointer merge/split/drop acceptance remains #8. |
| 15 | Shared ruler/selection/locator alignment visually checked; raw nearest/range tests passed. | Full irregular-input hover/pan/zoom matrix outstanding. |
| 16 | Shared locators and two-row stack inspected; event guides persisted through relaunch. | Full reorder/merge/remove/scroll matrix limited by pointer bridge. |
| 17 | Visible/hidden native query counts measured (see window report). | Long-history interaction latency and resource budgets outstanding. |
| 18 | Core move tests preserve chart-owned settings/guides; insertion regression checks annotations and style. | Full native annotated cross-chart move matrix outstanding. |
| 19 | Guide/readout/replay tests passed; direct locator editing worked. | Pointer guide-drag/Escape/replay not established. |
| 20 | Last-stream insertion regression passed with later capture, source collapse and atomic undo/redo. | Native annotated last-stream pointer move outstanding. |
| 21 | Core metadata/replay and background analysis tests passed. | Full native redo-across-acquisition/navigation sequence outstanding. |
| 22 | Native semantic Cmd-Z and local text Undo/Redo checked after command fix. | Two-window independent history matrix not fully replayed. |
| 23 | Background analysis undo/redo regressions passed. | Not repeated with native pointer timing. |
| 24 | Metadata-only history/continuation pruning and reversible stream visibility tests passed. | Large-capture undo memory measurement outstanding. |
| 25 | Native Target controls and Cmd-Shift-D used; routing tests passed. | Full terminal/focus combination matrix not replayed. |
| 26 | Atomic chart registration/core concurrency tests passed. | Repeated live concurrent create-chart UI stress not performed. |
| 27 | Shared-row width/parser/storage tests passed; live two-column producers used throughout. | No new gap established. |
| 28 | Continuation/ownership tests passed. | Native repeated interrupt/rerun legend/segment inspection not fully repeated. |
| 29 | Group reassociation/replay and live-destination rejection tests passed. | Native reassociation sheet mapping/undo not exercised end-to-end. |
| 30 | Target epoch, MRU and explicit registration tests passed. Explicit session 34 used for events and alert producers. | Full native target switching sequence not repeated. |
| 31 | Native rename/Trash/Restore retained ID 34; listing and restoration tests passed. | No new gap established. |
| 32 | Growing silent-live domain observed; raw receipt-timing tests passed. | Native 15-minute rolling transition not timed. |
| 33 | Native endpoint toggles and fixed-duration following checked; session clock advanced during silence. | Native drag-to-now gesture remains limited. |
| 34 | Linked bounds retained 11.3-second duration natively; relevant model tests passed. | Extended statistics/refit workload remains #13 and soak work. |
| 35 | Native forecast target flow checked; training-range and background-fit tests passed. | Full linked/fixed live multirow forecast timing matrix outstanding. |
| 36 | Analytic regression/status tests passed; native exact target creation and Undo worked. | Full native edit/delete/move recovery matrix outstanding. |
| 37 | Native independent endpoint mode changes and meaningful Undo checked; preference/navigation regression passed. | Complete native Back/Forward plus mode-Undo sequence not replayed. |
| 38 | Native test windows were quit/closed during this session; core close/target/capture semantics passed. | Full native simultaneous-session close/fallback matrix outstanding. |
| 39 | Created-chart replay regression passed; new before-source insertion undo/redo checked natively. | Native attach-many-columns plus unrelated-later-lines scenario not fully replayed. |
| 40 | Manual reopen restored session 33's guides/layout with disconnected producers. Fresh cold pipelines created new sessions after readiness fix. | First-visible-point latency remains unmeasured. |

Final checks: release build, signing and local install passed. Final `swift test` executed 89 tests with zero failures (one opt-in native window measurement skipped); the earlier opt-in full run passed all 88 then-existing tests, including that native measurement. All eight independent transport regressions passed. Final simultaneous cold pipelines passed after the readiness and notification-error changes.

**#14 stays open** for the explicit outstanding native/failure/resource work above, including actual banners, physical sleep/wake, exact minimum size, hour-long paused capture and week-scale resource measurements. #8 also stays open for pointer drop/preview/cancellation acceptance. #13 and #19 are numerical/performance work outside this unlocked-desktop implementation session; #15 remains the umbrella audit.
