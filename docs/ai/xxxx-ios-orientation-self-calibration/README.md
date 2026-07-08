# iOS orientation self-calibration for AX-derived coordinates

Work record for the investigation and fix of issue #34 — "iOS tap coordinates
are wrong when app orientation and Simulator window rotation differ".

## Problem

Three coordinate spaces coexist on the iOS Simulator, and sim-use conflated
them:

| Surface | Space | Rotates with UI? |
|---|---|---|
| AX element frames (`element.accessibilityFrame` via the idb bridge) | app UI space | yes |
| HID touch events (`FBSimulatorIndigoHID` normalizes by the fixed `deviceType.mainScreenSize`) | device-native portrait framebuffer | no |
| AX point hit-test input (`accessibilityElementForPoint:`) | device-native portrait framebuffer | no |
| Screenshots (`takeScreenshot`) | raw framebuffer | no |

No transform existed between them, so every AX-derived coordinate was handed
to HID verbatim. Upright portrait is the only state where the spaces happen to
coincide.

Three user-visible symptoms, all one root cause:

1. **Taps miss under rotation.** `tap @N` / `--label` / `#<id>` land at the
   un-rotated position. Reproduced live: on a landscape iPad, tapping
   "About" opened "VPN & Device Management" (exactly the report in the issue
   comment); in the opposite landscape the same tap silently hit the nav bar.
2. **`describe-ui` outlines silently lose regions.** The quadtree recovery
   probes in framebuffer space but books coverage with UI-space frames; the
   corrupted bookkeeping dropped the entire Settings sidebar (16 entries) at
   180° and 12 of 16 in landscape.
3. **Screenshots appear rotated** (out of scope here; see Open items).

Android is unaffected — `AccessibilityNodeInfo` bounds, input injection, and
screenshots all share one rotated screen space (verified live in landscape).

### Measured transforms

