# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `swipe` now accepts `--from x,y --to x,y` and positional `x,y x,y` coordinates on top-level, iOS, Android, and iOS batch surfaces while keeping the existing four coordinate flags.
- `tap`/`long-press` now print a non-fatal `[i]` advisory to stderr when a `--label`/`--value`/`--label-contains` selector resolves to an element covering ≥90% of the screen — a common footgun on canvas-rendered UIs (e.g. Flutter) where a full-screen wrapper element makes the tap land on the screen centre instead of the intended control. The tap still fires; the advisory recommends a positional `@N`/`#N` alias or explicit coordinates.

### Changed

- `--label`/`--value` exact matching and `--label-contains` now fall back to whitespace-collapsed comparison when the exact pass finds nothing, so a multi-line `AXLabel` (which the compact `describe-ui` outline renders space-joined) matches the space-joined string an agent copies back. Existing exact matches are unaffected — the fallback only runs when the exact pass matched zero elements.
- Daemon client now retries a command once against the same daemon when the simulator reports the post-boot `transient_booting` readiness gap, matching the long-documented behaviour.
- Bridge `/swipe` now accepts durations up to 10 s (previously silently clamped to 5 s), covering the full `--duration` range the CLI validates for long-press holds. Bridge `versionCode` bumped to 16.
- `ios type` builds one HID session for the whole string instead of re-initialising FBSimulatorControl per character.

### Fixed

- Daemon client no longer tears down a healthy daemon and re-executes the command when the daemon answers with a command-level error (element not found, etc.). Failed commands now surface immediately instead of paying a full daemon respawn, and side-effecting commands are no longer executed twice.
- Daemon shutdown no longer deletes the socket/pidfile of a successor daemon that took the paths over, which previously chained invisible orphan daemons.
- Daemon base directory under `/tmp` is now validated on every run (symlinks, foreign owners rejected; loose permissions tightened to 0700) instead of trusting whatever was pre-created there.
- Bridge `/a11y_tree_full` no longer reads the active root's `windowId` after the node was recycled, which silently dropped popup/dialog secondary windows on Android 11–12.
- Bridge `/keyboard/input` no longer leaks the borrowed root `AccessibilityNodeInfo` on every call.
- `record-video` no longer hot-spins without frame pacing when screenshot frames persistently fail to decode.
- Daemon no longer shuts itself down in the middle of a request that runs longer than the idle timeout (e.g. `tap --wait-timeout` beyond the timeout, or a long `batch`). The idle timer now defers shutdown while a request is in flight.
- Daemon client no longer respawns and resends a command when the daemon drops the connection *after* receiving the request (a possible mid-execution crash). Such ambiguous outcomes now surface a dedicated error with a hint to re-observe the screen before retrying, so a side-effecting verb (tap/type/swipe) is never silently applied twice. Pre-delivery failures (connect/write) still respawn as before.
- `keyboard-state` now routes through the per-UDID daemon like every other verb (amortised init) and surfaces crash advisories and error `Hint:` lines; a vestigial `run()` override had silently opted it out. The `soft`/`hidden`/failure exit codes are unchanged.

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
