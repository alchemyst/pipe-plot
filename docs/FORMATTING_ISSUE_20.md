# Swift formatting — issue #20

Validation date: 2026-11-01. Toolchain: Xcode 27.2 (27B52), Apple Swift 6.4.2, bundled swift-format 6.4.4.

## Changes

- Added an explicit `.swift-format` configuration, four-space indentation and a 120-column target. Only the semicolon style rule is enabled; declaration, API and control-flow rewrite rules are disabled.
- Added `just format` and non-mutating `just format-check`, using `xcrun swift-format` with explicit configuration and paths.
- Formatted the manifest and maintained production/test sources. Scripts, generated files and the Xcode project remain outside the scope.
- Documented toolchain selection and formatter usage in README.md.

## Formatting and behavior review

- `just format-check`: passed.
- `just format` repeated after formatting: SHA-256 hashes of all 71 Swift files unchanged.
- Strict lint on deliberately unformatted standard input: returned nonzero as expected.
- `git diff --check`: passed.
- Reviewed the source diff and compared baseline (`git show HEAD:<path>`) against formatted files using the toolchain's SwiftParser/SwiftSyntax token stream. All 71 files have identical tokens after excluding semicolons and collection trailing commas. Whitespace/trivia is excluded from this comparison. No intentional behavior, API, persistence or test-framework changes.

## Package tests

`just test` passed in the developer environment on 2026-11-01. Its package command, `swift test`, completed with:

- PipePlotCoreTests: 74 tests passed, zero failures.
- ppTests: 3 tests passed, zero failures.
- PipePlotTransportTests: 8 tests passed, zero failures.

## Hosted app tests

The second command in `just test` completed successfully:

```sh
xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath .build/xcode test
```

33 tests executed, two opt-in tests skipped, zero failures; `TEST SUCCEEDED`.
Xcode emitted an unrelated out-of-date CoreSimulator warning; the macOS test destination succeeded.
The test host bypasses the user's saved database, IPC startup and window restoration. No app was installed.

## Review and limits

Independently formatted all 71 committed baseline Swift files in a temporary directory with the checked-in configuration; every resulting file matched the working tree byte for byte. This confirms the source changes are exactly formatter output. A SwiftParser/SwiftSyntax comparison also found identical non-trivia tokens except semicolons and collection trailing commas.

Native pointer, VoiceOver, notification and sleep/wake checks were not repeated for this mechanical ticket; broader acceptance remains under #14. No follow-up is needed for this ticket's automated checks.

Formatter setup and mechanical formatting are recorded in separate local commits.
