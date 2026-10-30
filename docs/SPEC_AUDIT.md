# Specification audit — 2026-10-30

Follow-up implementation and current validation evidence: [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md). This file retains the original audit findings.

Audited application revision: `54c29f7`. Baseline: original `251e8f0:SPEC.md`, compared with current `SPEC.md` and the user's subsequent requests. **The implementation is not yet fully compliant.** Passing existing tests and the recent visual checks do not establish completion of the specification.

## Scope and evidence

The spec diff contains only the requested line default, session-clock stopping, snap/hover corrections and sine generator feedback. No unrelated requirement was removed from the spec. Preserving existing explicit mark settings is a compatibility interpretation of the new default.

This review distinguishes confirmed decisions from proposed refinements. Proposed items are gaps relative to the design, not newly settled requirements. Native Canvas rendering, SQLite/local IPC and rendering reduction are within implementation discretion. Source timestamps, periodicity analysis, remote sharing, notarisation and older macOS support remain excluded.

Evidence: source review of the core, UI, parser, transport, storage and tests; a fresh `swift test` run (19 XCTest cases passed); five isolated core reproductions below. Prior interactive/end-to-end observations are identified as recorded evidence in `VALIDATION.md`, not claimed as rerun during this audit. The CLI/transport review used a smaller subagent; the other review agents reached their usage limit, so the main agent reviewed core and UI directly. Production code and specification were not changed for this audit.

## Confirmed-contract defects

1. **Live ownership can be stolen by implicit continuation.** Start plain A, end it, explicitly attach B to A's name, then start plain C. C reuses B's live stream. The continuation branch checks the old attachment's activity but not current stream ownership; explicit registration leaves the old continuation slot intact. This violates the no-hijacking requirement. Finishing either connection can also remove the other's owner entry. Reproduced. See `Sources/PipePlotCore/PipePlotStore.swift:134` and `:155`.
2. **Redo can hide an unrelated live producer.** Move A from chart 1 to chart 2, undo, attach B to chart 1, redo. Chart 1 becomes invisible with B still attached. Visibility snapshots overwrite the state needed by later arrivals. Reproduced; acceptance 20/21. See `PipePlotStore.swift:286`.
3. **Named attachment ignores chart recency.** Create charts 1 and 2, explicitly target chart 1, attach a missing name by session ID: it goes to chart 2. The implementation chooses the array's last chart, not the session's most recently used chart. Reproduced; acceptance 30/40. See `PipePlotStore.swift:108`.
4. **Rejected registration mutates layout and routing.** A new-session request with duplicate column names throws, but still creates a session and changes target. Creation/persistence precedes validation. Reproduced. The analogous new-chart path has the same ordering problem. Compound failures must leave model/history unchanged. See `PipePlotStore.swift:102` and `:125`.
5. **Cold `pp -c` creates an extra chart.** CLI bootstrap creates a session/chart before registration; `.newChart` then creates another chart. Acceptance 26 explicitly requires only the initial chart in this case. Cold `-s` similarly creates an extra session. Source-confirmed, not rerun against the installed app during this audit. See `Sources/PipePlotApp/PipePlotAppModel.swift:54`, `Sources/PipePlotTransport/UnixSocket.swift:249`, and `PipePlotStore.swift:104`.
6. **Gestures do not share a live preview across rows.** Pan/zoom domain, selection preview and time-guide preview are local `ChartRow` state. Other rows receive the committed result only after the gesture. The stack therefore has competing X mappings during navigation, contrary to coordinated interaction. Pan calculations also receive full row width while the plot excludes its Y gutter. See `Sources/PipePlotApp/SessionWindow.swift:136`–`:227`, `Sources/PipePlotApp/PlotCanvas.swift:57`.
7. **Multi-column reassociation is not usable from the UI.** The UI passes one source/destination pair; the core requires the entire active attachment group. A two-column repair cannot be completed through the offered action. Ended newly created groups cannot use the active-attachment-only repair either. Acceptance 29 is incomplete. See `PipePlotAppModel.swift:139`, `PipePlotStore.swift:181`–`:221`.
8. **The specified left-edge tracking button is missing.** Fixed-duration following exists in a selection menu, but the confirmed direct button on the linked selection's left edge is absent. See `SessionWindow.swift:333`–`:371`, `PlotCanvas.swift:30`–`:60`; acceptance 33.

## Other implementation gaps and risks

