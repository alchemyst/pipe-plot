#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
bundle="$root/.build/research/State Lane Lab.app"
mkdir -p "$bundle/Contents/MacOS"

xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    "$root/scripts/research/Issue44StateLane.swift" -o "$bundle/Contents/MacOS/StateLaneLab"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cactusdynamics.pipeplot.statelanelab</string>
  <key>CFBundleName</key><string>State Lane Lab</string>
  <key>CFBundleExecutable</key><string>StateLaneLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ "${1:-}" = "--build-only" ]; then
    printf '%s\n' "$bundle"
else
    open -n "$bundle"
fi
