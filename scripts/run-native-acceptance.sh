#!/bin/bash
# Build actual app/test sources as a standalone native XCTest harness. This avoids
# launch-service test-host failures and never opens the user's saved database.
set -euo pipefail
repo_root="$(CDPATH= cd "$(dirname "$0")/.." && /bin/pwd -P)"
harness_dir="$repo_root/.build/native-acceptance-harness"
python3 - "$repo_root" "$harness_dir" <<'PY'
import json, pathlib, sys
root, harness = map(pathlib.Path, sys.argv[1:])
harness.mkdir(parents=True, exist_ok=True)
path = json.dumps(str(root), ensure_ascii=False)
(harness / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PipePlotNativeAcceptance", platforms: [.macOS("27.0")],
    dependencies: [.package(name: "PipePlot", path: ROOT)],
    targets: [
        .target(name: "PipePlotApp", dependencies: [.product(name: "PipePlotCore", package: "PipePlot"), .product(name: "PipePlotTransport", package: "PipePlot")], path: "App", exclude: ["PipePlotApp.swift"]),
        .testTarget(name: "PipePlotAppTests", dependencies: ["PipePlotApp", .product(name: "PipePlotCore", package: "PipePlot"), .product(name: "PipePlotTransport", package: "PipePlot")], path: "Tests")
    ], swiftLanguageModes: [.v5])
'''.replace('ROOT', path))
for name, source in [('App', root/'Sources/PipePlotApp'), ('Tests', root/'Tests/PipePlotAppTests')]:
    link = harness/name
    if not link.is_symlink():
        link.symlink_to(source, target_is_directory=True)
PY
exec swift test --package-path "$harness_dir" "$@"
