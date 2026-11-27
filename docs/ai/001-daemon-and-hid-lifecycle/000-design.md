# 001 — Per-device daemon and HID connection lifecycle: Design

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-06-05 (the daemon shipped in the first public release) |
| **Primary PRs** | #6, #7, #12, #13, #23, #58, #61 (retired), #72, #147, #154 |
| **Related** | [006-xcode27-support](../006-xcode27-support/000-investigation.md), [008-linux-android-build](../008-linux-android-build/000-design.md), [009-resizable-app-session](../009-resizable-app-session/000-investigation.md) |

> Backfilled on 2026-10-14 from the PR descriptions, the code, `CHANGELOG.md`
> and work notes. It is a retrospective reconstruction, not a plan written
> before the work.

> Updated 2026-10-20: iOS batches opt out of automatic transient-booting
> request replay because earlier steps can have side effects. Other commands
> retain the retry behavior below. See [011.005](../011-device-hub-paste/005-batch-retry-policy.md).

## Background

A cold sim-use command loads the FB* frameworks, builds an `FBSimulatorSet`,
and opens a HID connection before it sends one event. An agent sends many
short commands in sequence, so that setup cost repeats on every command. A
long-lived process per device keeps the frameworks loaded and the HID
connection open.

A long-lived process also keeps state that can become stale: a connection to a
simulator that rebooted, a transport selected before `dtuhidd` attached, a
daemon built from an older binary, or a daemon started for another adb server.
Most bugs in this area made a command report success while it delivered
nothing — the worst failure for a tool that agents use.

## Goals

- Keep warm commands fast: one daemon per device, frameworks and HID
  connection reused.
- Never apply a side-effecting command (`tap`, `type`, `swipe`) twice.
- Never send through a connection that cannot reach the current device; fail
  loudly instead of reporting a delivered event.
- Keep the CLI output the same whether a command runs in the daemon or
  in-process.

### Non-goals

