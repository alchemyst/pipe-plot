# PipePlot 0.2.0 preview — 14 November 2026

[GitHub release](https://github.com/alchemyst/pipe-plot/releases/tag/v0.2.0)

This first downloadable release is explicitly an **unnotarized preview**.
The app and bundled CLI are ad-hoc signed. They are not Developer ID signed
or notarized by Apple. macOS may block first launch; the release notes link
to Apple's instructions. It is published as a GitHub prerelease.

## Artifact

- Source tag: `v0.2.0`, commit `f8b11679c71a0ed62a4349a34e1020d4b3bed791`.
- Build: Xcode 27.2 (27B52), macOS SDK 27.2, Apple Silicon.
- Command: `PIPEPLOT_AD_HOC=1 just release 0.2.0`.
- Asset: `PipePlot-0.2.0-macos-arm64-adhoc.dmg` (3,313,016 bytes).
- SHA-256: `e79cfc84c4658aeb3ae024132ef0252e2d76eaf6156a5c62d70b306c7b75d6d5`.
- A matching `.sha256` file is attached to the release.

The previous local 0.2.0 packaging experiment was preserved in
`.build/distribution/v0.2.0-before-20261114/` before rebuilding. No previously
published release asset was replaced.

## Verification

- `just check` passed: 91 package/CLI tests; 88 app tests passed, five opt-in
  tests skipped; independent transport regression checks passed.
- The skipped tests cover opt-in sustained/soak, research-prototype and native
  window measurements. This release run does not claim those checks passed.
- Packaging verified DMG integrity, version 0.2.0, ARM64 architecture, code
  signatures, the Applications link, and bundled `pp --help`.
- Copied the app out of the finished DMG and launched that app with its bundled
  CLI against an isolated database/socket. Ten numeric samples were stored
  with their expected values; the event command also completed successfully.
- Downloaded the uploaded GitHub assets and checked the checksum and byte-for-byte
  equality with the locally verified DMG before publishing.

Local logs are in `.build/release-validation/` (ignored by Git).
A clean-machine Gatekeeper installation, menu-based CLI installation on a
fresh account, and Homebrew installation were not verified. This release does
not add a Homebrew cask. Developer ID signing and notarization remain future
release work.
