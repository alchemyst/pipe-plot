# Refinement issue #31: scoped SQLite statements

## Change

- `SQLiteStatement` owns one prepared statement, finalizes it on explicit close or deinit, checks text, numeric, and null bindings, and distinguishes row, done, and SQLite failure when stepping. Call sites close statements within the existing connection lock and before the next write where ordering matters.
- `SampleStore`, range queries, reusable fits, segment remapping, and derived-series queries retain their SQL, streaming loops, query limits, segment IDs, locks, WAL connection model, and transaction order. Read failures now throw instead of returning empty counts, bounds, or partial sample lists.
- Initialization inspects `PRAGMA table_info(samples)` and adds `segment_id` only when absent. An unrelated migration failure propagates; failed initialization closes its connection.

## Validation

On macOS 27.2, arm64, Swift 6.4.2:

- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just test`: 100 package tests passed (84 core, 12 transport, 4 CLI); 62 hosted app tests passed, with two existing opt-in skips.
- `PIPEPLOT_XCODE_DERIVED_DATA=/tmp/pipeplot-issue27-xcode.YP4Sbt just strict-build`: 100 package tests passed with strict concurrency and warnings as errors; hosted build-for-testing succeeded with warnings as errors.
- `just format-check` and `git diff --check`: passed.
- New temporary-database tests cover prepare failure, invalid binding index, step failure after a row, a public query that encounters an error instead of returning partial rows, `SQLITE_BUSY` recovery, and idempotent migration. `sqlite3_next_stmt` checks cleanup after failures.

## Benchmarks

The following are one run each, before and after the change, using the same local scripts and 10,000-row inputs. The sample script compiles with Swift's default optimization; the derived script compiles with `-O` and measures the processor rather than SQLite queries.

| Command and measure | Before | After |
| --- | ---: | ---: |
| `scripts/benchmark-sample-store.sh 10000`, append 10,000 two-column rows | 1.244 s | 1.336 s |
| Same, query 10,000 rows | 0.00377 s | 0.00465 s |
| Same, maximum resident set | 11,010,048 B | 11,042,816 B |
| `scripts/benchmark-derived-series.sh 10000`, processor elapsed | 0.0464 s | 0.0519 s |
| Same, maximum resident set | 5,996,544 B | 5,963,776 B |

Both sample runs returned 10,000 rows and counted 10,000 per stream. Both derived runs produced 99,000 outputs with the same checksum and retained 6,060 numeric slots. In the default compilation, the observed append difference was +0.092 s (+7.4%) and query difference was +0.00088 s (+23%). A single run at these short durations cannot establish whether either difference persists. The derived processor does not use SQLite, so its single-run timing is not evidence of a storage regression.

For a second comparison, the parent commit `a5ceb27` and this commit `326b2dc` were archived into temporary directories. Each archived core source set and the same `SampleStoreBenchmark.swift` were compiled with `swiftc -O -parse-as-library` and run three times in alternating before/after order, with 10,000 rows per stream. No source or production data was changed for this comparison.

| Optimized trial | Before append | After append | Before query | After query |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1.304 s | 1.323 s | 4.327 ms | 3.090 ms |
| 2 | 1.190 s | 1.182 s | 2.989 ms | 3.178 ms |
| 3 | 1.227 s | 1.176 s | 2.981 ms | 5.110 ms |
| Median | 1.227 s | 1.182 s | 2.989 ms | 3.178 ms |

The optimized median append difference is −0.045 s (−3.7%); the median query difference is +0.189 ms (+6.3%). The latter is smaller than the within-version spread, and the paired trials alternate direction for both measures. Median maximum resident set was 10,371,072 B before and 10,158,080 B after. These observations show no consistent or material slowdown or memory growth at this workload. They do not establish a general performance bound or UI responsiveness.

## Limits

No live saved data, installed build, pointer/VoiceOver interaction, notification, or sleep/wake acceptance was exercised. Those broader native checks remain under issue #14's acceptance work.
