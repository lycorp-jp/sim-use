# 012.003 — Shared session transitions

> Updated 2026-11-12: Bracketed and scoped IPv6 serials also need to pass the
> mandatory lock's path validation. See [004-ipv6-session-paths.md](004-ipv6-session-paths.md).

## Context

Review-loop round 1 of #189 found R189-06. A client's state lock does not
coordinate disk records and adb forwards with another client or process.
Cleanup can delete a replacement record written during its ownership query.
Two clients can also both discover a port change, then attempt to remove the
same old forward. The second removal fails even though recovery succeeded.

## Decision

Use a persistent, private per-device `bridge.lock` next to `bridge.json`.
An advisory file lock coordinates clients and processes that share this store.
Hold it from the initial disk read through ownership queries, discovery, forward
changes, and record publication or deletion. Host-change cleanup follows the
same rule. Always take the instance state lock before the file lock when both
are needed. Warm in-memory requests take neither a file lock nor an adb query.
HTTP and response decoding remain outside the file lock.

Keep the lock file in place. Removing it would allow a process waiting on the
old inode to overlap a process that opens a new one. Lock acquisition has a
bounded wait and fails without changing the session. Follow the private-file
checks used by `PasteboardLock`, with Darwin and Glibc imports for this backend.

## Verification plan

Add gated regressions for a second client that starts during cleanup's ownership
query, and for a second migration that starts during provider discovery. First
observe failures on the reviewed code. Then verify that both clients complete,
only one replacement forward remains, and action attempts do not duplicate.
Run the focused Swift suite, `make build`, and `make test` after the fix.

## Result

The two gated regressions failed against `f8a0a72`: cleanup deleted the
replacement record, and concurrent migration failed with `listener not found`.
Both passed after the lock change. The focused bridge/session/discovery suite
passed 69 tests before two additional lock failure-path tests were added.

`make build` and `make test` passed; the full suite reported 1,626 passing
tests, including the lock timeout and release-after-error checks. Two new
async-context warnings in the test assertions were then removed without a
production-code change; the focused suite passed all 71 tests after that
adjustment, with no new warnings.

A live check on an isolated headless API 36 emulator
(`simuse_e2e_api36`, serial `emulator-5580`) restarted the bridge from 8080 to
41153 with an unrelated listener on the old port. Concurrent daemon UI and
independent screenshot calls succeeded and left one forward to the new port.
A subsequent tap succeeded, and the screenshot was a PNG.

A separate Python process held `bridge.lock` with `fcntl.flock`. A new
`android ping` process waited until release, then succeeded. A warm daemon
`describe-ui` completed while the file lock was still held. This verifies that
processes share the lock and that warm HTTP stays outside it. The temporary
daemon and emulator were stopped after the check.

Logs and the live harness are in `.build/pr185-takeover/review-round1-*`.
The APK did not change. Kotlin tests and the full Android device suites were
not rerun in this round. Linux compilation was not tested in this environment.
