# Visible concurrent capture benchmark

This opt-in workload opens an isolated AppKit window containing the production `SessionWindow` and Canvas charts. It compares one chart against three charts with every chart inside the window. Each chart has one stream, 6,000 history rows over one minute, and two adjacent injected spikes. A fixed 20-second selection includes both spikes. During capture, the test alternates three pan and three zoom actions through the same model methods used by the navigation menu. The viewport retains the live edge throughout.

Each chart has an independent Unix socket producer. Each producer sends 80 bursts of eight rows with a 50 ms interval between burst starts, awaiting the production acknowledgement for each row. After capture, the test checks all 6,640 stored values per stream, both spikes in the reduced display data, both extrema in the raw selection statistics, and the unchanged selection.

## Reproduce

From a terminal on a Mac with a graphical session, allow room for a 1,000 × 1,300 point content area plus window chrome. Keep the window visible during the run. Use a fresh trace filename.

```sh
trace="$(mktemp -t pipeplot-visible)"
PIPEPLOT_ACCEPTANCE_TRACE="$trace" ./scripts/run-native-acceptance.sh \
  --filter testVisibleConcurrentCaptureResponsiveness
```

The test prints the process ID, the screen and window geometry, per-stream render match counts and a result for each chart count. It checks that the window fits on the screen and each chart's plot is fully visible. It uses a fresh temporary store and socket in each case. The trace file records the app's opt-in Canvas events.

Throughput divides all acknowledged rows by the elapsed wall-clock time from starting the producers to the final acknowledgement. Latency uses the shared monotonic clock and joins a socket send to the Canvas event for that exact stream and sample timestamp. A stream emits a render event when its newest displayed sample falls inside the plot. Refreshes coalesce many inputs, so the latency distribution covers observed matches and the benchmark reports how many rows matched. Canvas events identify renderer work before WindowServer presentation. Query counts include submitted background work during capture and the final render drain.

## Baseline on 4 November 2026

Apple M2 Pro, 12 CPU cores, 16 GiB RAM, macOS 27.2 (26B123), arm64 Debug native harness. The usable desktop was 2,560 × 1,410 points and the measured window frame was 1,000 × 1,384 points. Every 944 × 210 point chart overlay fit fully inside its AppKit visible rectangle in both runs. Early runs with shorter windows clipped the third plot and prompted the fixture height change. The table uses the two runs that verified full visibility.

| Visible charts | Run | Accepted rows | Rows/s | Exact Canvas matches | Median | p95 | Max | Submitted queries | Refresh ticks |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 640 | 161.70 | 13 (2.03%) | 49.5 ms | 357.6 ms | 357.6 ms | 26 | 7 |
| 1 | 2 | 640 | 161.69 | 12 (1.88%) | 48.0 ms | 347.7 ms | 347.7 ms | 26 | 8 |
| 3 | 1 | 1,920 | 483.95 | 38 (1.98%) | 75.4 ms | 423.8 ms | 427.9 ms | 87 | 8 |
| 3 | 2 | 1,920 | 484.31 | 39 (2.03%) | 75.7 ms | 383.1 ms | 387.8 ms | 84 | 9 |

Each chart rendered at least 11 of the matched live rows before its producer finished. The full 6,640-row sequence and both spikes per stream passed the raw, display and selection checks. The exact match fractions describe sampling by the display refresh. The p95 describes that observed subset, and rows per second describes this paced input.

For comparisons on the same machine and build configuration, investigate a repeated drop below 154 rows/s for one chart or 460 rows/s for three (about 95% of the slower run). Investigate a repeated p95 above 460 ms or 525 ms (the larger measured p95 plus two 50 ms producer intervals, rounded upward). Query reference limits are 28 or 93, respectively, allowing one additional display and one selection query per chart. These are diagnostic thresholds for this workload.

## Profile a regression

Repeat the benchmark to collect an unprofiled reference. In a separate run, attach Time Profiler to the XCTest process ID printed by `VISIBLE_CAPTURE`. When SwiftPM buffers test output, find the process with `pgrep -fl testVisibleConcurrentCaptureResponsiveness` and use the `xctest` process ID.

```sh
xcrun xctrace record --template 'Time Profiler' --attach "$pid" \
  --time-limit 30s --output .build/visible-capture.trace
```

Use `VISIBLE_BEGIN` and `VISIBLE_RESULT` to separate seeding, capture and final verification. Compare the main-thread Canvas and SwiftUI update stacks, the background query and SQLite stacks, and the ingestion workers. Correlate query counts and Canvas trace timestamps with each result before changing refresh cadence, reduction or caching.
