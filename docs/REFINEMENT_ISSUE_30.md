# Refinement issue #30: chart editor presentation

## Changes

- Moved the selection inspector, chart header, stream legend, and guide manager into cohesive views. Header and legend menus still build live snapshot actions from the current chart and session. Each view owns its rename or editor draft rather than receiving a long list of row callbacks.
- Replaced the guide manager's three overlapping presentation flags with one sheet request and one sheet-owned mode: guide list, new value guide, or edit guide. Text and time drafts remain in the sheet across sample refreshes and display suspension. Back leaves the draft without a store edit; Add and Save are the only detail actions that commit. Existing alert settings remain independently saved, and detail saving still merges into the current guide through `updateGuideDetails`.
- Paired the forecast target's stream and training selection in one request. Its sheet owns the value and label draft. Legend rename, derived-series and reassociation sheets also use one optional route. Removed unnecessary `@Bindable` model wrappers; the session model keeps the binding used for selected chart.
- Left gesture preview and committed navigation/guide mutations separate. The existing preview ownership already kept the row callbacks focused; a new gesture controller would add plumbing without simplifying them. The chart layout and toolbar structure remain unchanged.
- Corrected time-guide draft rounding at a millisecond carry and before the Unix epoch. The editor rounds the complete timestamp before deriving the displayed minute and seconds.

## Validation on 2026-11-03

- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just test`: passed; 4 CLI, 12 transport, 79 core package tests; 62 hosted macOS app tests, with 2 opt-in skips. The run includes guide, forecast, annotation, derived-series, gesture/responder and new presentation tests.
- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just strict-build`: passed with strict concurrency and fatal warnings for package and hosted app/test targets.
- `just format-check`: passed.

### Native hosted evidence

`ChartPresentationTests.testNativeGuideDraftSurvivesSampleRefreshAndOcclusionWithoutSave` mounts the real guide manager in an `NSHostingView`, types `42` into its AppKit field editor, ends editing, appends a sample, refreshes the model and replaces the hosting root with the same sheet request, then suspends and reveals the display. The field still reads `42`; the saved guide remains at its original value. The focused mode tests cover Back without commit, draft survival during capture, explicit detail save, time input validation, and before-epoch/millisecond carry.

This hosted test exercises model display suspension, not a real WindowServer occlusion event. Native keyboard Escape and pointer interaction with the new sheets, VoiceOver, notifications, and sleep/wake were not manually checked. The opt-in sustained acceptance and broader #14 native matrix were not repeated. No live saved data was touched and no build was installed.
