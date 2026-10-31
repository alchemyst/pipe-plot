# Window visibility validation — 2026-10-31

Issue [#12](https://github.com/alchemyst/pipe-plot/issues/12).

Session windows observe AppKit occlusion, miniaturisation, focus, and app hide/unhide notifications. A visible background window remains active. Fully occluded, minimised, or app-hidden windows skip display timer refreshes and display/statistics/nearest/fit query submission. Their canvases, ruler, and selection inspector are suspended; chart row identity is retained so open editors survive. Uncommitted pointer gesture previews are cleared.

Capture, SQLite writes, and raw-row guide crossing evaluation remain independent of window visibility. Revealing refreshes the current stored snapshot in an animation-disabled transaction and preserves persisted timeline, selection, and chart targeting. Closing still follows the existing session close/disconnect path.

Already submitted background work can finish after suspension; it does not chain into more hidden-window fits. Each stream retains at most the existing last-result cache per query kind, rather than accumulating samples or replaying a backlog on reveal.

## Reproduction

On a logged-in macOS desktop:

```sh
PIPEPLOT_MEASURE_WINDOWS=1 swift test --filter WindowVisibilityTests
```

The opt-in test creates four native NSWindows hosting the actual SessionWindow SwiftUI view, runs AppKit's event loop, and waits for visibility transitions to settle. It compares four visible windows with one visible and three minimised windows, for idle and ingest cases. Each window has one stream. Ingest appends one row per session roughly every 50 ms through the normal store API. Display refreshes use the real shared 0.75-second timer. The idle streams remain connected with no new rows.

CPU is process CPU time from clock(), expressed as a percentage of one CPU core over each approximately four-second wall interval. Queries count background analysis submissions; refreshes count non-suspended timer/reveal refreshes. The test also exercises orderOut, app hide/unhide, deminiaturisation, and collection while hidden.

## Observed debug-build results

Apple Silicon, local macOS desktop, 2026-10-31; final full-suite run:

| Window state | Input | Wall seconds | CPU seconds | CPU % of one core | Queries | Refreshes | Rows per session |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Four visible | Idle | 4.034 | 0.1753 | 4.34 | 20 | 20 | 0 |
| Four visible | Ingest | 4.010 | 0.5903 | 14.72 | 24 | 24 | 68 |
| One visible, three minimised | Idle | 4.050 | 0.1752 | 4.33 | 6 | 6 | 0 |
| One visible, three minimised | Ingest | 4.030 | 0.5606 | 13.91 | 6 | 6 | 68 |

Display queries and refreshes scale down to the remaining visible window. CPU reduction is modest in this short run, especially idle; these measurements do not establish a general CPU or memory budget. The ingest CPU includes capture into all four sessions and SQLite persistence, which deliberately continue.

This harness bypasses IPC and disables delivered system notifications by using a temporary database. Existing transport and guide crossing tests cover those separate paths. It is not a week-long soak test or an end-to-end notification delivery test. Initial harness attempts without AppKit's event loop incorrectly left every test window occluded; those runs are excluded from the table.

Regression tests additionally verify zero hidden query submissions, deferred forecast fitting, current data after reveal, unchanged timeline/selection modes and chart target, and producer disconnection with retained samples on deliberate close.

Final checks: `PIPEPLOT_MEASURE_WINDOWS=1 swift test` passed all 85 package tests, `./scripts/test-transport.sh` passed all eight independent transport regressions, and `swift build -c release` passed.

## UI-session recheck — 2026-10-31

Rechecked after shared locator/brace and native command changes on an M2 Pro MacBook Pro (12 cores, 16 GB), macOS 27.2 (26B123), debug test build. `PIPEPLOT_MEASURE_WINDOWS=1 swift test` passed all 88 tests, including the four-window native measurement and hide/reveal/collection assertions.

| Window state | Input | Wall seconds | CPU seconds | CPU % of one core | Queries | Refreshes | Rows per session |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Four visible | Idle | 4.027 | 0.1803 | 4.48 | 20 | 20 | 0 |
| Four visible | Ingest | 4.053 | 0.5488 | 13.54 | 24 | 24 | 71 |
| One visible, three minimised | Idle | 4.044 | 0.1906 | 4.71 | 5 | 5 | 0 |
| One visible, three minimised | Ingest | 4.053 | 0.6642 | 16.39 | 6 | 6 | 67 |

The display-query/refresh gate still scales with visible windows. CPU was higher in the minimised ingest interval in this run, so these short measurements **do not establish a CPU improvement**. Capture/persistence continue in all windows. Other desktop work and a separate sparse IPC producer were active; this is not an isolated resource-budget benchmark. The native harness again verified orderOut, app hide/unhide, deminiaturisation and raw sample retention while hidden.
