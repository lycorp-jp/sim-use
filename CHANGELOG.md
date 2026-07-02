# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Daemon client now retries a command once against the same daemon when the simulator reports the post-boot `transient_booting` readiness gap, matching the long-documented behaviour.

### Fixed

- Daemon client no longer tears down a healthy daemon and re-executes the command when the daemon answers with a command-level error (element not found, etc.). Failed commands now surface immediately instead of paying a full daemon respawn, and side-effecting commands are no longer executed twice.

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
