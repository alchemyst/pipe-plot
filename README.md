# PipePlot

Native macOS plots for temporary numeric streams. Pipe a sampler into `pp`; each whitespace-separated column becomes a line in the current target chart. Data is saved locally, and inspecting history does not interrupt capture.

## Build and install

Requires Apple Silicon, macOS 27, Xcode's Swift toolchain, and [just](https://just.systems/). Building the app's icon also requires POV-Ray, Python 3 with Pillow, and macOS `iconutil`. No third-party Swift packages are required.

```sh
just build
just test
just install
```

Open `PipePlot.xcodeproj` and select the shared **PipePlot** scheme to build, run, test, profile, or archive the app in Xcode. The app target links the local Swift package's `PipePlotCore` and `PipePlotTransport` products. Xcode processes the tracked `Config/Info.plist`, renders and copies the icon, and signs the app with a local ad-hoc identity. App unit tests belong to the Xcode project; shared-code and CLI tests remain in SwiftPM.

`just build` builds the Release app and the SwiftPM `pp` CLI; `just bundle` is an equivalent command. The app is written to `.build/xcode/Build/Products/Release/PipePlot.app`. Xcode tracks changes to the app sources, plist, and icon inputs, reusing unchanged outputs. `swift build -c release --product pp` builds only the CLI.

`just test` runs both the package tests and the Xcode app tests. `just check` additionally runs the independent transport regression tests. The smoke and cold-pipeline scripts in `scripts/` exercise an installed app and create sessions, so they are not part of `just check`. Hosted app tests run without opening the user's database, starting IPC, or restoring application windows.

`just install` builds and installs an ad-hoc signed `~/Applications/PipePlot.app` and `~/.local/bin/pp` together. Add `~/.local/bin` to your shell's `PATH` if it is not already present. Building alone does not update either installed copy; run `just install` again after changes.

`just icon` regenerates standalone icon artwork in `.build/icon/`; see [the icon build notes](design/icon/README.md). App builds render their own copy in Xcode's derived files directory. Generated assets and local Xcode state are ignored by Git. The `justfile` remains the command runner; the build uses Xcode and SwiftPM directly, without Make.

## Capture

```sh
printf '1\n2\n3\n' | pp
sampler | pp -n memory -u MiB
sampler | pp -c
sampler | pp 2 used free
printf 'started\npressure stable\n' | pp --event
producer | pp --event 2
pp ls
pp --help
pp --test 2
```

`pp` launches the installed app when needed. Standard output stays clean during capture; diagnostics go to standard error. Rows are timestamped locally when received. All columns are values, including the first column. Spaces, tabs, negatives and scientific notation work. Invalid/non-finite rows and changes in column count are rejected as whole rows. A final valid row need not end with a newline.

The target sink is explicit and shared across windows. Changing focus never redirects a producer. Cmd-N creates a new session; Cmd-Shift-D creates and targets a chart. Existing producers retain their assigned streams.

`pp --test [columns]` generates a local sine-wave stream at one row per second (one column by default, up to 32). It uses the same target, chart, and session routing options as a pipeline. Press Ctrl-C to finish and retain the generated samples; no producer process is started.

`pp --watch 'command'` runs a command repeatedly using `/bin/sh -c` and plots its standard output using the normal numeric row parser. For example, `pp --watch 'sysctl -n vm.loadavg | awk "{print \$2}"' --interval 5 -n load` samples every five seconds. The default interval is two seconds, measured after each command finishes, so runs never overlap. Output without a final newline is accepted; multiple numeric lines produce multiple samples. Standard error is displayed in the terminal, and a nonzero command exit stops polling with an error. Press Ctrl-C to stop the command and finish the capture. The command's standard input is `/dev/null`. Use shell quoting as you would for any command string, and make sure its output is numeric.

`pp --event` reads UTF-8 text lines and adds one session-wide vertical time guide for each nonblank line. Each event is timestamped when `pp` receives the line; CRLF is accepted, and a final line without a newline is kept. A line is limited to 64 KiB; invalid UTF-8, NUL bytes, and oversized lines are rejected with a diagnostic on standard error. Event connections create no numeric streams. They use the current target by default; `-c` or `-s` routes to a new chart or session, and `pp --event 2` attaches to session 2. It cannot be combined with `--test`, numeric line names, or `--unit`. The session clock advances while any producer or event connection remains active and freezes when the last one ends.

A plain rerun can continue the latest disconnected group if the target has not changed and the column count matches. Concurrent or ambiguous captures create new streams. This rule does not identify shell commands; use a session number and line names when you need explicit identity, or `--fresh` to request new lines.

