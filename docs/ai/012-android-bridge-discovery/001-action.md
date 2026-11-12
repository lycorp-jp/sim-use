# 012 — Android bridge endpoint discovery: Action log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-12 | Retained the contributor's endpoint discovery and action retry commit without changes. | #185, `ff966c0e1821042191b9c1c21845d8fb400c00a0` |
| 2026-11-12 | Added cold/failure discovery, session generations, and HTTP outside the state lock. | `fix/bridge-port-fallback-takeover` |
| 2026-11-12 | Replaced the fixed fallback range with a loopback port 0 bind. Verified unit tests and live Android behavior. | #189 |
| 2026-11-12 | Recorded the remaining warm endpoint identity boundary. | #188 |

## Outcome (as of 2026-11-12)

The continuation is implemented and verified on its branch. Merge is pending.
The original commit by @iopass4 remains an unchanged ancestor. Use a merge
commit when this continuation lands to retain the contribution history.

- `Sources/AndroidBackend/Bridge/BridgeClient.swift` discovers an endpoint on
  cold setup and after failure. Restored disk sessions require discovery and
  forward ownership checks before HTTP. Warm bridge operations run no adb
  commands. The state lock does not cover HTTP or response decoding.
- Immutable session snapshots carry a generation. Old display responses cannot
  replace the current cache, and old failures cannot remove a newer forward.
  Cleanup checks ownership and preserves the triggering error if cleanup fails.
- A business request has at most one replay. GET transport failures can retry;
  POST retries require connection refusal or HTTP 401. Timeout, cancellation,
  lost connection, and business HTTP 500 do not cause action replay.
- `bridge/app/src/main/java/com/linecorp/simuse/devicebridge/server/HttpServer.kt`
  first binds `127.0.0.1:8080`, then loopback port 0 on a bind conflict. Discovery
  publishes the actual port. APK metadata is 24 / 0.16.1. HTTP protocol remains
  2 because the provider fields are additive and HTTP envelopes are unchanged.

## Verification

Environment: macOS, Xcode 27.0 (27A266a), Android API 36 emulator, headless
`simuse_e2e_api36` AVD, serial `emulator-5580`. Commands ran from the repository
root. Local logs and measurements are in `.build/pr185-takeover/`.

| Check | Result |
| --- | --- |
| Warm-path regression before the client change | Failed against the original #185 implementation because warm calls ran adb queries. |
| `make test` | Passed; 1,613 tests, no failures. |
| `./bridge/gradlew -p bridge :app:testDebugUnitTest` with supported JDK and Android SDK | Passed; 52 tests. |
| `./scripts/build-bridge.sh` | Passed; refreshed the bundled release APK. |
| `make build` | Passed after the APK refresh. |
| `git diff --check` | Passed. |
| AndroidTapTests / AndroidTypeTests / AndroidDescribeUITests / AndroidScreenshotTests | Passed serially through the Android runner; 13 tests in four suites. |

The Swift regressions cover warm ping/tree/action/display adb counts, bounded
recovery, cold bearer isolation, forward ownership, action attempt counts,
overlapping HTTP, and stale cache/cleanup results. Kotlin tests cover preferred
and ephemeral loopback binding and provider lifecycle snapshots.

The device suites used this invocation once per suite, in sequence:

```bash
ANDROID_SERIAL=emulator-5580 \
SIM_USE_ADB="$ANDROID_HOME/platform-tools/adb" \
SIM_USE_TEST_BINARY="$PWD/.build/debug/sim-use" \
SIM_USE_SKIP_BRIDGE_VERSION_CHECK=1 \
  ./scripts/test-runner-android.sh -t AndroidTapTests
```

An initial combined test filter ran the device suites concurrently. They
interfered with each other's screens. That invalid run was replaced by the
serial runner results above.

Live checks followed [reproduction.md](reproduction.md):

- With an unrelated listener on 8080, init succeeded on device port 42239.
  UI, tap, and screenshot succeeded. The unrelated listener received zero
  requests and zero Authorization headers.
- Forced port changes, 42239 to 38547 to 41771, recovered through a GET
  transport failure and a tap connection refusal. The daemon PID stayed the
  same. Warm calls after each recovery succeeded.
- With the same installed APK and screen, seven warm `describe-ui` samples
  had medians of 2.125 s for the original #185 CLI and 0.089 s for this branch.
  Total adb calls per warm invocation fell from five to one. The remaining call
  is the existing process-liveness probe; bridge discovery and forward queries
  fell from four to zero. These are local measurements, not a latency guarantee.

## Deviations from plan

The original contribution combines discovery and POST retry changes in one
commit. Separate independent PRs would require rewriting that contribution.
The continuation retains it and uses separate follow-up commits instead.

## Open questions

A warm bridge restart can leave an unrelated listener at the cached device
port. A successful adb ownership check does not authenticate that listener.
This accepted boundary and possible low-cost identity checks are tracked in
#188. Per-request discovery is not restored as a mitigation.
