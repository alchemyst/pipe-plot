#!/bin/bash
set -euo pipefail

repo_root="$(CDPATH= cd "$(dirname "$0")/.." && /bin/pwd -P)"
"$repo_root/scripts/build-app-bundle.sh"
bin_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
ditto "$repo_root/.build/pipeplot-stage/PipePlot.app" "$HOME/Applications/PipePlot.app"
install -m 0755 "$bin_dir/pp" "$HOME/.local/bin/pp"
printf 'Installed PipePlot.app to %s/Applications and pp to %s/.local/bin/pp\n' "$HOME" "$HOME"
printf 'Ensure %s/.local/bin is on PATH.\n' "$HOME"
