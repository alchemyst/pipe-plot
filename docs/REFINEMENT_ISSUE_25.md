# Swift refinement #25: Swift 6 migration

Both the Swift package and the Xcode app/test targets now use Swift 6 language mode. Xcode also selects complete concurrency checking. `just strict-build` compiles package tests with complete checking and warnings as errors, then builds the hosted app tests with Swift warnings as errors. `just check` remains the behavioral test gate.

Validated with Xcode 27.2, Apple Swift 6.4.2, and the project deployment target macOS 27.0. This toolchain provides `Synchronization.Mutex` and `isolated deinit`; the Swift 6 migration depends on those facilities. The checked-in formatter and its toolchain are described in `README.md`.

## Isolation boundaries

- `BackgroundQueries` still sends SQL scans and fits to its serial user-initiated queue, using the independent read-only `SampleStore`. Its result handlers are explicitly `@MainActor @Sendable`; the main queue publishes results and invokes them. Query caches, generation invalidation, and stale display coordinates are unchanged.
- `GuideNotifications` entry points and completion handlers are main-actor isolated. System notification callbacks cross back to that actor before reporting errors. The delegate's presentation completion remains a system-owned callback.
- `SessionWindowObserver` registers notification callbacks with `queue: .main`. `MainActor.assumeIsolated` expresses that queue contract at the callback boundary; the notification name is read before crossing the boundary. Visibility still depends on window visibility, minimization, occlusion, and app hiding, with no app-activation gate. Reporting remains deferred to the next main-queue turn.
- `PipePlotAppModel`, `WindowStateView`, and `ContextMenuRegion` use `isolated deinit` so observer tokens, the ingestion server, and the local event monitor are released on the main actor. The representable dismantle hooks still remove observers/monitor promptly when SwiftUI removes the view.
- `AcceptanceTrace` uses a mutex to guard both render deduplication and complete JSON-line writes. The instrumentation remains disabled without `--acceptance-trace`.

## Unsafe and unchecked audit

Every remaining `@unchecked Sendable` declaration is covered by a synchronization invariant:

| Type | Invariant |
| --- | --- |
| `PipePlotStore` | Its recursive lock guards all mutable metadata and restoration state. Initial load finishes before publication. Store mutations hold that lock while calling the independently locked sample store. Public `samples` access can bypass metadata bookkeeping, but does not bypass SQLite synchronization. |
| `SampleStore` | Its recursive lock serializes handle, statement, and transaction access, including module-internal extension queries. The handle is initialized before publication and closed after the last owner releases the object. The UI uses a separate read-only WAL connection for historical scans. |
| `GuideCrossingDetector` | Its lock guards all per-guide crossing state through evaluation and finalization. |
| `IngestionEventMailbox` | Its lock guards pending arrays, overflow counters, and the single-drain scheduling flag. A typed batch crosses to the main actor; no lock is held during delivery. |
| `IngestionConnectionRegistry` | Its lock serializes store registration with admission and session close/delete with detachment. Socket sends occur after unlocking, on utility workers. |
| `SocketConnection` | Its state lock guards close and descriptor leases; read and write locks guard their respective buffers/operations. A descriptor is closed only after shutdown and the last lease. `withFileDescriptor` grants a synchronous borrowed descriptor; callers must neither retain nor close it. Current production use polls only within the closure. |
| `UnixSocketServer` | Its lifecycle lock serializes start/stop and socket-path ownership; its state lock guards listener identity, stopped flag, clients, and path ownership. Stop drains the accept queue before closing the listener lease. |

The remaining `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` calls are the SQLite `SQLITE_TRANSIENT` sentinel at text-binding call sites, including a test fixture; SQLite copies the bound text. No `nonisolated(unsafe)` or `@preconcurrency` suppression was introduced.

## Validation

`just check` passed: 79 core tests, 12 package transport tests, 4 CLI tests, 40 hosted app tests (2 opt-in skips), and 12 isolated transport regression tests. The isolated transport test package was also rerun in Swift 6 mode after updating its temporary manifest: 12 passed. `just format-check` and `git diff --check` passed. `just strict-build` passed with no project-source warnings; Xcode emitted only a CoreSimulator version mismatch message disabling simulator device support and two App Intents metadata-extraction warnings because the targets have no App Intents dependency. The hosted macOS destination and tests succeeded despite those tooling messages.

Existing hosted tests cover model release and temporary-socket teardown, window visibility and query suspension, and fresh menu snapshots. Native pointer menu tracking and window observer removal during real SwiftUI dismantling were not manually exercised by this migration. These remain native acceptance checks; compilation and hosted tests do not establish those interactions.
