# Core sample-store benchmark

Run `scripts/benchmark-sample-store.sh [rows-per-stream]` from any directory. The script compiles the core sources with the installed Swift compiler, inserts timestamped two-column rows into a temporary SQLite database, queries up to the store's 50,000-row query limit, and reports `/usr/bin/time -l` resource data. It deletes the temporary database and executable when finished.

This measures synchronous core SQLite insertion/query work. It does not measure the app, chart rendering, UI responsiveness, IPC, or concurrent producers. Treat results as a local baseline, not an acceptance threshold.

## Recorded run

- Date: 2026-10-30
- Environment: macOS 27.0.1, arm64, Apple Swift 6.4.0.34.1; machine model was not recorded.
- Command: `scripts/benchmark-sample-store.sh 100000`
- Workload: 100,000 timestamped two-value rows; one transactional `SampleStore.append` per row; then a 50,000-sample query on one stream.
- Append: 30.49 s reported by the harness.
- Query: 50,000 rows returned in 0.292 s.
- SQLite count: 100,000 samples per stream.
- Process: 31.32 s real, 5.46 s user, 15.70 s system.
- Maximum resident set size: 20,430,848 bytes (about 19.5 MiB); peak memory footprint reported by `time`: 16,695,824 bytes.

The build used the compiler's default optimization settings. The numbers describe this machine and workload only; they do not establish UI fluidity or long-history interaction latency.
