# Viewport acceptance

2026-11-04, macOS 27.2, isolated Release app and local `pp` producers. The native windows used a temporary SQLite store and a dedicated Unix socket.

## #39 · Fixed bounds through time navigation

Set Chart 1 to −5…15 and Chart 2 to 100…180 in the chart inspector. With both producers live, used Time Range → Show All History, Follow Now, Back, Forward, then dragged a fixed selection and pressed F. The first chart's inspector kept −5…15 through those actions. After F, the displayed time domain matched the selection. The Edit menu still showed Undo Selection.

After closing the window, both configured ranges were present in the on-disk metadata. The isolated native inspector reopen was not observed. The model regression checks both ranges after every action and after close/reopen, exact captured values, and that the next semantic undo removes the selection. It also exercises the same Frame Selection action as the menu and F.

## #42 · Smallest native window during capture

Opened Chart Settings in a fresh two-chart session, set Chart 1 to −5…15, and dragged a 5.2-second fixed selection. Both producers supplied a row approximately every 250 ms. Dragged the lower-right border inward and tried the bottom edge. The smallest observed frame was 850 × 632 points on the Retina display, including window chrome. The chart pane was 530 points wide with the inspector open. Double-clicked the title bar to re-expand.

At the minimum and after re-expanding, Now advanced, the same fixed selection was shown, and the chart inspector retained −5…15. The chart and selection remained visible with ordinary hover coordinates. After finishing the producers, queried SQLite in sequence order. Both streams contained exactly 311 rows and every value matched the corresponding producer's deterministic sequence.

The supported minimum still had usable plot geometry. Separate responder and layout tests exercise zero and one-point dimensions, suppress conversion and hit-testing, cancel an in-progress selection preview on collapse, and restore hover after expansion.