- Physical iOS devices: they run in-process until the daemon can hold their
  session (issue #120).
- Binary or streaming output (`screenshot`, `record-video`, `stream-video`,
  `android init`, `android ping`): these set `daemonBypass` and run in-process.

## Design

**How a verb reaches the daemon.** A command conforms to
`SimUseExecutableCommand` (`Sources/SimUseCore/Types/SimUseExecutableCommand.swift`).
`execute()` does the work and returns a `Codable` result; `format(_:)` renders
it. The default `run()` resolves the device, runs `clientPreflight()`, and
then either calls `execute()` in-process or forwards the request to the daemon.
The client forwards the full argv tail (the daemon parser must see
`ios <verb>` to reach the iOS namespace), with `--device` injected when it is
absent (`DeviceResolver.injectingDeviceIfNeeded`). The command stays
in-process when `daemonBypass` is true, when `SIM_USE_NO_DAEMON=1`, inside the
daemon (`SIM_USE_IN_DAEMON=1`, set by `DaemonServer`), and for physical iOS
devices. The daemon runs `executeAsDaemonResponse` and returns the same result
as JSON; the client calls `format(_:)` locally.

**Daemon files and lifetime.** `DaemonPaths` keeps one socket, pidfile and log
per device under `/tmp/sim-use-<uid>/`. `DaemonClient` spawns the daemon on
demand, with stdin on `/dev/null`. `DaemonServer` serves one request at a time
(`handleChain`) and exits after an idle timeout (`--idle-timeout`, default
600 s). The wire format is one JSON line per request and per response
(`DaemonProtocol.swift`); `_ping` and `_stop` are management commands.

**Daemon identity gates.** Before a request, `DaemonClient.ensureCompatibleDaemon`
sends `_ping`. The daemon reports its `simUseVersion` and connection identity
(`DaemonPingData`). A different version or identity stops the daemon, and the
spawn path starts a new one from the current binary
(`SIM_USE_DAEMON_VERSION_CHECK=0` disables only the version comparison). Each
business request also carries the client's connection identity, and the
daemon refuses a mismatch before it parses the request
(`DaemonDispatch.connectionMismatchOutcome`; see
[008](../008-linux-android-build/000-design.md)).

**HID connection cache.** `HIDInteractor` caches one connection per device
(`CachedConnection`). Each entry stores a boot token (`HIDBootIdentity`): the
identity of the `launchd_sim` process that serves the device
(`LaunchdSimLocator`), with the mtime of `launchd_bootstrap.plist` as a
fallback. A connection is reused only when the token still matches
(`HIDBootIdentity.isReusable`). Each send runs under a deadline
(`HIDSendDeadline`, 30 s, `SIM_USE_HID_SEND_TIMEOUT_MS`, `0` disables). A failed
send drops the cached connection; `HIDPerformRecovery` resends once only for
errors which prove that nothing reached the device. A connection whose
transport was auto-selected within `HIDBootIdentity.transportTrustWindow`
(15 s) of the boot serves its command but is not reused
(`transportTrusted`), because `dtuhidd` can attach after the selection.

## Alternatives & decisions

| Decision | Options considered | Chosen because | PR |
| --- | --- | --- | --- |
| A remote error (`ok=false`) is the command's result; it does not cause a respawn | Treat every failure as a stale daemon: clean up, respawn, resend | The resend ran a failed `type` or `tap --wait-timeout` a second time and orphaned a healthy daemon | #6 |
| `transient_booting` is resent once to the same daemon | No retry; retry on a new daemon | Accessibility is not ready for a short time after `simctl boot`; the daemon is healthy, so a new one gives nothing | #6 |
| Split transport failures by whether the request was delivered: before delivery → respawn and resend; after delivery → `ambiguousExecution` with a hint to re-observe | Always resend; never resend | A request that reached the daemon may have run. The caller is an agent, so it decides after it reads the screen; a side effect is never applied twice | #12 |
| The idle timer reschedules while a request runs (`activeRequests > 0`) | Reset the timer only at request start and end | A request longer than the timeout (`tap --wait-timeout 700`, a long batch) shut down the daemon mid-execution | #13 |
| `cleanup()` keeps the socket and pidfile when the pidfile holds another pid; `ensureBaseDirectory` rejects symlinks and foreign owners and resets the mode to 0700 | Unconditional cleanup; trust a pre-existing directory | An orphaned predecessor deleted its successor's files; `/tmp` is world-writable | #7 |
| Reuse a cached HID connection only when the boot token matches; fail closed when only one side has a `launchd_sim` identity | Check `state == .booted` only; marker mtime only (#23) | A reboot under the same UDID passed the state check, and the send hung or reported success with no effect. CoreSimulator does not always rewrite the marker, so the `launchd_sim` (pid, start time) identity is authoritative | #23, #58 |
| Each HID send has a deadline (30 s) | No deadline | A dead mach port can hang the send forever; the deadline covers a reboot mid-command | #58 |
| Refuse HID on a simulator booted while Device Hub was open (`dtuhidd` child of `launchd_sim`, started within 15 s of it) | Check only for `dtuhidd` presence | Presence cannot separate a poisoned boot from a Hub attached later. Retired when the idb migration selected the DTUHID transport automatically — see [006](../006-xcode27-support/000-investigation.md) | #61 |
| Cache but do not reuse a connection whose transport was auto-selected inside the 15 s window | Skip the cache; pin the first selection | `dtuhidd` attaches 0–3 s after boot, so an early selection can be wrong. An uncached connection would leak its mach port in the long-lived daemon | #72 |
| Restart a daemon whose version (git-describe string) or connection identity differs from the client's | Reuse any live daemon | A daemon from an older binary or for another adb server runs the wrong code or targets the wrong device | #147 |
| Check the connection identity on every request, in the daemon, before the parse | Rely on the `_ping` restart only | `_ping` times out after 2 s behind a busy daemon, so a request from another connection ran in that daemon | #147 |
| Read caller-side input (stdin, `--file`) in the client and forward it inline; do not bypass the daemon for input verbs | Bypass the daemon when stdin or a caller-relative file is used | With Device Hub open, HID from a short-lived process is lost — see [001-dtuhidd-short-lived-clients.md](001-dtuhidd-short-lived-clients.md) | #154 |

## Open questions

- The version gate compares git-describe strings. Two builds of the same dirty
  commit report the same string, so a rebuilt binary keeps talking to the old
  daemon until `sim-use daemon stop`. Accepted for development builds; not
  measured whether it matters for releases.
- A HID connection that dies without a reboot (same boot token) and hangs is
  covered only by the send deadline, not detected before the send (#23,
  "Known limitation").
- `android init` without a valid cached session opens a forward that it does
  not persist (#147, "Known limitations").

## Amendments

- Updated 2026-10-14: HID from short-lived processes is lost on the dtuhidd transport; all input verbs go through the daemon (#154) — see [001-dtuhidd-short-lived-clients.md](001-dtuhidd-short-lived-clients.md)
- Updated 2026-10-20: Add a command-level transient-retry policy; batches cannot be replayed after partial execution — see [011.005](../011-device-hub-paste/005-batch-retry-policy.md).
- Updated 2026-11-20: Refuse short-lived DTUHID input before sending (#175). See [002](002-no-daemon-dtuhid-refusal.md).
