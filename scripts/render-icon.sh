#!/bin/bash
set -euo pipefail

repo_root="$(CDPATH= cd "$(dirname "$0")/.." && /bin/pwd -P)"
# Xcode's GUI environment doesn't inherit the interactive shell's tool paths.
export PATH="$HOME/.pyenv/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
exec "${ICON_PYTHON:-python3}" "$repo_root/design/icon/build.py" --output-dir "$1"
