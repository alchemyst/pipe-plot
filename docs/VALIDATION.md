# Validation

Use `swift test` for the domain, parser, storage, and analysis checks. Build and install with the scripts documented in README.md. Run UI checks in a disposable session: saved sessions are retained when their windows close.

## End-to-end smoke checks

- With the app stopped, pipe `printf '1\n2\n3\n' | pp`. Check three retained observations, an ended connection, and one window.
- Pipe `printf '1 2\n3 4' | pp`. Check two streams and the unterminated final row.
- Repeat an unnamed pipeline without changing its target. Check continuation; then change targets away and back and check that a new group is created.
- Start concurrent slow producers, switch target windows, and check that their existing lines stay in place.
- Close one capturing window. Its CLI must fail promptly while other sessions continue collecting.
- Quit and manually reopen the app. Check open windows, target, guides, and settings restore, with previous producers disconnected.
- Launch by pipeline after quitting. Check the pipeline gets a fresh session rather than silently appending to a restored session.

## Interaction checks

- Create two charts. Change their units and Y limits. Move the final stream out of one, undo, and redo while input continues. Verify samples survive and annotations remain with the original chart.
- Create a chart, attach a producer, undo creation, then redo. Verify only the streams moved by undo return to that chart.
- Undo a guide edit, receive samples and register another producer, then redo. Acquisition must not clear edit redo.
- Select a range across multiple rows. Check count, sample-weighted mean, extrema, first/last and change against actual observations.
- Link selection end to now, then preserve its duration. Check silent periods, undo, and common timing across rows.
- Forecast to a horizontal guide. Check flat, negative, opposing and insufficient-data cases; moving the stream must not silently choose a different target.
- Drag guides and selection boundaries, cancel with Escape, and exercise text-field undo separately from session undo.
- Hover, pan and zoom rows with very different Y ranges. Check shared pixel alignment, nearest-observation timestamps, and navigation Back/Forward.

## Performance and failure checks

The spec's cold/warm latency and long-history resource goals are targets until measured. Record the device, build mode, stream count, sample rate and retained history alongside every result.

Measure cold and warm pipeline latency separately; inspect app and CLI RSS and idle CPU. Run long histories through the viewport reducer and compare exact selection statistics with raw data. Exercise disk-write failures, terminated IPC, an oversized line, NUL bytes, non-finite input, mixed-width rows, sleep/wake, and minimum-size windows.

Automated test results do not substitute for visual interaction, sleep/wake, or sustained resource measurements.

## Recorded checks — 2026-10-30

- `swift test -j 4`: 19 XCTest cases passed (15 core/storage/analysis and 4 socket transport cases).
- Release app build, ad-hoc signing and local installation succeeded on Apple Silicon with Swift 6.4 and macOS 27.0.1.
- Installed cold pipeline retained exactly three observations and reported EOF.
- Explicit named reattachment retained four observations on the same stream; two-column input retained an unterminated final row.
- Closing a capturing window made a quiet CLI exit nonzero promptly; other saved sessions remained available.
- `pp --test 2` produced two streams at approximately one-second intervals; Ctrl-C exited successfully with clean stdout and froze the session clock. `pp --test 0` failed clearly.
- Raw history over 50,010 observations produced exact count, mean, median and regression; reduced plotting retained range endpoints within its bounded output.
- Metadata migration preserves earlier sessions, and corrupt metadata fails instead of silently replacing the session index.

After unlocking the Mac, visual checks confirmed line rendering, axis labels, the now marker, and a drag-to-now selection labelled “End follows now” with updating statistics. A mouse-event delivery defect found during this check was fixed in `009266b`; the rebuilt installed app shows the crosshair and exact observation readouts without changing chart height compared with the empty readout state. Ending the demo froze the visible clock, selection and statistics; manually restarting restored that frozen state. Sustained interaction-latency, sleep/wake, disk-full and week-scale resource checks remain unmeasured; no performance budget is claimed.

## Audit follow-up — 2026-10-30

The implementation and evidence following the specification audit are tracked in
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md). The final suite passed 44
XCTest cases, and the release app/CLI were installed. The controlled simultaneous
cold-pipeline check is available as `scripts/check-cold-pipelines.py`; quit PipePlot
first, and expect it to create one retained test session. It caught a continuation
race that the earlier core-only concurrency tests did not cover.

Final native checks verified a visible cold-start window, ruler alignment,
snap-to-now selection, the shared inspector and the left-edge duration-follow
button. Further interactive checks were stopped after the user noticed menus
opening; do not report the entire manual acceptance matrix as passed.

## First-use feedback implementation — 2026-10-30

The serial full suite passes 63 XCTest cases: 50 core, 8 transport and 5 app.
The guide regression checks exercise model undo/redo and observable command
invalidation; they do not simulate Cmd-Z in a native window. Event tests cover
chunked/newline input, lifecycle, event-only history, persisted settings and failed
registration rollback. Crossing tests cover direction, hysteresis, cooldown,
repeated threshold values, and new-attachment baselines. Numeric and peak tests
exercise SI/IEC parsing and display helper behavior.

No native pointer operations were performed for this feedback pass. Notification
banners, triangle gestures, live sheet stability and visual label collisions need
manual acceptance. Existing physical sleep/wake and long-run limits still apply.
