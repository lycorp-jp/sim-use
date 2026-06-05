# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-06-25

### Added

- Cross-command crash / termination awareness. While a per-UDID daemon drives a device, sim-use watches the target's process liveness between commands and surfaces a death the moment the next command runs — no polling. The signal is process liveness (a hosted-app pid that was alive and is now gone), never foreground identity, so legitimate backgrounding (permission sheet, share sheet, app switcher) never false-fires while crash-and-relaunch (same bundle, new pid) is caught. A death surfaces three ways: a loud `==== PROCESS DISAPPEARED ====` banner above the `App:` header (with a `[!]` sticky reminder on later commands and a quiet `[i]` line for low-confidence idle-gap deaths), a reconciled `App:` header showing the real foreground (`SpringBoard` on iOS, the launcher package on Android — never a stale or empty app name), and a sibling `process` object in `--json` (`{ events: [{ kind, bundleId, pid, confidence }], pending }`, `kind` ∈ `disappeared` | `replaced` | `changed_while_idle`). sim-use reports the fact and a confidence band, never a verdict. Idle-gap deaths (default 120 s window, `SIM_USE_CRASH_WINDOW`) are downgraded and re-baselined so an out-of-band kill never raises a false alarm; `SIM_USE_NO_CRASH_DETECT=1` disables it entirely ([#83](https://github.com/lycorp-jp/sim-use/pull/83), issue [#81](https://github.com/lycorp-jp/sim-use/issues/81)).
- `sim-use app-state` — a lightweight read of which apps are running (no accessibility-tree fetch; `launchctl` on iOS, `ps` / `pm` on Android). `--bundle-id <id>` answers `running` | `not_running`; `--reset` re-baselines crash detection and clears any pending signal (after an intentional relaunch, attaching to an already-running app, or accepting a crash). Cross-platform via the standard verb dispatch ([#83](https://github.com/lycorp-jp/sim-use/pull/83)).
- Android timing-insensitive crash-dialog detection. `describe-ui` now detects the system "<app> keeps stopping" dialog directly from the accessibility tree, matching the locked AOSP framework resource ids (`android:id/aerr_close` / `aerr_app_info`) — app-agnostic and locale-independent. The dialog is on screen for a few seconds before the crashed process fully exits, so this catches a crash during the window where the process-liveness check may not yet fire. Surfaced as a `==== CRASH DIALOG DETECTED ====` banner above the outline and, in `--json`, under `data.crashDialog`. Works standalone (no daemon) and is independent of the process-liveness signal — either alone is a sufficient crash hint.
- Viewer blind-spot overlay. `sim-use viewer` can highlight regions the accessibility tree can't address — gaps where no actionable element is reported — so a human auditing a screen sees where automation is blind. Containers and non-actionable roles are excluded so it flags only genuine blind spots; the selection colour moved to purple for contrast.

### Fixed

- Actionable errors for Xcode 27 breakages. Xcode 27 removed SimulatorKit and its `dtuhidd` daemon kills keyboard HID system-wide; sim-use now surfaces a clear error pointing at the Device Hub re-boot fix instead of an opaque failure ([#85](https://github.com/lycorp-jp/sim-use/pull/85)).
- `sim-use viewer` rejects negative or malformed `Content-Length` headers instead of crashing `subdata(in:)` on the malformed request ([#86](https://github.com/lycorp-jp/sim-use/pull/86)).
- Android `describe-ui` now uses the recalculated depth when renumbering outline entries, fixing `@N` numbering after entries are folded.

- Initial public release.
