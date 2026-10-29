#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

swift build -c release
stage="$repo_root/.build/pipeplot-stage"
app="$stage/PipePlot.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$repo_root/.build/release/PipePlotApp" "$app/Contents/MacOS/PipePlot"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PipePlot</string>
  <key>CFBundleIdentifier</key><string>com.cactusdynamics.PipePlot</string>
  <key>CFBundleName</key><string>PipePlot</string>
  <key>CFBundleDisplayName</key><string>PipePlot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$app"
printf 'App bundle: %s\nCLI: %s/.build/release/pp\n' "$app" "$repo_root"
