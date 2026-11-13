# macOS HIG and accessibility review — 13 November 2026

PipePlot has a useful native foundation, but the current interface has material
accessibility and narrow-layout gaps. The highest priorities are readable
selection controls, precise selection without dragging, and accessible derived
plots. This is a review, not an implementation or accessibility certification.

## Basis and scope

Read Apple's live guidance before inspecting the app: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover),
[Charts](https://developer.apple.com/design/human-interface-guidelines/charts),
[Charting data](https://developer.apple.com/design/human-interface-guidelines/charting-data),
[Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards),
[Windows](https://developer.apple.com/design/human-interface-guidelines/windows),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar),
[Color](https://developer.apple.com/design/human-interface-guidelines/color),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
and [Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop).
Used Apple's Markdown versions where its documentation HTML required JavaScript.

Reviewed the working tree based on `f52df21`, including the existing release
changes. The installed application was older; built and ran the current Release
bundle from `.build/xcode/Build/Products/Release/PipePlot.app` for the substantive
walkthrough. Used native screenshots, the accessibility tree, menu operations,
keyboard input, and source inspection. Created session 70, **HIG review
2026-11-13**, with 100 observations in each of three synthetic streams. No
existing session data was edited. The review session remains available.

Native coverage: saved-session picker, empty chart, live input and EOF, populated
chart, time-range menu, Chart Settings, selection inspector and Boundary menu,
stream menus, move to a new chart and Undo, View/Session menus, and value-guide
creation using Tab and Return. The observed window was approximately 900 points
wide, with about 580 points left for chart content when the inspector opened.

## Findings

### 1. P1 — Inspector and selection layouts lose essential information

**Confirmed in the running app.** Open Chart Settings at the normal window size.
The chart title disappears behind the available header space, Follow Now and
Local become truncated, and Session 70 wraps. Then choose Session → Select
Visible Time Range: the selection dates, duration and mode collapse into short,
multiline fragments. These are the values needed to understand an analysis.

The cause is several competing controls and labels in fixed horizontal rows,
combined with a selection inspector fixed at 108 points high. See
`Sources/PipePlotApp/ChartHeader.swift:17`,
`Sources/PipePlotApp/SessionWindow.swift:235`, and
`Sources/PipePlotApp/SelectionInspector.swift:27` and `:64`.

Use an adaptive header and selection layout: keep the title, range and duration
readable; put secondary actions on another row or in a suitable menu. Let the
selection panel grow vertically. Consider moving the primary timeline commands
from the bottom bar into the toolbar/View menu; Apple reserves bottom bars for
small amounts of contextual status. This follows Apple's
[window](https://developer.apple.com/design/human-interface-guidelines/windows)
and [toolbar](https://developer.apple.com/design/human-interface-guidelines/toolbars) guidance.

Acceptance: at 850 and 900 points, with inspector both open and closed, all
selection bounds and duration remain readable; long chart names and units do
not hide the title or make controls ambiguous.

### 2. P1 — Arbitrary selection bounds still require a pointer gesture

**Confirmed menu coverage, supported by source.** Select Visible Time Range
works, and Boundary offers four tracking modes. Neither provides editable start
and end values or a duration field. The interactive ruler and gesture overlay
are hidden from accessibility; the alternative UI cannot express the same
precise interval that dragging can. Pan/zoom plus selecting the viewport is not
equivalent to independently editing selection edges.

See `Sources/PipePlotApp/SelectionInspector.swift:100`,
`Sources/PipePlotApp/TimelineLocators.swift:129`, and
`Sources/PipePlotApp/PlotCanvas.swift:104`. Add an Edit Selection command with
labelled start/end and duration controls, validation, and explicit tracking
state. Retain the existing gesture conveniences. Apple's
[accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)
requires alternatives to gestures; its
[chart guidance](https://developer.apple.com/design/human-interface-guidelines/charts)
calls for accessible chart interaction.

Acceptance: keyboard-only and VoiceOver users can create and adjust a precise
interval and obtain the same statistics/forecast as a pointer user, without
changing the viewport just to edit the interval.

### 3. P1 — Derived plots expose their existence, but not their data

**Source-confirmed; derived plotting was not exercised in this native run.**
The smoothed and rate canvases expose a name, estimate count, and calculation
provenance. They expose neither numeric values/trends nor axis bounds, and have
no chart descriptor. The raw chart's descriptor cannot substitute for these
different quantities. See `Sources/PipePlotApp/DerivedSeriesView.swift:159`.

Provide descriptors for both derived plots, preserving units, timestamps,
discontinuities, and the distinction between estimates and measurements. At
minimum supply useful bounds and a numeric/trend summary. Apple explicitly
requires accessible information for every chart; Audio Graphs are an optional
enhancement, not the only valid implementation. See
[Charts](https://developer.apple.com/design/human-interface-guidelines/charts).

Acceptance: a user can determine the rate's sign and magnitude and navigate
representative derived values without seeing either plot.

### 4. P2 — Small fixed chart text falls below Apple's macOS minimum

**Visible in the app and source-confirmed.** Extrema, latest values, NOW,
locator/interval labels and derived-axis labels include fixed 9-point fonts.
Apple recommends 13-point default text and a 10-point minimum on macOS, and
support for enlarged text. The application has no chart text-size control.
See `Sources/PipePlotApp/PlotCanvas.swift:262`, `:375`, `:397`,
`Sources/PipePlotApp/TimelineLocators.swift:58`, `:91`, and
`Sources/PipePlotApp/DerivedSeriesView.swift:154`.

Raise the minimum and add scalable chart typography with collision/layout
recalculation. Also review the explicit 18×18 selection tracking button and
18-point-wide drag handle against the accessibility page's macOS-specific
20×20 minimum; measure effective hit regions before claiming a target-size
failure. Do not apply the general touch-oriented 44-point rule indiscriminately
to desktop controls. See [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).

Acceptance: labels remain legible at standard size and an enlarged setting,
without obscuring data; small custom controls have adequate hit regions.

### 5. P2 — Statistics lack per-stream accessibility grouping

**Observed in the native accessibility tree, supported by source.** Three cards
were exposed as one text sequence beginning “temperature pressure flow”, then
all three sample-count rows, then all three min/max/mean rows. The association
between a stream and its statistics is conveyed visually but lost in that
reading order. Only the outer Selection inspector is explicitly grouped.
See `Sources/PipePlotApp/SelectionInspector.swift:188`.

Group each statistic card with its stream name and values, or give it one
coherent accessible summary. Preserve a reachable Retry action in error states.
Apple's [VoiceOver guidance](https://developer.apple.com/design/human-interface-guidelines/voiceover)
specifically calls for grouping related content rather than reading parallel
visual rows across unrelated items.

Acceptance: VoiceOver visits one stream's complete statistics before the next;
verify spoken output as well as the accessibility tree.

### 6. P2 — Series differentiation and palette adaptation are incomplete

**Observed default rendering plus source inspection.** Raw series use the same
solid stroke and circular marks; identity largely depends on color. Names on
some extrema/latest labels help, but are conditional, collision-suppressed, or
absent, so they do not consistently identify every trace. The fixed nine-color
palette has no appearance or Increase Contrast variants. See
`Sources/PipePlotApp/PlotCanvas.swift:200` and `:478` and
`Sources/PipePlotApp/StreamLegend.swift:29`.

Add stable non-color distinctions (dash/marker patterns or reliable direct
labels), reflect them in the legend, and validate colors against actual light,
dark, and increased-contrast backgrounds. Do not assume system appearance
adapts explicit hex colors. No rendered contrast ratios were measured in this
review, so this is not a claim that every palette color fails contrast. See
[Color](https://developer.apple.com/design/human-interface-guidelines/color).

Acceptance: overlapping streams remain identifiable without color; text and
essential graphics meet the chosen contrast targets in each appearance.

### 7. P2 — Common commands are missing from the menu bar

**Confirmed in native menus and source.** View contains only tab/full-screen
commands. Show/Hide Chart Settings, pan/zoom, fit selection, Follow Now and
time-range commands are absent. Export Chart/Selection CSV are available in
content controls but not File. See
`Sources/PipePlotApp/SettingsAndCommands.swift:403`.

Add contextual File/View commands, maintain disabled entries when unavailable,
and reflect the inspector's show/hide state. Give commands a clear selected-chart
target that can also be chosen without clicking the chart body; the current row
selection uses `onTapGesture` in `Sources/PipePlotApp/SessionWindow.swift:459`.
This follows Apple's [menu-bar guidance](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
and makes commands easier to discover and invoke from the keyboard.

## What works well

- Native window chrome, toolbar, inspector, standard fields and menus provide
  a familiar foundation. Inspector fields expose descriptive labels and headings.
- The raw chart has a substantial `AXChartDescriptor` implementation: time and
  value axes, units, series, discontinuities, guide/selection summaries and
  bounded representative data. It discloses downsampling rather than pretending
  to enumerate all observations. Native AX inspection confirmed chart summaries.
- Menu-based stream movement worked; Command-Z restored the stream and removed
  the newly created chart. This supplies a useful alternative to drag and drop.
- Value-guide entry focused the value field, Tab reached its label, and Return
  created the guide. Invalid/empty values initially disabled Add Guide.
- Native chart and stream menus provide useful contextual actions with labels.
  Their snapshot construction is designed to preserve a stable open menu while
  capture updates the underlying content.

## Verification limits and follow-up

This run did not perform a spoken VoiceOver/Audio Graphs session, enable Full
Keyboard Access, exercise Switch Control/Voice Control, measure contrast with
Accessibility Inspector, or test light appearance, Increase Contrast, Reduce
Motion, enlarged text, or every save/error/notification flow. An AX tree and unit
tests are evidence of implementation, not proof of end-to-end assistive use.

After fixing the findings, repeat the native window-size scenarios and complete
those assistive-technology checks. Prioritize selection parity and derived data
access before claiming comprehensive chart accessibility.

## Build and release-change checks

The accompanying pre-existing release changes were reviewed before committing:

- `just build`: passed for the Release application and CLI.
- `swift test`: 91 tests passed, zero failures.
- `PIPEPLOT_AD_HOC=1 scripts/package-release.sh 0.0.20261113`: passed;
  verified the mounted DMG, app version, arm64 binaries, signatures, Applications
  link, and bundled `pp --help`. Output remains under the ignored `.build/` tree.
- Compiled the actual transport source in a temporary executable harness:
  containing-app discovery passed both directly as bundled `pp` and through a
  `pipeplot-pp` symlink.
- Generated a cask using a temporary correctly named DMG fixture; Ruby syntax,
  expected CLI link name, and macOS requirement passed. This does not establish
  a real Homebrew installation or a published release.
- Shell syntax and `git diff --check`: passed.
- Focused Xcode tests for accessibility, inspector, session commands, guide
  interaction and snapshot menus built, but stalled without test results. The
  run was interrupted after approximately five minutes; no app-test pass is
  claimed.

Developer ID signing, notarization, GitHub workflow execution, clean-machine
Gatekeeper behavior, and Homebrew install/uninstall were not exercised. Nothing
was published or pushed during this review. The HIG findings remain unfixed.
