# Swift refinement #23: transport ownership and monotonic deadlines

## Ownership invariants

- `SocketConnection` owns one descriptor. `stateLock` protects closure and the active lease count. `close()` shuts the socket down once, waking blocked operations, and closes the descriptor only after all leases return. A leased descriptor cannot be recycled during send, receive, or the CLI's `poll` call. The public `withFileDescriptor` closure is synchronous; callers must not retain its integer afterward.
- `readLock` exclusively owns the pending frame buffer. `writeLock` serializes sends and temporary socket send-timeout options. Neither lock prevents `close()` from shutting down a blocked operation.
- `UnixSocketServer` serializes start/stop with `lifecycleLock`; `lock` protects listener identity, client membership, stopped state, and socket-path ownership. The listener is nonblocking, its accept queue polls for at most 100 ms, and `stop()` drains that queue before closing the old listener or allowing restart. Its weak queue capture does not keep an abandoned server alive. Client handlers are `@Sendable`.
- Connection and launch-retry deadlines and watch-command cadence use `ContinuousClock`; sample timestamps remain wall-clock `Date` values. Each watched command runs in its own process group, with only one group active at a time.

## Validation

- `swift test`: passed, 79 core, 12 transport, and 4 `pp` tests. The transport tests cover framing, slow peers, timeout budgets, blocked send/receive shutdown, repeated concurrent close, descriptor lease drainage, and listener restart. Watch tests cover output separation, failures, prompt stop, and descendant cleanup.
- `scripts/test-transport.sh`: passed, 12 transport tests in the isolated package.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: passed for the package targets with no warnings.
- `just format-check` and `git diff --check`: passed.

The app's complete-concurrency diagnostic build fails at `PipePlotAppModel.swift:62`: its `@MainActor` model calls `handle(_:)` directly from the new synchronous `@Sendable` worker handler. Issue #24 must separate blocking IPC work from main-actor state access. No app actor migration or hosted acceptance was performed in this ticket. Pointer, VoiceOver, notification, and sleep/wake behavior still require native acceptance checks.
