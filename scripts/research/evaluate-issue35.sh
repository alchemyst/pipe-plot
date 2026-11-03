#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h:h}"
marker=/tmp/pipeplot-issue35-research.optin
ready=/tmp/pipeplot-issue35-preview.ready
release=/tmp/pipeplot-issue35-preview.release
mode=${1:-benchmark}
if [[ "$mode" != benchmark && "$mode" != preview ]]; then
    print -u2 "Usage: $0 [benchmark|preview]"
    exit 2
fi
if [[ -e "$marker" ]]; then
    print -u2 "Research marker already exists: $marker"
    exit 1
fi
research_dir=$(mktemp -d /tmp/pipeplot-issue35.XXXXXX)
rm -f "$ready" "$release"
cleanup() {
    rm -f "$marker" "$ready" "$release"
    rm -rf "$research_dir"
}
trap cleanup EXIT

python3 - "$research_dir/history.sqlite" <<'PY'
import math
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=OFF")
db.execute("PRAGMA synchronous=OFF")
db.execute("CREATE TABLE samples(stream_id TEXT NOT NULL, timestamp REAL NOT NULL, sequence INTEGER NOT NULL, value REAL NOT NULL, segment_id TEXT, PRIMARY KEY(stream_id,sequence))")
start = 1700000000.0
rows = 120960  # seven days at one row per five seconds, per stream
with db:
    for column in range(10):
        identifier = f"00000000-0000-0000-0000-{column+1:012x}"
        baseline = (column // 5) * 1000 + (column % 5) * 30
        amplitude = 3 if column < 5 else 60
        for offset in range(0, rows, 4096):
            db.executemany(
                "INSERT INTO samples VALUES(?,?,?,?,?)",
                ((identifier, start + i * 5 + (180 if i >= rows // 2 else 0), i,
                  baseline + math.sin(i / 17) * amplitude,
                  "first" if i < rows // 2 else "reconnected")
                 for i in range(offset, min(offset + 4096, rows))))
db.execute("CREATE INDEX samples_by_time ON samples(stream_id,timestamp,sequence)")
print(f"SEEDED rows={rows*10} streams=10 database={sys.argv[1]}")
db.close()
PY

print -r -- "$research_dir/history.sqlite" > "$marker"
if [[ "$mode" == preview ]]; then
    test_name=testHostedNativePreview
else
    test_name=testHostedResearchComparison
fi
xcodebuild -project PipePlot.xcodeproj -scheme PipePlot -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${PIPEPLOT_XCODE_DERIVED_DATA:-/tmp/pipeplot-issue27-xcode.YP4Sbt}" \
    -only-testing:PipePlotAppTests/SwiftChartsPrototypeTests/$test_name \
    ENABLE_TESTABILITY=YES \
    test
