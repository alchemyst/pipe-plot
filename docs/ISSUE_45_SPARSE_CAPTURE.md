# Sparse capture presentation acceptance

Issue #45, measured 2026-11-04 on Apple M2 Pro, 16 GiB RAM, macOS 27.2 (26B123), Release app and CLI.

`python3 scripts/check-first-visible-sample.py` now launches the built app in a fresh `/tmp/pipeplot-acceptance-*` directory with an explicit socket and SQLite database. It never connects to the installed app's socket or existing user sessions. The explicit app process launch replaces LaunchServices discovery for this isolated measurement. “Cold” means a new app process, not a flushed OS filesystem cache. The script retains the database and trace for inspection and shuts down only its own child processes.

Every accepted render must match the intended stream UUID and the receipt timestamp of the expected raw value in SQLite, as well as the send-time threshold. During the sparse update a second live chart receives a different value, and the script verifies both charts actually render. In the recorded run the two rows even share a receipt timestamp; matching stream identity remains essential.

| Boundary | Measured time |
| --- | ---: |
| Process launch plus first CLI row to intended Canvas pass | 0.656 s |
| Warm CLI first row to intended Canvas pass | 0.072 s |
| Second row after 120 seconds of silence to intended Canvas pass | 0.511 s |

These are one-run observations of a visible-window drawing pass, not display scanout or a percentile/regression budget. The first and sparse samples render while stdin remains open. After a final valid unterminated row and EOF, SQLite contains exactly `[123.456, 234.567, 345.678]` in the intended stream and `[987.654, 876.543]` in the competing stream. A preliminary two-second smoke run also passed.

`python3 scripts/check-cold-pipelines.py` additionally passed against a fresh isolated database: two concurrent CLI processes formed one session and one chart with distinct streams, containing exactly `[1, 11]` and `[2, 12]`. Both final rows were unterminated. This check inspects SQLite values, rather than relying solely on metadata counts.

Reproduce after `./scripts/build-app-bundle.sh` on an unlocked desktop. The first-visible script accepts `--app`, `--pp`, `--output`, and `--silent-seconds`; defaults use this checkout's Release products. Python syntax compilation passed. Raw result and trace: [measurement](acceptance-2026-11-04/first-visible-sample.json), [trace](acceptance-2026-11-04/first-visible-sample.trace.jsonl).