- **Undo/splitting:** Move to New Chart creates a chart and moves the stream as two separate actions, changes the target, and can leave a partial operation on failure (`PipePlotAppModel.swift:132`). The proposed compound split/move contract calls for one step and preserved routing except source collapse.
- **Undo into a collapsed predecessor:** undoing chart creation appends streams to the predecessor without making it visible (`PipePlotStore.swift:272`). This is a source-level edge-case risk for acceptance 39; no dedicated reproduction was run.
- **Reassociation inverse:** the inactive-attachment inverse can remove a destination owner without checking whether a later producer owns it, and does not refresh destination aggregate metadata after remapping (`PipePlotStore.swift:310`–`:354`). Needs an adversarial regression test before claiming later-attachment safety.
- **Incomplete editing/lifecycle surface:** no chart reorder/delete/rename actions, no session deletion, no session-title editor despite a core rename method, and no recovery UI for retained collapsed-chart settings. Some are proposed features/deferred UI decisions, but their absence prevents the corresponding full acceptance scenarios from passing.
- **Stream presentation:** colour is chosen by position within a chart and marks are chart-wide. Moving a stream can change its colour and line/dot settings. This differs from the proposed preservation of stream style. Legend drag/drop is absent; menu movement exists.
- **Timeline/selection UI:** no pinned shared time ruler while scrolling; no independent stream inclusion controls; selection details are repeated inside rows rather than a stable inspector. Duration and first/last values are not shown in the selection statistics; mean is not identified as sample-weighted. The proposed WASD/F/Escape-clear keyboard interactions are missing.
- **Guide editing:** horizontal guides have exact-value/label controls; session time guides lack equivalent edit/delete/note controls in the menus. Vertical labels are not drawn and guide recolouring is absent. Edge dragging is not complemented by the full proposed keyboard/menu surface.
- **Forecast scope:** one forecast configuration per session, rather than the proposed multiple simultaneous forecasts. Auto Y extent is based on observations and can leave an out-of-range target/crossing outside the plotted Y domain. Extreme-horizon and persistence behaviour need dedicated checks; a valid calculated crossing alone does not verify useful rendering.
- **UI workload:** visible-data reduction and raw selection statistics run synchronously on the main actor. Reduction bounds output but scans selected raw history; statistics include median sorting and are requested from view evaluation. Hover/redraws can repeat this work. No measured fluidity/latency result supports the long-history requirement (`PipePlotAppModel.swift:165`–`:218`, `RangeQueries.swift:60`–`:131`).
- **Resource limits:** finished attachments remain retained; navigation history is uncapped. Undo itself is capped at 200 metadata actions and raw samples are disk-backed. Transport frames/parser input are bounded, but total clients and handshake waits lack limits/deadlines. Startup loads all saved metadata and queries each saved stream's bounds/count before serving the first pipeline.
- **Persistence failure atomicity:** SQLite sample writes and JSON metadata persistence are separate operations; mutation followed by a failed metadata write does not generally roll back model/history. Startup storage failure uses `fatalError`. Disk-full/fault handling remains unverified; do not infer durability guarantees from ordinary restart tests.
- **Routing polish:** new-session/chart operations refresh only the affected window immediately; other target indicators catch up on their timer. The menu's Cmd-Shift-D uses the last chart while the window action uses its selected chart. These need multiwindow shortcut/indicator checks.
- **Proposed CLI details:** groups created with `-c`/`-s` are not stored as subsequent plain-continuation candidates; repeated selection of the same target invalidates continuation. `-u` is stored but never initializes the displayed chart unit. Rejections before the first valid row are stderr-only, and the saved rejection count is not displayed. Cold listing/lookup can create a bootstrap session as a side effect.

## Reproduced core outcomes

Run from the repository root (uses isolated temporary stores, removed on exit):

```sh
swiftc -I Sources/CSQLite Sources/PipePlotCore/*.swift docs/audit/main.swift -o /tmp/pipeplot-audit-repro
/tmp/pipeplot-audit-repro
```

Observed at the audited revision:

```text
LIVE_OWNER_HIJACK true continued true
EXPLICIT_USES_LAST_NOT_MRU true
REDO_HIDES_LATER_PRODUCER true
REJECTED_REQUEST_CREATED_SESSION 1 CHANGED_TARGET true
UNIT_HINT_NOT_APPLIED true
```

These are diagnostic reproductions of defects, not passing acceptance assertions. The fifth concerns a proposed convenience rather than a confirmed requirement.

## Acceptance scenario coverage

“Covered” below means evidence for the stated narrow case, not blanket certification. “Partial” means a known missing part or only a subset exercised. “Unverified” means no adequate recorded test. Scenario numbers refer to `SPEC.md`.

