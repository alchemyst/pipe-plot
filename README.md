# PipePlot

Native macOS plots for temporary numeric streams. Pipe a sampler into `pp`; each whitespace-separated column becomes a line in the current target chart. Data is saved locally, and inspecting history does not interrupt capture.

## Build and install

Requires Apple Silicon, macOS 27, Xcode's Swift toolchain, and [just](https://just.systems/). No third-party Swift packages are required.

```sh
just test
just install
```

`just install` builds and installs an ad-hoc signed `~/Applications/PipePlot.app` and `~/.local/bin/pp` together. Add `~/.local/bin` to your shell's `PATH` if it is not already present. You can also invoke `~/.local/bin/pp` directly. Building alone does not update either installed copy; run `just install` again after changes.

Use `just` to list the project commands. `just build` compiles the release binaries, `just bundle` builds the app in `.build/pipeplot-stage/` without installing it, and `just check` runs the package tests and independent transport regression tests. The smoke and cold-pipeline scripts in `scripts/` exercise an installed app and create sessions, so they are not part of `just check`.

`just icon` regenerates the static icon assets and requires POV-Ray, Python with Pillow, and macOS `iconutil`; see [the icon build notes](design/icon/README.md). Ordinary builds use the existing icon and do not require those tools. The underlying Swift and shell commands can also be run directly without `just`.

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

Closing a session window stops capture into that session but retains its data. EOF means input ended; it does not establish whether the upstream command succeeded. Upstream programs may buffer output before `pp` sees it.

## Investigate and arrange

All rows share hover, selection, time guides, pan and zoom. Shift-drag pans; Ctrl-wheel or pinch zooms; ordinary vertical scrolling moves through the stack. Drag selects; drag near now to link the selection end. The left-edge tracking button preserves the selected duration. With the timeline focused, A/D pan, W/S zoom, F fits the selection and Escape clears it. Back/Forward navigation is separate from Cmd-Z edits.

Chart and stream menus provide rename, move, style, hide and restore actions. Moving a stream preserves its producer, history and appearance; axis units and value guides stay with their chart. Continue/Reassociate maps an entire sampler group to disconnected lines, with Undo preserving later observations. Guides support precise values/times, labels, and colors. Horizontal value guides can be configured for rising, falling, or either crossing, with hysteresis and a cooldown; notifications are evaluated against incoming raw samples and require macOS notification permission. Selection statistics use raw observations, and multiple guide-targeted linear forecasts share the furthest future horizon.

Saved sessions can be renamed or moved to Trash from the saved-session picker. Recently deleted sessions can be restored with their data; deleting or closing a session disconnects its producers. Restoration never restarts a shell command.

## Development

`Sources/PipePlotCore` owns parsing, storage and reversible model edits. `Sources/PipePlotTransport` owns local socket framing and discovery. `Sources/pp` is the CLI; `Sources/PipePlotApp` is the native interface. Raw observations are separate from presentation edits so undo does not restore stale sample arrays.

Statistics and straight-line regression share an Accelerate/vDSP implementation. Centered moments are computed in batches of at most 1,024 observations and merged, keeping range-query working memory bounded while fitting actual receipt timestamps. Median selection remains in SQLite for stored histories. Kernel-based smoothing and derivative estimates, including explicit resampling and gap policies, are tracked in [#19](https://github.com/alchemyst/pipe-plot/issues/19).

[SPEC.md](SPEC.md) records the product requirements. [Validation scenarios](docs/VALIDATION.md) describe the automated and manual checks needed before calling every interaction production-ready.

The controls and behaviors above describe the current implementation. The documented manual interaction and visual acceptance scenarios have not all been exercised; consult the validation guide before treating the UI as fully verified.
