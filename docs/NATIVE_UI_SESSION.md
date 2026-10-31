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
