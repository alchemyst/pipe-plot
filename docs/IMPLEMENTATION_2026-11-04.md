# New-ticket implementation sequence

The open GitHub backlog inspected on 2026-11-04 consists of #36–#45.

| Order | Ticket | Reason |
| --- | --- | --- |
| 1 | #38 CLI contract | Establish isolated subprocess routing and error assertions. |
| 2 | #37 waiting-input diagnostics | Extend the tested CLI behavior without changing healthy capture. |
| 3 | #41 malformed stdin | Reuse the subprocess fixture to verify recovery across byte boundaries. |
| 4 | #43 sparse signed statistics | Establish raw-observation and selection-boundary expectations. |
| 5 | #36 raw CSV export | Build snapshot export against those raw-data semantics. |
| 6 | #39 persistent chart bounds | Establish separation between navigation and chart configuration. |
| 7 | #42 minimum geometry | Protect that state through collapsed rendering geometry. |
| 8 | #45 sparse presentation latency | Correlate the intended stream and persisted rows in an isolated app. |
| 9 | #40 concurrent visible workload | Measure the verified renderer and capture path with explicit evidence boundaries. |
| 10 | #44 discrete-state lane | Record the design decision, then evaluate an opt-in prototype against the preceding interaction invariants. |

The CLI, raw-data, and viewport tracks can proceed independently; each track retains its internal order. Ticket commits remain separate. Existing uncommitted release packaging, installation UI, and transport-discovery changes are preserved outside ticket commits.

Validation distinguishes raw-store and model tests, subprocess contracts, hosted visible-window drawing, and actual native interaction. A Canvas trace is a drawing-pass observation, not physical display scanout. Experimental state lanes do not imply a production rendering migration.
