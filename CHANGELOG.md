# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- GitHub Actions CI (`.github/workflows/tests.yml`): Swift unit tests on macOS hosted runners (idb-derived FB XCFrameworks cached between runs), bridge Kotlin JVM unit tests on ubuntu, and a bridge protocol parity check — all for every push and pull request targeting `main`.

### Changed

- JSON output no longer emits the legacy `udid` key (dual-emitted since the `deviceId` transition); `deviceId` is the canonical key in `devices --json`, `daemon stop/status --json`, and Viewer API responses. Inputs (daemon wire decode, Viewer API requests) still accept `udid` as a deprecated alias, to be removed in a future release.
- Daemon client now retries a command once against the same daemon when the simulator reports the post-boot `transient_booting` readiness gap, matching the long-documented behaviour.
- Bridge `/swipe` now accepts durations up to 10 s (previously silently clamped to 5 s), covering the full `--duration` range the CLI validates for long-press holds. Bridge `versionCode` bumped to 16.
- `ios type` builds one HID session for the whole string instead of re-initialising FBSimulatorControl per character.
- `ios stream-video --format` help now marks `bgra` as experimental (no frame count is reported for that format).

### Fixed

- `DaemonClient.stopDaemon` no longer waits on and SIGTERMs a pidfile pid that is the caller's own process (a stale pidfile can hold a recycled pid; in-process daemons in tests always do). Signalling ourselves fanned out through every live `DaemonServer`'s SIGTERM source and tore down unrelated daemons mid-request — the main source of daemon-test flakiness under parallel load.
- Cached HID connection is now validated against the simulator's boot instance before reuse, so a simulator shut down and re-booted under the same UDID gets a fresh connection instead of hanging the daemon (or failing every command) on the dead one until restart. Additionally, any failed HID perform drops the cached connection, and failures that provably happened before delivery (dead mach port) are transparently retried once against a rebuilt session.
- `ios batch --ax-cache` was a complete no-op: the default `perBatch` never cached and every selector-based step refetched the AX tree. `perBatch` now resolves all steps against one snapshot, `perStep` refetches at each step, `none` never caches, and `--wait-timeout` poll ticks bypass the cache (updating it) so delayed elements are still found.
- Daemon client no longer tears down a healthy daemon and re-executes the command when the daemon answers with a command-level error (element not found, etc.). Failed commands now surface immediately instead of paying a full daemon respawn, and side-effecting commands are no longer executed twice.
- Daemon shutdown no longer deletes the socket/pidfile of a successor daemon that took the paths over, which previously chained invisible orphan daemons.
- Daemon base directory under `/tmp` is now validated on every run (symlinks, foreign owners rejected; loose permissions tightened to 0700) instead of trusting whatever was pre-created there.
- Bridge `/a11y_tree_full` no longer reads the active root's `windowId` after the node was recycled, which silently dropped popup/dialog secondary windows on Android 11–12.
- Bridge `/keyboard/input` no longer leaks the borrowed root `AccessibilityNodeInfo` on every call.
- `record-video` no longer hot-spins without frame pacing when screenshot frames persistently fail to decode.
- `record-video` no longer hangs forever when AVAssetWriter stops accepting frames; a stalled writer now fails the recording with an explicit error after 10 s.
- Daemon no longer shuts itself down in the middle of a request that runs longer than the idle timeout (e.g. `tap --wait-timeout` beyond the timeout, or a long `batch`). The idle timer now defers shutdown while a request is in flight.
- Daemon client no longer respawns and resends a command when the daemon drops the connection *after* receiving the request (a possible mid-execution crash). Such ambiguous outcomes now surface a dedicated error with a hint to re-observe the screen before retrying, so a side-effecting verb (tap/type/swipe) is never silently applied twice. Pre-delivery failures (connect/write) still respawn as before.
- `keyboard-state` now routes through the per-UDID daemon like every other verb (amortised init) and surfaces crash advisories and error `Hint:` lines; a vestigial `run()` override had silently opted it out. The `soft`/`hidden`/failure exit codes are unchanged.
- `ios stream-video` with the BGRA pixel format no longer exits 0 when the underlying stream fails to start or dies mid-stream; startup and mid-stream errors now terminate the streaming loop and surface as a non-zero exit instead of a stderr-only message.
- `record-video`'s stop watchdog no longer exits 0 when video finalization overruns its grace window, which could report success for a truncated/unplayable MP4. It now warns on stderr and exits 70 (`EX_SOFTWARE`), and the grace window is 3 s (was 1.5 s).
- Viewer API no longer reports success when the underlying sim-use invocation exits non-zero without a parseable JSON envelope; the subprocess's stderr is now surfaced in the error response instead of a generic JSON-parse failure.

### Removed

- Dead `.hidSwipePerformed` notification posted by `ios swipe` — nothing ever observed it since its introduction.

## [0.9.0] - 2026-06-29

Initial public release.

### Added

- Cross-platform CLI driving iOS Simulator and Android emulator/device through a single command surface.
- `ui` (alias: `describe-ui`) — compact, token-efficient screen outline with `@N` alias addressing and `#<id>` / `#N` / `#N@M` selectors.
- Full interaction surface: `tap`, `swipe`, `long-press`, `touch`, `type`, `paste`, `button`, `gesture`, `multi-touch`, `keyboard-state`, `screenshot`, `record-video`, `app-state`.
- iOS-only verbs under `sim-use ios`: `key`, `key-combo`, `key-sequence`, `stream-video`, `batch`.
- Android bridge APK (`bridge/`) with AccessibilityService + HTTP server, bootstrapped via `sim-use android init`.
- Per-UDID background daemon for iOS, amortising per-call init cost.
- Cross-command crash / termination detection with process-liveness tracking and Android crash-dialog detection.
- `sim-use viewer` — bundled local web app for visualising the accessibility tree with blind-spot overlay.
- `sim-use init` — install the bundled agent skill into Claude Code or other AI clients.
- `--json` envelope on every command for machine consumption.
- Homebrew formula via `brew tap lycorp-jp/tap && brew install sim-use`.
