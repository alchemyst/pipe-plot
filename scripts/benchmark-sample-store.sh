#!/bin/bash
set -euo pipefail

repo_root="$(CDPATH= cd "$(dirname "$0")/.." && /bin/pwd -P)"
row_count="${1:-100000}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/pipeplot-benchmark.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

swiftc -parse-as-library \
  -I "$repo_root/Sources/CSQLite" \
  "$repo_root"/Sources/PipePlotCore/*.swift \
  "$repo_root/scripts/SampleStoreBenchmark.swift" \
  -o "$build_dir/SampleStoreBenchmark"

printf 'macOS: %s\n' "$(sw_vers -productVersion)"
printf 'Architecture: %s\n' "$(uname -m)"
printf 'Swift: %s\n' "$(swift --version | head -n 1)"
printf 'Rows per stream: %s\n' "$row_count"
/usr/bin/time -l "$build_dir/SampleStoreBenchmark" "$row_count"
