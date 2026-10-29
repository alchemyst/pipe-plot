#!/bin/bash
set -euo pipefail

if [[ -n "${PIPEPLOT_PP_BIN:-}" ]]; then
  pp_bin="$PIPEPLOT_PP_BIN"
elif [[ -x "$HOME/.local/bin/pp" ]]; then
  pp_bin="$HOME/.local/bin/pp"
else
  pp_bin="$(command -v pp || true)"
fi
if [[ -z "$pp_bin" || ! -x "$pp_bin" ]]; then
  echo "Could not find installed pp. Set PIPEPLOT_PP_BIN or install to ~/.local/bin/pp." >&2
  exit 1
fi

line_name="pp-smoke-$(date +%s)-$$"
printf '1\n2\n' | "$pp_bin" --new-session -n "$line_name"
listing="$("$pp_bin" ls)"
session_number="$(printf '%s\n' "$listing" | awk -v stream="$line_name" '
  /^Session [0-9]+:/ { session=$2; sub(":$", "", session) }
  /^    / && index($0, stream) { print session; exit }
')"
if [[ -z "$session_number" ]]; then
  echo "Smoke stream $line_name was not found in pp ls output:" >&2
  printf '%s\n' "$listing" >&2
  exit 1
fi

# Reattach by public session number and exact stream name; this only changes
# the newly created smoke-test session and leaves existing sessions untouched.
printf '3\n4\n' | "$pp_bin" "$session_number" "$line_name"
listing="$("$pp_bin" ls)"
if ! printf '%s\n' "$listing" | grep -F "    $line_name  4 samples  ended" >/dev/null; then
  echo "Expected four samples on $line_name after explicit attachment:" >&2
  printf '%s\n' "$listing" >&2
  exit 1
fi
printf 'PipePlot smoke test passed in new session %s (stream %s).\n' "$session_number" "$line_name"

previous_max="$(printf '%s\n' "$listing" | awk '/^Session [0-9]+:/ { n=$2; sub(":$", "", n); if (n>max) max=n } END { print max+0 }')"
test_session=$((previous_max + 1))
"$pp_bin" --test 2 --new-session &
test_pid=$!
cleanup_test_process() {
  kill -INT "$test_pid" 2>/dev/null || true
  wait "$test_pid" 2>/dev/null || true
}
trap cleanup_test_process EXIT
sleep 2.2
kill -INT "$test_pid"
if ! wait "$test_pid"; then
  echo "pp --test did not finish cleanly after Ctrl-C" >&2
  exit 1
fi
trap - EXIT
test_listing="$("$pp_bin" ls)"
test_lines="$(printf '%s\n' "$test_listing" | awk -v wanted="$test_session" '
  /^Session [0-9]+:/ { id=$2; sub(":$", "", id); inSession=(id==wanted) }
  inSession && $1=="Line" && $3+0 >= 2 && $5=="ended" { seen[$2]=1 }
  END { count=0; for (line in seen) count++; print count }
')"
if [[ "$test_lines" -lt 2 ]]; then
  echo "Expected two ended sine streams with at least two samples in session $test_session:" >&2
  printf '%s\n' "$test_listing" >&2
  exit 1
fi
printf 'Sine test passed in new session %s (two streams, Ctrl-C flush).\n' "$test_session"