New charts show connecting lines by default; dots can be enabled independently. Axis labels use decimal SI prefixes by default or binary prefixes (Ki, Mi, Gi, …) when selected. Entered guide values accept a number with a recognized SI/binary prefix and unit, such as `1.5 GiB`. Automatic Y scaling can include zero, and a horizontal guide can be selected as a relative value origin so axis labels show offsets from it while the plotted data stays unchanged. Explicit Y limits and chart units are available in Settings.

Prominent local peaks and troughs are labelled from observed samples when a chart has at most six streams; the display does not interpolate points. Hover readouts reserve their space, and selection boundaries are marked across the chart stack. A linked boundary has a distinct marker and follows the chosen clock behavior.

The shared time axis displays local time or UTC. A session time guide can serve as the time origin, displaying signed elapsed times from that guide. The toolbar also provides recent history spans, Show All History, Follow Now, and Back/Forward viewport navigation. Session controls rename a session or move it to Recently Deleted; the saved-session picker restores deleted sessions.

The session clock advances while at least one producer remains connected, even during silence. When its final producer disconnects, the clock freezes at disconnect time and resumes on the next connection.

Minimised, fully occluded, and app-hidden session windows keep collecting and checking configured guide alerts while suspending chart canvases, display refreshes, and analysis queries. Revealing a window loads current stored data without replaying samples or changing its timeline or selection modes.

Closing a session window stops capture into that session but retains its data. EOF means input ended; it does not establish whether the upstream command succeeded. Upstream programs may buffer output before `pp` sees it.

## Investigate and arrange

All rows share hover, selection, time guides, pan and zoom. Shift-drag pans; Ctrl-wheel or pinch zooms; ordinary vertical scrolling moves through the stack. Drag selects; drag near now to link the selection end. The left-edge tracking button preserves the selected duration. With the timeline focused, A/D pan, W/S zoom, F fits the selection and Escape clears it. Back/Forward navigation is separate from Cmd-Z edits.

Drag the handle at the start of a stream's legend onto another chart to merge it, onto a separator to insert a row, or onto Add Chart to create a row. Valid destinations show a merge outline or insertion marker. Escape or dropping outside clears the preview. Stream menus offer the same moves, including Insert as New Chart Before, for keyboard use. Each move, including a new row and collapse of an empty source, is one undoable action.

Chart and stream menus provide rename, move, style, hide and restore actions. Hide from Layout removes a stream and its annotations while capture continues; Chart actions → Restore Hidden Stream brings it back, including when every stream in the chart is hidden. Turning both lines and dots off retains annotations and is labelled Marks off. Moving a stream preserves its producer, history and appearance; axis units and value guides stay with their chart. Continue/Reassociate maps an entire sampler group to disconnected lines, with Undo preserving later observations. Guides support precise values/times, labels, and colors. Horizontal value guides can be configured for rising, falling, or either crossing, with hysteresis and a cooldown; notifications are evaluated against incoming raw samples and require macOS notification permission. Selection statistics use raw observations, and multiple guide-targeted linear forecasts share the furthest future horizon.

The shared ruler includes a loop-style interval brace and labelled time locators. Click a locator flag to edit its exact time/label; double-click each interval triangle independently to toggle tracking. The selection Forecast menu can create a new target guide with an exact SI/binary value even when no guides exist; creating its guide and forecast is one Undo step. Open chart, stream, guide and selection menus keep a fixed native menu tree while live updates continue.

Saved sessions can be renamed or moved to Trash from the saved-session picker. Recently deleted sessions can be restored with their data; deleting or closing a session disconnects its producers. Restoration never restarts a shell command.

## Development

`Sources/PipePlotCore` owns parsing, storage and reversible model edits. `Sources/PipePlotTransport` owns local socket framing and discovery. `Sources/pp` is the CLI; `Sources/PipePlotApp` is the native interface. Raw observations are separate from presentation edits so undo does not restore stale sample arrays.

Statistics and straight-line regression share an Accelerate/vDSP implementation. Centered moments are computed in batches of at most 1,024 observations and merged, keeping range-query working memory bounded while fitting actual receipt timestamps. Median selection remains in SQLite for stored histories. Kernel-based smoothing and derivative estimates, including explicit resampling and gap policies, are tracked in [#19](https://github.com/alchemyst/pipe-plot/issues/19).

[Window visibility validation](docs/WINDOW_VISIBILITY_VALIDATION.md) records the native four-window CPU/query measurement and its reproduction command.

[Native UI session evidence](docs/NATIVE_UI_SESSION.md) records the issue fixes, all 40 scenario outcomes and outstanding pointer/lifecycle/resource checks.

[SPEC.md](SPEC.md) records the product requirements. [Validation scenarios](docs/VALIDATION.md) describe the automated and manual checks needed before calling every interaction production-ready.

The controls and behaviors above describe the current implementation. The documented manual interaction and visual acceptance scenarios have not all been exercised; consult the validation guide before treating the UI as fully verified.
