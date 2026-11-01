# Smoothing and first derivatives

Issue [#19](https://github.com/alchemyst/pipe-plot/issues/19), implemented 2026-11-01.

Open a stream's Actions menu → **Smoothing and derivative…**. Apply adds separate
smoothed-value and first-derivative panels under its original chart. Edit or Remove
changes only derived analysis. Settings are saved with the stream, move with it,
and have one semantic Undo step. Hiding the stream/chart hides its derived panels.
The original samples, plot, hover readouts, selection statistics, forecasts and
crossing alerts remain raw. Derivative units are chart value units per second;
higher derivatives are not offered. The panels share the original time domain and
hover line, with independent value axes. They are display panels, not new producer
identities or destinations for capture, statistics, or forecasting.

## Resampling contract

- The initial suggestion is the median positive spacing among the first 129 raw
  observations, excluding spacings across attachment segments and duplicate times.
  It accounts for measured receipt cadence, including cumulative shell-loop drift.
  At least two distinct within-segment times are needed to apply through the UI.
- The user can override the interval. It is fixed until explicitly edited, not
  recalculated on each tick, rolling window, reconnect, or restart. The grid is
  anchored to the stream's earliest stored observation; viewport panning never
  rounds each timestamp or changes grid phase.
- Interpolation uses actual receipt timestamps. Between observations no further
  apart than Maximum observation gap, reconstruct grid values by linear
  interpolation. Intervals exceeding the gap limit restart the filter. Reconnect
  boundaries always restart it, even when observations are close in time. Legacy
  samples with no segment ID form one segment; no missing boundary is inferred.
- At a duplicate timestamp within a segment, the last observation in sequence
  order wins for derived analysis. Raw history retains every duplicate. The
  incremental processor holds one pending observation to resolve duplicates;
  `finish` consumes the final pending observation without padding a filter edge.
- Observed grid points only is a separate choice. Any grid point without an exact
  observed value breaks the filter window; with jitter, no result may be possible.
  Exact matching has a time tolerance of min(1 microsecond, interval × 1e-5) to
  accommodate floating-point Date precision, not to round away receipt jitter.
- Every output carries the number of interpolated grid values in its full filter
  support. The UI summarizes this provenance for displayed estimates. Linear
  interpolation attenuates fast changes and biases derivatives of curved signals,
  especially inside missing runs. A raw ramp remains linear; a reconstructed sine
  is not exact. This policy is reconstruction, not evidence of unobserved values.
- Intentional downsampling is rejected: the configured interval must be no larger
  than the suggested cadence. A recent 129-observation median more than 20% faster
  than the configured grid also suspends derived output with a downsampling error.
  Choose a finer interval in that case. Small cadence fluctuations are treated as
  receipt jitter; no irregular-signal antialiasing guarantee is made. Coarse-grid
  decimation requires a separately designed antialiasing stage and is unavailable.
- Limits: interval at least 1 ms; requested window 4–2048 intervals; maximum gap
  at least one interval, at most 10,000 intervals and at most seven days. These
  constrain numerical work; input remains receipt-timed and raw retention unchanged.

## Filtering and live edges

Both choices fit degree-three polynomials. Ordinary Savitzky–Golay has uniform
weights; the default weighted variant uses Hann-square weights
`cos(pi * i / (2 * (radius + 1)))^4`. Weighted orthogonal polynomials, with a second
orthogonalization pass, construct the kernels once. First-derivative coefficients
include the interval scale, giving value/second with the correct sign. Accelerate
`vDSP_vsaddD` removes the center value before `vDSP_dotprD` applies each kernel,
reducing cancellation for large constant offsets. The smoothed baseline is restored.
The two precomputed coefficient vectors form a replaceable kernel boundary.

The window is rounded to an odd number of points, with radius equal to the nearest
integer to `requestedWindow / (2 * interval)`, bounded to 2–1024. The sheet reports
the resulting exact window and half-window delay. Output timestamps identify the
**center**, not arrival time. Only full centered windows produce estimates: the
first and last radius points, plus the edges of each gap/reconnect, have no output.
There is no zero padding, extrapolation, provisional estimate or later revision.
A live producer additionally needs the next distinct observation to close the
pending duplicate group. Thus availability lags the center by half a window plus
up to one observed sampling interval; silence can extend that wait. An ended or
historical query flushes the pending input without inventing future grid values.

The live UI recomputes a bounded viewport query on its existing background queue,
not the main thread. It scans raw rows with context on both sides; it never filters
plot-reduced points. The processor itself supports incremental chunks with the
same outputs as batch input. FIR storage depends only on window size; display
storage retains first/last and extrema of both quantities, at most six points per
bucket (400 buckets by default). Run IDs prevent lines across removed gaps.
Hidden/minimized windows submit no derived queries. Undo/reassociation invalidates
cached results, and disabled configurations cannot reappear from a late query.

## Reproducible validation

Run `swift test --filter DerivedSeriesTests` and the Xcode app tests. Tests cover:

- Constants, rising/falling ramps, quadratic/cubic polynomials, sinusoidal sign,
  amplitude and time alignment, and a very large constant offset.
- 1.007-second loop drift with receipt jitter, duplicate last-wins, a short missing
  run, long gaps, reconnects, observed-only insufficiency, and chunk boundaries.
- Viewport query versus full-history estimates, bounded display reduction, persisted
  configuration, Undo/Redo after later input, and unchanged raw counts/statistics.
- Seeded filter comparison and measured interpolation bias. The weighted default
  is an evaluated choice, not a claim of universal superiority.

Seed 190019: 20,000 grid samples contain a 0.01-cycle/sample sine, interference at
0.31 and 0.43 cycles/sample with amplitudes 0.5 and 0.3, and uniform noise of
scale 0.1 (uniform range −0.05…0.05). Compare the common interior (centers 101…19899), with no padded edges:

| Quantity | Ordinary SG | Weighted SG |
| --- | ---: | ---: |
| Radius | 10 | 16 |
| −3 dB cutoff, cycles/sample (0.0001 resolution) | 0.0510 | 0.0522 |
| Smoothing RMSE | 0.0320853 | 0.00942788 |
| First-derivative RMSE | 0.00900877 | 0.00227100 |
| Centered delay, intervals | 10 | 16 |

The alternative has a 2.35% higher cutoff and a longer latency. This particular
interference-dominated example favors weighted SG; noise distributions and
bandwidth choices can change the comparison. Both methods omit unsupported edges.
The design is informed by Schmid, Rath and Diebold,
[Why and How Savitzky–Golay Filters Should Be Replaced](https://pmc.ncbi.nlm.nih.gov/articles/PMC9026279/)
and its [2023 correction](https://doi.org/10.1021/acsmeasuresciau.3c00017).
This implementation evaluates weighted SG; it does not implement the paper's
modified-sinc kernels or boundary extrapolation methods.

The resampling-bias case uses a 0.08 rad/s sine, cadence 1.003 s, deterministic
±0.06 s jitter, and one missing input every 37 observations. With the default
10-second weighted window, smoothing RMSE was 0.00050023 and derivative RMSE was
0.00010960 value/s. The ramp/drift test remains exact to Date precision; this
curved-signal case demonstrates the nonzero bias rather than assuming it away.

## Sustained engine benchmark

Run `scripts/benchmark-derived-series.sh [rows-per-stream]`. It compiles with `-O`,
generates ten streams with measured-time jitter and drift, consumes outputs without
retaining history, and reports `/usr/bin/time -l`. This isolates the numerical
engine, excluding SQLite, IPC, UI rendering and app memory.

Recorded on 2026-11-01, Mac14,9, 16 GiB, macOS 27.2:
120,961 observations per stream, five-second nominal spacing (seven simulated days),
101-point weighted windows. 1,209,610 inputs processed in 0.551 s (about 2.19 million
input rows/s); 1,208,680 estimates emitted. Ten processors retained 6,060 numeric
slots (48,480 bytes), including kernels and buffers. Maximum process RSS was
5,996,544 bytes. Simulated history is accelerated input, not a seven-day soak.
These measurements do not close the application-level acceptance work in #14.

## Final checks — 2026-11-01

- Package suite: 72 tests passed, zero failures.
- Xcode hosted app suite: 25 tests, zero failures, one opt-in resource test skipped.
  The standalone app-source harness also passed the same 25 tests with that skip.
- Eight independent transport regressions passed.
- Release app build and ad-hoc signing passed; `git diff --check` passed.
- A native NSHostingView render of the derived panels was inspected: the separate
  axes, units, kernel label, delayed-edge gaps and aligned hover line are legible.
  This is fixture rendering, not a claim of full manual live-stream UI acceptance.

An initial incremental hosted test launch stalled before app startup in dyld.
A clean host subsequently entered tests, but that diagnostic run was interrupted.
A later build failed in CopySwiftLibs with a missing-file error. The final unchanged
hosted invocation succeeded. The failed/interrupted attempts are not test passes.
The successful final command was:

```sh
xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/issue-19-xcode \
  ENABLE_DEBUG_DYLIB=NO test
```
