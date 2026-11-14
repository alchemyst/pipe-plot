# Developing PipePlot

[Back to the project](../README.md) · [Contributing](../CONTRIBUTING.md)

## Build and install

Requires Apple Silicon, macOS 27, Xcode's Swift toolchain, and [just](https://just.systems/). Building the app's icon also requires POV-Ray, Python 3 with Pillow, and macOS `iconutil`. No third-party Swift packages are required.

```sh
just build
just test
just install
```

Open `PipePlot.xcodeproj` and select the shared **PipePlot** scheme to build, run, test, profile, or archive the app in Xcode. The app target links the local Swift package's `PipePlotCore` and `PipePlotTransport` products. Xcode processes the tracked `Config/Info.plist`, renders and copies the icon, and signs the app with a local ad-hoc identity. App unit tests belong to the Xcode project; shared-code and CLI tests remain in SwiftPM.

`just build` builds the Release app and the SwiftPM `pp` CLI; `just bundle` is an equivalent command. The app is written to `.build/xcode/Build/Products/Release/PipePlot.app`. Xcode tracks changes to the app sources, plist, and icon inputs, reusing unchanged outputs. `swift build -c release --product pp` builds only the CLI.

`just format` formats `Package.swift` and the Swift files under `Sources/` and `Tests/`. `just format-check` checks the same files without modifying them and exits unsuccessfully on formatting findings. Both use the checked-in `.swift-format` configuration and the formatter bundled with the selected Xcode toolchain through `xcrun`; use Xcode 27.2 (Apple Swift 6.4.2, `swift-format` 6.4.4) for reproducible results. Check the selection with `xcodebuild -version` and `xcrun swift-format --version`; `DEVELOPER_DIR` can select a different Xcode installation. The style uses four spaces and a 120-column target, with semicolons expanded into separate statements. Declaration and control-flow rewrite rules are disabled to keep formatting mechanical. Generated files, the Xcode project file, and scripts/design assets are outside the formatting scope.

`just test` runs both the package tests and the Xcode app tests. `just check` additionally runs the independent transport regression tests. The smoke and cold-pipeline scripts in `scripts/` exercise an installed app and create sessions, so they are not part of `just check`. Hosted app tests run without opening the user's database, starting IPC, or restoring application windows.

`just test` and `just strict-build` use `.build/xcode` for Xcode derived data by default. Set `PIPEPLOT_XCODE_DERIVED_DATA` to an absolute directory to use a separate build location, for example `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-xcode just test`.

`just install` builds and installs an ad-hoc signed `~/Applications/PipePlot.app` and `~/.local/bin/pp` together. Add `~/.local/bin` to your shell's `PATH` if it is not already present. Building alone does not update either installed copy; run `just install` again after changes.

`just icon` regenerates standalone icon artwork in `.build/icon/`; see [the icon build notes](../design/icon/README.md). App builds render their own copy in Xcode's derived files directory. Generated assets and local Xcode state are ignored by Git. The `justfile` remains the command runner; the build uses Xcode and SwiftPM directly, without Make.

## Architecture and validation

`Sources/PipePlotCore` owns parsing, storage and reversible model edits. `Sources/PipePlotTransport` owns local socket framing and discovery. `Sources/pp` is the CLI; `Sources/PipePlotApp` is the native interface. Raw observations are separate from presentation edits so undo does not restore stale sample arrays.

Statistics and straight-line regression share an Accelerate/vDSP implementation. Centered moments are computed in batches of at most 1,024 observations and merged, keeping range-query working memory bounded while fitting actual receipt timestamps. Median selection remains in SQLite for stored histories. Opt-in smoothing and first-derivative panels are available from each stream’s **Smoothing and derivative…** action. Choose a fixed resampling interval, centered window and gap policy; the default weighted Savitzky–Golay filter produces delayed estimates in value/second without changing raw data or statistics. [Derived analysis](DERIVED_SERIES.md) documents interpolation, unavailable downsampling, edge latency, reproducible comparisons and the sustained engine benchmark.

[Window visibility validation](WINDOW_VISIBILITY_VALIDATION.md) records the native four-window CPU/query measurement and its reproduction command.

[Latest acceptance execution](ACCEPTANCE_2026-11-01.md) records the native, failure, sleep/wake and resource checks, with explicit remaining limits and reproduction scripts.

[Native UI session evidence](NATIVE_UI_SESSION.md) records the issue fixes, all 40 scenario outcomes and outstanding pointer/lifecycle/resource checks.

[SPEC.md](../SPEC.md) records the product requirements. [Validation scenarios](VALIDATION.md) describe the automated and manual checks needed before calling every interaction production-ready.

The controls and behaviors above describe the current implementation. The documented manual interaction and visual acceptance scenarios have not all been exercised; consult the validation guide before treating the UI as fully verified.
