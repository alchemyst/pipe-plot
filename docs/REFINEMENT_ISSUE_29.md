# Refinement issue #29: explicit background analysis requests

## Changes

- Chart display, derived series, selection statistics, and hover reads now request work from chart/selection/hover lifecycle tasks. Rendering reads typed idle/loading/cached/failed state and never starts a query. Forecast refresh requests fits explicitly before composing statuses.
- Each stream or forecast slot has one running query and one replaceable desired request. A superseded completion cannot publish over the latest key. Cancel and eviction clear desired work and reject late results, while an already running synchronous SQLite scan finishes. Re-requesting the same key after cancellation waits for that scan and then starts a fresh one.
- Results live in observable stream slots, not an app-wide revision. Requests include range, sample count/latest time, and configuration, live mode, or forecast selection as appropriate. Display and compatible derived results retain their real coordinates while a new range loads. Statistics and nearest reads require an exact key. Existing core membership/revision checks continue to validate reusable fits.
- Reassociation and undo/redo invalidate analysis state. Hidden and closed sessions cannot enqueue work through delayed tasks. Failed results offer explicit retry in their relevant UI. Analysis keeps the dedicated serial worker and the independent read-only SQLite WAL connection.

## Validation on 2026-11-03

- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just test`: passed; Swift package tests 4 CLI, 12 transport, 79 core; hosted macOS app tests 58 with 2 opt-in skips. The fit reuse regression printed `silentTicks=40 queries=0 rawFits=0 boundaryQueries=1 boundaryFits=1 crossing=40s`.
- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just strict-build`: passed, including Swift package strict concurrency and hosted app/test build with warnings fatal.
- `just format-check`: passed.
- `./scripts/benchmark-sample-store.sh 10000`: two columns, 10,000 rows per stream; append 1.121593042 s, query 0.003708 s for 10,000 returned rows, maximum RSS 12,009,472 bytes.
- `./scripts/benchmark-derived-series.sh 10000`: 10 streams, 10,000 rows per stream; 99,000 outputs, elapsed processing 0.0463910103 s, 2,155,590 input rows/s, maximum RSS 5,996,544 bytes.

The two scripts exercise isolated core operations, not chart interaction or end-to-end background scheduling. These are one-run measurements, not before/after speedup claims. The blocked-worker tests directly show at most one submitted scan while rapid keys or repeated eviction accumulate, followed by one latest-key submission. The 40-tick live test bounds fit work for unchanged membership.

## Limits

The opt-in sustained acceptance run and broader #14 native acceptance matrix were not repeated. These tests do not establish pointer, VoiceOver, notification, sleep/wake, or long-duration resource behavior. No installed build or live saved data was used.
