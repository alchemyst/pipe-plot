# Stream drag and drop — issue #8, 2026-11-01

Branch: `codex/issue-8-stream-drag-drop`.

The stream payload is declared as an exported Uniform Type in `Config/Info.plist`
and passed to SwiftUI destinations as a `UTType`. The first manual test confirmed
that the source drag image followed the cursor but neither merge nor insertion
responded. Investigation found the previous undeclared pasteboard identifier
resolved to `nil` through `UTType`, preventing type matching at the destinations.
After rebuilding and restarting, the user repeated the requested split/merge
check and confirmed: “It works now.”

The existing chart merge outlines and before/between/after insertion markers are
retained. A native three-line handle now starts the drag independently of the
legend's horizontal scrolling and menu button. Its AppKit drag-end callback clears
the shared preview on success, Escape, or an outside drop. Add Chart also displays
a targeted outline and uses a visible insertion anchor.

Destinations accept the app's private stream payload instead of arbitrary text.
The hover preview and commit share the same validation: one known, visible stream
in the same undeleted session; a different visible merge destination; or a valid
visible insertion anchor. Invalid input does not mutate metadata or undo history.
Only one destination can display feedback at a time. Keyboard move/insert menus
continue to call the same model operations.

## Automated checks

- Debug app build passed.
- `swift test`: 60 package tests passed.
- All app tests passed through a temporary Swift package harness in
  `.build/issue-8-harness`: 22 tests, one opt-in window measurement skipped, zero
  failures. The harness uses the actual app and test source directories, excludes
  only the application entry point, and links the repository's core/transport
  products.
- `StreamDropTests` verifies destination rejection, preview reset and invalidation,
  insertion at the first/middle/last positions, last-stream collapse, identity and
  live capture through moves and undo/redo, inherited and explicit style, retained
  chart units/guides, persisted merge results, and resolution of the registered
  payload type. Existing core insertion tests
  also cover persistence and atomic insertion replay with later capture.
- `git diff --check` passed.

Two Xcode test launches stalled before test execution. A sample of the isolated
retry showed the host blocked in dyld dependency loading (`__open`), before the
application entry point. These attempts are not counted as test passes. The
standalone harness executes the app assertions but does not validate hosted test
launching.

## Native pointer acceptance

The development build displayed the new handles in Session 40. Before the type
registration fix, computer-use drags from both the original legend and the new native handle to the bottom
separator did not produce an accepted drop. A subsequent destination click also
left the layout unchanged. This is inconclusive about whether the remaining
failure is in the bridge or the app, consistent with the prior native session.
The user then confirmed the drag image followed the cursor but destinations did
not respond. This is an observed application failure in that build, not merely a
bridge limitation. After the type declaration fix, the user was asked to retry
split and merge, checking that a preview appeared before release, and confirmed
“It works now.” This establishes the reported pointer failure is resolved.

Undo/redo, invalid destinations and preview cleanup are covered by automated
assertions. The user's brief confirmation does not independently establish that
they exercised every cancellation and invalid-drop variant. The full native
regression matrix remains useful for subsequent checks:

1. With two live streams in one chart, drag a handle to the top/bottom separator.
   Check the insertion marker, new row, and continuing capture in both rows.
2. Drag into another chart. Check its outline/merge label and the moved legend.
   Move the last stream and confirm its empty source row collapses.
3. Undo and redo each move once. Check the whole row operation and later samples.
4. Hover over a valid target, then press Escape or drop outside. Check all
   feedback clears and layout/undo history stays unchanged.
5. Try the source chart, another session and external text. Check they do not
   advertise a valid move. Repeat using Add Chart and keyboard menu equivalents.
