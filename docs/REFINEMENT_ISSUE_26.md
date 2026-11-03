# Swift refinement #26: per-session presentation ownership

`SessionModel` is a stable `@MainActor @Observable` object for each session ID. It owns the presentation snapshot, selected chart, navigation stacks, display activity, clock pulse, and forecast statuses. The application model retains these objects through refresh, window close/reopen, and trash/restore; it continues to coordinate session discovery, capture targets, window routing, domain operations, and the ingestion service. A lightweight `SessionListing` catalog changes only for picker metadata (title, open/deleted state, chart count, stream count), not each sample count.

`SessionWindow` and its chart rows read their own session object. A single selected-chart binding now serves tap selection, command insertion, and chart highlighting; the view's synchronization-only selection state and `onChange` bridge are gone. Snapshot and forecast assignments compare values before publishing. A stream-to-session index lets analysis entry points resolve their session without reading every presentation snapshot. Query execution and its shared revision remain in `BackgroundQueries` for issue #29.

## Two-session observation check

`SessionModelTests` prewarms a query for session B, then tracks B's snapshot selection, clock, selected chart, navigation availability, forecasts, `sessionNow`, and statistics entry point. A new sample, tick, chart selection, navigation, selection edit, and full refresh in session A cause zero observed changes in B. A separate catalog observation also stays unchanged for A's sample count update. The tests check state invalidation in two independent session objects; they do not measure drawing time or prove a speedup in two visible native windows.

The identity test holds one `SessionModel` reference and verifies it remains the same object after refresh, close/reopen, and trash/restore. Existing hosted tests cover window startup, visibility/occlusion policy, forecast behavior, drag, and navigation.

An opt-in native test also mounted four `SessionWindow` instances in temporary `NSWindow`s. Visible, minimized, hidden, and revealed assertions passed while ingestion continued. In one four-second idle segment it recorded 20 queries/20 display refreshes with four visible windows, versus 5/5 with three minimized; process CPU was about 6.0% versus 2.8%. With ingestion, the segments recorded 24/24 versus 6/6 and about 16.9% versus 14.4% CPU. These are one-run workload observations, not a before/after comparison or a speedup claim. Pointer behavior, notification permission, and sleep/wake acceptance remain outside this check.

## Validation

On Xcode 27.2 / Apple Swift 6.4.2, `just test` passed: 79 core, 12 transport, 4 CLI, and 42 hosted app tests (2 opt-in skips). `just strict-build` passed package tests with complete checking and warnings as errors, then compiled the hosted app/test targets with warnings as errors. `just format-check` and `git diff --check` passed. The opt-in `testNativeWindowWorkMeasurement` passed as 1 hosted test in 21.5 seconds using a copied `.xctestrun` with `PIPEPLOT_MEASURE_WINDOWS=1`. Xcode logged its existing CoreSimulator version mismatch and App Intents metadata-extraction notices, with no project-source warnings. All tests used temporary stores and sockets; no local installation or user database was touched.

To repeat the opt-in native measurement after `just strict-build`, copy the test manifest beside itself and set one environment variable. Keeping the copy beside the original preserves Xcode's relative test-product paths:

```sh
python3 - <<'PY'
import plistlib
from pathlib import Path
source = Path('.build/xcode/Build/Products/PipePlot_macosx27.2-arm64.xctestrun')
target = source.with_name('PipePlot_native_window_issue26.xctestrun')
data = plistlib.loads(source.read_bytes())
data['PipePlotAppTests']['EnvironmentVariables']['PIPEPLOT_MEASURE_WINDOWS'] = '1'
target.write_bytes(plistlib.dumps(data))
PY
xcodebuild test-without-building \
  -xctestrun .build/xcode/Build/Products/PipePlot_native_window_issue26.xctestrun \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -only-testing:PipePlotAppTests/WindowVisibilityTests/testNativeWindowWorkMeasurement
```
