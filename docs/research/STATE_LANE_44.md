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
