# Native UI session — 2026-10-31

Release builds installed in `~/Applications/PipePlot.app` with the matching `~/.local/bin/pp`. Checks use fresh test sessions; existing captured sessions are retained.

## #16 — menus

Before the change, the original SwiftUI stream menu opened during `pp --test 2`, but clicking Color did not retain a visible submenu while live chart/clock updates continued. This reproduces the reported symptom; it does not isolate whether sample, clock, or hover invalidation was its sole cause.

Chart actions, stream actions/colors, guide creation/colors, selection boundaries, stream inclusion and forecast controls now materialize native NSMenu trees once per opening. View updates replace only the builder for the next opening. They cannot rebuild an already tracked menu. Capture and display refresh remain active. Stream secondary-click actions use the same snapshot policy.

Native observation: Color remained open and selected through at least ten seconds of live sample arrivals and advancing Now labels, then Color 7 could be activated. Keyboard navigation/activation was also exercised. Broader menu checks are recorded below as the associated controls are exercised.

Final menu build: secondary-click opened stream actions. With the menu open from 12:23:18 through 12:23:33, Down selected Rename, Up wrapped to Color, Right opened its submenu, Down twice selected Color 3, and Return activated it. Now advanced throughout. `swift test` passed (native window measurement opt-in skipped); release build/install passed.
