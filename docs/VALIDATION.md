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

The initial release was visually inspected for line rendering, axis labels and the now marker. Final drag-to-now snapping and hover-height checks were blocked by the Mac being locked. The code paths are implemented, but these interactions still need a hands-on check. Sustained interaction-latency, sleep/wake, disk-full and week-scale resource checks remain unmeasured; no performance budget is claimed.
