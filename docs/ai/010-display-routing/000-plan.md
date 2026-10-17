# 010 — Display routing (iPhone Duo, Resize Mode) and device rotation: Plan

| | |
| --- | --- |
| **Status** | Implemented in the stack #157, #158, #161, #163, #164, #165 (awaiting merge) |
| **Anchor date** | 2026-10-16 |
| **Primary PRs** | #157 (S1), #158 (S2), #161 (S3), #163 (S4), #164 (S5), #165 (S6) |
| **Related** | [009-resizable-app-session](../009-resizable-app-session/000-investigation.md) (#143; this plan replaces its tier-1 guard with real routing), [002-ios-orientation-self-calibration](../002-ios-orientation-self-calibration/000-design.md), [001 dtuhidd short-lived clients](../001-daemon-and-hid-lifecycle/001-dtuhidd-short-lived-clients.md), facebook/idb#965, facebook/idb#980 |

## Background

sim-use binds every iOS primitive to the **main display**: HID digitizer
target 0, the `displayClass 0` framebuffer, and AX translator `displayId: 0`
(see 009). Two Xcode 27 features put the app on another display:

1. **iPhone Duo** (Xcode 27.1): a foldable device with two integrated displays. Only one is active at a time.
2. **Resize Mode** (`devicectl device appResize`, Xcode 27, any iPhone): the frontmost app moves to the virtual `Resizable` display (#143).

`devicectl device info displays` on the two test devices:

| Device | Display | `displayId` | Type | Pixels (@3x) | Notes |
| --- | --- | --- | --- | --- | --- |
| iPhone Duo / 27.1 | `LCD` (cover) | 1 | integrated | 1398x2034 | `primary`; active when folded |
| | `LCD-1` (inner) | 3 | integrated | 2007x2853 | active when unfolded; `rot90` when the device is portrait |
| | `Resizable` | 5 | virtual | 7680x4320 | Resize Mode |
| iPhone 17 / 27.0 | `LCD` | 1 | integrated | 1206x2622 | `primary` |
| | `Resizable` | 4 | virtual | 7680x4320 | Resize Mode |

The `Resizable` display is always listed, also with no session, and it stays
`active: false` with the backlight off **during** a session. Only
`devicectl device info appResize` tells that a session is active (009).

Measured on `main` @ `81c3089` (idb `1f6943f8`) with the Duo unfolded:

| Surface | Result |
| --- | --- |
| `screenshot` | Black image of the cover framebuffer (1398x2034) |
| `tap`, `swipe` | Print success, deliver nothing |
| `ui` tree fetch | Correct frames in UI space (951x669) |
| `ui` header and regions | Screen reported as 669x951, so the region bands are wrong |
| Point hit-test (`ui --point`, orientation calibration, collapsed-children recovery) | Fails: "No translation object returned"; the advisory fires every time; the sidebar is lost behind `Group (0,0 951x669)` |

Under Resize Mode, 009 records the same failures and ships a guard that
refuses touch verbs.

The Duo cover display also changes the layout model. iOS 27 puts the status
bar, the Dynamic Island and the back button in a **trailing rail** (about
x ≥ 382 of 466). The current y-band regions put `#BackButton` (399,179) in
`Content`.

## Spike evidence (2026-10-16, Xcode 27.1, Device Hub open)

All mechanisms run on the host with the pinned idb. Nothing runs or is
installed in the simulator. The one-off probe in E7 was for evidence only.

### Integrated displays (iPhone Duo / iOS 27.1)

| # | Mechanism | Result |
| --- | --- | --- |
| E1 | Hinge: XPC to dtuhidd feature `com.apple.coredevice.feature.remote.hid.vendordefined`, `IndigoVendorDefinedEvent` (usage page `0xFF61`, usage `0x5B`, OSSerializeBinary dict `{type: range, value: <deg>, source: hinge-slider-control, provider: com.apple.Virtualization.VirtualMachines}`) | `closed` and `flat` switch the active display in 1–2.5 s |
| E2 | Orientation: same event, `{type: enum, value: portrait\|pud\|landscape-left\|landscape-right, source: orientation-picker-control}` | Inner rotation: portrait→`rot90`, landscape-left→`rot0`, landscape-right→`rot180`, pud→`rot270` |
| E3 | Touch: existing DTUHID `IndigoDigitizerEvent` with `target = 3` (dtuhidd service `touchscreen(0x103)`; low byte = `displayId`) | Taps verified in all four rotations; swipe verified |
| E4 | UI point → normalized inner panel (W=669, H=951) | `rot0 (x/W, y/H)`, `rot90 (y/W, 1−x/H)`, `rot180 (1−x/W, 1−y/H)`, `rot270 (1−y/W, x/H)`. Same math as upstream `SimulatorDisplayGeometry.unrotatedPoint` |
| E5 | dtuhidd queues only **2** events while it creates the services of a new peer (~0.77 s) | A one-shot swipe loses its moves. A warm peer (the daemon) does not |
| E6 | AX: `AXPTranslator` `displayId: 3` in `FBAXTranslationRequest.swift` | Hit-test works. Hit-test space = native panel points (the model of 002 holds) |
| E7 | AX id mapping: one-off probe of `XCTDisplayManager allDisplayIDs` / `uniqueIDForDisplayWithID:` | Joined by `uniqueId`, AX id == devicectl `displayId` for 1, 3 and 5 |
| E8 | `xcrun simctl io <udid> screenshot --display=<uniqueId or name>` | Returns the selected display, already rotated to the UI |
| E9 | `devicectl device info displays --json-output -` | ~0.1 s; gives `active` and `currentOrientation` per display |

### Fold signals (iPhone Duo, 2026-10-16)

| # | Check | Result |
| --- | --- | --- |
| E19 | Lock with `sim-use button lock`, then read displays | The active display keeps `active: true`; its `backlightState` goes `activeOn` → `inactiveOn` (dimmed lock screen). The other display is `off`. So `active`, not the backlight, tells which display hosts the UI |
| E20 | Fold or unfold while locked | The active display switches, and the device wakes (`activeOn`) on the lock screen |
| E21 | Hinge angle → active display | 0° → cover and 180° → inner from every path tested. 130° → inner when reached from 0°, 60° or 180°, but a 10° step from 120° kept the cover. Steps of 30° up from 0° kept the cover until 180°; steps down from 180° kept the inner display down to 45°. The result at an intermediate angle depends on the path |
| E22 | Upstream confirmation | idb confirms `fold` by the **measured hinge angle** from the CoreDevice feature `com.apple.coredevice.feature.monitormotion`, and gates on `querymotioncapabilities` (`hingeAngle`). The Xcode 27.1 `devicectl` has no command for it |

### Found while building S1 (2026-10-16)

| # | Check | Result |
| --- | --- | --- |
| E23 | Single-display rotation through the pinned idb's Purple GSEvent (`FBSimulatorHIDEvent.deviceOrientation`), no devicectl | Works on iPhone 17 / iOS 27.0 and 26.5, iPhone 16 Pro / iOS 18.6, iPad Pro 13-inch / iOS 26.5, with Xcode 27.0 and 26.6 selected. Purple numbers landscape in interface style: device `landscapeRight` is Purple `landscapeLeft` (upstream `physicalPurpleOrientation`) |
| E24 | devicectl `currentDeviceOrientation` vs display rotation | Same frame for every integrated display: cover `rot0` ↔ `portrait`, inner `rot90` ↔ `landscapeRight`. The orientation **picker value** is one quarter turn behind the reported device orientation while the inner display is active (picker `portrait` reads back `landscapeRight`), and equal on the cover |
| E25 | Orientation the app does not accept | The reported device orientation does not change either (Settings on the Duo cover, `portrait-upside-down` on any iPhone-size screen). An iPad accepts `portrait-upside-down` |
| E26 | devicectl `info displays` on iOS 18.6 / 26.5 runtimes | No `uniqueId`, no `active` key, no `Resizable` display; `backlightState: unknown`. iOS 27.0 single-display: `uniqueId` present, no `active` key |
| E27 | devicectl of Xcode 27.0 (651.13.5) on the Duo (iOS 27.1 runtime) | Reads all three displays and `appResize` correctly — open question 2 closed |
| E28 | `type` with the app on the inner display (S1, touch refused) | Text reaches the focused field: keyboard HID is device-wide |

### Found while building S2 (2026-10-16)

| # | Check | Result |
| --- | --- | --- |
| E29 | iOS 27.0 SDK Playground on the Duo cover | The scene is 386x678 (keeps out of the 80 pt status bar strip on the hardware's right edge). In landscape the AX root is 678x386, which matches no device size: the probe calibrator kept four candidates, spent its 3 probes and guessed portrait, so AX-id taps missed. Raw hit-tests showed the mapping itself was right in `landscape-left` |
| E30 | Same app, `landscape-right` | The strip is at the top of the interface: the scene starts 80 pt down. Panel `(260, 634)` hit the top-trailing corner; `(340, 634)` (no offset) missed. Same 80 pt strip on the inner display (scene 871x669 / 669x871), and HID and hit-test agree on the display-space coordinates |
| E31 | Scene placement by probes | Offsets {0, gap/2, gap} per axis, first candidate that two elements confirm. A single probe was fooled once: at the wrong offset the probe for LINE's Help button landed on the status bar's Wi-Fi icon, whose frame sits inside the button. With two confirmations: Playground corners 12/12 on the cover (3 orientations) and 16/16 on the inner display (4 orientations) |
| E32 | LINE `26.18.0` (iOS 27.0 SDK) on the Duo | Welcome → login → back in all four inner orientations; on the cover: login methods → phone number → tap field → `type` → unfold mid-flow (field value kept) → back on the inner display |
| E33 | Resize Mode after S2 | iPhone 17 / iOS 27.0, 560x874: `Tap Location: (450, 650)` exact, `#BackButton`, `ui --point`, a single pid in the tree. A cached active session outlived the session by up to 5 s; a root at the device's own size now re-checks it |

### Found while building S3 (2026-10-16)

| # | Check | Result |
| --- | --- | --- |
| E34 | Cost of UI-space calibration from the tree, iPhone 17 / iOS 27.0, Playground (`SIM_USE_PERF=1`, daemon log) | Sim lookup 5 ms, tree fetch 64–71 ms, routing check 0.1 ms, one probe 3–4 ms: ~75 ms per command, almost all of it the tree fetch |
| E35 | Same, calibrated from the `ui` snapshot (root frame read, probes, in-place confirmation) | `SIM_USE_PERF=1`: root frame + routing 8 ms, calibration probes 7 ms, confirmation 13 ms — 28–30 ms in all, against ~75 ms for the tree. `tap -x/-y` wall time is about 30–40 ms over `native` (~650 ms, noisy) |
| E36 | iPhone 13 mini / iOS 26.5 (UI 375x812, panel 360x780), portrait | `tap -x 355 -y 758` (inside the bottom-trailing corner button in the outline): `native` hit nothing, the default hit the button |
| E37 | Playground `gesture-presets`, alternating pinches | Only the first pinch after a launch is recognized, in either space (`native` too); the E2E relaunches before each pinch |
| E38 | `ui` with Control Center open (iPhone 17 / iOS 27.0, Duo / iOS 27.1, released 0.15.0 too) | The process dies with SIGBUS on a stack guard page in the AX serializer on a cooperative thread, 37 frames deep. Not related to this work: issue #160 |

### Found while building S4 (2026-10-17)

Playground `chrome-test` (NavigationStack, leading and trailing toolbar items, bottom toolbar, TabView), iPhone Duo / iOS 27.1. Fixtures in `Tests/Fixtures/outline-side-bars/`.

| # | Check | Result |
| --- | --- | --- |
| E39 | iOS 27.1 SDK build, cover, portrait (466x678) | Vertical bar x≈384–466: `#BackButton` (no label) (399,179), trailing `+` (404,240), tabs (396,494/544/594). The leading toolbar item `Edit` stays in the title row; the bottom toolbar item `Share` stays bottom centre. Before S4 the bar items were spread over Content and Bottom between the rows |
| E40 | Same, cover landscape-left / landscape-right | landscape-left: the bar is on the trailing edge, back button (611,29) inside the top band. landscape-right: the bar is on the **leading** edge (x≈0–84), content starts at x=84 |
| E41 | Same, inner display | Portrait (669x951): horizontal navigation bar and bottom tab bar, status items in the tree. Landscape-left and landscape-right: the bar is on the trailing edge (x≈881) |
| E42 | Settings (UIKit, system) on the cover, General | Time (400,83), Wi-Fi (409,123) and `#BackButton` (399,179) in the bar; the navigation bar leaves a full-width `Group` (0,24 466x58) behind |
| E43 | iOS 27.0 SDK build | Horizontal bars on the cover (inset 386x678) and on the inner display (871x669); the tab bar is a declared `Group "Tab Bar"` |
| E44 | LINE 26.17.0 built with Xcode 27.1 (early-bird branch) on the cover | Fills the 466x678 display (the 27.0 SDK build was a 386x678 inset scene). Welcome and login use custom chrome (`返回` button top left), so no bar; the main tabs need a signed-in account, which this simulator does not have |
| E57 | Same build, signed in with a test account (2026-10-17; login through the LINE repo's `line_login` task — its password step pastes, which Device Hub breaks (#153), so the password was typed) | Main tabs are `RadioButton`s with ids `#homeTab` … `#miniTab`. Cover portrait and landscape-left: `[Trailing  x>=396]` / `x>=598` with the clock and Wi-Fi; inner landscape-left and landscape-right: `[Trailing  x>=881]`; inner portrait: bottom tab bar in `[Bottom]`, no side region. Cover landscape-right: `[Leading  x<=70]` on the home tab, but **none on the chat tab**: LINE's own header has a two-segment control (`聊天` / `好友`) at x 42, above the bar; it joined the bar column (bar edge x 107) and the list rows then crossed it. Chat screens use LINE's own navigation bar (`#backButton`, top left) and hide the tab bar, so they have no side region |

### Found while building S5 (2026-10-17)

| # | Check | Result |
| --- | --- | --- |
| E45 | `xcrun simctl io <duo> enumerate` | The cover (1398x2034) and inner (2007x2853) ports are **both display class 0**; the `Resizable` port is class 1 with a 7680x4320 IOSurface. idb's `FBFramebuffer.mainScreenSurface` returns the first class-0 port, so it can never read the inner panel |
| E46 | `simctl io recordVideo --display=<devicectl uniqueId>` | Inner display with the UI in landscape-left: a 2006x2852 movie, panel-native portrait (not rotated like `simctl … screenshot`). Resize Mode 560x874: 1680x2622 — simctl cuts the scene from the canvas. `recordVideo` writes only to a file, so it cannot carry `stream-video` |
| E47 | sim-use after S5 | Inner display: `record-video` 2008x2854 (H.264 even padding), 149 frames in ~5 s, a tap during the recording visible. Resize Mode 560x874: `record-video` and `stream-video --format h264` both 1680x2622, the scene with no canvas. Fold during an inner recording: the video stays 2008x2854 and stderr ends with the moved-display notice |

### Found while building S6 (2026-10-17, Device Hub quit)

| # | Check | Result |
| --- | --- | --- |
| E48 | Quit Device Hub | Both booted simulators shut down. `simctl boot` (Xcode 27.1) of the Duo, and of iPhone 17 / iOS 27.0: no `dtuhidd` under `launchd_sim`; `devicectl` works |
| E49 | `ios fold` with no `dtuhidd` | Works. The XPC report to `com.apple.coredevice.feature.remote.hid.vendordefined` makes launchd start `dtuhidd` under the simulator's `launchd_sim`; it stays running. `devicectl device appResize start` does **not** start it |
| E50 | Cold boot, tap on the cover, unfold, tap on the inner display (before S6) | The first tap made an Indigo connection (no `dtuhidd`); the inner tap failed with `The legacy Indigo HID transport reaches only the main display`. A Resize Mode tap failed the same way |
| E51 | Same, tap the cover text field, fold open and closed, `type` (before S6) | `type` reported success, the field stayed empty; a daemon restart (new connection, DTUHID) typed correctly. The fold had started `dtuhidd`, which suppresses the legacy keyboard service under the cached Indigo connection |
| E52 | After S6, Device Hub quit | Inner taps 1 → 2 → 3 at the exact locations; typing after fold/unfold works; a Resize Mode tap on a cold iPhone 17 starts `dtuhidd` and lands at `(450, 650)`. Fold, rotate, AX routing, screenshot and video need no change |

### Found in the Device-Hub-open regression of S6 (2026-10-17)

| # | Check | Result |
| --- | --- | --- |
| E53 | `ios rotate` loop on the unfolded Duo with the vendor report connection closed 0 ms after the barrier reply (temporary build) | 12 of 16 reports were lost: the device orientation stayed as before and the command reported `The interface stayed …`, the same output as a refusal. With 100, 250, 400, 700 and 850 ms: 12/12 each. So a report is lost when the connection closes before the guest takes it; the 1 s settle normally leaves a wide margin |
| E54 | Refused orientation (`portrait-upside-down` on the cover display) | The device orientation does not change either: CoreDevice keeps `portrait`. A lost report and a refusal read back the same |
| E55 | Temporary build that skips the first vendor report of a daemon | `ios rotate portrait` and `ios fold closed` each logged `had no effect; sending it again` and then confirmed (6.6 s and 7.2 s) |
| E56 | Sequence inner `landscape-left` → `fold closed` → cover `portrait` → refused `portrait-upside-down` → `portrait` → `fold open` → `rotate portrait`, 57 runs with the resend | Failed 2 times. Traced failure: the topology before was correct (`landscapeRight`, `LCD-1 rot90`, offset 1, sent `landscapeLeft`, the same as every success); the first report and the resend 3 s later both had no effect. Device orientation after `fold open` is `landscapeRight` at once (8 reads in 2.5 s, 3 runs). Not reproduced with `SIM_USE_DEBUG=1` (14 runs), with CPU load, after 20–60 s idle, or without the unfold |

### Resizable display (Resize Mode)

Sessions: Duo folded, Settings, 560x874 and then 375x667 (`appResize set
900x500` snapped to 375x667); iPhone 17 / iOS 27.0, Playground, 560x874.

| # | Mechanism | Result |
| --- | --- | --- |
| E14 | Touch: `target = <Resizable displayId>` (5 on the Duo, 4 on iPhone 17); normalize the **scene** point against the **canvas in points** (`bounds / pointScale` = 2560x1440): `(x/2560, y/1440)` | Works on both devices and both scene sizes. Playground Tap Test reports `Tap Location: (450, 650)` and `(100, 400)` exactly. The scene sits at the canvas origin |
| E15 | AX: `displayId = <Resizable displayId>` | Hit-test works in **scene** points (origin = scene top-left). `--point 280,437` returns `健康数据` (y 409–461) |
| E16 | Screenshot: `simctl io … --display=Resizable` | Scene only: 1680x2622 for 560x874, 1125x2001 for 375x667 |
| E17 | `appResize start` with the Duo inner display at `rot90` | Refused: "not in a valid orientation … Rotate the device to portrait". Sessions are portrait-only |
| E18 | Why the 009 spike missed | `FBSimulatorIndigoHID.screenRatio` computes `point × scale / screenSize`, so it expects pixels. 009 passed the 2560x1440 **point** canvas, which made the ratio 3x too large. Likely, not reproduced |

### Rotation on single-display simulators (Safari in front)

| # | Device / runtime | `devicectl device orientation set` | Vendor event (E2) |
| --- | --- | --- | --- |
| E10 | iPhone 17 / iOS 27.0, Xcode 27.1 devicectl | Works (~0.5 s, `rot270` for `landscapeLeft`) | No effect |
| E11 | iPhone 17 / iOS 26.5, Xcode 27.1 and 26.6 devicectl | Works | No effect |
| E12 | iPhone 16 Pro / iOS 18.6, Xcode 27.1 and 26.6 devicectl | Works | — |
| E13 | iPhone Duo / iOS 27.1 | Prints success, no effect (inner stays `rot90`) | Works (E2) |

- The iOS 27.1 runtime accepts only the iPhone Duo device type (`simctl create` with iPhone 17 fails: "Incompatible device"), so E10–E13 cannot separate "runtime" from "device type".
- Names differ: `devicectl` uses **device** orientation, sim-use outline tags use **interface** orientation. Device `landscapeRight` gave `rot90`, and `sim-use ui` printed `(landscape-left)` for it.
- A portrait-only app (SpringBoard on iPhone) stays `rot0` after the device rotates.

## Goals

- **One routing model** for every display that hosts the app: `tap`, `swipe`, `touch`, `gesture`, `ui` (including `--point`) and `screenshot` work on the Duo inner display **and** in a Resize Mode session on any iPhone. This closes #143.
- `sim-use ios fold` controls the hinge of a foldable simulator and confirms the result.
- `sim-use ios rotate` rotates **any** iOS simulator and reports the resulting interface orientation.
- The outline groups side-rail chrome (back button, status bar) correctly on the Duo displays.
- Detection is by **capability and state**, not by model name, so a future device works without new code.
- A single-display device with no Resize Mode session keeps byte-identical behavior and output, except for the deliberate coordinate-default change in S3.
- `record-video` and `stream-video` capture the routing display.
- Explicit iOS coordinates default to UI space, the space of the outline and of Android.

**Non-goals**

- An in-simulator helper process (upstream `SimulatorFrameworkBridge`, `axbridge`).
- Physical Duo devices (`ios-device` backend).
- Android `fold` / `rotate`. Follow-up issue #166; the verb arguments stay portable.

## Design

### Display topology

New `SimulatorDisplayTopology` in `Sources/iOSSimBackend/Sim/`. It decodes the
devicectl displays document into `[SimulatorDisplay]` (`displayId`,
`uniqueId`, `name`, `type`, `primary`, `active`, `rotation`, `bounds`,
`pointScale`). `SimulatorDisplayGeometry` copies the upstream shape
(`rot0…rot270`, `unrotatedPointSize`, `pointSize`, `unrotatedPoint(from:)`) so
the idb migration only replaces the data source.

### Routing display resolution

One function decides where the app is, from two inputs that already have
cheap probes: the topology (E9) and the Resize Mode session state
(`ResizableAppSessionMonitor`, `Sources/iOSSimBackend/Sim/ResizableAppSession.swift`).

| State | Routing display | Digitizer target | Normalization canvas | Point transform | AX `displayId` |
| --- | --- | --- | --- | --- | --- |
| Resize Mode session active | `Resizable` (virtual) | its `displayId` | canvas points (`bounds / pointScale`) | none: scene point at canvas origin (E14) | its `displayId` (E15) |
| More than one integrated display | the `active` integrated display | its `displayId` | panel points | rotation (E4) | its `displayId` (E6, E7) |
| Otherwise | main display | 0 (unchanged) | unchanged | existing calibrator | 0 (unchanged) |

- The last row is the current code path. It runs when there is one integrated display and no session, so traditional devices are not affected.
- Both monitors cache in the daemon with a short TTL, and refresh after `fold`, `rotate`, and when the AX root size disagrees with the cached geometry. They share one devicectl client.
- On a non-main routing display, the orientation comes from devicectl `currentOrientation` (a session is always `rot0`, E17), so `OrientationCalibrator` probes are skipped.
- A sanity check fails loudly when a hit-test at the routing display centre returns nothing or a pid other than the frontmost app.

### Transport changes

- **HID:** an idb patch (`patches/idb/`, applied by `apply_idb_patches` in `scripts/build.sh`) adds a per-event digitizer `target` and an explicit normalization canvas **in pixels** (E18) to `FBSimulatorDTUHIDTransport`.
- **AX:** the same patch replaces the fixed `displayId: 0` in `FBAXTranslationRequest.swift` with a parameter.
- **Screenshot:** `simctl io … --display=<uniqueId>` (E8, E16) for any non-main routing display. 009 already does this for sessions.

### Fold verb

`sim-use ios fold <closed|half|open|DEGREES> [--device] [--json]`, iOS-only,
registered in `Sources/iOSSimBackend/Verbs/IOSSimCommand.swift`. The
vendor-event XPC lives in sim-use (`iOSSimBackend/HID/`), not in the idb patch.
After the send, the verb polls the topology. The signal is the display
`active` flag, not `backlightState` (E19, E20).

- `closed` (0°) expects the primary display and `open` (180°) a non-primary integrated display. Both are deterministic (E21). The verb fails on timeout.
- `half` (130°) and `DEGREES` have no fixed expectation (E21). The verb waits until the topology is stable, then reports the active display it observed. It does not claim the angle, because sim-use cannot measure it (E22).
- A fold wakes a locked device to the lock screen (E20). The verb reports this; it does not unlock.
- It refuses devices with one integrated display.

### Rotate verb

`sim-use ios rotate <portrait|landscape-left|landscape-right|portrait-upside-down> [--device] [--json]`.

- **Names are interface orientations**, the same names as the outline tag (`DisplayOrientation` in `Sources/iOSSimBackend/A11y/DisplayOrientation.swift`). The verb maps them to the device orientation it sends.
- **Transport by capability:** one integrated display → `devicectl device orientation set` (E10–E12); more → the orientation vendor event (E2, E13).
- **Result:** the verb reads back the device orientation and the routing display `currentOrientation`. It fails when the device orientation did not change. When the app does not support the orientation, it succeeds with an advisory and reports the real interface orientation.
- During a Resize Mode session the verb refuses: sessions are portrait-only (E17).

### Outline layout

`OutlineFormatter` (`Sources/iOSSimBackend/Normalizer/OutlineFormatter.swift`)
takes the screen size from the AX root frame and assigns `Top` / `Content` /
`Bottom` by `yBandInset = 120`. Two changes:

1. **Screen size:** on a non-main routing display, use the routing geometry `pointSize` (the scene size for a session), not the AX root frame (669x951 vs the real 951x669).
2. **Side rail:** add `Trailing` and `Leading` regions. They are **evidence-gated** (`Sources/iOSSimBackend/Normalizer/OutlineSideBars.swift`): an anchor (`BackButton` identifier, or a tab role `RadioButton`/`Tab`) in a 120 pt edge strip, at least two elements of its column stacked vertically, and the app's wide content clear of the bar's inner edge. The S4 evidence (E40) showed that the first idea — an anchor outside the top band — fails: in cover landscape-left the back button is in the top band. The bar's entries are listed after the bands. Without the evidence the output does not change.

The iOS host AX gives no stable navigation-bar role. On the cover display the
navigation bar is `AXGroup` with a localized role description (`导航栏`), so
`declaredRegionKinds` cannot detect it.

## Slices (one PR each, stacked in this order)

Each PR is based on the previous one, is not a draft, and gets a Prowl
review-loop round before the next one starts. Every PR ships its README,
`skills/sim-use/SKILL.md` and `CHANGELOG.md` changes, and bumps
`MINIMUM_SIM_USE_VERSION` in `skills/sim-use/scripts/preflight.py` when the
skill starts to rely on new behavior.

### S1 — Topology, posture verbs, honesty

Scope: `SimulatorDisplayTopology` and its monitor; routing display resolution
(decision only, no new transport); `ios fold`; `ios rotate` for every iOS
simulator; the 009 guard extends to a non-main integrated display (touch
verbs, `record-video`, `stream-video` refuse with an explanation);
`screenshot` follows the routing display; posture visibility (below).

Acceptance:

- `ios fold closed|open` switches the active display and confirms it within the timeout; `half` / `DEGREES` report the observed display; locked device works (E19–E20); single-display devices are refused with a clear error. `ios fold` with no argument prints the posture (active display, its orientation, session state).
- `ios rotate` works on iPhone 17 / iOS 27.0 and 26.5, iPhone 16 Pro / iOS 18.6, an iPad, and the Duo cover and inner displays; Xcode 26.6 and 27.1 selected; the `ui` orientation tag matches afterwards; refusal during a Resize Mode session; advisory for a portrait-only app.
- Unfolded Duo: `tap`, `swipe`, `record-video` fail with an explanation (no false success); `screenshot` returns the inner display (2853x2007 after rotation).
- Posture visibility: `ui --json` has a `display` object only on a non-main routing display; the text header gets a suffix such as `(inner, landscape-left)` or `(resizable 560x874)` only then. Single-display text output is byte-identical (golden test).
- Unit tests: devicectl document decoding (fixtures from E9, E19), resolution states, fold expectations, rotate name mapping.

### S2 — Touch and AX routing (closes #143)

Scope: idb patch (per-event digitizer target, pixel canvas, AX `displayId`);
`SimulatorDisplayGeometry`; calibrator bypass on non-main routing displays;
`--point`, collapsed-children recovery and the remote-content retry on the
routing display; the S1 and 009 touch guards are removed for integrated
displays and Resize Mode sessions.

Acceptance:

- Duo inner display, all four rotations, and cover display: `tap @N`, `tap --id/--label`, `swipe`, `long-press`, `touch`, `gesture` presets, `type`, `ui --point` all land (Playground Tap Test / Swipe Test / Touch Control counters, not only "success").
- Resize Mode on iPhone 17 / iOS 27.0 and on the folded Duo, two scene sizes: the same verbs land; `Tap Location` equals the requested point.
- `ui` on the inner display has no calibration advisory, and the Settings sidebar is no longer collapsed; no SpringBoard elements spliced into a session tree.
- Single-display regression: `make e2e-ios` green; the 009 E2E now asserts delivery instead of refusal.
- A 009 amendment records the new routing.

### S3 — Explicit coordinates default to UI space

Scope: `--coordinate-space` default flips to `ui` on every iOS verb that takes
explicit coordinates (`tap` / `long-press` `-x/-y/--point`, `swipe`, `touch`,
`multi-touch`, `gesture` pinch/rotate `--center-x/-y`, and the same verbs as
`batch` steps); `native` stays available. Orientation source: the same
calibration that selectors use (hit-test probes, CoreDevice when probes are
ambiguous; fixed calibration off the main display). `native` means the
routing display's native portrait points (S2).

Acceptance:

- Rotated iPhone (all four orientations), downscaled device (iPhone 13 mini class) and Duo inner/Resizable: `tap -x/-y` with numbers read from `ui` lands on the element by default; `--coordinate-space native` reproduces the old behavior.
- `swipe`, `touch` (atomic and split), `multi-touch` and `gesture pinch-*`/`rotate-*` take outline coordinates by default; batch steps match the standalone verbs.
- `--coordinate-space` given with an alias or a selector is rejected (either value); with a directional `gesture` preset it is rejected.
- `CHANGELOG.md` `### Changed` entry, skill and README text updated. The skill floor stays 0.16.0 (S1 already set it; S3 ships in the same release).
- Unit tests for the default and both spaces; batch parity.

### S4 — Outline layout on multi-display devices

Scope: screen size from the routing geometry; evidence-gated `Trailing` /
`Leading` regions; a Playground chrome screen (NavigationStack, TabView,
toolbar, trailing buttons).

Acceptance:

- Duo cover display: `#BackButton` and the status bar are in `Trailing`; content rows stay in `Content`. Inner display (landscape and portrait): bands match the 951x669 / 669x951 UI. Tab bar position verified on both displays and placed in a sensible region.
- Golden fixtures for single-display trees (iPhone portrait, landscape, iPad) are unchanged. Done: `Tests/Fixtures/outline-side-bars/` pins iPhone 17 (Playground chrome portrait/landscape, Settings) and iPad Pro 13-inch / iOS 26.5 (Playground chrome portrait/landscape, Settings sidebar, Settings › About with its back button) with no side region; with no bar the formatter takes the S3 path unchanged.
- LINE app (simulator build) on both Duo displays: main tabs, a chat, back navigation driven only through `ui` + `tap @N`. **Met (2026-10-17, E57):** signed in, the 27.1 SDK build went home tab → chat tab → a chat → back on the cover (portrait, landscape-right) and the inner display (landscape-left, portrait); the regions of every orientation are in E57. The cover landscape-right chat tab needed the segmented-control fix below. Before that, welcome → login → back was driven on both displays with the 27.0 and the 27.1 SDK builds (E44).

### S5 — Video on the routing display

Scope: `record-video` and `stream-video` capture the routing display (idb
framebuffer selected by display, or `simctl io … recordVideo --display`);
the display switch during a recording (fold while recording) is defined.

Acceptance: recordings of the inner display and of a Resize Mode session have
the right size and content; a fold during a recording either follows the new
display or ends with a clear message (decided in the slice); single-display
recording unchanged.

Result: met — E47; the fold keeps the starting display and ends with a notice (decision above).

### S6 (conditional) — Device Hub closed

Scope: with Device Hub quit, check `fold`, `rotate`, touch and AX routing.
Make it work if dtuhidd can be started on demand or Indigo can route; else
refuse with a message that names the requirement.

Result: works (E48–E52). dtuhidd can be started on demand; Indigo cannot route.

### After the stack

- File an issue for Android `fold` / `rotate`.
- `001-action.md`, plan status `Implemented`.

## Alternatives & decisions

| Decision | Options considered | Chosen because |
| --- | --- | --- |
| Do it now on the pinned idb (A), migrate idb later (B) | Wait for B; do A now | B is a full API migration (no FB* name survives since `1f6943f8`; facebook/idb#980 double rotation). A's CLI surface, tests and E2E carry over; the throwaway part is the patch, the devicectl source and the XPC transport. Upstream B does not cover Resize Mode (009), so A's session routing must survive B in some form |
| One routing model for the Duo and Resize Mode | Duo only, #143 later | E14–E16: the same target / `displayId` / per-display screenshot mechanism works for the virtual display; only the canvas rule differs |
| No process inside the simulator | upstream guest for the AX id; host-side devicectl id | E7 shows the ids are the same; product rule: nothing added to the simulator. For B: an upstream PR for a host-only identity source, or a small patch |
| Fold confirmation by the `active` flag; no angle claim | Measure the angle like upstream (`monitormotion`); trust the send | E21: 0° and 180° are deterministic. Reading `monitormotion` needs a CoreDevice client that the pinned idb does not have; the migration can add it |
| Fold transport in sim-use, not in the idb patch | idb patch; sim-use | Keeps the patch to the parameters that B makes native |
| Gate on state ("session active", "more than one integrated display") | Model name (`iPhone Duo`); device-type table; display count including virtual | Future devices work with no change; the `Resizable` display is listed on every Xcode 27 iPhone, so a raw display count would include every device |
| Side-rail regions gated by evidence | Device table ("Duo = trailing rail"); AX roles; geometry only | Roles are localized; tables need a change for each device; evidence keeps single-display output identical |
| Authoritative rotation from devicectl on a non-main routing display | Keep hit-test calibration | E9 is cheap and exact; probes do not reach the display without routing anyway |
| Rotation transport chosen by capability: Purple GSEvent on one integrated display, orientation picker report on more | devicectl `orientation set`; always vendor event; try one, then the other | E10–E13, E23: Purple needs no devicectl, runs on every runtime tested and is what upstream idb uses when the runtime has no device motion; devicectl is still used to read the result back. A fallback chain doubles the latency of the failure case |
| Rotation planning by a transport offset learned from the read-back | Per-display offset; hard-coded Duo table | E24: rotations and the reported device orientation share one frame, only the picker value is offset. The first guess (0 primary, 1 secondary) is corrected once when the device turned to the wrong side; a report that did not change teaches nothing (E25) and ends as "not accepted" with an advisory, never a second guess |
| Fold and rotate clear the describe-ui snapshot | Keep it, rely on the stale-snapshot advisory | A fold moves the app to another display with another geometry; a cached `@N` would tap the old coordinates on the new display |
| S1 also sizes the outline to the secondary display's interface | Leave it to S4 | The header said `669x951 (landscape-left)` — self-contradictory. One argument to `OutlineFormatter.render`; banding rules stay for S4 |
| A display without `uniqueId` uses its name as the identifier | Drop the entry; make the id optional | E26: every pre-iOS 27 runtime would read as "no display"; `simctl io --display` accepts names |
| S2: route per event in `HIDInteractor` (`FBSimulatorHID.displayRoute`), calibration via `RoutingDisplay.fixedCalibration` and `AXProbeSession` | Route in every verb | One place applies the route to every touch path (verbs, batch, gestures); keyboard events skip the lookup |
| S2: the main display asks CoreDevice when probes are ambiguous or the scene is inset | CoreDevice first on every command | Probes cost milliseconds and settle the common case; a fresh devicectl read costs ~0.1 s and is only needed when they cannot (E29) |
| S2: place an inset scene by probes, two confirmations per offset | Per-device strip tables; Apple's `ReservedRegion` API (in-app only) | Covers the Duo strip in every orientation, centred older-SDK scenes and windowed iPad scenes with one rule; one confirmation was fooled (E31) |
| S2: drop the `secondary_display` and `resizable_app_session` `ui` advisories | Keep them | Nothing is refused any more on those displays; the header tag and the `display` object say where the app is. `resizable_app_session` stays on `screenshot` |
| S2: a device-sized AX root re-checks a cached active session | Keep the 5 s staleness | Touches are now routed, not refused: a stale "active" would send them to the display the app left (E33) |
| Rotate takes interface orientation names | Device orientation names (devicectl) | Agents read the outline tag, which is interface orientation; one vocabulary in the CLI |
| `fold` and `rotate` are iOS-only verbs (`sim-use ios …`) | Top-level verbs now | No Android implementation yet. Android emulators can fold and rotate, so the arguments stay portable for a later top-level verb (owner decision, 2026-10-16: Android later, separate issue) |
| Explicit iOS coordinates default to UI space | Keep `native`; UI only on non-main displays | Owner decision 2026-10-16. Same space as the outline and Android; devicectl orientation removes the calibration-failure risk that kept `native` the default. Breaking for callers that hand-write native coordinates on a rotated or downscaled device: `CHANGELOG` `Changed` |
| Record and stream the routing display in this stack | Refuse until the idb migration | Owner decision 2026-10-16: complete Duo support |
| S3: UI-space orientation from the selector calibration, not devicectl first | devicectl `currentOrientation` on every command | Measured on iPhone 17 / iOS 27.0, portrait: `tap -x/-y` 610–660 ms native, 670–745 ms ui (one tree fetch plus probes). One devicectl read alone is ~0.1–0.3 s. CoreDevice stays the fallback when probes are ambiguous (S2) |
| S3: UI-space calibration from the `ui` snapshot first, used only when probes confirm the snapshot's elements are in place | Tree every time (+~75 ms, E34); snapshot like `tap @N` (no confirmation) | The snapshot path reads no tree, so the routing display comes from the daemon cache: after a Resize Mode session ended, an unconfirmed snapshot calibration sent the first tap to the gone `Resizable` display (`ResizeModeTests.firstExplicitTapFollowsSession` red without the confirmation). Two in-place hits within four probes cost a few ms (E35); any doubt falls back to the tree, which re-checks the routing (R158-03). CoreDevice is not consulted on this path |
| S3: the snapshot path reads the frontmost app's root frame (`FBAccessibilityElement.frame()`, no tree) and requires the snapshot to fit it (R161-01) | Element confirmation only; tree every time | A resized Resize Mode session (560x1200 → 560x667) kept its top controls, so element probes confirmed the old 1200 pt canvas and a gesture started below the scene. The root size also feeds the routing checks exactly as a tree fetch does |
| S3: split `touch --down` / `--up` take UI coordinates, each half calibrated | Keep `ui` atomic-only (split form would need `native`) | With `ui` as the default, the old rule would reject every split touch. Each half maps the point through the orientation at its own time, which is where the user sees it |
| S3: `gesture` pinch/rotate centre and canvas in UI space, every sample mapped | Keep native portrait for multi-touch presets | The calibration is affine, so mapping each interpolated sample keeps lines and arcs; the directional presets already use the UI canvas (#66) |
| S4: side-bar regions from geometry and anchors, not from device or SDK | Device table ("Duo cover = trailing"); trait/SDK checks; AX roles only | The bar edge depends on the display and the orientation (E40, E41); the host cannot read the app's SDK or traits. Anchors are `BackButton` and tab roles (`RadioButton`/`Tab`) — a tab with a sibling tab beside it outside the strip is a horizontal tab bar and does not count (review S4-001). The vertical evidence is the back button plus one more stacked member of its column reaching below the top band (a regular iPhone stacks its status clock above the back button inside the top band, S4-003), or two stacked tabs; any disjoint pair counts, so a rail wrapper does not hide the stack (S4-002). The app's wide content must stay clear of the bar's inner edge — rows on a regular iPhone cross the leading strip, so its back button never qualifies. Full-width grouping elements (the left-behind navigation bar group, E42) are containers, not crossing content |
| S4: a tab in a horizontal row never joins the bar column; wide content must exist beside the bar (in its vertical range); nothing may cross the bar's edge except an app header that is above the bar and inside the top band | Exclude tab roles from the column; drop the crossing rule; limit the crossing rule to the bar's vertical range | E57: LINE's header above the bar starts inside the strip. Excluding all tabs would drop the bar's own tabs; without the crossing rule a back button over row icons on a regular iPhone would become a bar. Limiting the crossing rule to the bar's range let a profile form (back button, avatar below it, fields below both — with or without a name label beside the avatar) pass as a bar (review S4-004, two rounds) |
| S4: bar entries listed after the bands, aliases renumbered in print order | Keep reading order (bar items between rows) | An agent reads the bar as one unit; aliases stay monotonic in the text |
| S5: capture through idb, framebuffer port chosen by pixel size, source crop for the Resize Mode scene (`patches/idb/display-video.patch`) | `simctl io recordVideo --display` for `record-video` | simctl writes only files (no `stream-video`) and has no `--fps`/`--scale`. Two integrated ports share display class 0 (E45), so the port is named by its unrotated size, which CoreDevice reports per display. The crop runs once per frame before the encoder, so every format sees the scene size |
| S5: the Resize Mode crop comes from the app's actual scene (frontmost application frame), rounded up to even pixels (review S5-001) | The session's requested size | An app can snap away from the request: Settings › General asked for 402x874 shows 437x874, and a 1206 px crop cut off 105 px |
| S5: the BGRA stream repacks padded rows (review S5-002) | Send the buffer with its stride | Consumers read packed `rawvideo`; a 1206 px crop buffer has a 4864-byte stride, and the Duo cover surface (1398 px) was padded before S5 too (0.15.0 sends 11,468,800 bytes per 1398x2034 frame) |
| S5: the end-of-capture check invalidates the session cache and refreshes a multi-display topology (review S5-003) | Reuse the 5 s / 2 s caches | A capture shorter than the cache window otherwise ends with no notice |
| S5: videos keep the panel's native portrait orientation | Rotate to the interface orientation | The main display has always recorded its framebuffer unrotated (`simctl recordVideo` does the same, E46); one rule for every display. Rotating every display is a separate change |
| S5: a display change during a capture keeps the starting display and ends with a stderr notice | Follow the new display; stop the capture | A new display changes the frame size mid-file; stopping loses the take. The notice names both displays; `--json` is unchanged (no new advisory kind) |
| S6: Device Hub closed — work, not refuse | Refuse routed input without dtuhidd | dtuhidd starts on demand through its XPC service (E49), which sim-use already uses for fold/rotate. A cached auto-selected Indigo connection is rebuilt once dtuhidd runs (keyboard, E51); routed touch starts dtuhidd itself (Resize Mode never does, E49). Only if dtuhidd still does not start does the command fail, naming Device Hub |
| Fold / rotate send the report once more when it had no effect (same active display; same device orientation and rotation) | Longer settle after the barrier; retry the whole command; no resend | A report can be lost (E53) and the resend recovers it (E55). The report is idempotent, so a refusal only reads back the same (E54); the cost is one more wait on a refusal (`portrait-upside-down` on the cover: 7.4 s). A longer settle bets on one margin and slows every call |
| Rotate is confirmed at once only when the device orientation **and** the interface reached the target | Device orientation alone | With the device alone, a read taken while the interface still followed was the final answer (open question 18). Same latency on the success path: 3.4–3.9 s per `ios rotate` before and after, 12 runs each |
| Posture shown only on a non-main routing display | Always; never | Owner decision 2026-10-16: single-display output stays identical |
| Device Hub closed: make it work if possible, else refuse with the requirement | Must work | Owner decision 2026-10-16 |

## Verification plan

- `make build`, `make test`. New unit suites: devicectl document decoding (fixtures from E9), routing display resolution (three states), geometry for the four rotations (E4) and the session canvas (E14), fold confirmation logic, region gating with golden fixtures for single-display trees (no change) and for the Duo cover and inner trees.
- Live, single-display: `ios rotate` round trip on iPhone 17 / iOS 27.0 and 26.5, iPhone 16 Pro / iOS 18.6, with Xcode 27.1 and 26.6 selected; the `ui` orientation tag matches after each rotation.
- Live, Resize Mode (009 recipe, Playground Tap Test): `Tap Count` and `Tap Location` match for 560x874 and one other size; `ui --point` and screenshot in the session; on iPhone 17 / iOS 27.0 and on the folded Duo.
- Live, iPhone Duo / iOS 27.1: fold round trip; `ios rotate` on the inner and the cover display; `tap` / `swipe` / `ui --point` in rot0 and rot90 unfolded and on the cover; screenshot sizes; outline regions on Settings and on the Playground chrome screen.
- E2E: the 009 Resize Mode suite changes from "touch is refused" to "touch lands". A new opt-in suite `e2e-ios-duo` (needs Xcode 27.1 and a Duo device). `make e2e-ios` on a single-display simulator must stay green.

## Open questions

1. Resolved by S6 (E48–E52) for Device Hub closed; Simulator.app (Xcode 26.x) with an iPhone Duo was not tried. **Hub closed / Simulator.app.** A fresh headless `simctl boot` (Device Hub running, but not showing the device) already had `dtuhidd` in its process tree, and `devicectl` worked. Not tested with Device Hub quit. With no dtuhidd, sim-use selects the Indigo transport (`defaultHIDTransport`). Can Indigo route to a non-main display? Not tested.
2. Resolved by E27: the selected Xcode's devicectl (27.0 or 27.1) reads the Duo.
3. Resolved by E21 (path-dependent). Not known: the rule behind it (angle delta, speed, or both), and whether a fully dark display (`off` on both) can happen with Always-On disabled.
4. Resolved in S4 (E39–E43): with the iOS 27.1 SDK the tab bar is in the vertical bar on the cover (all orientations) and on the inner display in landscape; horizontal at the bottom on the inner display in portrait and with the iOS 27.0 SDK everywhere.
5. Answered in S4: iPhone 17 (`设置`) and the Duo inner display in portrait expose the time and Wi-Fi in the app tree; the cover vertical bar does in Settings but not in the SwiftUI Playground. Status items are not anchors; they join the bar's column when present (E42).
6. E7 is one device and one runtime. E14 is two devices and two scene sizes; the "scene at canvas origin" rule is not proven for all sizes.
7. A fold once sent the foreground app (Settings) to SpringBoard on the cover display; another fold kept it. Not understood.
8. Rotation on the Duo **cover** display: E2 was measured only with the inner display active.
9. iPad simulators: rotation verified (E23). Resize Mode not tested on an iPad.
10. devicectl `currentOrientation` also works on single-display devices (E10). It could replace the hit-test calibrator everywhere, which is what the idb migration needs (facebook/idb#980). Out of scope here; record as a follow-up.
11. Resize Mode on the Duo inner display: refused at `rot90` (E17). Not tested at inner `rot0`.
12. `gesture rotate-cw` / `rotate-ccw` are not detected by the Playground on the cover, the inner display or a single-display iPhone 17 (pre-existing, display-independent). Not investigated here.
13. Resolved in review (R158-02): on a multi-display simulator, and off the main display, `describe-ui --point` fetches the tree first and uses the same routing, calibration and scene placement as the full outline. Review R158-05 then removed the single-display fast path too: it answered from a cached routing check, so the first point query after a Resize Mode session started hit SpringBoard. Every point query now fetches the tree first (one more tree fetch on an upright single-display simulator), and `OrientationCalibrator.soleOrientation` is gone.

14. Resolved in review (R161-02): a `batch` `gesture pinch-*`/`rotate-*` step sent one single-finger swipe (pre-existing, found with #66). It now sends the standalone verb's two-finger event (`IOSSimGestureCommand.multiTouchEvent`) on the batch-wide calibration.
15. S3: `paste --via-menu --target-x/-y` uses the same `hidPoint` mapping as `tap`, but it was not verified live: with Device Hub open the pasteboard write is replaced (#153), and `--via-menu` already fails on iOS 26.5/27.0 with `--target-id` too.
16. S3: software-keyboard elements have framebuffer-anchored frames in a rotated tree; they are discriminators in both the tree and the snapshot calibration (known issue, see #34 follow-ups).
17. S3: `tap @N` calibrates from the snapshot without the in-place confirmation that UI-space coordinates now use, so the first alias tap after a Resize Mode session starts or ends may still follow a stale routing cache. Not changed here.
18. S6: one `make e2e-ios-duo` run with Device Hub closed failed twice on timing: `ios fold closed` did not see the cover become active within 6 s, and an `ios rotate landscape-left` read back the device turned but the interface still landscape-right. Both suites then passed in four reruns and a second full run (7/7). **Partly resolved (2026-10-17):** the Device-Hub-open regression failed `FoldTests` once more (`ios rotate portrait` right after `fold open`). A vendor report can be lost (E53), so fold and rotate now send it once more when it had no effect (E55), and rotate no longer takes a turned device with an unturned interface as the answer. Still open: right after an unfold, the guest sometimes ignores orientation reports for more than 3 s (E56, 2 of 57 runs); the cause and the length of that window are not known.

## Amendments
- Updated 2026-10-17: all six slices done; action log in [001-action.md](001-action.md)
