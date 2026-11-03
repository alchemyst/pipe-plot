#!/bin/bash
# Experimental persistence comparison for issue #32. Creates and removes only temporary fixtures.
set -euo pipefail
repo_root="$(CDPATH= cd "$(dirname "$0")/../.." && /bin/pwd -P)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pipeplot-issue32.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
swiftc -O -parse-as-library -I "$repo_root/Sources/CSQLite" \
  "$repo_root"/Sources/PipePlotCore/*.swift \
  "$repo_root/scripts/research/Issue32PersistenceEvaluation.swift" \
  -o "$work_dir/evaluate"
for count in 1000 5000; do
  for extra in 0 20; do
    "$work_dir/evaluate" measure "$work_dir/measure-$count-$extra" "$count" "$extra"
  done
done
"$work_dir/evaluate" measure "$work_dir/measure-1000-ten-streams" 1000 0 10
for guide_count in 100 1000; do
  "$work_dir/evaluate" events "$work_dir/events-$guide_count" "$guide_count"
done
for mode in crash-raw crash-ack; do
  "$work_dir/evaluate" "$mode" "$work_dir/$mode"
  "$work_dir/evaluate" reopen "$work_dir/$mode"
done
python3 "$repo_root/scripts/research/issue32-persistence-models.py"
