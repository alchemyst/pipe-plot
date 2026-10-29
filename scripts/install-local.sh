#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
"$repo_root/scripts/build-app-bundle.sh"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
ditto "$repo_root/.build/pipeplot-stage/PipePlot.app" "$HOME/Applications/PipePlot.app"
install -m 0755 "$repo_root/.build/release/pp" "$HOME/.local/bin/pp"
printf 'Installed PipePlot.app to %s/Applications and pp to %s/.local/bin/pp\n' "$HOME" "$HOME"
printf 'Ensure %s/.local/bin is on PATH.\n' "$HOME"
