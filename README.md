# PipePlot

Native macOS plots for temporary numeric streams. Pipe a sampler into `pp`; each whitespace-separated column becomes a line in the current target chart. Data is saved locally, and inspecting history does not interrupt capture.

## Build and install

Requires Apple Silicon, macOS 27, and Xcode's Swift toolchain. No third-party Swift packages are required.

```sh
swift test
./scripts/install-local.sh
```

This builds an ad-hoc signed `~/Applications/PipePlot.app` and installs `~/.local/bin/pp`. Add `~/.local/bin` to your shell's `PATH` if it is not already present. You can also invoke `~/.local/bin/pp` directly. Build without installing using `./scripts/build-app-bundle.sh`.

## Capture

```sh
printf '1\n2\n3\n' | pp
sampler | pp -n memory -u MiB
sampler | pp -c
sampler | pp 2 used free
pp ls
pp --help
pp --test 2
```

`pp` launches the installed app when needed. Standard output stays clean during capture; diagnostics go to standard error. Rows are timestamped locally when received. All columns are values, including the first column. Spaces, tabs, negatives and scientific notation work. Invalid/non-finite rows and changes in column count are rejected as whole rows. A final valid row need not end with a newline.

The target sink is explicit and shared across windows. Changing focus never redirects a producer. Cmd-N creates a new session; Cmd-Shift-D creates and targets a chart. Existing producers retain their assigned streams.

`pp --test [columns]` generates a local sine-wave stream at one row per second (one column by default, up to 32). It uses the same target, chart, and session routing options as a pipeline. Press Ctrl-C to finish and retain the generated samples; no producer process is started.

A plain rerun can continue the latest disconnected group if the target has not changed and the column count matches. Concurrent or ambiguous captures create new streams. This rule does not identify shell commands; use a session number and line names when you need explicit identity, or `--fresh` to request new lines.

New charts show connecting lines by default; dots can be enabled independently. Hover readouts reserve their space, and dragging a selection end near the now marker links that boundary to the session clock.

The session clock advances while at least one producer remains connected, even during silence. When its final producer disconnects, the clock freezes at disconnect time and resumes on the next connection.

Closing a session window stops capture into that session but retains its data. EOF means input ended; it does not establish whether the upstream command succeeded. Upstream programs may buffer output before `pp` sees it.

## Investigate and arrange

All rows share hover, selection, time guides, pan and zoom. Shift-drag pans; Ctrl-wheel or pinch zooms; ordinary vertical scrolling moves through the stack. Drag selects; drag near now to link the selection end. The left-edge tracking button preserves the selected duration. With the timeline focused, A/D pan, W/S zoom, F fits the selection and Escape clears it. Back/Forward navigation is separate from Cmd-Z edits.

Chart and stream menus provide rename, move, style, hide and restore actions. Moving a stream preserves its producer, history and appearance; axis units and value guides stay with their chart. Continue/Reassociate maps an entire sampler group to disconnected lines, with Undo preserving later observations. Guides support precise values/times and labels. Selection statistics use raw observations, and multiple guide-targeted linear forecasts share the furthest future horizon.

Saved sessions can be renamed or moved to Trash from the saved-session picker. Recently deleted sessions can be restored with their data; deleting or closing a session disconnects its producers. Restoration never restarts a shell command.

## Development

`Sources/PipePlotCore` owns parsing, storage and reversible model edits. `Sources/PipePlotTransport` owns local socket framing and discovery. `Sources/pp` is the CLI; `Sources/PipePlotApp` is the native interface. Raw observations are separate from presentation edits so undo does not restore stale sample arrays.

[SPEC.md](SPEC.md) records the product requirements. [Validation scenarios](docs/VALIDATION.md) describe the automated and manual checks needed before calling every interaction production-ready.
