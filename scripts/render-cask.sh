#!/bin/bash
set -euo pipefail

dmg="${1:-}"
name="${dmg##*/}"
if [[ $# -ne 1 || ! -f "$dmg" || ! "$name" =~ ^PipePlot-([0-9]+\.[0-9]+\.[0-9]+)-macos-arm64(-adhoc)?\.dmg$ ]]; then
    printf 'Usage: %s path/to/PipePlot-MAJOR.MINOR.PATCH-macos-arm64[-adhoc].dmg\n' "$0" >&2
    exit 1
fi
version="${BASH_REMATCH[1]}"
suffix="${BASH_REMATCH[2]:-}"
sha="$(shasum -a 256 < "$dmg")"
cat <<RUBY
cask "pipe-plot" do
  version "$version"
  sha256 "${sha%% *}"

  url "https://github.com/alchemyst/pipe-plot/releases/download/v#{version}/PipePlot-#{version}-macos-arm64$suffix.dmg"
  name "PipePlot"
  desc "Plot live numeric streams from the terminal"
  homepage "https://alchemyst.github.io/pipe-plot/"

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "PipePlot.app"
  binary "#{appdir}/PipePlot.app/Contents/MacOS/pp", target: "pipeplot-pp"
RUBY

if [[ "$suffix" == -adhoc ]]; then
    cat <<'RUBY'

  caveats <<~EOS
    This is an unnotarized preview, ad-hoc signed without Developer ID signing.
    macOS may block first launch. If you choose to open it, see:
      https://support.apple.com/en-us/102445

    The terminal command is pipeplot-pp. For example:
      pipeplot-pp --test 2 -c
  EOS
RUBY
fi
printf 'end\n'
