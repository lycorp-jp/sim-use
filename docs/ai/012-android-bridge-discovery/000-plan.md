# 012 — Android bridge endpoint discovery: Plan

| | |
| --- | --- |
| **Status** | Implemented on continuation branch; merge pending |
| **Anchor date** | 2026-11-12 |
| **Primary PRs** | #185 (original contribution), #189 (continuation; merge pending) |
| **Related** | #188, [008-linux-android-build](../008-linux-android-build/000-design.md) |

> Updated 2026-11-12: A new client no longer discovers before each first
> HTTP request. It reuses a disk session that a discovery created in the last
> 600 s. A response from another listener now also triggers discovery. See
> [002-review-hardening.md](002-review-hardening.md).

## Background

The bridge binds device loopback port 8080. If another app owns that port,
the old server fails on its accept thread. Discovery still returns a bearer
token, and the CLI connects to the other app. With an unrelated HTTP listener,
`android init` fails with HTTP 404 instead of reporting the bind failure.

PR #185 adds synchronous binding and endpoint discovery. Its client discovers
the endpoint before every HTTP operation and holds a recursive lock through
HTTP and display decoding. On the review emulator, warm `describe-ui` calls
regressed from a 61 ms median to 1,979 ms (seven calls with the same PR APK).

This continuation starts at the original commit
`ff966c0e1821042191b9c1c21845d8fb400c00a0`. It keeps that commit and author intact.
The original commit includes both discovery and POST retry changes, so the
continuation uses separate follow-up commits instead of rewriting it.

## Goals

- Start the bridge when another app owns 8080.
- Discover a new client's endpoint before sending a bearer token, including
  when a client restores a disk session.
- Run warm requests without adb queries or a lock held across HTTP.
- Recover once after a failed handshake, connection refusal, or HTTP 401.
- Do not repeat a POST whose outcome is unknown.
- Keep responses from an old connection out of the current display cache.

## Design

`HttpServer` first binds `127.0.0.1:8080`. On a bind conflict it binds loopback
port 0 and publishes the actual port before `start()` returns. Other bind
failures remain startup errors. There is no fixed fallback range.

The shell-only `SimuseContentProvider` keeps the token in `result` and adds
optional `port`, `server_state`, and `server_error` fields. A running endpoint
has an actual port in 1...65535. An explicit stopped or failed state is never
treated as a legacy reply. Replies without the new fields retain port 8080.
HTTP protocol version remains 2: existing HTTP envelopes do not change, and
legacy discovery replies remain supported.

`BridgeClient` discovers once for a new in-memory session. A restored forward
is reused only after discovery and an adb ownership check. Cold setup and
endpoint removal are serialized under a state lock. HTTP uses an immutable
session snapshot outside the lock. Session generations guard protocol and
display cache publication, and prevent an old failure from deleting a newer
forward. Failed ownership queries preserve the session and the original error.

The client retries a failed handshake once. It retries a business GET after a
transport error, and a POST only after connection refusal or HTTP 401. Each
business request has at most one replay. Business HTTP 500 responses and
uncertain POST transport failures are reported without replay.

## Alternatives & decisions

| Decision | Options considered | Chosen because |
| --- | --- | --- |
| Discovery timing | Every HTTP operation; cold setup and failure | adb queries dominate the hot path. Discovery before cold HTTP blocks the reported token exposure. |
| Fallback port | Fixed range; port 0 | The kernel selects and binds an available port in one operation. Discovery already returns the actual port. |
| Concurrency | Lock across HTTP; immutable session snapshots | Independent requests can complete while another HTTP request is blocked. Generations protect current state. |
| Protocol version | Bump HTTP version; additive shell discovery | The HTTP contract is unchanged. Missing discovery fields retain legacy behavior. |
| History | Rewrite/split original commit; append follow-ups | The owner requires preservation of the contributor's original commit. |

### Accepted boundary

A warm daemon does not proactively detect a bridge restart. If the bridge
changes ports and an unrelated listener takes the old port, a request can
reach that listener before failure triggers discovery. In particular, an
unrelated listener can receive a bearer token. Strong endpoint identity for
this case is tracked in #188; per-request adb discovery is not
the chosen mitigation. Ordinary refusal or HTTP 401 still triggers recovery.

## Verification plan

Reproduction steps: [reproduction.md](reproduction.md). Results:
[001-action.md](001-action.md).

- Swift regressions: no adb calls on warm ping/tree/action/display paths;
  bounded rediscovery; bearer isolation on cold setup; forward ownership;
  POST attempt counts; overlapping HTTP; stale cache publication and cleanup.
- Kotlin tests: preferred binding, ephemeral fallback, loopback binding, and
  consistent lifecycle snapshots after startup success or failure.
- `scripts/build-bridge.sh`, `make build`, and `make test`.
- Live Android: occupy 8080, initialize, read UI, tap, and take a screenshot;
  stop/restart the bridge on another port and recover after connection refusal.
- Compare seven warm `describe-ui` calls with the review baseline, and record
  adb call counts. The warm bridge path must issue zero adb commands. The
  separate process-liveness probe is outside `BridgeClient` and stays unchanged.

## Amendments

- Updated 2026-11-12: Trust window for discovered disk sessions, recovery after a response from another listener, shared disk session ownership, one discovery in `init` — see [002-review-hardening.md](002-review-hardening.md).
- Updated 2026-11-12: Coordinate disk and forward transitions across clients and processes — see [003-shared-session-lock.md](003-shared-session-lock.md).
- Updated 2026-11-12: Accept bracketed and scoped IPv6 adb serials in session paths — see [004-ipv6-session-paths.md](004-ipv6-session-paths.md).
