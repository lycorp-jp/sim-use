# Pitfalls and Recipes

Detailed solutions for common sim-use issues. The symptom index in SKILL.md points here.

## Label collision

**Symptom:** `tap --label 'X'` hits the wrong element, or returns `multipleMatches`.

**Why:** Multiple elements share the same accessibility label (e.g. a segmented control at the top and a tab bar at the bottom both say "Chat").

**Recipes:**
1. Add `--element-type RadioButton` (or whatever the outline shows) to narrow by type.
2. Add `--frame minY=0.7r` to restrict to a screen region. Use `r`-suffixed fractions for device-independent targeting.
3. Combine both: `--label 'Chat' --element-type RadioButton --frame minY=0.7r`.
4. If the element has a `#<id>` in the outline, use `tap '#<id>'` instead — it bypasses label matching entirely.

## Alias staleness

**Symptom:** `tap @N` fails or taps the wrong element after navigating to a new screen.

**Why:** `@N` aliases are cached from the last `ui` snapshot. Any screen change invalidates them.

**Rule:** Always re-run `sim-use ui` after any action that changes the screen (navigation, dismissing a dialog, scrolling). Then use the fresh `@N` values.

## iOS: rotated simulator

**Symptom:** The `App:` header shows an orientation tag like `(landscape-right)` or `(portrait-upside-down)`, or a tap emits an `[i] Screen orientation could not be confirmed…` advisory.

**Why:** iOS accessibility frames rotate with the app while HID taps target the fixed portrait framebuffer. sim-use bridges the two automatically: every AX-derived tap (`@N`, `#<id>`, `--label` family, batch steps) self-calibrates the current orientation with 1–3 hit-test probes and transforms coordinates before dispatch.

**Recipes:**
1. Normally nothing to do — selectors work in any orientation, and outline/tap coordinates always read in UI space (what you see).
2. The calibration-fallback advisory means the mapping could not be verified (empty or symmetric screen) and portrait was assumed; re-run `ui` and retry, or pass `-x/-y` with `--coordinate-space native` (device-native portrait points).
3. A "snapshot was captured at WxH…" advisory means the device rotated after the last `ui`; re-run `ui` to refresh the `@N` table.
4. Explicit `-x/-y`/`--point`, `swipe`/`touch`/`multi-touch` coordinates and the pinch/rotate centre take outline (UI-space) numbers and go through the same calibration. `--coordinate-space native` turns it off: the numbers are then device-native portrait points.
5. `batch` calibrates once per run. If a step rotates the device (or navigates to a screen that forces a different orientation), later selector steps may mis-target — split the flow into separate batches around the rotation.

## iOS: Resize Mode (resizable app session)

**Symptom:** The `ui` header ends in `display Resizable 560x874` (`--json`: a `data.display` object with `kind: virtual` and `resizableSession`), its size is not a real device size, and `screenshot` prints `[i] Captured the 'Resizable' display …`.

