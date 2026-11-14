# Releasing PipePlot for macOS

The distribution is an Apple Silicon DMG for macOS 27 or later. It contains
`PipePlot.app` and an Applications shortcut. Drag the app onto Applications,
then open the installed copy. Use **PipePlot → Install pp Command…** to link
the bundled CLI into `~/.local/bin`. Replacing the app at the same location
updates the CLI too. To undo the menu installation, remove the link it created
at `~/.local/bin/pp`.

## One-time signing setup

For normal Gatekeeper behavior, enroll in the Apple Developer Program and
create a **Developer ID Application** certificate with its private key. A
Developer ID Installer certificate is not needed for a drag-to-Applications DMG.
See Apple's [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
guides.

For GitHub Actions, export the certificate and private key from Keychain Access
as a password-protected .p12. In the repository's **Settings → Environments**,
create a `release` environment and restrict it to trusted release tags
(e.g. `v*`). Configure:

| Environment setting | Value |
| --- | --- |
| Secret `DEVELOPER_ID_P12_BASE64` | Base64 of the .p12 (`base64 -i DeveloperID.p12 \| tr -d '\n'`) |
| Secret `DEVELOPER_ID_P12_PASSWORD` | Password for the .p12 |
| Secret `APPLE_ID` | Apple Account email for notarization |
| Secret `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that account |
| Variable `APPLE_TEAM_ID` | Apple Developer Team ID |
| Variable `DEVELOPER_ID_APPLICATION` | Signing identity, e.g. `Developer ID Application: Example (TEAMID)` |

The workflow imports the identity into a temporary runner keychain. Keep the
private key and credentials out of the repository.

## Build on GitHub

After the workflow is on the default branch, tag the commit to ship and push
the tag. Run **Package macOS release** against that tag:

```sh
git tag v0.2.0
git push origin v0.2.0
gh workflow run release.yml --ref v0.2.0
```

The job uses GitHub's [Xcode 27 preview runner](https://github.com/actions/runner-images/issues/14404)
and creates a draft release with the notarized DMG and its SHA-256 checksum.
Review the generated notes and use the smoke check below before publishing.
If the preview runner is unavailable or the build fails there, use the same
packaging script locally.

## Build on your Mac

Use Apple Silicon and an Xcode toolchain with the macOS 27 SDK, plus the icon
build tools listed in the [development guide](DEVELOPMENT.md). Create a notarization profile once; the
command prompts for the credentials if they are omitted:

```sh
xcrun notarytool store-credentials pipeplot-release
```

From a clean checkout of the commit tagged `v0.2.0`, build the signed DMG:

```sh
export PIPEPLOT_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)'
export PIPEPLOT_NOTARY_PROFILE=pipeplot-release
just release 0.2.0

dmg=.build/distribution/v0.2.0/PipePlot-0.2.0-macos-arm64.dmg
gh release create v0.2.0 "$dmg" "$dmg.sha256" --verify-tag --draft --generate-notes
```

The tag must already be on GitHub for the last command. If you only want to test
packaging locally, run `PIPEPLOT_AD_HOC=1 just release 0.2.0` with both signing
variables unset. It produces a separately named `-adhoc.dmg` and checksum for
local testing. The script mounts the finished DMG, verifies the bundle and
binaries, and runs `pp --help` before moving the outputs into place.

## Publish the Homebrew cask

Create a public GitHub repository named **`alchemyst/homebrew-tap`**. After
publishing the GitHub release, use its final DMG (download it if Actions built
it) to generate the cask in a local checkout of the tap:

```sh
dmg=PipePlot-0.2.0-macos-arm64.dmg
gh release download v0.2.0 --pattern "$dmg"
mkdir -p /path/to/homebrew-tap/Casks
./scripts/render-cask.sh "$dmg" > /path/to/homebrew-tap/Casks/pipe-plot.rb
```

Commit and push `Casks/pipe-plot.rb`. Users can then run:

```sh
brew install --cask alchemyst/tap/pipe-plot
```

The [cask](https://docs.brew.sh/Cask-Cookbook) installs the app and links the
bundled CLI as `pipeplot-pp` in Homebrew's bin directory. That name avoids
colliding with other tools named `pp`, including the one shipped by Homebrew's
NSS formula. Use `pipeplot-pp` in the same way as `pp`, or use the app menu
to get the short name in `~/.local/bin`. Homebrew manages its own link during
upgrade and uninstall. There's no separate formula or installer. For subsequent
releases, regenerate the cask from the new DMG and push it to the
[tap](https://docs.brew.sh/Taps). Keep published DMGs immutable so existing
checksums remain valid.

## Smoke check

On a clean macOS 27 Apple Silicon machine or VM, download the release through
a browser and mount it. Drag the app to Applications, eject the DMG, and
confirm the installed app opens normally. Try **Install pp Command…** and run
`printf '1\n2\n3\n' | pp` to confirm the points appear. Separately test the
Homebrew path with no existing PipePlot app or `pp` on PATH: install the cask,
run the same pipeline with `pipeplot-pp`, uninstall the cask, and confirm its app and link are gone.
