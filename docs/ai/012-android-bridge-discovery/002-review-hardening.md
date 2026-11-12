# 012.002 — Review hardening

## Context

A review of #189 at `11b352ad` measured the continuation on a headless Android
API 36 emulator (`simuse_e2e_api36`). Warm daemon requests were fast again, but
the review found two functional gaps and three smaller defects.

| Finding | Evidence at `11b352ad` |
| --- | --- |
| R189-01: each new process paid provider discovery | `screenshot` and `android ping` bypass the daemon. `android screenshot` had a median of 1,469 ms, against 536 ms on `main`. `adb shell content query` alone took 921 ms. |
| R189-02: a warm client did not recover from another listener | A warm daemon used device port 8080. The bridge restarted on another port, and an unrelated HTTP server that returns 404 took 8080. Each later request failed with `Bridge returned HTTP 404` and sent the bearer token again (four requests, four tokens). Only a daemon restart recovered. |
| R189-03: a port change could strand a forward | After the port change, a new process replaced the forward and the disk session. The daemon then failed, deleted that disk session, and created a third forward. `adb forward --list` showed two forwards to the same device port. |
| R189-04: `init` discovered two times | `initialize` queried the provider, then a new `BridgeClient` queried it again. `portForward` reported the first reply, not the port of the connection. |
| R189-05: library code wrote to stderr | `cleanupEndpoint` wrote a line to stderr. In a daemon the user cannot see it. |

## Decisions

| Finding | Decision | Reason |
| --- | --- | --- |
| R189-01 | `BridgeSession` records `discoveredAt`. A new client reuses the disk session, token included, when a provider discovery created it less than `BridgeClient.restoredSessionTrustWindow` (600 s) ago and `adb forward --list` shows its forward. The unauthenticated handshake still runs before the bearer token is sent. Reuse does not rewrite the file, so the window is not extended. Sessions without `discoveredAt` (older releases) still need discovery. | The disk session now comes from the shell-only provider, so it has the same trust level as the in-memory session of a warm daemon. The boundary that #188 tracks is already accepted for that session. 600 s is the default daemon idle timeout. An ownership check costs one `adb forward --list` call, not one provider query. |
| R189-02 | `BridgeClient` classifies a response that is not HTTP 200. A body that is a bridge JSON envelope is a bridge failure, and the endpoint stays. Other bodies come from another listener: the client discards the endpoint, repeats a GET one time, and reports a POST without replay. | The bridge reports every error as a JSON envelope (`HttpServer.kt`, `ActionRouter.errorJson`). The classification is an inference, so an action is not repeated. One failed request triggers discovery; before, the daemon stayed on the wrong listener. |
| R189-03 | The client does not keep the disk session from `init`. It reads the file when it establishes or discards an endpoint. It deletes the file only when the file still describes the forward that it discards. | The file is the only record of the forward that sim-use processes share for a device. A client that deletes a newer record strands that forward. A client that reads the newer record can reuse its forward. |
| R189-04 | `BridgeClient.connectAfterBridgeStart(startupTimeout:)` forces one provider discovery with the startup polling budget, then runs the handshake. `initialize` reports the port of that connection. | `init` restarts the bridge, so a recent disk session is not sufficient there. One query is sufficient, and the report must describe the connection that was tested. |
| R189-05 | Remove the stderr line. | The original request error is returned, and the session stays for the next call to check. The line added no recovery step. |

A response with HTTP 200 and a body that is not a bridge envelope does not
discard the endpoint. Such a listener is the "plausible response" case of #188.

## Verification

Environment: macOS, headless `simuse_e2e_api36` AVD (Android API 36), serial
`emulator-5554`, debug CLI built from the working tree on `11b352ad`, bridge
APK 24 / 0.16.1. The APK did not change in this round.

Regression tests were added to `BridgeConnectionScopingTests` before the fixes.
Four of them failed against `11b352ad`: reuse of a recent session, GET and POST
recovery after a response from another listener, and reuse of a replaced disk
session. `make test` then passed: 1,622 tests, no failures.

Live checks followed [reproduction.md](reproduction.md). Latency values are
medians of ten calls after two warm-up calls.

| Check | `11b352ad` | This round |
| --- | --- | --- |
| `android screenshot` (new process) | 1,469 ms | 533 ms |
| `android ping` (new process) | 999 ms | 57 ms |
| `keyboard-state` / `ui` / `tap @1` (warm daemon) | 56 / 63 / 79 ms | 62 / 69 / 80 ms |
| Provider queries in `android init` | 2 (from the code) | 1 (adb recording wrapper) |
| adb calls of four new processes after `init` | not measured | 4 `forward --list`, 0 `content query`, 0 new forwards |

- R189-02, GET: with the listener on the warm port, the first `ui` call
  succeeded. The listener saw one request. `adb forward --list` showed one
  forward, to the new device port. The daemon PID did not change.
- R189-02, POST: the first `button home` failed with HTTP 404 and was not
  repeated. The second succeeded. The listener saw one request.
- R189-03: after a port change, `screenshot` in a new process replaced the
  forward. The warm daemon then ran `ui` and `button home` through that
  forward. `adb forward --list` showed one forward at each step.

### Device suites on the final code

`make e2e-android` ran on `5623fe8` (CLI `v0.16.0-8-g5623fe8`) against the
same headless AVD, serial `emulator-5554`. The runner ran the suites in
sequence. All ten suites passed: 29 tests, exit code 0.

| Suite | Tests |
| --- | --- |
| AndroidTapTests | 3 |
| AndroidStreamVideoTests | 5 |
| AndroidRecordVideoTests | 4 |
| AndroidScreenshotTests | 3 |
| AndroidSwipeScrollTests | 3 |
| AndroidTypeTests | 3 |
| AndroidKeyboardStateTests | 1 |
| AndroidMultiTouchTests | 1 |
| AndroidButtonTests | 2 |
| AndroidDescribeUITests | 4 |

After the run, `adb forward --list` showed one forward for the device, to
device port 8080. The run at `11b352ad` in [001-action.md](001-action.md)
covered four of these suites (13 tests).

## Open questions

- The listener in R189-02 still receives the bearer token of the first
  request. #188 tracks endpoint identity.
- A new process inside the trust window has the same boundary as a warm
  daemon: it can send the token to a listener that replaced the bridge and
  answers the handshake like the bridge.
