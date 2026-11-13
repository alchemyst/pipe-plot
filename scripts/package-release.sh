#!/bin/bash
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

version="${1:-}"
[[ $# -eq 1 && "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die "Usage: $0 MAJOR.MINOR.PATCH"
[[ "$(uname -m)" == arm64 ]] || die "Run on Apple Silicon."
sdk="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${sdk%%.*}" -ge 27 ]] || die "Select Xcode with the macOS 27 SDK or newer."

identity="${PIPEPLOT_SIGN_IDENTITY:-}"
profile="${PIPEPLOT_NOTARY_PROFILE:-}"
if [[ "${PIPEPLOT_AD_HOC:-0}" == 1 ]]; then
    [[ -z "$identity" && -z "$profile" ]] || die "Unset signing settings for an ad-hoc test build."
    identity=-
    suffix=-adhoc
else
    [[ -n "$identity" && -n "$profile" ]] ||
        die "Set PIPEPLOT_SIGN_IDENTITY and PIPEPLOT_NOTARY_PROFILE, or use PIPEPLOT_AD_HOC=1 for local testing."
    suffix=
fi

cd "$(dirname "$0")/.."
out="$PWD/.build/distribution/v$version"
name="PipePlot-$version-macos-arm64$suffix.dmg"
mkdir -p "$out"
[[ ! -e "$out/$name" && ! -e "$out/$name.sha256" ]] ||
    die "Output already exists: $out/$name (or its checksum). Move it aside before rebuilding."
work="$(mktemp -d "$out/.work.XXXXXX")"
mount="$work/mounted"
attached=0
cleanup() {
    if [[ "$attached" == 1 ]]; then
        hdiutil detach "$mount" >/dev/null || return
    fi
    rm -rf "$work"
}
trap cleanup EXIT

xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-release \
    CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$version" build
swift build -c release --product pp
bin_dir="$(swift build -c release --show-bin-path)"

mkdir "$work/image"
app="$work/image/PipePlot.app"
ditto .build/xcode-release/Build/Products/Release/PipePlot.app "$app"
install -m 0755 "$bin_dir/pp" "$app/Contents/MacOS/pp"
ln -s /Applications "$work/image/Applications"

sign_flags=(--timestamp --options runtime)
if [[ "$identity" == - ]]; then
    sign_flags=(--timestamp=none)
fi
codesign --force --sign "$identity" "${sign_flags[@]}" "$app/Contents/MacOS/pp"
codesign --force --sign "$identity" "${sign_flags[@]}" "$app"

if [[ "$identity" != - ]]; then
    notary_args=(--keychain-profile "$profile")
    if [[ -n "${PIPEPLOT_NOTARY_KEYCHAIN:-}" ]]; then
        notary_args+=(--keychain "$PIPEPLOT_NOTARY_KEYCHAIN")
    fi
    # Homebrew extracts the app from its disk image. Staple both so the app
    # carries its own ticket after it is copied out of the DMG.
    ditto -c -k --keepParent "$app" "$work/PipePlot.zip"
    xcrun notarytool submit "$work/PipePlot.zip" "${notary_args[@]}" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
fi

dmg="$work/$name"
hdiutil create -volname PipePlot -srcfolder "$work/image" -format UDZO "$dmg"
if [[ "$identity" != - ]]; then
    codesign --sign "$identity" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
fi

hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg"
attached=1
app="$mount/PipePlot.app"
[[ "$(readlink "$mount/Applications")" == /Applications ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
for executable in "$app/Contents/MacOS/"{PipePlot,pp}; do
    [[ "$(lipo -archs "$executable")" == arm64 ]]
    codesign --verify --strict "$executable"
done
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/pp" --help >/dev/null
hdiutil detach "$mount"
attached=0

(cd "$work" && shasum -a 256 "$name" > "$name.sha256")
mv "$dmg" "$out/$name"
mv "$work/$name.sha256" "$out/$name.sha256"
printf 'Packaged %s\n' "$out/$name"
