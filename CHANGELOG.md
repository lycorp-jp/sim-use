# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.0] - 2026-07-09

### Added

- GitHub Actions CI (`.github/workflows/tests.yml`): Swift unit tests on macOS hosted runners (idb-derived FB XCFrameworks cached between runs), bridge Kotlin JVM unit tests on ubuntu, and a bridge protocol parity check — all for every push and pull request targeting `main`. (#26)
- `make build` / `make test` condense swift output via [xcsift](https://github.com/ldomaradzki/xcsift) (TOON summary; test coverage report) when it is installed — strictly optional, plain swift output otherwise; `SIM_USE_XCSIFT=0` forces plain output. (#26)
- `swipe` now accepts `--from x,y --to x,y` and positional `x,y x,y` coordinates on top-level, iOS, Android, and iOS batch surfaces while keeping the existing four coordinate flags. (#27, #30 — thanks @joonyeonglim!)
- `tap` and `long-press` now accept `--point x,y` as a coordinate-pair alternative to `-x`/`-y` on top-level, iOS, Android, and iOS batch surfaces (#25). The two forms are mutually exclusive and resolve through one shared `TapCoordinateResolver`, and `describe-ui --point` now parses through the same `CoordinatePair` grammar as `swipe --from/--to` (a malformed value fails with ArgumentParser's standard invalid-value diagnostic instead of the previous bespoke message). (#40)
- `tap`/`long-press` — and `ios batch` tap steps — now surface a structured advisory when a label/value selector resolves to a near-full-screen element (measured against the Application root frame), so daemon-routed calls show the warning in terminal output and `--json` instead of burying it in the daemon log. (#29, #36 — thanks @joonyeonglim!)

### Changed

- `describe-ui --point` coordinates are now interpreted in the same UI space as the printed outline frames. On a rotated simulator the query is transformed onto the framebuffer before the hit-test (previously the raw point was hit-tested in framebuffer space and returned the wrong element); an upright device behaves exactly as before. (#38)
- `describe-ui` surfaces the calibrated interface orientation: the `App:` header gains a suffix tag (e.g. `(landscape-right)`) when the device is not upright, `--json` `data` gains an `orientation` field, and the alias snapshot records the orientation it was captured under. (#38)
- Swipe coordinate flags now live in a shared `SwipeCoordinateOptions` group, so the top-level, iOS, and Android surfaces validate identically; the swipe success line and `--json` `data` payload derive the coordinates from the execution result (`data` now includes a `coordinates` object). (#30)
- `swipe --duration` is capped at 10 seconds on every surface (parity with `tap` / `multi-touch` / gesture presets). The error message spells out that durations are in seconds, so a millisecond value passed by habit (0.5.x `android swipe`, `adb shell input swipe`) fails loudly instead of producing a multi-minute swipe. (#30)
- JSON output no longer emits the legacy `udid` key (dual-emitted since the `deviceId` transition); `deviceId` is the canonical key in `devices --json`, `daemon stop/status --json`, and Viewer API responses. Inputs (daemon wire decode, Viewer API requests) still accept `udid` as a deprecated alias, to be removed in a future release. (#22)
- `--label`/`--value` exact matching and `--label-contains` (plus the Android-only `--value-contains`) now fall back to whitespace-collapsed comparison when the exact pass finds nothing, on both iOS and Android, so a multi-line label (which the compact `describe-ui` outline renders space-joined) matches the space-joined string an agent copies back. Existing exact matches are unaffected — the fallback only runs when the exact pass matched zero elements. The Android exact pass now end-trims both query and label, matching iOS. The round-trip covers labels the outline renders untruncated (≤ 60 graphemes) and unescaped; longer labels still need the `@N` outline alias or `describe-ui --json` (raw labels). (#28, #31 — thanks @joonyeonglim!)
- Whitespace collapsing is one canonical implementation (`SelectorTextMatcher` in SimUseCore) shared by the iOS/Android outline renderers and both selector resolvers, so the display form and the matching form can never drift apart. The outline now also folds Unicode whitespace the old collapse missed (NBSP, U+2028/U+2029 line separators), so element lines cannot wrap on exotic line breaks. (#31)
- `--wait-timeout` polling now also retries while the selector matches multiple elements (previously only not-found), so a transient ambiguity during a screen transition no longer aborts the wait on the first tick; a stable ambiguity still reports `multipleMatches` with its disambiguation hint once the window expires. (#31)
- Daemon client now retries a command once against the same daemon when the simulator reports the post-boot `transient_booting` readiness gap, matching the long-documented behaviour. (#6)
- Bridge `/swipe` now accepts durations up to 10 s (previously silently clamped to 5 s), covering the full `--duration` range the CLI validates for long-press holds. Bridge `versionCode` bumped to 16. (#8)
- `ios type` builds one HID session for the whole string instead of re-initialising FBSimulatorControl per character. (#9)
- `ios stream-video --format` help now marks `bgra` as experimental (no frame count is reported for that format). (#21)

### Fixed

- `sim-use devices` no longer hangs forever on machines with enough simulators installed to push `simctl list devices -j` past the ~64 KB kernel pipe buffer. `SimctlDeviceLister.runSimctl` now drains stdout/stderr concurrently with the child (the same `readabilityHandler` drain `Adb.run` uses on the Android path) instead of reading only after `waitUntilExit()`, which deadlocked once the child blocked on `write(2)`. (#39 — thanks @JustHm!)
- The root `sim-use --help` abstract no longer claims the tool is iOS-Simulator-only; it now mentions Android emulators/devices as well. (#35)
- iOS taps resolved through accessibility (`tap @N` / `#N` / `#<id>` / the `--label` family, batch tap steps, `paste --via-menu` targets and edit-menu items) now land correctly when the simulator or the app is rotated (#34). AX frames are reported in the app's UI space while HID events are interpreted in the device-native portrait framebuffer; sim-use now self-calibrates the orientation per command with 1–3 accessibility hit-test probes and transforms AX-derived coordinates before dispatch. Explicit `-x/-y` coordinates keep their raw framebuffer semantics. When calibration cannot be confirmed (empty or fully symmetric screens) the command falls back to portrait and surfaces an `orientation_calibration_fallback` advisory. (#38)
- `describe-ui` quadtree recovery no longer silently drops whole regions on rotated simulators — the same #34 coordinate mismatch corrupted its coverage bookkeeping (live repro: the entire Settings sidebar vanished from the outline on an upside-down iPad). (#38)
- `describe-ui --point` no longer overwrites the `@N` alias snapshot with a single-element table, so `tap @N` keeps resolving against the last full outline after a point query. (#38)
- `android swipe` invoked directly now enforces the same coordinate rules as the other surfaces: negative coordinates and identical start/end points are rejected at validate time instead of being forwarded to the bridge. (#30)
- Swipe coordinates are validated as finite and ≤ 100000 on all surfaces, so values like `inf`, `nan`, or `1e19` fail with a clean validation error instead of trapping the daemon in the Double→Int conversion. (#30)
- Tap and long-press coordinates get the same finite / ≤ 100000 validation on every surface — `tap -x inf -y 5` or `-x 1e19` targeting an Android device previously trapped the Double→Int conversion instead of failing with a clean validation error. (#40)
- The top-level `swipe` and `android swipe` no longer disagree on fractional Android coordinates (truncation vs rounding); both round half away from zero via shared accessors. (#30)
- `android swipe --pre-delay`/`--post-delay` are bounded to 0–10 seconds like every other surface; the previous sign-only check let `inf`/`nan` through into the Double→UInt64 sleep conversion, which trapped the daemon. (#30)
- Android swipe rejects coordinate pairs that round to the same integer pixel (e.g. `--from 10.4,10.4 --to 10.49,10.49`), which previously passed the Double comparison but dispatched a degenerate same-point gesture to the bridge. (#30)
- `DaemonClient.stopDaemon` no longer waits on and SIGTERMs a pidfile pid that is the caller's own process (a stale pidfile can hold a recycled pid; in-process daemons in tests always do). Signalling ourselves fanned out through every live `DaemonServer`'s SIGTERM source and tore down unrelated daemons mid-request — the main source of daemon-test flakiness under parallel load. (#26)
- Cached HID connection is now validated against the simulator's boot instance before reuse, so a simulator shut down and re-booted under the same UDID gets a fresh connection instead of hanging the daemon (or failing every command) on the dead one until restart. Additionally, any failed HID perform drops the cached connection, and failures that provably happened before delivery (dead mach port) are transparently retried once against a rebuilt session. (#23)
- `ios batch --ax-cache` was a complete no-op: the default `perBatch` never cached and every selector-based step refetched the AX tree. `perBatch` now resolves all steps against one snapshot, `perStep` refetches at each step, `none` never caches, and `--wait-timeout` poll ticks bypass the cache (updating it) so delayed elements are still found. (#20)
- Daemon client no longer tears down a healthy daemon and re-executes the command when the daemon answers with a command-level error (element not found, etc.). Failed commands now surface immediately instead of paying a full daemon respawn, and side-effecting commands are no longer executed twice. (#6)
- Daemon shutdown no longer deletes the socket/pidfile of a successor daemon that took the paths over, which previously chained invisible orphan daemons. (#7)
- Daemon base directory under `/tmp` is now validated on every run (symlinks, foreign owners rejected; loose permissions tightened to 0700) instead of trusting whatever was pre-created there. (#7)
- Bridge `/a11y_tree_full` no longer reads the active root's `windowId` after the node was recycled, which silently dropped popup/dialog secondary windows on Android 11–12. (#8)
- Bridge `/keyboard/input` no longer leaks the borrowed root `AccessibilityNodeInfo` on every call. (#8)
- `record-video` no longer hot-spins without frame pacing when screenshot frames persistently fail to decode. (#9)
- `record-video` no longer hangs forever when AVAssetWriter stops accepting frames; a stalled writer now fails the recording with an explicit error after 10 s. (#19)
- Daemon no longer shuts itself down in the middle of a request that runs longer than the idle timeout (e.g. `tap --wait-timeout` beyond the timeout, or a long `batch`). The idle timer now defers shutdown while a request is in flight. (#13)
- Daemon client no longer respawns and resends a command when the daemon drops the connection *after* receiving the request (a possible mid-execution crash). Such ambiguous outcomes now surface a dedicated error with a hint to re-observe the screen before retrying, so a side-effecting verb (tap/type/swipe) is never silently applied twice. Pre-delivery failures (connect/write) still respawn as before. (#12)
- `keyboard-state` now routes through the per-UDID daemon like every other verb (amortised init) and surfaces crash advisories and error `Hint:` lines; a vestigial `run()` override had silently opted it out. The `soft`/`hidden`/failure exit codes are unchanged. (#11)
- `ios stream-video` with the BGRA pixel format no longer exits 0 when the underlying stream fails to start or dies mid-stream; startup and mid-stream errors now terminate the streaming loop and surface as a non-zero exit instead of a stderr-only message. (#21)
- `record-video`'s stop watchdog no longer exits 0 when video finalization overruns its grace window, which could report success for a truncated/unplayable MP4. It now warns on stderr and exits 70 (`EX_SOFTWARE`), and the grace window is 3 s (was 1.5 s). (#18)
- Viewer API no longer reports success when the underlying sim-use invocation exits non-zero without a parseable JSON envelope; the subprocess's stderr is now surfaced in the error response instead of a generic JSON-parse failure. (#17)
- `sim-use android tap` no longer crashes on every invocation with ArgumentParser's "can't read a value from a parsable argument definition" fatal. `performTap`'s default `MultiTouchOptions()` was a directly-initialized `ParsableArguments` value, and the first `.fingers` read trapped before anything was dispatched; the parameter is now optional with `nil` meaning single-touch. The top-level `sim-use tap` routed to Android was unaffected (it passes its parsed options through). (#41)
- The bundled skill's `preflight.py` daemon-restart autofix no longer appends the session `--device` flag to `daemon stop --all` (the two are mutually exclusive), so the autofix actually stops the stale daemon instead of failing with exit 64 while reporting success. (#2 — thanks @viseator!)

### Removed

- Dead `.hidSwipePerformed` notification posted by `ios swipe` — nothing ever observed it since its introduction. (#14)

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
