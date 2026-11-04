# State lane prototype decision

Decision recorded 2026-11-04 before prototype implementation. Issue [#44](https://github.com/alchemyst/pipe-plot/issues/44) asks for an opt-in evaluation. A standalone macOS fixture will exercise the interaction before any production changes. Production would use the shared viewport and time selection alongside `PlotCanvas`, a per-stream presentation choice near `StreamLegend`, and a discrete accessibility description alongside `PlotAccessibility`. The fixture will use bundled observations and separate state from the main app.

## Observation semantics

- Use exact numeric 0 and 1 as discrete Low and High. Draw a marker at the receipt time. A short connector between equal states in the same capture segment, within the fixture's two-second gap threshold, is a faint association between observations. State within the interval remains unknown.
- Leave the interval between unlike observations blank. Its endpoints bound a possible change. The samples provide no exact transition time or count.
- Leave longer gaps and capture segment boundaries blank. Draw no implied state before the first or after the last observation. The two-second threshold is a fixture parameter. A production policy needs cadence and input provenance decisions.
- Show unsupported values on a separate marker level within that lane, break any association across them, and expose the unmodified value and timestamp. The stream remains available for analog viewing.
- Hover snaps only near a visible raw observation. A gap reports no nearby observation. Render all fixture observations and leave a production density and aggregation policy open.

## Interaction and accessibility

One time domain and one explicit selection drive the analog chart and both state lanes. Align the plot edges so a given timestamp lands at the same x-coordinate in every row. Use pointer drag in Pan or Select mode, and visible native controls for pan, zoom, mode, reset, and clearing the selection. Show the same crosshair on every row.

Each row will provide a keyboard and VoiceOver target. Left and Right move among visible raw observations. The VoiceOver adjustable action will invoke the same stepping behavior. Report the row name, raw value, receipt timestamp and state classification in an accessibility value. The prototype will expose the shared viewport and selection as text so they can be read through standard navigation.

## Run the fixture

On macOS, run `scripts/research/evaluate-issue44.sh` from the checkout. Add `--build-only` to compile without opening a window. The fixture has no socket, session database, or persisted layout.

- Pressure, Inlet valve and Pump enabled share the same time grid, selection shading and observation crosshair. Use the pan and zoom buttons or drag in Pan mode. Switch to Select and drag from any plot.
- Inlet valve includes a fractional unsupported observation, a long same-value gap, a reconnect and an interval between differing observations. Pump enabled includes a reconnect between two nearby Low observations. An outlined square marks an unsupported value.
- A focused row uses Left and Right to step. Space starts and finishes a selection at raw receipt times. The VoiceOver interface exposes equivalent adjustable actions and a named Set selection boundary action.
