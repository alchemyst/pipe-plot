# Refinement issue #33: native window toolbar and chart inspector

## Change

The session window now puts New Session, Add Chart, Chart Settings and session actions in native toolbar items. The chart list has a labeled drop target for adding a chart from a dragged stream; the existing chart insertion targets remain. Menu and keyboard chart actions still route through the focused `SessionCommandTarget`. The toolbar's explicit Add Chart action uses the focused open session without sampling the AppKit text responder, because responder changes after hiding the inspector do not invalidate toolbar availability.

The selected chart's axis unit, number scale, zero inclusion, relative value origin, Y range, relative time origin and guide notifications are in a native inspector. The Settings scene contains only storage information. Opening the inspector pins the current fallback chart as the selected chart, so its title and row highlight agree until the user chooses another chart. The inspector's per-chart subtree has chart identity, and editable unit and Y-range text stays in `SessionModel` keyed by chart ID through snapshot updates, chart switches, hiding, and occlusion. Guide notification text similarly stays keyed by guide ID within its session. A save clears only the affected dirty fields after the model reports successful persistence; failed writes retain them for retry. Text field writes that match the latest saved value do not create a dirty draft, and refresh clears drafts that have become equal to saved settings. Guide alert changes continue to merge into the current guide so another editor's label or coordinate edit is preserved. Chart settings and guide edits retain the existing domain undo actions.

An opt-in acceptance fixture uses only `PIPEPLOT_ACCEPTANCE_DATABASE=/tmp/pipeplot-acceptance-*/acceptance.sqlite`, validates an existing temporary directory, seeds two sessions with samples and guides, and gives the app a unique short `/tmp` socket. Invalid fixture paths stop launch instead of falling back to live data. Ordinary launches still use the normal app model. The fixture is for checking actual WindowGroup toolbar and inspector behavior, which an `NSHostingView` alone cannot establish.

## Verification

- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just test`: 100 package tests passed (84 Core, 12 Transport, 4 CLI); 69 hosted app tests passed, with two opt-in tests skipped. The new app tests cover per-chart draft retention, independent unit/range saves, semantic undo, invalid range, persistence failure and retry, guide alert merge, matching persisted text after refresh, and active native text editing while switching charts and refreshing. The combined hosted count includes the narrow Undo menu repair tests.
- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just strict-build`: passed (`** TEST BUILD SUCCEEDED **`).
- `just format-check` and `git diff --check`: passed.

## Native acceptance

The actual app was launched with the isolated fixture and unique temporary socket. In both dark and light appearances at a 900 × 632 window (580-point content height), the toolbar, chart and inspector were readable; the notification controls were visible. Hiding and reopening the inspector while editing preserved the unsaved unit. After hiding it, Add Chart remained enabled and created Chart 2. Returning to Chart 1 restored its unsaved draft. The Window menu showed both seeded fixture sessions; switching sessions showed the voltage chart's `mV` unit without the pressure chart's draft. The Settings scene showed only Storage.

The final native Undo check covered the related focused bridge repair: with a field focused but unchanged, Undo and Redo were disabled; typing offered Undo Typing, and menu Undo restored the field text without changing the saved chart unit. Hiding the inspector exposed Undo Axis Settings for the saved chart edit. Native menu and keyboard semantic Undo/Redo both worked, and remounting after save/undo/redo kept Save Unit disabled when text matched the saved unit. The bridge repair and its independent tests are documented in `REFINEMENT_ISSUE_28.md`.

The hosted `NSHostingView` test used an 850 × 580 window for active text editing and chart switching. This establishes draft ownership at that host size, not exact 850-point `WindowGroup` layout. Actual Scene minimum-width resizing, physical stream drag/drop, VoiceOver, notification authorization and installed-build behavior were not exercised in this pass.
