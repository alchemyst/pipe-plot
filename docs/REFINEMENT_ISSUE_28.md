# Swift refinement #28: native session undo

`PipePlotStore` remains the sole semantic undo history. It keeps reversible domain records per session, retains the newest 200 actions, and rolls back failed persistence. `SessionUndoManager` gives each session one stable AppKit manager that reads the store's current action names and availability and forwards undo/redo to store replay through `PipePlotAppModel`. Undo registration is disabled in that manager, so AppKit does not build a second action stack. Failed edits, no-ops, and failed undo/redo therefore leave native availability in sync with the store. Edits made outside a focused view are visible immediately because the manager reads the store when queried.

`SessionWindowObserver` installs the manager through `NSWindowDelegate.windowWillReturnUndoManager(_:)`. This supplies both the window's native undo action and SwiftUI's read-only `undoManager` environment value. The delegate proxy forwards other optional callbacks to the prior scene delegate and restores it when the observer detaches. Its `nonisolated(unsafe)` weak prior-delegate reference is assigned only at initialization; the nonisolated `NSObject` forwarding methods read it during AppKit's main-thread delegate callbacks. Hosted tests check forwarding and restoration. A content-view undo responder was rejected during development because it captured the window field editor's undo action. With the window route, an active text field uses its own editor manager.

The custom Undo/Redo command group, first-responder text-manager lookup, and global editing/undo notification revision observers are removed. AppKit's ordinary Edit commands now use the active responder and window manager. Core records for stream reassociation and forecast-target creation already group each compound edit into one semantic action; the bridge presents each as one named native action. Core action names now distinguish add/edit/delete guides, add/edit/delete time guides, and chart hide/restore.

## Validation

All tests use temporary stores; no live saved data was opened and no app was installed.

| Command | Result |
| --- | --- |
| `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just test` | Passed: 79 core, 12 transport, 4 CLI, and 54 hosted app tests; 2 hosted opt-in skips. |
| `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just strict-build` | Passed package tests and Xcode app/test build with warnings as errors. |
| `just format-check` and `git diff --check` | Passed. |
| `xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/pipeplot-issue27-xcode.YP4Sbt -only-testing:PipePlotAppTests/SessionUndoManagerTests test -quiet` | Final targeted run passed 9 of 9 hosted tests after the last focus-wait and menu assertions. |

Hosted native tests exercise synthetic Cmd-Z and Shift-Cmd-Z key equivalents targeted at each of two `NSWindow` instances, menu enablement before and after undo/redo, an actual SwiftUI `TextField` receiving the session manager in its environment while its field editor keeps local undo, and an AppKit `NSTextField` field editor. They also cover edits made outside focus, failed edits and replay, no-ops, 200-action retention, independent session histories, close/reopen, Trash/restore, and single-step reassociation and forecast-target actions.

The hosted key-equivalent test targets the windows explicitly. It does not exercise untargeted dispatch from the app's actual SwiftUI Edit menu or physical keyboard input. Close/reopen coverage checks model and manager identity in the hosted process; a separate app relaunch was not exercised. These remain native UI acceptance checks. Xcode also printed a CoreSimulator version notice and an App Intents metadata notice; neither failed the macOS test or build.
