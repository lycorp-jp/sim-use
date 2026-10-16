# 009.001 — Touch and accessibility routing to the Resizable display

## Context

This record ended with a stop-gap: detect the session and refuse touch
input, because the scene's place inside the 7680x4320 canvas was unknown and
a spike that swept digitizer targets 0–10 did not land a tap. The iPhone Duo
work (docs/ai/010-display-routing) revisited the spike on 2026-10-16.

## Change

- **The scene sits at the canvas origin.** Send `IndigoDigitizerEvent` with
  `target = <Resizable display id>` (4 on iPhone 17, 5 on iPhone Duo) and
  normalize the scene point against the canvas **in pixels**:
  `ratio = point × pointScale / 7680x4320`, i.e. `point / 2560x1440`.
  Verified on iPhone 17 / iOS 27.0 and the folded Duo, scenes 560x874 and
  375x667: Playground `Tap Location: (450, 650)` for a tap at (450, 650).
- **Why the spike missed:** `FBSimulatorIndigoHID.screenRatio` computes
  `point × scale / screenSize`, so it expects pixels; the spike passed the
  2560x1440 point canvas, which made every ratio three times too large.
  Likely, not reproduced.
- **Accessibility:** the AX translator takes `displayId = <Resizable display
  id>`; its point hit-test is in scene points. No offset or canvas is needed.
- **Detection still comes from `devicectl device info appResize`.** The
  `Resizable` display stays `active: false` with the backlight off during a
  session, so the display list cannot tell.
- Shipped in the 010 S2 change: touch verbs and hit-tests are routed instead
  of refused; `ui` drops its `resizable_app_session` advisory and names the
  display in the header; `record-video` / `stream-video` still refuse.
  A `ui` whose root is the device's own size re-checks a cached session, so
  touches return to the main display when the session ends.
- The Tier 3 plan above (bump idb, upstream `DisplaySelection`, the guest
  bridge) is not needed for Resize Mode: a small patch to the pinned idb
  (`patches/idb/display-routing.patch`) adds the digitizer target and the AX
  display id.

Refs: docs/ai/010-display-routing/000-plan.md (E14–E18, E33).
