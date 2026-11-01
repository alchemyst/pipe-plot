#!/bin/bash
set -euo pipefail

repo_root="$(CDPATH= cd "$(dirname "$0")/.." && /bin/pwd -P)"
cd "$repo_root"
xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
swift build -c release --product pp