**Why:** Xcode 27 can move the frontmost app of an iOS 27+ simulator onto a virtual display named `Resizable` and give it any size (Device Hub's resize button, or `xcrun devicectl device appResize start`). sim-use detects the session and routes touch input, hit-tests, screenshots and video to that display. Issue: https://github.com/lycorp-jp/sim-use/issues/143.

**Recipes:**
1. Work as usual: `ui`, selectors, `@N`, `tap`, `swipe`, `gesture`, `type` and `screenshot` all act on the resized app. The `App:` header is the only place the scene's *actual* size shows — `appResize set` reports the size it asked for, which the scene may snap away from.
2. Explicit `-x/-y` are scene points (the scene is never rotated).
3. `record-video` and `stream-video --format h264|bgra` capture the scene (its size at the display scale, cut from the canvas). The screenshot-based `stream-video` formats (`mjpeg`, `raw`, `ffmpeg`) read the main display only and refuse.
4. The check costs one `devicectl` query per device per 5 s. A `ui` or selector tap whose root changed size re-reads it at once, so a session that just started or ended is noticed by the next `ui`. A raw `-x/-y` tap with no `ui` in between can see the previous answer for up to 5 s. `SIM_USE_RESIZE_SESSION_CHECK=0` disables the check; the per-device daemon reads it at spawn time.

## iOS: iPhone Duo (multi-display simulator)

**Symptom:** The `ui` header names `inner display` (for example `App: Settings  951x669  (landscape-left, inner display)`) or `cover display`. Older builds use `display LCD-1` for the inner screen. `--json` keeps raw names and ids; `data.display` is absent on the main/cover screen.

**Why:** The iPhone Duo simulator (Xcode 27.1) has two integrated displays: the primary cover and the inner panel. sim-use uses inner/cover aliases only for a verified Duo device type and valid two-panel topology; unknown layouts keep system names. The active screen is not a hinge measurement: a half-open device can use the inner screen too. sim-use routes touch input, hit-tests, screenshots and video to the display that hosts the app and takes its orientation from CoreDevice.

**Recipes:**
1. Check the posture: `sim-use ios fold --device <UDID>` names the active display and its orientation.
2. Fold and unfold with `sim-use ios fold closed|open --device <UDID>`; rotate with `sim-use ios rotate <orientation>` (interface names, as the `ui` header prints them). Both clear the `ui` snapshot — re-run `ui` before `tap @N`.
3. An iOS 27.1 SDK app puts its back button, trailing toolbar items, tab bar and status bar in a **vertical bar** on the cover display (and on the inner display in landscape). The outline lists it last, as `[Trailing  x>=N]` — `[Leading  x<=N]` when the cover is in landscape-right; its `@N` aliases tap as usual. The back button there has **no label**: tap it with `#BackButton`, not by the previous screen's title.
4. Explicit `-x/-y` take the numbers `ui` prints on either display; `--coordinate-space native` means the inner panel's unrotated points.
5. `record-video` and `stream-video --format h264|bgra` capture the inner display in its native portrait orientation (2008x2854), like the main display. A fold during a recording keeps the display the recording started on and prints `[i] The app moved to … while \`record-video\` ran` at the end — start a new recording after a fold.
6. In 0.16.0, `screenshot` can return a black or stale inner-display image even when the cover visibly shows normal content. This capture-selection bug is fixed in 0.16.1. Check `sim-use --version` and upgrade an affected CLI before using cover captures as visual evidence.

## System layer detection

**Symptom:** `ui` output shows unexpected content — the `App:` header names a system process like `SpringBoard` (iOS) or `com.android.systemui` (Android).

**Why:** A system alert, permission dialog, or share sheet is covering the app. The accessibility tree reflects whatever is on top.

**Recipe:**
1. Read the outline to identify the overlay (e.g. "Allow Paste", location permission, share sheet).
2. Dismiss it: tap the appropriate button (`Allow`, `Don't Allow`, `Cancel`), or `sim-use button home` to go home.
3. Re-run `ui` to confirm you're back in the app.

## Missing app controls in the outline

**Symptom:** Preflight passes with a content warning. Or `ui` succeeds, but the outline has no elements, or it shows the `[i] … recovered from other processes …` advisory (`--json`: `advisory.kind: remote_content_recovery`).

**Why:** The app exposed an empty accessibility tree. On iOS, sim-use then recovers content from other processes. This can be normal for a system picker; the advisory alone does not mean the app is broken. If nothing can be recovered, the outline stays empty.

**Recipe:**
1. Compare the outline with the visible screen. If it contains the expected controls (for example, the picker's), continue normally.
2. If visible app controls are missing on an iOS simulator, check whether app accessibility was enabled before the app launched. The current preference value alone does not establish the state at launch. See [idb's accessibility guidance](https://github.com/facebook/idb/blob/main/website/docs/idb/accessibility.mdx).
3. If needed, enable app accessibility for that simulator, then relaunch the target app and re-read `ui`:

   ```bash
   xcrun simctl spawn <UDID> defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool true
   ```

4. If controls are still missing, inspect the app with Accessibility Inspector or VoiceOver to check what it exposes.

This setting applies to iOS simulators. Preflight only prints guidance; it does not apply the setting, relaunch the app, or restart the daemon for a content warning.

## iOS: paste drops text

**Symptom:** Paste errors, or a custom control does not show the expected text.

**Why:** The current implementation verifies clipboard staging and invokes native menu Paste, without requiring a connected hardware keyboard. A field must be focused and expose the edit menu; app-specific editing rules, paste prompts and concurrent clipboard writes still apply.

**Recipes:**
1. Focus the field with `tap '#<id>'`, then `paste 'text'`. Use `--replace` to overwrite all content.
2. For explicit targeting, use `paste 'text' --via-menu --target-id <field-id>` or `--target-x/--target-y`. A missing menu is an error, not a reported success.
3. Inspect the UI for paste permission prompts; approve only with user authorization. Check the resulting field, not just the command exit status.
4. A readback mismatch means the clipboard changed or staging failed. Stop other clipboard writers, including on another shared device, before retrying. Do not log unexpected clipboard contents or restore an old backup over newer external content.
5. For controls that do not support native Paste, report the capability limit. Do not substitute US-keyboard `type` for arbitrary Unicode, change keyboard/sync settings, or fall back to overwriting the host clipboard.

Simulator.app and Device Hub use different clipboard stacks. sim-use permits verified legacy staging only while the guest's CoreDevice ownership signal is inactive; otherwise it uses verified CoreDevice. Do not revive the old raw `simctl pbcopy` + Cmd+V workaround.

## iOS: U+FFFC icon placeholder

**Symptom:** An element's label in the outline contains a replacement character (often invisible or rendered as `￼`) before the actual text.

**Why:** iOS uses U+FFFC as an object-replacement character for inline icons. The accessibility label includes it.

**Recipe:** Use `--label-regex` with a pattern that skips the prefix: `--label-regex '.*Settings$'` or `--label-contains 'Settings'`.

## Android: paste denied

**Symptom:** `sim-use paste` succeeds but the field is empty, or the command errors.

**Why:** Android 10+ blocks background processes from setting the clipboard on some devices/configurations.

**Recipe:** Use `sim-use type 'text'` instead. On Android, `type` handles full unicode including CJK and emoji.

## Android: button back unpredictability

**Symptom:** `sim-use button back` navigates somewhere unexpected.

**Why:** Android's back behavior is app-defined. It might close a dialog, pop a nav stack, minimize the app, or do nothing.

**Recipe:** Always `ui` after `button back` to confirm where you ended up. If the result is wrong, use `tap` on a visible "Close" or "Cancel" button instead.

## Tap lands but nothing happens

**Symptom:** `tap` reports success but the UI doesn't change.

**Why:** The element wasn't interactive yet (animation in progress, view still loading), or it's a toggle that needs a brief hold.

**Recipes:**
1. For animation: add `--pre-delay 0.3` to wait before tapping, or `sleep 0.4` between commands.
2. For toggles/switches (shown as `CheckBox` in the outline): add `--duration 0.05`.
3. For elements that appear after navigation: use `--wait-timeout 3` to poll until the element exists.
