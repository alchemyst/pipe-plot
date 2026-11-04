# New-ticket implementation sequence

The open GitHub backlog inspected on 2026-11-04 consists of #36–#45.

| Order | Ticket | Reason |
| --- | --- | --- |
| 1 | #38 CLI contract | Establish isolated subprocess routing and error assertions. |
| 2 | #37 waiting-input diagnostics | Extend the tested CLI behavior without changing healthy capture. |
| 3 | #41 malformed stdin | Reuse the subprocess fixture to verify recovery across byte boundaries. |
| 4 | #43 sparse signed statistics | Establish raw-observation and selection-boundary expectations. |
| 5 | #36 raw CSV export | Build snapshot export against those raw-data semantics. |
| 6 | #39 persistent chart bounds | Establish separation between navigation and chart configuration. |
| 7 | #42 minimum geometry | Protect that state through collapsed rendering geometry. |
| 8 | #45 sparse presentation latency | Correlate the intended stream and persisted rows in an isolated app. |
| 9 | #40 concurrent visible workload | Measure the verified renderer and capture path with explicit evidence boundaries. |
| 10 | #44 discrete-state lane | Record the design decision, then evaluate an opt-in prototype against the preceding interaction invariants. |

The CLI, raw-data, and viewport tracks can proceed independently; each track retains its internal order. Ticket commits remain separate. Existing uncommitted release packaging, installation UI, and transport-discovery changes are preserved outside ticket commits.

Validation distinguishes raw-store and model tests, subprocess contracts, hosted visible-window drawing, and actual native interaction. A Canvas trace is a drawing-pass observation, not physical display scanout. Experimental state lanes do not imply a production rendering migration.

## Results

- #38, #37, #41: isolated macOS subprocess contracts cover numeric/event routing, CLI usage errors, waiting input, and recovery across malformed byte/row boundaries. Ten contract tests pass. A 32 MiB malformed row grows child RSS by less than 8 MiB and contributes no stored samples.
- #43: signed sparse selection statistics match hand calculations, including empty series, wider viewports, display reduction and database reopen.
- #36: chart and explicit-selection export stream raw observations from a consistent SQLite snapshot. The CSV columns are `receipt_timestamp` (Unix seconds), `stream_id`, `name`, and `value`; bounds are inclusive and ordering is stream UUID, timestamp, then sequence. Staging and atomic replacement protect existing destinations. Five core tests cover quoting, concurrent capture, cancellation, failure and protection of active capture files. Native chart and selection Save actions each produced exactly the 30 Pressure observations in the isolated SQLite fixture. Native cancellation of a running progress sheet was not exercised on this short fixture.
- #39, #42: see [native viewport and resize evidence](VIEWPORT_ACCEPTANCE.md), backed by model, layout and responder regressions.
- #45: see [isolated sparse-capture results](ISSUE_45_SPARSE_CAPTURE.md), including process-cold/warm timings, 120 seconds of silence, a competing chart and exact persisted values after EOF.
- #44: see the [design decision and native prototype evaluation](research/STATE_LANE_44.md). The experiment remains opt-in and separate from production; spoken VoiceOver output and production density policies remain outside the completed prototype evaluation.
- #40: the [visible capture benchmark](VISIBLE_CAPTURE_BENCHMARK.md) records two runs with all charts fully onscreen, independent socket producers, active selection and pan/zoom. It reports matched input-to-Canvas latency separately from physical presentation, checks every stored value and spike, and derives diagnostic budgets from the local baseline.

## Integrated validation

- All 117 Swift package tests passed (91 core, 12 transport, 14 CLI), and the independent transport regression passed its 12 tests.
- The standalone native harness passed 84 selected tests: 79 executed and five existing/opt-in tests skipped. Its app-bundle-only `StreamDropTests.testDragTypeCanBeResolvedByDropDestinations` check was validated separately against the built app's exported `com.cactusdynamics.pipeplot.stream` declaration and `public.data` conformance. In the initial full harness run, the UTI resolution assertions passed and only its `Bundle.main` plist lookup failed because the standalone harness is not the app bundle.
- Swift 6 strict-concurrency/warnings-as-errors package compilation and Xcode app/test build-for-testing passed. `swift-format` strict lint, `git diff --check`, and Python syntax compilation passed.
- The normal `just check` entry point passed the package phase, but its Xcode hosted process blocked in dyld before Swift/XCTest entry. The process was stopped without touching the user's installed app. A bounded copied-products retry under `/tmp` started XCTest but stalled in the existing native inspector text-editor test; the same test passed in the standalone native harness. No hosted-suite success is claimed.
