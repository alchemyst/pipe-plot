# Native, lifecycle and resource acceptance — 2026-11-01

This records execution of [#14](https://github.com/alchemyst/pipe-plot/issues/14),
separately from feature implementation and the earlier 40-scenario evidence table
in [NATIVE_UI_SESSION.md](NATIVE_UI_SESSION.md). Checks use disposable sessions or
isolated temporary databases; previously captured sessions are retained.

Hardware: Mac14,9 (M2 Pro MacBook Pro), 16 GiB, macOS 27.2 (26B123).
Native desktop checks use the installed release app and matching `pp`. Native
responder, IPC and sustained UI measurements use debug builds of the actual app
sources, hosted by XCTest. They are identified below rather than equated with
manual pointer operations or release-process performance.

## Native interactions

Fresh native session 41 received two one-second sine/cosine columns through the
installed CLI. The session was raised before inspecting visibility-dependent UI.
Capture continued while the following controls were exercised:

- Double-clicking plot background created a vertical guide at 12:47:47. Dragging a
  23.5-second interval displayed the shared brace, boundary markers and raw stats.
  A single click elsewhere cleared the interval; Cmd-Z restored the same bounds
  and raw statistics while the visible Now clock continued advancing.
- F fitted the interval without editing its bounds. The forecast menu stayed open
  from 12:50:12 to 12:50:24 while input/clock updates continued, then its entry for
  Acceptance B opened the exact target sheet. Value 10 and label Native acceptance
  target created one target/forecast action. Cmd-Z removed both; Cmd-Shift-Z restored
  them. The fixed training range and 23 selected observations were retained.
- A pointer drag changed the horizontal target from 10 to approximately 8; one
  Cmd-Z restored 10. A later drag with a concurrently requested Escape committed
  before Escape arrived, after which Escape cleared the interval. That attempt is
  **not** evidence of in-drag cancellation. Deterministic native-responder coverage
  below exercises that ordering instead.
- Dragging the lower-right window border inward reduced the outer width to 850
  points. The 580-point minimum content height plus title bar was retained. The
  plot, stream actions, forecast row and bottom navigation were readable and input
  continued. This supersedes the earlier bridge-limited resize attempt.

A fresh four-window native measurement on this revision passed. With all four
windows visible, idle refresh/query counts were 20/24 over four seconds; with
three minimized they were 5/5. During ingestion the corresponding counts were
24/24 and 6/6, with 66 accepted rows per session in each phase. Process CPU was
6.76%/14.96% of one core for visible idle/ingestion, and 4.45%/14.01% with three
minimized. This is a short debug XCTest profile, including the driver, not the
release-process or hour-long budget. [Raw results](acceptance-2026-11-01/window-measurement.txt).

## Multiwindow routing, history and close

In sessions 57/58, a named producer remained attached to 57 while Cmd-N created
and targeted 58. Two plain producers joined 58 even after focus returned to 57;
its Target button correctly read “Set target”. Native double-clicks created one
time guide in each session. Cmd-Z in 58 removed only its guide, then Cmd-Z in 57
removed only 57's guide. New observations arrived in all three producers; native
Redo restored 57's guide without restoring 58's. F was dispatched before Redo,
but no changed viewport was established, so that attempt is not additional native
navigation evidence. Navigation/history isolation also has app regression coverage.
[Saved checkpoints](acceptance-2026-11-01/native-routing.jsonl).

After B ended while C stayed live, a fresh producer created a separate line. Its
native “Continue / Reassociate Group…” sheet mapped that line to B; Undo restored
the source and Redo mapped it again, retaining observations arriving throughout.
This exposed stale destination counts/status on Undo: SQLite rows moved back but
the old destination incorrectly stayed Live. Reassociation history now retains its
prior destination state and refreshes both sides' counts/time bounds on reversal.
The expanded core regression failed on all three fields before the correction.

The corrected installed release was repeated in session 59: Undo showed the
[destination at one sample/Ended and source at two/Live](acceptance-2026-11-01/reassociation-undo-fixed.json).
After another source observation, [Redo retained all four destination observations](acceptance-2026-11-01/reassociation-redo-fixed.json).

Closing targeted session 58 disconnected both of its active CLI producers with
“The PipePlot session window was closed.” Session 57 kept receiving observations
and became Target. Closing its final window left the app running; a new pipeline
created visible session 59 and retained all three values. Manual quit/relaunch
also restored exactly sessions 54, 55 and 56 in three windows; session 55 retained
its capture/guides and the Target stayed in 56. These checks supplement the earlier
native text Undo/Redo, endpoint triangles, rename/Trash/Restore, shared ruler and
Local/UTC checks in NATIVE_UI_SESSION.md; unchanged interactions are not claimed
as newly repeated here. The 40-scenario table there remains the coverage inventory,
with this report superseding its outstanding resource/lifecycle/control evidence.
Not every possible combination of pointer gestures, units and forecast states was
manually replayed; model/responder regressions cover the additional permutations.

## Guide alerts and delivered banners

The native guide editor exposed a second stale-sheet defect: “Save Guide” could
replace an independently enabled alert with the sheet's older guide. Saving value
and label now merges into the current guide. A regression preserves the alert
through save/Undo and verifies a removed guide cannot be resurrected by a stale
sheet. The installed editor was repeated: Rising remained enabled after Save and
reopening; Falling and Both were then selected and saved successfully.

Session 55 used the installed CLI and a guide at 1.5 with zero hysteresis. Rising
and Falling used the default ten-second cooldown; Both used zero cooldown. Raw
baseline/crossing inputs exercised rising (1→2), falling (2→1), and both (1→2→1).
The macOS Notification Center log records actual “displaying as banner” events,
not merely successful submission: rising at 14:16:59, 14:17:55 and 14:18:25;
falling at 14:19:10; both-direction presentations at 14:20:11 and 14:20:12.
[Presentation records](acceptance-2026-11-01/notification-banners.txt) contain only
PipePlot events; macOS redacts their body text. The user additionally confirmed
“Yes, a banner appeared” for the rising alert. The computer-use tool selected a
desktop widget rather than the banner, so no banner screenshot is claimed.

System Settings showed PipePlot allowed, Desktop and Notification Centre enabled,
and Temporary alert style. Global notification suppression while sharing was Off
for notifications (i.e. banners suppressed). With explicit user permission it was
briefly changed to Allow Notifications for the crossing runs, then restored to
**Notifications Off** and verified. No per-app style or Focus setting was changed.
The earlier denied-permission check remains recorded in NATIVE_UI_SESSION.md;
today's allowed delivery supplements it. Event streaming is independently checked
below and by the actual app/server integration test.

## Native responder integration

`NativeResponderAcceptanceTests` creates the actual `PlotInteractionView` in an
isolated NSWindow and delivers native down/drag/up NSEvents directly to that view.
AppKit's `cancelOperation` action is invoked between drag and release, providing
unambiguous Escape ordering without changing external desktop input.

Cancellation removes the preview, commits nothing and preserves Redo. Redo restores
the previous guide edit. Four intermediate drag positions followed by release
produce one model edit; one Undo restores the prior value and preserves a sample
accepted during the drag. This is native-responder integration, not a claim that
the computer-use bridge held a pointer while pressing Escape successfully.

## Isolated failure paths

`FailureAcceptanceTests` limits an isolated SQLite database to 32 pages. It
receives the real SQLITE_FULL failure (`database or disk is full`) after 238
acknowledged two-column rows on this run. Both columns retain all 238 observations,
with no partial rejected row; reopening retains the same counts. This does not
fill the Mac's filesystem.

A separate metadata-path failure occurs after one acknowledged row. The next raw
row commits to SQLite but its metadata write fails and append throws. In-memory
counts truthfully reflect both committed raw rows; the second is not acknowledged.
Restoring the last saved metadata and reopening reconciles counts to two, retaining
both values. It neither discards acknowledged data nor claims the failed append
was acknowledged. This fault is a metadata-path error, not a physical disk-full test.

`IPCFailureAcceptanceTests` uses the production app model/server with an explicitly
injected temporary socket. Abrupt client EOF marks that producer disconnected and
freezes its clock while retaining its acknowledged observation. Closing a second
session sends the truthful `session_closed` error, retains its sample and leaves
another session accepting observations. A row before hello receives a protocol
error. Reopening retains all acknowledged values. Default model initialization
and production socket selection remain unchanged.

## Physical sleep/wake

A real installed `pp` producer collected into session 45. The system power log
recorded Deep Idle sleep at 12:58:52 and wake at 12:59:07. The producer continued
emitting during that interval (maximum receipt spacing about 1.33 s), so this first
run does not establish a missing-observation gap.

The repeat deliberately stopped only the test producer around sleep, keeping its
CLI connection open, then resumed it after wake. All 150 values (0…149) were
retained in order, with a 33.1599-second receipt-time gap. The producer exited 0
with empty stdout/stderr, and the saved stream ended normally. No observations
were fabricated to fill the silent interval. The physical power-state transition
and deliberately paused input are separate evidence; the log does not imply that
all background processes suspended for the whole recorded sleep interval.

After the repeat, the desktop locked. Computer use reported that automatic unlock
was paused following physical input. A request to unlock manually was sent; shell
checks and the isolated resource run continued. After manual unlock, session 45 reopened with its complete capture and the
receipt-time gap visible; navigation and controls responded normally.

## Cold/warm/sparse presentation

An opt-in `--acceptance-trace PATH` app argument records process start, window
visibility transitions and drawing passes containing actual observed samples.
`PIPEPLOT_ACCEPTANCE_TRACE` forwards that argument only when `pp` launches the app.
No normal preference or capture behavior is changed by the tracing flag.

The initial cold attempt saved its sample but produced no visible-window Canvas
sample render within 30 seconds. Raising the window exposed the retained point;
its first traced render was approximately 39 seconds after pipeline start.
Removing `open -g` alone did not resolve a second attempt. The startup fix therefore
also explicitly opens and presents the initial CLI-launched window at application launch. First accepted rows now refresh
their session promptly rather than waiting for the periodic display timer; later
rows retain the coalesced update cadence. Ready warm connections bypass launching
and do not repeatedly activate the app.

The startup fix supplies an initial window opener from SwiftUI Commands, which
exists before any scene appears. Previously, opening the first window depended on
an opener installed only after that window appeared. An ordinary initial scene
now binds the first destination, with separate data-driven windows for additional
sessions. Restoring additional windows is deferred until the first binding exists.

Two post-fix cold/warm runs measured 1.827 s / 0.063 s and 4.045 s / 0.316 s.
The latter overlaps acceptance-harness compilation and retains the slower result;
the proposed under-two-second cold target is not a guaranteed bound. In the full
[sparse run](acceptance-2026-11-01/latency-final.json), a second sample after
120 seconds of silence rendered in 0.667 s, within the one-second sparse target.
A preceding run lost window visibility during its silence and timed out; its
[cold/warm result and timeout](acceptance-2026-11-01/latency-command-opener.json)
are retained. No UI was raised to manufacture the successful cold measurement.
The trace boundary is a visible-window Canvas drawing pass, not physical scanout.

Reproduce with PipePlot stopped on an unlocked desktop:

```sh
just install
scripts/check-first-visible-sample.py --silent-seconds 120
```

## Sustained resource measurement

The separate `SustainedAcceptanceTests` run seeds seven days at five-second cadence
(120,961 rows per stream, 1,209,610 total) before measurement. It opens a real
SessionWindow on a fixed historical 15-minute viewport and fixed training interval,
then ingests ten values on a nominal five-second schedule through the normal store. Three more
session windows remain hidden while receiving one value each at the same cadence.
The measured process includes app rendering, storage, analysis, XCTest and AppKit;
it excludes transport/CLI. It is not the isolated numerical-engine benchmark from
#19. Preparation is accelerated; the subsequent paused-view soak is real time.

The report records RSS, process CPU, query/refit counts, accepted rows, inactive
window time, unchanged timeline/selection and historical viewport reload cost.
External observations additionally record SQLite/WAL sizes. The desktop's physical
sleep and lock occurred during this run and must be accounted for when interpreting
visibility and CPU figures. A locked/occluded window is intentionally suspended;
its reduced CPU is not attributed to visible-window rendering optimization.

The [one-hour report](acceptance-2026-11-01/soak.json) passed after 3,600.23 seconds.
Scheduling, workload and sleep yielded 694 new rows per primary stream and hidden
producer rather than an assumed 720; retained
counts were asserted exactly. The fixed viewport/selection stayed unchanged and
no raw training fit was resubmitted. The run submitted 2,393 queries, including
50 queries for five historical viewport reloads taking 0.167 seconds combined.
RSS started at 129.04 MB, reached a maximum sampled 130.60 MB and ended at 71.12 MB. CPU consumed
82.21 seconds (2.28% of one core averaged over the run). The window was inactive
for 2,514.88 seconds: this average includes the locked/occluded interval and must
not be represented as continuous foreground performance. The initial visible
minute consumed 4.38 CPU seconds, approximately 7.3% of one core.

The run compiled before the startup, first-row refresh and one-point window-observer
attachment fixes described here. It exercises the unchanged steady ingestion,
rendering, query and persistence paths. External process/database observations are
retained in [the resource log](acceptance-2026-11-01/soak-process-resources.jsonl).
Between external observations at elapsed 18:55 and 59:56, retained rows increased
from 1,212,444 to 1,218,593. SQLite grew from 227,254,272 to 228,622,336 bytes;
WAL changed from 795,192 to 374,952 bytes. These are partial-run observations,
not an extrapolated seven-day storage budget.

Reproduce (shows a temporary floating test window for the requested duration):

```sh
PIPEPLOT_SOAK_SECONDS=3600 \
PIPEPLOT_SOAK_REPORT="$PWD/.build/acceptance-soak.json" \
scripts/run-native-acceptance.sh --filter SustainedAcceptanceTests
```

The same script runs routine app tests without either opt-in measurement flag.
The harness uses repository app/test sources and excludes only the application
entry point; it does not validate signed test-host launching or system notifications.

## Restart analysis and first-row regressions

A new restart test reproduced one raw analysis submission for a closed saved
forecast. Closed/deleted sessions now clear their derived forecast status and
submit no fit until explicitly reopened. The same test reopens that session and
verifies its fit and all ten observations are available.

The first-row IPC test settles registration, deliberately sets the displayed
clock 60 seconds behind, and sends a real acknowledged row. Without any window
timer subscription, the session snapshot updates and its visible time domain
includes that row. This verifies the immediate first-row refresh advances time
as well as metadata; later ordinary rows still use the periodic display cadence.

## CLI and event acceptance

A final simultaneous cold-start repeat launched two plain producers with no app
running. They created one new session (57), one chart and two distinct streams;
each retained values 1, 2 and 3, exited zero and emitted no stdout/stderr. The saved
rows were available after 1.127 s; both streams had visible sample render traces
and appeared Ended in the native window. This time measures saved rows, separately
from the first-visible timings above. [Concurrent cold result](acceptance-2026-11-01/cold-concurrent.json).


Installed session 46 accepted three two-column rows, including the final row
without a newline. A malformed numeric field and a three-column row were rejected
as whole rows with stderr diagnostics; stdout remained empty. Both stream histories
contain exactly their three expected values. Two concurrent `pp -c` requests then
created distinct chart/stream identities in that session. Session 47 accepted two
text events with CRLF, a blank line and final unterminated input; it contains two
guides and zero numeric streams. See [CLI results](acceptance-2026-11-01/cli-matrix.json).

## Per-process resource profile

Two approximately 60-second phases used the installed release app and a real CLI
connection. The desktop was locked, so these numbers describe suspended/hidden UI.
The separate UI-source soak and its visible/locked timing are reported above.

| Phase | App CPU, % one core | CLI CPU, % one core | App interrupt wakeups/s | CLI interrupt wakeups/s | Maximum sampled app RSS | Maximum sampled CLI RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Connected, no new rows | 0.0315 | 0.0123 | 1.76 | 3.97 | 77.41 MB | 6.98 MB |
| One row every five seconds | 0.1335 | 0.0169 | 1.66 | 3.96 | 73.35 MB | 6.21 MB |

These are measured conditions, not proposed universal budgets or a claim about
foreground rendering CPU. RSS is sampled, not a kernel maximum. Physical footprint
and cumulative wakeup/CPU counters are retained in
[the resource report](acceptance-2026-11-01/cli-resources.json).

`scripts/process-resources.c` reads the current user's process counters through
`proc_pid_rusage`. On this Apple Silicon Mac the CPU fields use Mach absolute ticks,
not nanoseconds: a 0.2-second `clock()` burn measured 4,800,812 ticks, and the
125/3 timebase converted that to 0.200034 seconds. The initial raw capture was kept
and its CPU counters converted before generating the table. The committed helper
performs that conversion directly. Interrupt wakeups are per-process counters;
they are not a battery-energy measurement. The sampling helper itself also runs.

Reproduce with the app running:

```sh
scripts/measure-cli-resources.py --seconds 60
```

## Large-history undo memory

The optimized core benchmark runs against a SQLite backup of the isolated
week-scale store, never the live workload or user database. It applies 1,000 mixed
rename/hide/restore edits, then exhausts Undo and Redo. Exactly 200 actions are
retained in each direction, and all 1,214,570 observations in the ten-stream test
capture remain unchanged. The report includes RSS checkpoints at 200/500/1,000
edits. This tests metadata-only history and reversible layout removal; it is not a
claim of unlimited Undo or persistence of edit history across app restarts.

The benchmark source is `scripts/UndoHistoryBenchmark.swift`; supply a copy of an
isolated test database with ten streams. Compile it with the core sources in the
same manner as `scripts/benchmark-derived-series.sh`. The [measured result](acceptance-2026-11-01/undo-memory.json) records a maximum sampled RSS of 17.61 MB (16.33 MB initially), including Undo/Redo, for 1,000 mixed edits in 0.57 seconds.

## Routine validation and limits

The final package run passes 74 core, eight transport and three protocol tests. The current app-source harness passes
33 tests, with two opt-in measurements skipped in its routine run. The separate
hour-long test passed. Eight independent transport regressions
pass. Release build/signing/local installation pass; Python script compilation,
C compiler warnings and `git diff --check` pass.

One package rerun under concurrent builds missed the three-second expectation in
the non-reading-peer transport test. An isolated rerun passed all eight transport
tests; the independent transport suite also passed all eight. The failed run is
not counted as a full package pass. The 74 core tests and three protocol tests
passed in that run.

An Xcode hosted test attempt stalled in dyld dependency loading before application
main (144 KiB process RSS). Its stack was sampled and that specific test host and
runner stopped. It is not counted as a pass, nor attributed to application source
execution. A subsequent signed Xcode hosted run passed all 33 app tests, with two
opt-in measurements skipped. It includes the startup and alert-sheet fixes. The
last reassociation core correction was then verified by the final package suite,
33-test app-source harness, release build/install and native release repeat above.
