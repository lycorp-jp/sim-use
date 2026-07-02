# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Daemon shutdown no longer deletes the socket/pidfile of a successor daemon that took the paths over, which previously chained invisible orphan daemons.
- Daemon base directory under `/tmp` is now validated on every run (symlinks, foreign owners rejected; loose permissions tightened to 0700) instead of trusting whatever was pre-created there.

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