| # | Assessment | Evidence or remaining gap |
|---|---|---|
| 1 | Covered, recorded | Installed cold three-row pipeline retained all rows and EOF. |
| 2 | Partial | Core routing exists; cross-window indicators and shortcut selection need checking. |
| 3 | Unverified end to end | Concurrent socket tests do not prove simultaneous cold application launch. |
| 4 | Partial | Sparse point/quiet clock checked; exact two-minute scenario not recorded. |
| 5 | Unverified | No controlled hour-long paused-view resource/stability run. |
| 6 | Covered, automated | Disk history and >50,000-row raw queries; viewport does not delete data. |
| 7 | Partial | Independent chart switches exist; full live hide/show exercise not recorded. |
| 8 | Partial | Numeric guide editing exists; zero/resize/navigation matrix not fully exercised. |
| 9 | Substantial automated coverage | Parser split/final/NUL/oversize/width cases; not every numerical/visual edge tested. |
| 10 | Partial | EOF, quiet window close and transport failures checked; disk failure/distinct states incomplete. |
| 11 | Unverified | Sleep/wake and minimum-window live input. |
| 12 | Covered calculations; UI incomplete | Raw statistics regression passes; displayed fields missing. |
| 13 | Partial | Restart retention recorded; explicit saved-session deletion absent. |
| 14 | Partial | Move/collapse implemented; split is two undo steps, style changes. |
| 15 | Fails full interaction | Shared committed domain/hover; gesture previews are row-local. |
| 16 | Partial | Committed time guides span rows; reorder/remove UI and shared preview missing. |
| 17 | Unverified/risk | Main-thread history work; no latency/CPU benchmark. |
| 18 | Partial | Chart-owned settings retained; collapsed settings recovery UI absent. |
| 19 | Partial | Preview/commit/cancel paths exist; full visual undo/cancel exercise not recorded. |
| 20 | Fails adversarial replay | Redo can hide a later producer. |
| 21 | Fails | Reproduced later-producer visibility loss despite retained redo. |
| 22 | Partial | Per-session stacks/text undo paths exist; multiwindow complete exercise absent. |
| 23 | Unverified architecture | Analysis is synchronous; asynchronous cancellation race not exercised. |
| 24 | Partial | Metadata-only capped undo; reversible removal absent, other history/resource growth unbounded. |
| 25 | Partial | Target routing implemented; duplicate shortcut/current-chart discrepancy. |
| 26 | Fails cold path | Bootstrap causes an extra chart; rejected creation is not atomic. |
| 27 | Covered, automated/recorded | Shared timestamps, two columns, width rejection and final row. |
| 28 | Partial | Basic continuation passes; mixed explicit/implicit attachment can steal a live stream. |
| 29 | Fails UI repair | Core group reassociation exists; UI sends only one column. |
| 30 | Fails named missing-line case | Last chart used instead of most recently used chart. |
| 31 | Partial | Stable small IDs persist; session rename/reorder UI absent. |
| 32 | Implemented, partially tested | Rolling span logic and receipt timestamps; full timed transition not recorded. |
| 33 | Partial | Snap/end-follow visually checked; left-edge button and shared drag preview missing. |
| 34 | Partial | Duration semantics/raw queries exist; sustained linked-selection workload unmeasured. |
| 35 | Partial | Fit/forecast paths exist; full linked/fixed rendering and persistence exercise absent. |
| 36 | Partial | Degenerate fit checks/reference handling exist; full guide lifecycle/undo visuals unverified. |
| 37 | Partial | Semantic modes and navigation histories exist; complete interaction sequence not recorded. |
| 38 | Partial | Quiet-session close checked; cross-window immediate target fallback not fully checked. |
| 39 | Partial | Basic populated-chart undo/redo test passes; collapsed predecessor edge remains. |
| 40 | Partial | Manual restore and fresh plain pipeline recorded; cold option paths and named MRU fail. |

## Requested changes

- Lines on/dots off: implemented and tested for new charts; saved explicit settings preserved.
- Snap selection end to now: implementation corrected and visually checked in the preceding validation; coordinated preview across rows is still incomplete.
- Stable hover height: reserved readout space and mouse-event fix; previous visual checks recorded stable height.
- Stop time when last pipe breaks: core test plus terminal-side interrupt/restore checks recorded. Silent connected streams keep advancing.
- `pp --test [count]`: implemented, normal routing, approximately one row/second, two-column and Ctrl-C checks recorded.

## Recommended correction order

First fix ownership, transactional registration and replay conflict handling with regression tests. Next fix cold launch and MRU routing. Then implement session-wide gesture previews, group repair and the missing confirmed selection affordance. Address the remaining proposed UI choices explicitly rather than silently claiming completion. Finally run the missing multiwindow, failure, sleep/wake and controlled long-history performance scenarios. Existing successful checks should remain evidence, but must not be presented as full spec acceptance.
