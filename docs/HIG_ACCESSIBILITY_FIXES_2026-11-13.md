# HIG and accessibility fixes — 13 November 2026

Implements the seven findings in [the original review](HIG_ACCESSIBILITY_REVIEW_2026-11-13.md), using the Apple sources linked there. The original report remains a record of the pre-fix application.

| Finding | Change | Validation |
| --- | --- | --- |
| 1. Narrow layouts | Separate wrapping chart title/unit from actions; two-row timeline controls; intrinsically sized selection panel; constrain the chart scroll area to the actual window. | Native 900-point window with inspector open/closed, long chart title and unit, and selection visible. A 530-point panel hosting test covers narrower content. |
| 2. Precise selection | Session → Edit Selection and panel button; labeled exact timestamps, milliseconds, duration and four tracking modes; validation and one semantic selection commit. | Native keyboard entry of 18:57:25.000–18:57:30.500 produced a 5.5-second interval and 36 observations per stream without changing the viewport. Repeated with VoiceOver enabled. Tests cover modes, commit-time clock, invalid inputs and included streams. |
| 3. Derived accessibility | Smoothed/rate chart descriptors and numeric summaries with units, bounds, sign, extrema, timestamps, independent runs and estimate provenance. | Native AX tree exposed both plots and their numeric summaries; descriptor tests check values, gaps, failure states and bounded representatives. |
| 4. Typography and targets | Minimum 11-point custom chart text; 100/150/200% setting; scaled margins/tick density; common collision reservations for guide, NOW and peak labels; 24-point custom buttons/drag handle. | Native 100% and 200% with inspector and selection. The run caught and corrected label overlap and selection-panel overflow. Units remain in the header rather than being clipped in each Y-axis tick. |
| 5. Statistics grouping | Each card combines its stream name and complete statistics; Retry remains a separate control. | Native AX order is now temperature plus all its values, then pressure plus all its values, then flow. |
| 6. Non-color identity/contrast | Stable stream dash/marker combinations and matching legend keys; opaque chart background; appearance-adapted palette and custom colors. | Native light/dark and Increase Contrast inspection. Tests check all nine palette colors plus black, white and gray against the actual background constants: at least 5:1 normally and 7:1 with increased contrast. |
| 7. Menu commands | File CSV exports; View inspector, selected chart, navigation, zoom, fit, Follow Now, time ranges and text size. | Native menus, inspector show/hide state, selection CSV save panel, and switching the inspector from Chart 2 to Chart 1 through View → Selected Chart. Existing command-target tests cover focused-session isolation and text-editing guards. |

## Verification

- Release Xcode build with Swift warnings treated as errors: passed.
- Shared package/CLI tests: 91 passed.
- Focused app suites through `scripts/run-native-acceptance.sh`: 34 passed. These compile the real app sources, covering HIG accessibility, raw chart accessibility, inspector, session commands, guide interaction, snapshot menus, latest labels and annotation layout.
- Formatting and `git diff --check`: passed.
- An earlier broader standalone run hit the existing `StreamDropTests` bundle-declaration check: the standalone test executable has no app Info.plist. Independently verified that the built app exports `com.cactusdynamics.pipeplot.stream`, conforming to `public.data`. This is not recorded as an app-test pass.

Native testing used the Release app and synthetic review session 70 only. The session retains the long test chart name/unit, derived plots and an extra empty chart used to test targeting. System appearance, Increase Contrast and VoiceOver were restored to their original states; chart text size was restored to 100%.

## Limits

The native tool could inspect accessibility elements and edit fields while VoiceOver was enabled, but did not expose VoiceOver's spoken output; attaching to its feedback window timed out. Spoken statistics order and Audio Graph playback remain manual checks. AX descriptors and correct tree ordering are evidence of implementation, not a completed auditory acceptance test.

The native window was 900 points wide (580 points of chart content with the inspector). Attempts to drag its edge did not produce a verified 850-point window; the narrower automated panel test does not substitute for that exact full-window check. No Switch Control or Voice Control session was performed. Contrast tests validate color components against the opaque plot backgrounds, not pixel measurements of every antialiased element. Dense charts can still suppress optional labels, and the finite pattern set can repeat across streams.
