# Using PipePlot

[Back to the project](../README.md) · [Build and development](DEVELOPMENT.md)

## Runnable examples (macOS)

Each example creates a new chart. `pp` must be installed and on `PATH`.
Press Ctrl-C to stop; the capture remains saved.

### Track a process’s memory

Sample resident memory once a second, in KiB. This runs as written for your current shell; replace `$$` with another process ID to track that process.

```sh
pp --watch "ps -p $$ -o rss=" --interval 1 \
  -c -n rss -u KiB
```

RSS is resident memory, not the “Memory” figure in Activity Monitor. Sampling stops if the process exits.

### Track system load

Read the one-minute load average once a second. Uses the macOS `sysctl` command.

```sh
pp --watch 'sysctl -n vm.loadavg | awk "{print \$2}"' \
  --interval 1 -c -n load
```

Adapted from the load-average example in [ttyplot](https://github.com/tenox7/ttyplot#examples).

### Plot ping times

Plot 30 round-trip times in milliseconds. This example uses loopback; replace `127.0.0.1` with your router or another host.

```sh
LC_ALL=C ping -c 30 127.0.0.1 |
  sed -n -l 's/.*time=\([0-9.]*\) ms.*/\1/p' |
  pp -c -n latency -u ms
```

Adapted from [ttyplot](https://github.com/tenox7/ttyplot#ping-plot-with-sed) and [wesplot](https://github.com/cactusdynamics/wesplot#example-use-cases). On macOS, `sed -l` flushes each line. Headers and unanswered pings produce no samples.

### Plot a transfer rate with pv

Send 20 MiB of zeroes to `/dev/null`, limited to 2 MiB/s, and plot bytes per second. Requires `pv` (`brew install pv`). No file is created.

```sh
{ dd if=/dev/zero bs=1048576 count=20 2>/dev/null |
    pv -n -r -L 2m -i 0.5 >/dev/null
} 2>&1 | pp -c -n throughput -u B/s
```

[pv’s numeric rate output](https://www.ivarch.com/programs/quickref/pv.shtml) goes to stderr. The group sends that output to `pp` and discards the transferred bytes. This is a rate-limited demonstration, not a disk benchmark.

### Try two generated signals

Generate two sine waves at one sample per second. No other command is needed.

```sh
pp --test 2 -c
```

Each input column becomes a separate line. All columns are values; timestamps are assigned when rows arrive.

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

If a pipe stays open for about two seconds before its first usable numeric row, `pp` reports what it has received on standard error. Run the producer alone to check when it emits complete numeric rows. Producers and intermediate filters can buffer their output when writing to a pipe. For example, Python's unbuffered mode works on macOS with `python3 -u sampler.py | pp`. In a Python producer you can also use `print(value, flush=True)` after each sample.

The target sink is explicit and shared across windows. Changing focus never redirects a producer. Cmd-N creates a new session; Cmd-Shift-D creates and targets a chart. Existing producers retain their assigned streams.

`pp --test [columns]` generates a local sine-wave stream at one row per second (one column by default, up to 32). It uses the same target, chart, and session routing options as a pipeline. Press Ctrl-C to finish and retain the generated samples; no producer process is started.

`pp --watch 'command'` runs a command repeatedly using `/bin/sh -c` and plots its standard output using the normal numeric row parser. For example, `pp --watch 'sysctl -n vm.loadavg | awk "{print \$2}"' --interval 5 -n load` samples every five seconds. The default interval is two seconds, measured after each command finishes, so runs never overlap. Output without a final newline is accepted; multiple numeric lines produce multiple samples. Standard error is displayed in the terminal, and a nonzero command exit stops polling with an error. Press Ctrl-C to stop the command and finish the capture. The command's standard input is `/dev/null`. Use shell quoting as you would for any command string, and make sure its output is numeric.

`pp --event` reads UTF-8 text lines and adds one session-wide vertical time guide for each nonblank line. Each event is timestamped when `pp` receives the line; CRLF is accepted, and a final line without a newline is kept. A line is limited to 64 KiB; invalid UTF-8, NUL bytes, and oversized lines are rejected with a diagnostic on standard error. Event connections create no numeric streams. They use the current target by default; `-c` or `-s` routes to a new chart or session, and `pp --event 2` attaches to session 2. It cannot be combined with `--test`, numeric line names, or `--unit`. The session clock advances while any producer or event connection remains active and freezes when the last one ends.

A plain rerun can continue the latest disconnected group if the target has not changed and the column count matches. Concurrent or ambiguous captures create new streams. This rule does not identify shell commands; use a session number and line names when you need explicit identity, or `--fresh` to request new lines.

New charts show connecting lines by default; dots can be enabled independently. Axis labels use decimal SI prefixes by default or binary prefixes (Ki, Mi, Gi, …) when selected. Entered guide values accept a number with a recognized SI/binary prefix and unit, such as `1.5 GiB`. Automatic Y scaling can include zero, and a horizontal guide can be selected as a relative value origin so axis labels show offsets from it while the plotted data stays unchanged. Explicit Y limits and chart units are available in Settings.

Prominent local peaks and troughs are labelled from observed samples when a chart has at most six streams; the display does not interpolate points. Hover readouts reserve their space, and selection boundaries are marked across the chart stack. A linked boundary has a distinct marker and follows the chosen clock behavior.

The shared time axis displays local time or UTC. A session time guide can serve as the time origin, displaying signed elapsed times from that guide. The toolbar also provides recent history spans, Show All History, Follow Now, and Back/Forward viewport navigation. Session controls rename a session or move it to Trash; the saved-session picker restores deleted sessions.

The session clock advances while at least one producer remains connected, even during silence. When its final producer disconnects, the clock freezes at disconnect time and resumes on the next connection.

Minimised, fully occluded, and app-hidden session windows keep collecting and checking configured guide alerts while suspending chart canvases, display refreshes, and analysis queries. Revealing a window loads current stored data without replaying samples or changing its timeline or selection modes.

Closing a session window stops capture into that session but retains its data. EOF means input ended; it does not establish whether the upstream command succeeded. Upstream programs may buffer output before `pp` sees it.

## Investigate and arrange

All rows share hover, selection, time guides, pan and zoom. Shift-drag pans; Ctrl-wheel or pinch zooms; ordinary vertical scrolling moves through the stack. Drag selects; drag near now to link the selection end. The left-edge tracking button preserves the selected duration. With the timeline focused, A/D pan, W/S zoom, F fits the selection and Escape clears it. Back/Forward navigation is separate from Cmd-Z edits.

Use **Session → Edit Selection…** to enter exact start/end timestamps (including milliseconds), a fixed duration, and tracking mode without dragging or changing the viewport. The selection panel keeps its bounds visible and groups statistics by stream. **View** contains chart targeting, Chart Settings, pan/zoom, time ranges and **Chart Text Size** (100%, 150%, 200%); **File** contains chart and selection CSV exports.

Charts use stable dash/marker patterns with matching legend keys, and adapt their colors to light, dark and increased-contrast appearances. Raw and derived charts expose numeric accessibility summaries and representative chart descriptors. Derived values remain explicitly identified as estimates.

Drag the handle at the start of a stream's legend onto another chart to merge it, onto a separator to insert a row, or onto Add Chart to create a row. Valid destinations show a merge outline or insertion marker. Escape or dropping outside clears the preview. Stream menus offer the same moves, including Insert as New Chart Before, for keyboard use. Each move, including a new row and collapse of an empty source, is one undoable action.

Chart and stream menus provide rename, move, style, hide and restore actions. Hide from Layout removes a stream and its annotations while capture continues; Chart actions → Restore Hidden Stream brings it back, including when every stream in the chart is hidden. Turning both lines and dots off retains annotations and is labelled Marks off. Moving a stream preserves its producer, history and appearance; axis units and value guides stay with their chart. Continue/Reassociate maps an entire sampler group to disconnected lines, with Undo preserving later observations. Guides support precise values/times, labels, and colors. Horizontal value guides can be configured for rising, falling, or either crossing, with hysteresis and a cooldown; notifications are evaluated against incoming raw samples and require macOS notification permission. Selection statistics use raw observations, and multiple guide-targeted linear forecasts share the furthest future horizon. Forecast fits are reused while the selected samples are unchanged; linked training bounds and countdowns continue advancing during silent input.

The shared ruler includes a loop-style interval brace and labelled time locators. Click a locator flag to edit its exact time/label; double-click each interval triangle independently to toggle tracking. The selection Forecast menu can create a new target guide with an exact SI/binary value even when no guides exist; creating its guide and forecast is one Undo step. Open chart, stream, guide and selection menus keep a fixed native menu tree while live updates continue.

In Saved Sessions, select multiple sessions to move them to Trash together, or use Clean Up Older Than a Week for sessions closed more than seven days ago. The Trash menu (called Bin in some regions) lets you restore sessions with their data or empty it to delete them permanently. Moving a session to Trash or closing it disconnects its producers. Restoration never restarts a shell command.

## Related tools

[Compare PipePlot with ttyplot, wesplot, LabPlot and other plotting tools](SIMILAR_PROJECTS.md).
