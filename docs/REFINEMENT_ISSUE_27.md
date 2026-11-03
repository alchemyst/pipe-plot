# Swift refinement #27: focused session commands

The session window publishes its open, nondeleted `SessionModel` with `focusedSceneValue`. `PipePlotCommands` reads it through `@FocusedValue(SessionModel.self)`. The previous global `activeSessionID` command route is removed. The focused model supplies the selected visible chart (or the last visible chart when nothing is selected). New Chart Below, Add Value Guide, and Add Time Guide at Now use that one context; Cmd-Shift-D, Cmd-Option-G, and Cmd-Option-T are attached to their visible menu items. The chart row's hidden shortcut-only buttons and the picker’s duplicate Cmd-N registration are gone. Window-local letter navigation ignores command, option, and control modifiers, so Cmd-Shift-D cannot also pan the chart.

The value-guide command requests the existing guide editor on the selected row. The scroll view brings an offscreen selected row into view so it can consume the request. The request can be taken once and clears if the chart becomes hidden or the session closes or moves to Trash. The native chart Guides menu uses the same request. Time-guide commands use the session clock, including its stopped time.

| Focus state | Contextual commands | Undo/Redo |
| --- | --- | --- |
| Open session window, no text editing | New chart enabled; guide commands require a visible chart | Session history for that focused session |
| Session picker, Settings, or no session window | Disabled because no session scene publishes a value | Native text undo if a text editor has it; otherwise disabled |
| Text editor in a session | Disabled to preserve editing shortcuts | Text editor's `UndoManager` |
| Closed or trashed session | Disabled even if a stale focused object is observed | Disabled |

New Session and Open Saved Sessions remain global commands. Issue #28 owns native `UndoManager` integration; this ticket keeps the existing session history and text-editor undo behavior.

## Apple API basis

Checked Apple documentation on 2026-11-03: [Building and customizing the menu bar with SwiftUI](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui) shows an `Observable` object published with `focusedSceneValue` and read by `@FocusedValue` in `Commands`. Apple's [focusedSceneValue](https://developer.apple.com/documentation/swiftui/view/focusedscenevalue%28_%3A%29) documentation defines scene-wide scope; [FocusedValue](https://developer.apple.com/documentation/swiftui/focusedvalue) follows the active focus scope. [CommandMenu](https://developer.apple.com/documentation/swiftui/commandmenu) supplies the native menu items. These APIs are available in the installed Xcode 27.2 / Swift 6.4.2 toolchain and macOS 27.0 deployment target.

## Validation and limits

`SessionCommandTests` exercise both directions of focus routing between two session models, selected-chart insertion order, one guide request consumed once, one time-guide mutation, undo/redo targeting, and disabled behavior for picker/no focus, text entry, closed sessions, hidden charts, and Trash. They also verify that modified command keys do not enter window-local navigation and that AppKit text responders are recognized. They use temporary stores. The hosted test process does not mount `PipePlotApplication`'s actual SwiftUI menu bar, so physical keyboard dispatch, menu highlighting, and focus transitions between live session windows and Settings were not directly exercised. Their availability follows the focused-scene API contract and is still a native UI acceptance item; the unit tests do not prove it.

`just test` was first run twice at its default `.build/xcode` location. Its package phase passed each time: 79 core, 12 transport, and 4 CLI tests. In both attempts Xcode launched the test host but started no hosted test case after more than two minutes; only those exact temporary test processes were stopped. Sampling one showed the main thread blocked in dyld dependency loading at `__open`, before app or test code. A default-location `just strict-build` passed package tests and the Xcode app/test build with warnings as errors; there were no project-source diagnostics. Xcode emitted its CoreSimulator version mismatch and App Intents metadata notices.

A clean Xcode derived-data directory under `/tmp` removed the launch stall. That first full hosted run then reached an existing drag-type test that read the source `Config/Info.plist` under Documents and blocked in `Data(contentsOf:)` at `__open`. The test now checks `Bundle.main.infoDictionary` instead, verifying the exported type declaration in the built app itself. A final clean `build-for-testing` with warnings as errors and `test-without-building -parallel-testing-enabled NO -only-testing:PipePlotAppTests` passed all 45 hosted tests (2 opt-in skips), including the three new command tests and the revised drag-type test.

The `justfile` now accepts `PIPEPLOT_XCODE_DERIVED_DATA` for its test and strict-build Xcode steps; its default remains `.build/xcode`. With `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt`, the prescribed `just test` passed all package tests and all 45 hosted tests (2 opt-in skips). `just strict-build` passed at that same location, with no project-source diagnostics; `just format-check` and `git diff --check` also passed. Documents privacy gating is a possible explanation for the earlier `__open` stalls, but was not proven. No app was installed and no live saved data was used.
