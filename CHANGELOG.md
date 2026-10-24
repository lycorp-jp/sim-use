# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Notarized Homebrew packages retain their original Developer ID signature after installation.

### Changed

- iOS: `type` is much faster on long text, for example about 0.4 s instead of 6 s for 66 mixed-case characters. The stabilization delay now runs once after the text instead of after every key event; set `SIM_USE_TYPE_KEY_DELAY_MS` if a text control needs a pause between keys.

### Fixed

- Homebrew: preserve the upstream signature for notarized releases instead of replacing it with an ad-hoc signature. Release installation checks now use the same formula generator and verify that Homebrew leaves the signed binary unchanged.

## [0.16.0] - 2026-10-21

Control the iPhone Duo's inner and cover displays and apps in Xcode Resize Mode, with new fold and rotation commands. iOS coordinates now match the `ui` outline by default; scripts that use device-native portrait coordinates must add `--coordinate-space native`. Unicode paste works again with Simulator.app and Device Hub, with safeguards against duplicate or misplaced input.

### Added

- iOS: interact with apps on the iPhone Duo's inner display or in Xcode Resize Mode. Touches, UI queries and screenshots follow the app's display, including after rotation; the bundled skill now requires sim-use 0.16.0. (#157, #158, #164, #165, #170)
- `sim-use ios fold closed|open|half|<degrees>` folds or unfolds an iPhone Duo simulator. Run it without an argument to read the current posture; `open` and `closed` confirm that the expected display becomes active. (#157, #165)
- `sim-use ios rotate <orientation>` rotates a simulator and reports whether the app accepted the change. Fold and rotation commands clear old `@N` references so they cannot target the previous layout. (#157, #165)
- iOS: record and stream the app's display on an unfolded iPhone Duo or in Resize Mode with `record-video` and `stream-video --format h264|bgra`. Capture stays on its starting display and warns if the app moves or resizes; older screenshot-based stream formats still require the main display. (#164, #165)
- iOS: the `ui` outline groups vertical navigation and tab bars into `Leading` or `Trailing` regions on iPhone Duo apps built with the iOS 27.1 SDK, making controls easier to find. (#163, #169, #171)

### Changed

- **Breaking — iOS coordinates now use the same space as the `ui` outline.** Taps, swipes, touches, multi-touch, gesture geometry, menu-paste targets and batch steps follow this default. Add `--coordinate-space native` if your scripts use device-native portrait points; the flag is not valid with selectors, aliases or directional gesture presets. (#161, #163)
- iOS: touch commands and menu-based paste now work in Xcode Resize Mode instead of refusing to run. The outline identifies the resized display, and commands return to the main display when the session ends. (#143, #158, #164, #165 — thanks @iXerol!)
- iOS: `ui`, `ios fold` and `ios rotate` call the iPhone Duo's screens `inner display` and `cover display`, rather than showing system names. Raw display names in JSON are unchanged. (#170)
- iOS: when screen probes cannot confirm orientation, commands use the rotation reported by the simulator instead of guessing or showing an unnecessary warning. (#158)
- iOS: `ui --point` now checks the app's current layout before identifying a control. The first query after Resize Mode starts describes the app rather than the home screen, at the cost of an extra UI read. (#158)

### Fixed

- iOS: Unicode `paste` works again with Simulator.app and Device Hub in either keyboard mode, preserving the caret and selection. `--replace` waits for Select All before pasting; shared clipboard sync can still affect the Mac and other devices. (#172)
- iOS: menu-based paste no longer retries after a potentially delivered action or taps unrelated app controls. Replacement requires a confirmed selection or an empty field, and localized Paste and Select All menus are recognized, including Russian and Portuguese. (#172)
- iOS: a failed batch no longer automatically repeats completed steps, which could paste text twice. Check the completed steps before retrying a failed batch yourself. (#172)
- iOS: batch paste steps now use the same clipboard checks and safe replacement as standalone paste, including `--via-menu`. Text starting with `-` is preserved, and a step cannot change the batch's target device. (#172)
- iOS: typing and keyboard commands keep working after folding or rotating an iPhone Duo with Device Hub closed. Touches on the inner display or in Resize Mode also work without opening Device Hub first. (#165)
- iOS: pinch and rotate gestures in `ios batch` now perform the requested two-finger gesture and honor its settings, rather than sending a single-finger swipe. (#161, #163)
- Physical iOS: `ui` and `tap` briefly retry when an app's UI is not ready just after launch, instead of immediately suggesting that the device is locked or the app lacks development permissions. (#110, #156 — thanks @mvanhorn!)
- iOS: the outline recognizes iPhone Duo side bars beside narrow cards or small content elements, rather than mixing navigation controls into the content. (#171)
- iOS: content that extends beyond its pane no longer hides an iPhone Duo side bar from the outline or gets grouped into that bar. (#169)
- iOS: a failed `ui` read now explains that the app's UI could not be read and gives recovery advice, including how to restart the simulator's accessibility service when it stops responding. (#168)
- iOS: `stream-video --format bgra` produces correctly sized pixel frames on displays such as the iPhone Duo cover, including with `--scale`, so raw-video players can decode them. (#164, #165)
- Viewer: errors and recovery hints are no longer lost when a command exits immediately. (#165)

## [0.15.0] - 2026-10-14

Run Android automation on Linux and through remote adb servers, including WSL setups. H.264 streaming is smoother on iOS and no longer accumulates delay on Android; **Android stream consumers must now read MPEG-TS instead of bare H.264**. Xcode Resize Mode is detected explicitly, so unsupported actions fail with guidance rather than silently doing nothing.

### Added

- Linux support for Android automation with a Swift 6 toolchain. Use `scripts/install-linux.sh` to install; UI inspection, input, screenshots and app-state commands work as on macOS, while iOS, video, Viewer and skill installation remain macOS-only. (#141, #147 — thanks @iopass4!)
- Connect to Android devices through a remote adb server, such as Windows adb from WSL. sim-use uses the server's host for the bridge, supports a `SIM_USE_BRIDGE_HOST` override, and keeps cached connections separate when servers change. (#141, #147 — thanks @iopass4!)
- iOS: `stream-video --format h264` provides smoother live previews with much less data than screenshot-based streaming. It uses the same player command as Android. (#132, #133)
- iOS: detect Xcode Resize Mode and capture the resized app with `screenshot`. UI reads warn about the session, and unsupported touch and video commands stop with an explanation instead of reporting success; the bundled skill now requires sim-use 0.15.0. (#143, #150 — thanks @iXerol!)
- iOS: `tap --coordinate-space ui` lets you use coordinates copied from the outline on a rotated screen. Device-native portrait coordinates remain the default in this version. (#142, #144 — thanks @iXerol!)
- `sim-use android ui` is now a short form of `android describe-ui`, matching the top-level command. (#141, #147 — thanks @iopass4!)

### Changed

- **Android H.264 streams now use MPEG-TS instead of bare H.264.** Update consumers to read MPEG-TS; previews no longer accumulate delay during interaction or after a long pause on a still screen. Recordings still preserve real elapsed time. (#135, #136)
- Preview H.264 streams on either platform with `ffplay -f mpegts -probesize 32768 -i -`. This replaces a command that could fail to open Android streams; a still Android screen may need interaction before playback starts. (#136)
- iOS: screenshot-based stream formats (`mjpeg`, `raw`, `ffmpeg`) are deprecated; use `--format h264` for better frame rates and smaller streams. Android's equivalent formats and iOS `bgra` remain available without a warning. (#134, #138)
- iOS: recording and streaming now share encoder settings, keeping picture quality consistent between the two commands. MP4 recordings remain compatible with QuickTime, Finder and GIF conversion. (#132, #133)

### Fixed

- iOS: with Device Hub open, `batch --stdin`, `batch --file`, `type --stdin` and `paste --stdin` now deliver their input rather than silently doing nothing. Relative paths for `type --file` and `paste --file` now use the caller's directory. (#154)
- iOS: Resize Mode outlines no longer include home-screen controls or report an incorrect orientation. (#143, #150 — thanks @iXerol!)
- iOS: paused or unresponsive video consumers no longer prevent Ctrl-C from stopping H.264 or BGRA streams. Closing the receiving player ends the stream cleanly. (#138)
- Android: failed bridge connections remove the port forwards they created, rather than leaving another unused forward after each attempt. (#147)
- Android: reconnecting removes the stale forward from the correct device, including when several devices are connected. (#147)
- The bundled skill warns when a successful UI read returns missing or incomplete app content, and points to recovery guidance instead of treating the screen as ready. (#139, #145 — thanks @SunsetWan!)
- The bundled skill checks the CLI version before looking for devices and gives an upgrade command when it is too old, rather than misreporting a disconnected device. (#127 — thanks @BoWuGit!)
- iOS: ambiguous selector errors show the actual match count and enough detail to choose a control. Recovery hints suggest useful filters and the current `--device` option. (#146)

## [0.14.0] - 2026-08-27

Inspect and interact with development-signed apps on physical iPhones and iPads, and capture screenshots even outside those apps. Connected iOS devices now appear alongside simulators and Android targets, with `ui`, selector-based `tap` and `screenshot` available through the usual top-level commands. GIF recordings can also include visible start and end markers.

### Added

- Experimental physical iPhone and iPad support through `sim-use ios-device`: read the foreground app's UI and tap controls by label, without installing a test runner. The device must be unlocked and the app must have `get-task-allow=true`; coordinate taps, swipes and gestures are not supported. (#93, #99 — thanks @subdiox!)
- Use top-level `sim-use ui`, selector-based `tap` and `screenshot` with a physical iOS device. Unsupported actions explain the limitation and suggest an alternative; `ios-device` remains available for device-specific options. (#126)
- `sim-use devices` lists USB-connected iPhones and iPads alongside other targets. A new `kind` field distinguishes simulators, emulators and physical devices; use `--no-physical-ios` to skip iOS hardware discovery. (#122)
- `sim-use ios-device screenshot` saves whatever is on the device's screen, including system apps and the home screen. Unlike UI inspection and tapping, it does not require a development-signed app, and a failed capture leaves an existing output file intact. (#118)
- Physical iOS outlines show accessibility identifiers as `#id`, which `tap` accepts directly or through `--id`. Use these stable identifiers when a control's visible label changes. (#114)
- `ios-device` commands support `--json` for shared automation scripts, with structured results and recovery hints. Commands still open a device session each time; session reuse is tracked separately in #120. (#123)
- `record-video --gif-markers` adds START and END cards to GIFs, making the boundaries of a looping demo clear. Screen-only capture remains the default. (#100, #101 — thanks @kws0210!)

### Fixed

- Physical iOS outlines no longer omit the navigation-bar back button, so it can be found and tapped like other controls. (#114)
- All attached iOS devices are discovered reliably when several are connected at once. (#99)
- Physical iOS commands report empty UI trees, missing or ambiguous targets, and invalid query settings instead of claiming success or choosing a control silently. (#99)
- Unrelated device notifications no longer get mistaken for command replies, preventing incorrect physical-device results. (#99)
- `sim-use ios` commands direct physical-device users to the supported commands instead of misidentifying their iPhone as an unreachable Android device. (#99, #126)
- Physical-device discovery returns in about a second when no iPhone or iPad is attached, rather than waiting five seconds. (#117)
- Device names containing `/` no longer turn default screenshot filenames into unintended directory paths. (#119)

## [0.13.0] - 2026-08-06

Record animated GIFs on iOS and Android for demos and bug reports. Input targeting is more accurate on iPhone mini and older Plus models, and UI outlines now show text in multi-line editors so automation can verify what it entered.

### Added

- `record-video --format gif`, or an output filename ending in `.gif`, creates a looping GIF on either platform. Adjust frame rate and size with `--fps` and `--scale`; if conversion fails, the original MP4 is kept. (#84 — thanks @kws0210!)

### Fixed

- iOS: taps, swipes and point queries target the correct controls on iPhone 12/13 mini and older Plus models, where display scaling previously shifted input away from the intended position. (#90 — thanks @subdiox!)
- iOS: small controls and screen edges are read more accurately on those scaled displays, improving orientation detection and recovery of missing content such as document pickers. (#64, #92)
- iOS outlines show values for multi-line text editors, sliders and buttons, so entered chat text can be checked without switching to JSON. Values that only repeat the label are omitted. (#87)
- JPEG scaling produces the requested pixel dimensions on Retina displays, rather than images larger than requested. (#83, #85 — thanks @EuanTop!)
- `type ""` is a true no-op, including when an empty shell variable is passed on a machine without a usable Xcode setup. (#92)
- Custom builds now honor `SIM_USE_VERSION`, so development and release binaries report the requested version instead of a stale Git-derived version.

## [0.12.0] - 2026-07-29

Device Hub workflows now work on Xcode 27 without rebooting into a different setup. Video recording is smoother and uses less CPU, and Android gains live streaming through the same top-level command as iOS. Rotated-screen gestures and smaller UI output make automation easier to use.

### Added

- Android live streaming through `sim-use stream-video` or `android stream-video`, with efficient H.264 and screenshot-based alternatives. Streams continue past Android's recording time limit, stop cleanly when the consumer closes, and report capture failures; `--json` is rejected because stdout carries video. (#78, #80)
- `sim-use android record-video` provides direct access to Android recording, with the same options as the top-level command. (#79)
- iOS: `swipe` and atomic `touch --down --up` accept `--coordinate-space ui`, so coordinates from the outline work after rotation. Device-native portrait coordinates remain the default; Android accepts the option without changing its behavior. (#66, #74)
- `describe-ui --json --no-raw` omits the large raw accessibility tree while keeping the outline and structured controls, reducing output for scripts and agents. (#63, #69 — thanks @4faramita!)
- The bundled skill recommends smaller UI reads, fewer screenshots and batching known actions to reduce agent context and command overhead. (#63 — thanks @4faramita!)
- Viewer shows screen orientation beside the dimensions, making rotated iOS layouts easier to identify. (#57, #71)
- `SIM_USE_HID_TRANSPORT=indigo|dtuhid` lets developers force an iOS input connection for troubleshooting. Restart the device daemon or disable it for an override to take effect. (#68)
- `SIM_USE_DEBUG=1` enables detailed diagnostic logs, including input connection selection and batch commands. Restart an existing daemon for the setting to take effect there. (#67, #72)
- `make e2e-matrix` checks iOS behavior across Xcode 26/27 with Device Hub open and closed, and saves logs for each setup. (#77)
- Agent evaluations accept a specific binary with `make eval ARGS="-b <path>"` and record its path and version, so contributors can test a development build rather than the installed release. (#65)
- New screenshot and recording tests check output files, stdout capture and Android recording restarts on live devices. (#81)

### Changed

- Recording uses native video instead of repeated screenshots, delivering smoother playback with less CPU use. iOS supports 1–60 fps with a new default of 30; Android uses its native rate, continues across recording time limits, and stops if the screen rotates. (#52, #70 — thanks @subdiox!)
- Xcode 27 Device Hub input now works automatically, whether Device Hub was open or closed when the simulator booted. The updated iOS backend also handles native two-finger gestures and no longer needs separate framework files beside the executable. (#68)
- iOS single-finger gesture presets use the current screen size and orientation by default instead of a fixed phone-sized canvas. Pinch and rotation presets retain their previous coordinate behavior. (#73, #74)
- Building the iOS frameworks now requires [XcodeGen](https://github.com/yonaskolb/XcodeGen). After switching Xcode versions, run `./scripts/build.sh dev` again before building sim-use. (#68)
- Contributor-facing video and process helpers are shared between backends, making Android and iOS video work easier to maintain without changing command behavior. (#78, #79)

### Fixed

- iOS: input sent just after a simulator boots with Device Hub open no longer leaves later commands using a non-working connection. (#67, #72)
- iOS: scroll and edge-swipe presets follow their named direction on rotated screens, including in batches, instead of moving in portrait-screen directions. (#34, #66, #73)
- iOS: `describe-ui` can recover controls from a system document picker instead of returning an empty outline, with a warning that the recovered view has limited hierarchy information. (#64, #75)
- Video recording is no longer limited to the screenshot loop's roughly 8–10 fps. (#52, #70)
- Android recordings keep a still final frame visible until the requested stop time and include frames already arriving when capture stops. (#52, #70)
- The iOS Playground login screen keeps its buttons clear of keyboard suggestions, so batch login tests can complete reliably. (#76, #77)

### Removed

- Removed the Device Hub input blocker and `SIM_USE_SKIP_DTUHIDD_CHECK`: those simulator setups now work without an override. (#68)
- Removed the `scripts/build.sh` commands `strip`, `sign-frameworks` and `sign-xcframeworks`; separate framework packaging and signing are no longer needed. (#68)

## [0.11.0] - 2026-07-23

Use sim-use with Xcode 27 Beta 4 and later through Simulator.app or headless workflows. Input recovers more reliably after simulator restarts, and unsupported Device Hub setups give clear errors instead of silently dropping actions. Expanded iOS, Android and agent-level tests improve release checks.

### Added

- Android Playground app and live-device test suites cover common input and UI-reading workflows. Run them with `make e2e-android`. (#47)
- iOS Playground screens and tests cover Unicode paste, rotated-screen taps and real permission alerts. (#47)
- Agent evaluations run natural-language tasks against the Playground apps and check the results, catching cases where skill guidance leads an agent to the wrong command. (#47)
- `make eval` and `pnpm eval` check prerequisites, estimate API cost and ask for confirmation before running agent evaluations. (#47)

### Changed

- Release checks now require passing live-device tests, with the test strategy documented for contributors. (#47)
- `make e2e` runs iOS and Android tests in sequence; use `make e2e-ios` or `make e2e-android` for one platform. (#47)
- The iOS test runner continues after a suite fails and prints a complete pass/fail summary, including previously omitted keyboard and streaming tests. (#47)
- Tap and long-press help use consistent wording and group timing options together; command behavior and defaults are unchanged. (#42, #49)
- Viewer development dependencies are updated to clear the toolchain's known security advisories. (#48)

### Fixed

- Xcode 27 Beta 4 and later work through Simulator.app or headless use. Keep Device Hub closed when booting the simulator in this version; contributors must rebuild older framework builds with `./scripts/build.sh dev`. (#56)
- iOS input commands report an error and recovery steps when a simulator was booted with Device Hub open, rather than claiming to tap or type successfully while doing nothing. (#60, #61)
- Input connections recover after a simulator is shut down and booted again. Stuck input sends time out with an error rather than blocking every later command, without risking an automatic duplicate action. (#55, #58)
- `sim-use viewer` displays snapshots from rotated iOS Simulator windows. (#50 — thanks @thickfive!)
- `make build`, `make test` and live-device test runners work with the changed build layout in Xcode 26.6+ and Xcode 27, without missing-framework errors or build-lock hangs. (#56)
- Release packaging accepts resource bundles produced by newer Xcode versions instead of rejecting otherwise valid builds. (#59)
- Keyboard and video test suites use the current `sim-use ios` command names, so they exercise the intended commands again. (#47)
- The Cmd+A test accepts an empty field that exposes its placeholder, avoiding a false failure. (#47)
- Release help and Homebrew instructions point to the public GitHub repository and `lycorp-jp/tap`, rather than the old internal host.

## [0.10.0] - 2026-07-09

Taps and UI queries work correctly on rotated iOS screens, and coordinate shortcuts make input commands easier to write. Device discovery and long-running automation are more reliable, with safeguards against duplicate actions and clearer recording failures. **JSON consumers must use `deviceId` instead of the removed `udid` output key.**

### Added

- Write swipes as `--from x,y --to x,y` or positional coordinate pairs, reducing the number of flags needed on either platform and in iOS batches. (#27, #30 — thanks @joonyeonglim!)
- `tap` and `long-press` accept `--point x,y` as a shorter alternative to separate `-x` and `-y` flags, including in iOS batches. (#25, #40)
- Tap and long-press warn when a label or value matches an almost full-screen element, helping scripts and agents avoid tapping a container instead of its control. (#29, #36 — thanks @joonyeonglim!)
- GitHub Actions runs Swift and Android bridge unit tests and checks that the CLI and bridge agree on their communication version for every push and pull request to `main`. (#26)
- Build and test output is easier to scan when optional [xcsift](https://github.com/ldomaradzki/xcsift) is installed, with test coverage included. Set `SIM_USE_XCSIFT=0` for plain output. (#26)

### Changed

- **Breaking — JSON output uses `deviceId` only; the legacy `udid` key is removed.** Daemon and Viewer requests still accept `udid` as a deprecated input alias. (#22)
- Labels copied from the outline match controls even when the app uses line breaks or extra whitespace. Existing exact matches take priority on iOS and Android. (#28, #31 — thanks @joonyeonglim!)
- Outlines also normalize unusual Unicode whitespace, keeping labels on one line and consistent with selector matching. (#31)
- `--wait-timeout` waits through temporarily ambiguous matches during screen transitions instead of failing immediately. Persistent ambiguity still reports the matching controls. (#31)
- `describe-ui --point` uses the same coordinates as the outline, so point queries stay accurate after rotation. (#38)
- iOS outlines and JSON results include the detected orientation, letting users and scripts identify a rotated layout. (#38)
- Swipe validation is consistent across top-level, iOS and Android commands, and JSON results include the executed coordinates. (#30)
- `swipe --duration` is limited to 10 seconds and errors clarify the unit, preventing accidental multi-minute gestures when milliseconds are supplied. (#30)
- Android long-press holds can last the full 10 seconds accepted by the CLI instead of being cut off at five seconds. (#8)
- iOS typing reuses one input connection for the whole string, reducing per-character overhead. (#9)
- Commands retry once when a simulator is briefly not ready just after boot. (#6)
- iOS streaming help marks `bgra` as experimental and notes that it does not report a frame count. (#21)

### Fixed

- iOS: selector-based taps, batch taps and menu-paste actions hit the correct controls after rotation. Explicit coordinates keep their device-native portrait behavior in this version. (#34, #38)
- iOS: rotated-screen outlines no longer omit whole areas such as an iPad's Settings sidebar. (#34, #38)
- `describe-ui --point` no longer replaces the full outline's `@N` references, so later alias taps still target the expected controls. (#38)
- `sim-use devices` no longer hangs when many installed simulators produce a large device list. (#39 — thanks @JustHm!)
- `sim-use android tap` works again instead of crashing before sending input; top-level `sim-use tap` was unaffected. (#41)
- Commands that return an ordinary error no longer restart the daemon and run again, avoiding duplicate actions and unnecessary delays. (#6)
- If a connection fails after a command may have started, sim-use reports the uncertain result instead of silently sending it again. Check the screen before retrying an action. (#12)
- iOS input reconnects after a simulator reboot instead of hanging on an old connection. A send is retried only when it is known not to have reached the device. (#23)
- Long waits and batches no longer stop halfway through because the daemon's idle timeout expires. (#13)
- `ios batch --ax-cache` now controls whether UI reads are reused across steps. Waiting for delayed controls still refreshes the UI. (#20)
- Android outlines include popup and dialog controls that were missing on Android 11–12. (#8)
- Repeated Android text input no longer leaks accessibility resources. (#8)
- Invalid swipe coordinates fail with a clear error instead of crashing the background service. Direct `android swipe` also rejects negative coordinates and identical endpoints. (#30)
- Invalid tap and long-press coordinates now produce validation errors rather than crashing on Android. (#40)
- Android swipe commands round fractional coordinates consistently, whether called through the top-level or Android namespace. (#30)
- Android swipes reject endpoints that round to the same pixel instead of sending a zero-distance gesture. (#30)
- Android swipe delays are limited to 0–10 seconds and reject invalid numbers instead of crashing. (#30)
- Recording stops with a clear error if its video writer stalls, rather than hanging indefinitely. (#19)
- Recording reports failure if video finalization times out, rather than claiming that a potentially unplayable file was saved. (#18)
- Recording no longer consumes excessive CPU when captured frames repeatedly fail to decode. (#9)
- iOS BGRA streaming returns an error when capture cannot start or fails mid-stream, rather than reporting success. (#21)
- Viewer shows command errors even when the CLI cannot return JSON, rather than claiming success or showing a generic parsing failure. (#17)
- `keyboard-state` uses the background service for faster repeated queries and displays crash warnings and recovery hints consistently. (#11)
- The bundled skill can restart stale daemons successfully instead of passing incompatible device options and reporting a false recovery. (#2 — thanks @viseator!)
- Stopping a stale daemon no longer risks stopping the calling process or unrelated daemons during parallel tests. (#26)
- A shutting-down daemon no longer removes a replacement daemon's connection files, preventing orphaned background processes. (#7)
- Daemon files in `/tmp` are checked for safe ownership and permissions, rather than trusting an existing directory. (#7)
- Top-level help now describes Android support as well as iOS Simulator support. (#35)

### Removed

- Removed an unused internal swipe notification. Commands and public behavior are unchanged. (#14)

## [0.9.0] - 2026-06-29

The first public release brings iOS Simulator and Android automation into one CLI for developers and AI agents. Read a compact description of the screen, act on its controls, and capture the result without switching between platform-specific tools.

### Added

- A shared set of commands for iOS simulators and Android emulators or devices: tap, swipe, type, paste, gestures, app state, screenshots and video recording.
- `ui` (also called `describe-ui`) turns the screen into a compact text outline. Use `@N` references or accessibility identifiers to target controls without estimating coordinates.
- `sim-use init` installs the bundled skill into Claude Code or another AI client, giving agents guidance for observing and controlling apps.
- `sim-use viewer` opens a local web UI to inspect the accessibility tree and highlight areas that are missing from it.
- `--json` output lets scripts read command results consistently.
- iOS keyboard shortcuts, key sequences, live video streaming and multi-step batches are available under `sim-use ios`.
- `sim-use android init` sets up the Android helper app needed for UI inspection and input.
- An iOS background service reduces startup overhead for repeated commands on the same simulator.
- Crash and termination detection warns when the app stops between commands, including Android crash dialogs.
- Install with Homebrew: `brew tap lycorp-jp/tap && brew install sim-use`.
