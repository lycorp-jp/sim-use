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
2. The calibration-fallback advisory means the mapping could not be verified (empty or symmetric screen) and portrait was assumed; re-run `ui` and retry, or use explicit `-x/-y`/`--point`.
3. A "snapshot was captured at WxH…" advisory means the device rotated after the last `ui`; re-run `ui` to refresh the `@N` table.
4. Explicit `-x/-y`/`--point` (and `--target-x/y`) are never transformed — they are device-native portrait coordinates by contract.
5. `batch` calibrates once per run. If a step rotates the device (or navigates to a screen that forces a different orientation), later selector steps may mis-target — split the flow into separate batches around the rotation.

## iOS: Resize Mode (resizable app session)

**Symptom:** `tap`, `long-press`, `swipe`, `touch`, `gesture`, `multi-touch`, `paste --via-menu`, a `batch` with a touch step, `record-video` or `stream-video` fails with `A resizable app session (Xcode 27 Resize Mode) is active on simulator …` (`--json`: `ok: false` with a `hint`). `ui` prints `[i] A resizable app session … is active` (`--json`: `advisory.kind: resizable_app_session`) and its `App:` header shows a size that is not a real device size (`560x874`, `375x667`, `874x402` on an upright iPhone 17). `screenshot` prints `[i] Captured the 'Resizable' display …`.

**Why:** Xcode 27 can move the frontmost app of an iOS 27+ simulator onto a virtual display named `Resizable` and give it any size (Device Hub's resize button, or `xcrun devicectl device appResize start`). The main display then shows only the wallpaper, with SpringBoard frontmost. Simulator touch input, the main framebuffer and the accessibility point hit-test are all bound to the main display, so a tap would be reported as delivered and reach nothing — which is why sim-use refuses it. Keyboard input is device-wide and does reach the app. Issue: https://github.com/lycorp-jp/sim-use/issues/143.

**Recipes:**
1. Observe freely: `ui` is the app's own tree at the resized size (hit-test recovery and orientation calibration are skipped, so collapsed groups stay collapsed), and `screenshot` is redirected to the `Resizable` display. `record-video` and `stream-video` are refused — they can only capture the main display; record the app with `xcrun simctl io <udid> recordVideo --display=<uuid> <file.mov>` (the error's hint fills in the uuid). The `App:` header is the only place the scene's *actual* size shows — `appResize set` reports the size it asked for, which the scene may snap away from.
2. Drive with the keyboard: `type`, Cmd+V `paste`, `key`, `key-combo`, `key-sequence` and keyboard-only `batch` runs work during a session. `paste --via-menu` is a long-press plus menu taps and is refused like a tap. Focus the field *before* starting the session, since focusing needs a tap.
3. To tap, end the session: stop the `devicectl device appResize start` process (or rotate the device — rotation ends a session), re-run `ui`, then tap. The app returns to the device's native size.
4. Never use `--point`/`-x -y` as a workaround — raw coordinates are refused like selectors, and `ui --point` describes SpringBoard, not the app.
5. The check costs one `devicectl` query per device per 5 s. A session that just *started* is noticed by the next `ui`, selector tap, or touch step of a `batch` (a newly resized root frame bypasses the cache; a `batch` re-checks before every touch step) unless the scene is exactly the device's own size; a session that just *ended*, and standalone raw `-x/-y` taps right after a start, can see the previous answer for up to 5 s. `SIM_USE_RESIZE_SESSION_CHECK=0` disables the check (you are then back to silent no-op taps); the per-device daemon reads it at spawn time, so set it on the first command or pair it with `SIM_USE_NO_DAEMON=1`. This recipe needs sim-use 0.15.0 or newer — the preflight enforces it.

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

**Symptom:** `sim-use paste 'text'` succeeds but the text field stays empty.

**Why:** The default path sends HID Cmd+V, which requires Simulator's hardware keyboard to be connected (Simulator > I/O > Keyboard > Connect Hardware Keyboard). In soft-keyboard-only mode, HID Cmd+V is silently dropped.

**Recipes:**
1. Check keyboard state: `sim-use keyboard-state`. If `soft`, use the menu path.
2. Menu path: `sim-use paste 'text' --via-menu --target-id <field-id>` — long-presses the field and taps the iOS edit menu "Paste" button.
3. If you control the simulator setup, enable hardware keyboard for all subsequent paste calls.

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
