#!/bin/bash
set -euo pipefail

repo_root="$(CDPATH= cd "$(dirname "$0")/.." && /bin/pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/pipeplot-transport-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/Tests/TransportRegressionTests"
cp "$repo_root/Tests/PipePlotTransportTests/UnixSocketTests.swift" \
  "$test_dir/Tests/TransportRegressionTests/UnixSocketTests.swift"
cat > "$test_dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PipePlotTransportRegression",
    platforms: [.macOS("27.0")],
    dependencies: [.package(name: "pipeplot", path: "$repo_root")],
    targets: [
        .testTarget(
            name: "TransportRegressionTests",
            dependencies: [.product(name: "PipePlotTransport", package: "pipeplot")]
        )
    ],
    swiftLanguageModes: [.v5]
)
EOF
swift test --package-path "$test_dir"
