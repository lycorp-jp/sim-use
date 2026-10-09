# Xcode 27 Resize Mode (resizable app session): investigation, evidence, and the stop-gap

Work record for [issue #143](https://github.com/lycorp-jp/sim-use/issues/143)
(reported 2026-09-15 by @iXerol), investigated and reproduced 2026-10-09.
This document exists so the next person does not have to re-derive any of
it: every claim below was measured live, and the places where the measurement
stopped short are marked as such.

Environment: macOS 26.6.2, Xcode 27.0 (27A266a) selected (27.1 RC and 26.6 also
installed), iPhone 17 simulator on iOS 27.0 (24A434), sim-use `main` @ `76802ca`
(post-0.14.0), idb pinned at `1f6943f8a`. Reproduction is **headless** — neither
Simulator.app nor Device Hub is needed; `devicectl` reaches a `simctl boot`ed
simulator through CoreDevice directly.

## TL;DR

- All four symptoms in the issue reproduce. They share one root cause: every
  iOS-simulator primitive sim-use (and the pinned idb) drives is bound to the
  **main display** — HID touch (digitizer target 0, normalised against
  `mainScreenSize`), the framebuffer (`displayClass == 0`), and the
  accessibility *point hit-test*. Resize Mode moves the frontmost app to a
  virtual display named `Resizable`; the main display keeps SpringBoard.
- The `Resizable` display **has its own touchscreen digitizer** (dtuhidd
  virtual service `touchscreen(0x104)`, bound to the Resizable display UUID),
  so real routing is possible in principle — but a naive attempt did not land
  a tap (see Spike), and the geometry is unresolved.
- Upstream idb has no Resize Mode work. It landed multi-display plumbing for
  iPhone Duo on 2026-10-06 (`DisplaySelection`, digitizer targets, per-display
  framebuffers, AX `--display-id` via a new guest bridge) which is the right
  foundation, but its "active display" model never selects a virtual,
  backlight-off display, so it does not cover Resize Mode as-is.
- **Shipped here (tier 1):** detect the session via `devicectl device info
  appResize`, refuse touch verbs with an explanation, redirect `screenshot` to
  the Resizable display, and mark `ui`/`ui --point` with an advisory while
  skipping the hit-test driven steps that were polluting the tree and the
  orientation probe. Keyboard verbs are untouched because keyboard HID is
  device-wide and reaches the resized app (verified).

## Reproduction recipe

```bash
UDID=4F480C10-679A-47F3-AE36-99D0EC643774      # iPhone 17 / iOS 27.0
xcrun simctl boot $UDID && xcrun simctl bootstatus $UDID -b
# build + install Playgrounds/iOS (scripts/test-runner.sh build_playground_app), then
xcrun simctl launch $UDID com.cameroncooke.SimUsePlayground
# the session lives as long as this process; `simctl terminate` of the frontmost app also ends it
nohup xcrun devicectl device appResize start --device $UDID --preferred-size 560x874 &
xcrun devicectl device info appResize --device $UDID        # active: "Display: Resizable (<uuid>)"; idle: CoreDeviceError 24004
```

The Playground's **Tap Test** screen (`Tap Count: N`) is the right probe for
whether a touch actually reached the app.

### What was measured (pre-fix)

| Symptom | Measurement |
|---|---|
| tap/swipe report success, deliver nothing | `Tap Count` stays 0 under auto, forced `dtuhid` (Device Hub open) and forced `indigo` transports; every run prints `✓ Tap at … completed successfully` |
| screenshot captures the wrong display | `sim-use screenshot` → 1206x2622 (main display, wallpaper only). `xcrun simctl io $UDID screenshot --display=<Resizable uuid or "Resizable">` and `devicectl device capture screenshot --display-unique-id <uuid>` → 1680x2622 (the app, 560x874 @3x) |
| SpringBoard elements spliced into the tree | On a screen with a collapsed `Group` (Playground main menu), `ui --json` contains pid=SpringBoard nodes — a `Group (0,0 402x874)` and the Dynamic Island — inside the app's 560x874 tree. `ui --point 100,300` returns `Subtree: SpringBoard` outright |
| orientation misreported | Scene 874x402 on an upright device: `[i] Screen orientation could not be confirmed (3 probe(s)); assuming landscape-right`, header `(landscape-right)`; `devicectl device info displays` says `rot0` |

Other facts that shaped the design:

- `appResize set 402x874` produced a 437x874 scene (the issue's "snapping is
  not stable" is real). CoreDevice reports the size it *asked for*; the AX root
  frame (the `App:` header) is the only place the scene's actual size shows.
- The `Resizable` display (`type: virtual`, 7680x4320 px @3, `displayId 4`)
  and its CoreSimulator IO port stay enumerated **after** the session ends,
  and its `backlightState` is `off` even while a session is active. Neither
  presence nor backlight can detect a session. `simctl io screenshot
  --display=Resizable` with no session returns a stale frame of the last scene.
- The display's `uniqueId` changes on every boot.
- `type` into a focused field during a session lands in the app (keyboard HID
  is not display-bound).
- `devicectl device info appResize --json-output -` writes a JSON document on
  stdout for success *and* failure (`error.code 24004` = no session, `1000` =
  device unknown). Xcode 26.6's devicectl already knows the subcommand and
  answers 24004 for a simulator; older toolchains presumably print
  "Unrecognized subcommand". ~0.3 s per call.

## Root cause, per symptom

1. **HID.** `FBSimulatorDTUHIDTransport` and `FBSimulatorIndigoHIDTransport`
   normalise against `deviceType.mainScreenSize` and send
   `IndigoDigitizerEvent.target = 0` — the main-screen alias. Events land on
   SpringBoard's wallpaper.
2. **Screenshot.** `FBFramebuffer.mainScreenSurface` picks the IO port whose
   descriptor has `displayClass == 0`. The port descriptor exposes no display
   UUID to match against, which is why the stop-gap goes through `simctl`.
3. **Tree pollution.** `legacyAccessibilityElement(at:)` (hit-test) resolves on
   the main display; `legacyAccessibilityElements` (tree) follows the frontmost
   app. sim-use's `CollapsedChildrenRecovery` adopts hit-test results as
   synthesized children of collapsed groups → SpringBoard nodes in the app
   tree. Only screens with collapsed groups show it (Tap Test does not, the
   main menu does).
4. **Orientation.** `OrientationCalibrator` probes ride the same hit-test, so
   they are evidence about SpringBoard; and `orderedCandidates` treats a scene
   whose size matches the landscape swap as rotated.

## The digitizer finding (why tier 3 is possible)

Guest-side dtuhidd log, `xcrun simctl spawn $UDID log show --predicate
'process == "dtuhidd"'`, with Device Hub open:

```
Created HID service id mainTouchscreen(0x101)   … property displayUUID → 854C6C2D-… (LCD)
Created HID service id touchscreen(0x104)       … property displayUUID → B05EE8F8-… (Resizable)
                                                … property Product → "CoreDevice touchscreen(B05E…)"
```

Both services exist from boot and persist. Upstream idb's
`SimulatorTouchscreenProtocol` reads these through
`com.apple.coredevice.feature.remote.universalhidservice` (`connectedServices`)
and derives the digitizer target as `_ServiceID & 0xFF` — i.e. `0x104 → 4` —
which `SimulatorDigitizerHIDTransport` then sends as `IndigoDigitizerEvent.target`.

### Spike (inconclusive)

Patched the pinned `FBSimulatorDTUHIDTransport.sendTouch` to read
`SIM_USE_SPIKE_TARGET` / `SIM_USE_SPIKE_CANVAS`, forced `dtuhid`, and swept
target 0…10 × normalisation canvas {2560x1440 (display points), 560x874 (scene
points)} against the Tap Test screen. `Tap Count` stayed 0 for every
combination; dtuhidd logged no errors. Most likely the coordinate space, not
the target: CoreDevice keeps reporting the Resizable display's bounds as the
7680x4320 canvas during a session, while the capture surface is cropped to the
1680x2622 scene — where the portrait scene sits inside the landscape canvas,
and which rectangle the digitizer's 0…1 range spans, is unknown. The spike was
reverted (`git -C idb_checkout checkout -- .` + `build.sh frameworks && install
&& xcframeworks && make build`; note `build.sh dev` hard-resets the checkout).

## Upstream idb (facebook/idb) status, 2026-10-09

- No issue or PR mentions Resize Mode / `appResize`.
- [#965](https://github.com/facebook/idb/issues/965) (open, 2026-09-24): iPhone
  Duo inner-display taps unreachable. Maintainer reply: "multiple display
  awareness … being built". Landed 2026-10-06 as a series:
  `DisplaySelection` (`.main` / `.active` / `.display(uniqueID:)` /
  `.configuration(generation:)`), `SimulatorDisplayProtocol`
  (`com.apple.coredevice.feature.getdisplayinfo`), `SimulatorTouchscreenProtocol`,
  per-display framebuffers (`FramebufferSurfaceLocator.surface(uniqueID:)`),
  `AXBridgeUIAutomation` with `--display-id` over the new in-guest
  `SimulatorFrameworkBridge`, and `README.md` § "Multiple displays".
- The model is Duo's: `.active` is derived from *integrated* display activity
  / backlight; a `virtual`, backlight-`off` display is never active, and
  `.display(uniqueID:)` for HID/AX requires the display to be active. The
  legacy `.accessibility` backend (what sim-use uses) "does not route to
  displays". So upstream does not handle Resize Mode today, but has every
  piece the tier-3 work needs except the Resizable-specific geometry.
- Migration cost is large: the FB* prefix is gone (`SimulatorHID`,
  `SimulatorDigitizerHIDTransport`, `AXBridgeUIAutomation`), and AX moved to a
  guest-side bridge executable. This compounds the idb-bump project already
  described in `docs/ai/xxxx-xcode27-support/README.md`.

## Other tools

- WebDriverAgent [#1267](https://github.com/appium/WebDriverAgent/pull/1267)
  (merged 2026-09-29, v16.13.0): `currentDisplayId` setting listed via
  `/wda/screens`; explicit selection, no auto-detection, fails rather than
  falls back. Same stance as the stop-gap here.
- AXe [#7](https://github.com/cameroncooke/AXe/issues/7) (Stage Manager:
  describe-ui returns the background) and
  [#69](https://github.com/cameroncooke/AXe/issues/69) (Xcode 27 orientation
  probe) are open without fixes. XcodeBuildMCP 2.7.0 advertises Device Hub
  support, nothing on Resize Mode.

## What shipped (tier 1) and why it is shaped this way

`Sources/iOSSimBackend/Sim/ResizableAppSession.swift`:

- `ResizableAppSessionProbe` — runs `xcrun devicectl device info appResize
  --device <udid> --json-output - --timeout 5 --quiet` and classifies the
  *document* (not the exit status): `result` → active, `error.code 24004` →
  inactive, anything else → `unavailable(reason)`, which every caller treats
  as "no session" and only logs.
- `ResizableAppSessionMonitor` — actor with a per-UDID 5 s TTL cache (lives in
  the per-UDID daemon), sticky "no such subcommand", skipped on Xcode < 27
  (`XcodeCompatibility.selectedXcodeMajorVersion()`) and under
  `SIM_USE_RESIZE_SESSION_CHECK=0` (read by the daemon at spawn — a later
  client's environment does not reach a running daemon). The cache is the
  whole cost model: one ~0.3 s spawn per device per 5 s instead of one per
  command. `state(for:refreshIfInactive:)` lets a caller with in-band
  evidence bypass a cached *non-active* answer: the fetcher passes
  `sceneSizeIsNotADeviceSize` (AX root frame ≠ device portrait size and ≠ its
  landscape swap), so a session that started inside the window is seen by the
  first `ui` or selector tap. The first E2E run caught exactly this gap: the
  launch helper's `describe-ui` cached "no session" seconds before the
  session started, and `ui`/`tap` inside the window read the stale answer.
  What still waits out the window: a session that just *ended*, raw `-x/-y`
  taps right after a start, and a scene at exactly the device's own size.
- `ResizableAppSessionGuard.assertTouchInputReachesApp` — called after
  `performGlobalSetup` in `tap` (`long-press` shares the path), `swipe`,
  `touch`, `gesture`, `multi-touch`, and `batch` when any step kind is tap /
  swipe / gesture / touch (`IOSSimBatchCommand.containsTouchStep`). `tap`
  checks a second time after selector resolution, because that resolution
  fetched a tree and may have refreshed the cache (see the monitor). Throws
  `ResizableAppSessionError` (`LocalizedError + HintProviding`, so `--json`
  carries `hint`).
- `AccessibilityFetcher.fetchAccessibilityInfo` — asks the monitor once per
  fetch; under a session it returns the raw tree in identity calibration with
  the `resizable_app_session` advisory and **skips** calibration and
  collapsed-children recovery. `pointQuery` attaches the same advisory and
  skips its tree-calibration fallback.
- `IOSSimScreenshotCommand` — under a session captures through
  `ResizableDisplayScreenshot` (`simctl io <udid> screenshot --type=png
  --display=<uuid> <path>`) and attaches the advisory with the pixel size.
  `ExecutionResult` now conforms to `CommandAdvisoryProviding` (registered in
  `CommandAdvisoryContractTests`).

Design choices worth knowing before changing anything:

- **Detection is CoreDevice, not in-band.** An in-band detector was
  considered: a hit-test at the app root's centre returning a pid other than
  the frontmost app's. It is cheap but ambiguous — a cross-process sheet (the
  issue #64 family) produces the same signature, and the own-size case
  (402x874) leaves no size mismatch to corroborate. `devicectl` is unambiguous
  and the TTL cache keeps it affordable.
- **Touch verbs fail; they do not warn-and-continue.** The issue's core
  complaint is a scripted flow continuing against a screen that never changed.
  An advisory on a `✓` line is exactly what an agent skims past.
- **Raw `-x/-y` is refused too.** The digitizer target is the problem, not
  coordinate resolution; raw coordinates land on SpringBoard just the same.
- **Recovery is skipped, not filtered by pid.** Filtering synthesized hits to
  the app's pid would keep the walk's probe cost for no benefit — every hit
  is SpringBoard's during a session.

Measured after the fix (same simulator): `ui` 0.46 s with the cache warm
(baseline ~0.4 s); touch verbs refuse in ~0.3 s; screenshot of the Resizable
display 1680x2622 with the advisory; after ending the session `ui`, `tap`
and `screenshot` return to their normal output with no advisory.

## Verification

- Unit: `swift test --filter 'ResizableAppSession|ResizableDisplayScreenshot|BatchTouchStepScan|CommandAdvisoryContract'`
  — document classification (captured fixtures), argument pins, cache
  TTL/sticky/kill-switch/Xcode gate, error and advisory text, simctl failure
  mapping, batch step scan.
- Live: `Tests/ResizeModeTests.swift` (`SIM_USE_E2E=1`, in the
  `scripts/test-runner.sh` suite list). Skips itself when `devicectl` cannot
  host a session (Xcode 26 legs), starts a real session via a backgrounded
  `appResize start`, asserts the `ui` advisory and single-pid tree, touch
  refusals (`tap`, `swipe`, `ios batch`) plus `type` landing, screenshot
  redirection, and ends the session in every path. 3/3 green on the
  environment above (≈32 s).
- **Gotcha that cost a run:** the per-UDID daemon's version gate compares
  `git describe` strings, so rebuilding on the same dirty commit leaves the
  *old* daemon serving requests — the second E2E run exercised code that was
  not in the running daemon and failed identically to the first. Before live
  verification of a rebuilt binary, `sim-use daemon stop --udid <udid>` (or
  `--all`). `sim-use daemon status` shows the version each daemon runs.

## Follow-ups (not in this PR)

1. **Tier 2 — observation polish.** `ui` could tag the `App:` header (e.g.
   `(resizable 560x874)`) so text-mode readers see it without the banner; the
   outline cache could carry the session flag so `tap @N` refuses without a
   devicectl round-trip.
2. **Tier 3 — real routing.** Bump idb to the `DisplaySelection` series,
   teach "active display" about a hosted virtual display (CoreDevice's
   `appResize` state is the signal), route HID to digitizer target
   `touchscreen(0x104)`, resolve the scene's rectangle inside the 7680x4320
   canvas (devicectl's `capture screenshot --display-unique-id` crops to it,
   so CoreDevice knows), and use `--display-id` for AX hit-tests. iPhone Duo
   support shares all of this except the geometry — plan them together.
3. The `SimulatorFrameworkBridge` guest executable upstream introduced is a
   new runtime dependency shape (something must be installed/launched in the
   simulator). Decide whether sim-use accepts that before committing to the
   bump.
