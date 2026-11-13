#!/bin/bash
set -euo pipefail

dmg="${1:-}"
name="${dmg##*/}"
if [[ $# -ne 1 || ! -f "$dmg" || ! "$name" =~ ^PipePlot-([0-9]+\.[0-9]+\.[0-9]+)-macos-arm64\.dmg$ ]]; then
    printf 'Usage: %s path/to/PipePlot-MAJOR.MINOR.PATCH-macos-arm64.dmg\n' "$0" >&2
    exit 1
fi
version="${BASH_REMATCH[1]}"
sha="$(shasum -a 256 < "$dmg")"
cat <<RUBY
cask "pipe-plot" do
  version "$version"
  sha256 "${sha%% *}"

  url "https://github.com/alchemyst/pipe-plot/releases/download/v#{version}/PipePlot-#{version}-macos-arm64.dmg"
  name "PipePlot"
  desc "Plot live numeric streams from the terminal"
  homepage "https://github.com/alchemyst/pipe-plot"

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "PipePlot.app"
  binary "#{appdir}/PipePlot.app/Contents/MacOS/pp", target: "pipeplot-pp"
end
RUBY
