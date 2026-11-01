#!/bin/bash
set -euo pipefail
repo_root="$(CDPATH= cd "$(dirname "$0")/.." && /bin/pwd -P)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/pipeplot-derived-benchmark.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
swiftc -O -parse-as-library -I "$repo_root/Sources/CSQLite" \
  "$repo_root"/Sources/PipePlotCore/*.swift "$repo_root/scripts/DerivedSeriesBenchmark.swift" \
  -o "$build_dir/DerivedSeriesBenchmark"
sw_vers -productVersion
sysctl -n hw.model hw.memsize
/usr/bin/time -l "$build_dir/DerivedSeriesBenchmark" "${1:-120961}"