With native portrait size W×H in points, framebuffer point `f` ↔ UI point `u`
(measured empirically on iOS 26.5, iPad Pro 11" M5, 834×1210):

```
portrait               u = f
portrait-upside-down   u = (W−fx, H−fy)
landscape-right        u = (fy, W−fx)      f = (W−uy, ux)   (one rotate-left from upright)
landscape-left         u = (H−fy, fx)      f = (uy, H−ux)   (one rotate-right from upright)
```

Landscape names follow CoreSimulator's display descriptor
(`xcrun simctl io <udid> enumerate` → `UI Orientation:`).

### Key detection constraint

The AX-reported screen size **cannot** identify the orientation: 0° and 180°
share the same size, and the two landscapes share the same swapped size. The
issue's suggestion ("detect via AX screen size") is therefore insufficient on
its own — it only prunes candidates.

## Orientation source — options considered

| Source | Verdict |
|---|---|
| Public FB*/SimulatorKit headers | **Zero** orientation API exported. |
| `SimDisplayRotationAngleDelegate.didChangeDisplayAngle:` (private) | Push-only; a one-shot CLI never receives the initial value. Would need new SimDeviceIO wiring. |
| `SimDisplayRenderable.displaySize` (private) | Likely stays native-sized; unreliable. |
| XCTest `_XCT_getDeviceOrientationWithCompletion:` (private) | Queryable but requires standing up a test-manager channel — far too heavy per command. |
| SimulatorBridge protocol | No orientation method (historical claims disproved by header inspection). |
| `simctl io enumerate` "UI Orientation" label | Real and live, but subprocess + version-fragile text parsing, and **unverified semantics for app-forced orientation** (issue case 1). Used only for naming the enum cases. |
| Simulator.app per-device plist (`SimulatorWindowOrientation`) | Describes the *window*, not the app interface orientation — misses case 1. |
| **In-band self-calibration via AX hit-test** | **Chosen.** |

Notably, idb's own coordinate hook
`accessibilityTranslationConvertPlatformFrameToSystem:` (Apple's doc comment:
"It's the job of this function to translate co-ordinate spaces") is a no-op —
the gap exists upstream.

## Decision: self-calibration

The AX hit-test shares the HID input space (verified empirically), so instead
of *querying* the orientation we *measure* the mapping directly:

1. **Prune candidates** by comparing the AX Application-root size against the
   native portrait size (from `FBSimulator.screenInfo`, pixels ÷ scale):
   equal → {portrait, 180°}; swapped → {landscape-right, landscape-left};
   unknown (tap-alias path) → all four, ordered by a stale-snapshot hint.
2. **Probe.** Take a known element whose frame is far from the screen center
   (center-symmetric points project onto themselves under every mapping and
   discriminate nothing). Assume the leading candidate, inverse-transform the
   element's center into a framebuffer point, and hit-test it. The returned
   frame yields containment evidence against **all** remaining candidates at
   once (`retain T where frame ∋ T.framebufferToUI(probePoint)`), so the
   common cases — portrait and 180° — resolve in **one probe**.
3. **Uninformative results** (full-screen wrapper hit, nil) rotate the leading
   assumption and move to the next discriminator; budget capped at 3 probes.
4. **Failure degrades safely**: fall back to the highest-prior surviving
   candidate (portrait unless the dims are provably swapped) and attach an
   `orientation_calibration_fallback` command advisory. Never worse than the
   pre-fix behavior.
5. **Never cached across commands** — rotation can happen at any time. The
   portrait fast path's single probe is effectively a self-validating cache.

Because calibration measures the actual AX↔hit-test relationship, it covers
device rotation, Simulator window rotation, and app-forced orientation by
construction, and depends on no private API.

## Implementation

New files:

- `Sources/iOSSimBackend/A11y/DisplayOrientation.swift` — pure transform math
  (`NativePortraitSize`, `DisplayOrientation` with `uiToFramebuffer` /
  `framebufferToUI` / `uiSize`, edge clamping to `[0, limit)`).
- `Sources/iOSSimBackend/A11y/OrientationCalibrator.swift` — the
  candidate-elimination calibrator (injectable probe closure for tests),
  `OrientationCalibration` (carries `hidPoint(x:y:)`), `AXProbeSession`
  (one-time simulator lookup → probe + native size), snapshot-based and
  tree-based convenience entry points.

Integration points (transform applies to AX-derived coordinates **only**):

| Path | Change |
|---|---|
| `AccessibilityFetcher` tree fetch | Calibrates after the XPC fetch; wraps the quadtree probe as `probe(calibration.hidCGPoint($0))` when non-identity. `CollapsedChildrenRecovery` internals untouched (its bookkeeping is consistently UI-space). |
| `describe-ui --point` | Input redefined as **UI space** (the space printed frames use). The first probe doubles as calibration evidence; a tree-fetch calibration only runs when inconclusive. Also: `--point` no longer overwrites the `@N` alias snapshot (pre-existing footgun found during verification). |
| `tap @N` / `#N` (snapshot alias) | `OutlineAliasResolver.resolveWithPayload` exposes the matched entry + payload; calibration uses the tapped entry as the first discriminator (the confirming probe lands on the element about to be tapped). Mismatched snapshot dims emit a stale-snapshot advisory. |
| `tap #<id>` / `--label` family | New `AccessibilityPoller.resolveWithPollingHIDTarget` returns `{ui, hid, calibration, advisory}` from the same fetch that resolved the element. All dispatch shapes transformed: `tapAt`, duration down/up, two-finger (both fingers). |
| `ios batch` | `BatchContext` lazily computes one calibration per run (injectable for tests); selector tap steps transform, explicit x/y steps bypass. |
| `paste --via-menu` | `--id` target and edit-menu-item taps transformed; explicit `--target-x/y` raw. |
| `describe-ui` surfacing | `App:` header gains `(landscape-right)`-style tag when non-portrait (portrait output byte-identical); `--json` `data.orientation`; alias snapshot records its orientation. |
| Raw by contract | `tap -x/-y`, `touch`, `swipe`, `gesture`, `multi-touch`, keyboard verbs — device-native portrait coordinates, untouched (issue acceptance criterion). |

Out of scope / follow-ups: `screenshot` / `stream-video` / `record-video`
still emit the raw framebuffer orientation.

## Performance (measured, warm daemon, 180° iPad)

- One hit-test probe: **~3.2 ms** (p50; same primitive the quadtree already
  fires 50+ times per `ui`).
- `ui`: calibrate stage 4.8 ms of a 544 ms fetch — **< 1%**.
- `tap @N`: 0.66 s → 0.69 s (**+20–40 ms**, mostly the extra simulator-set
  lookup, not the probe).
- Explicit-coordinate verbs: zero overhead.
- Worst case: 3 probes ≈ +10 ms over the above.

## Verification

- 725 unit tests (`make test`), including: transform math against the
  empirically measured mappings, calibrator behavior for all four ground
  truths under a mock device, and a **sidebar-loss regression test** that
  fails with the raw probe and passes with the calibrated one.
- Live matrix on iPad Pro 11" (M5), iOS 26.5, all four orientations:
  outline completeness (sidebar present), `tap @N` on Settings "About"
  (opens About — previously opened VPN & Device Management in landscape-left
  and silently missed in landscape-right), `#<id>` path, `-x/-y` raw
  invariance (still hits the same physical point as pre-fix), batch selector
  step, header tag, and JSON `orientation` field.
- CoreSimulator's `UI Orientation` label was captured in each state to pin
  the `landscape-right` / `landscape-left` naming.

## Open items

- **Issue case 1 live check** (app-forced landscape with a portrait Simulator
  window, iPhone): the mechanism covers it by construction — calibration
  measures the actual AX↔hit-test relationship, and AX frames follow the
  interface orientation — but it has not been exercised live yet. Candidate
  repro: Safari fullscreen video on an iPhone simulator, or the reporter's
  app.
- **Screenshot rotation** to match the UI orientation (agents comparing
  screenshots against outline coordinates still see rotated pixels).
- The measured transform table assumes the hit-test space equals the HID
  space; if a future Xcode changes either side, the calibrator keeps working
  (it measures, not assumes) but the screenshot follow-up should re-verify.
