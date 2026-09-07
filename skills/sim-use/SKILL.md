---
name: sim-use
description: Drive iOS Simulator, Android emulator/device, and physical iPhone/iPad screens for AI agents. Use when asked to automate a simulator or emulator, drive a real iOS device, tap/swipe/type on a device, describe UI, take a screenshot, or interact with a mobile app.
---

## 0. Preflight

Before first interaction with a device, run the preflight check:

```bash
python3 scripts/preflight.py --device <UDID>
```

This verifies sim-use is installed and compatible with the skill, the device is reachable, and the daemon is healthy. If you don't have the script, do the checks manually:

1. `sim-use --version` — confirm sim-use is on PATH and supports the skill's documented commands.
2. `sim-use devices` — confirm the target device is listed and booted/connected.
3. `sim-use ui --device <UDID>` — confirm you can read the screen.

`--device` is optional when only one simulator is booted or one daemon is running. For Android, run `sim-use android init --device <serial>` once to install the bridge APK. Attached physical iPhones/iPads appear in `sim-use devices` with kind `physical` and route through the top-level verbs too — but only `ui`, selector-based `tap` and `screenshot`; every other verb rejects on that target. See *Physical iOS devices* below before driving one.

## 1. The observe-act loop

Every interaction follows the same cycle: **observe → act → verify**.

### Observe

```bash
sim-use ui --device <UDID>
```

Read the outline. Each element has an `@N` alias and optionally a `#<id>` identifier. List cells carry `#N` (dominant list) or `#N@M` (scoped).

Frames in the JSON output (`--json`: `entries[].frame`, `screen`) are in platform-native units — iOS **points**, Android **pixels**. Key off the envelope's `platform` field before doing math on coordinates across platforms. Always pair `--json` with `--no-raw` — see *Keeping output small* below.

### Act

Pick a selector, in order of preference:

| Selector | When to use |
|---|---|
| `tap @N` | Right after `ui`. Fastest, cache-backed. |
| `tap #<id>` | Stable across minor layout changes. Paste from the outline. |
| `tap --label 'X'` | Scripted flows. Combine with `--wait-timeout` for transitions. |
| `tap --label-regex '...'` | Dynamic labels with counters/timestamps. Anchor with `^...$`. |
| `tap --label-contains 'X'` | Substring match when exact label is unknown. |
| `tap -x N -y N` / `tap --point x,y` | Last resort for elements with no AX data. |

Disambiguate collisions with `--element-type` or `--frame minY=0.7r` (see `references/cheatsheet.md`).

### Verify

Always verify after acting — commands are fire-and-forget:

```bash
sim-use ui --device <UDID>       # read the new screen state
sim-use screenshot --device <UDID> --output after.png
```

### Keeping output small

Every byte of command output you read costs context. Defaults that keep the loop cheap:

- Prefer the default text outline over `--json`. The outline carries everything a tap needs (`@N` / `#<id>` aliases, roles, frames, states); reach for `--json` when you need structured fields for coordinate math (`entries[].frame`, `screen`) or full untruncated text (the outline truncates labels at 60 graphemes, `value=` at 30).
- When you do use `--json`, add `--no-raw`. `data.raw` is the raw accessibility tree — typically the bulk of the envelope's bytes, and useful only for debugging sim-use itself.
- One `ui` per action: the Verify read of step N is the Observe read of step N+1. Don't run a second `ui` in between.
- Verify with the text outline, not a screenshot. Reading a screenshot costs several times more than a typical outline; take one only when the check is genuinely visual (colors, images, layout).
- On iOS, to wait out a transition, prefer `tap --label 'X' --wait-timeout 3` (polls for the element) over re-running `ui` in a loop. Android `tap` has no `--wait-timeout`; use `sleep` between commands instead.
- For a known multi-step sequence on iOS, use `sim-use ios batch` (see `references/batch-reference.md`) — one invocation, one output.

### Common moves

| Task | Command |
|---|---|
| Scroll down | `sim-use gesture scroll-up --device <UDID>` (scroll-up = content moves up = page down) |
| Type text | `sim-use type 'hello' --device <UDID>` |
| Paste unicode | `sim-use paste 'こんにちは 🎉' --device <UDID>` (iOS: needs hardware keyboard) |
| Hardware button | `sim-use button home --device <UDID>` |
| Android back | `sim-use button back --device <UDID>` |
| Wait for animation | `sleep 0.4` between commands, or `--pre-delay 0.5` |
| Toggle/switch | `sim-use tap @N --duration 0.05 --device <UDID>` (UISwitch needs a brief hold) |
| Swipe | `sim-use swipe --from 50,500 --to 350,500 --device <UDID>` |
| Pinch zoom in | `sim-use gesture pinch-out --device <UDID>` (two-finger spread) |
| Rotate | `sim-use gesture rotate-cw --angle 90 --device <UDID>` |
| Record evidence GIF | `sim-use record-video --output demo.gif --device <UDID>` — stop with SIGINT/SIGTERM (never SIGKILL); transcodes after stop; auto-plays inline in PRs; add `--gif-markers` for START/END loop-boundary cards |

### Physical iOS devices (experimental)

The top-level verbs route a physical UDID automatically, but only three of them: `ui`, `tap` (`#<id>` / `--id` / `--label` / `--label-contains` / `--element-type` forms) and `screenshot`. **Never assume capability parity with the simulator** — every other verb or form (coordinates, `@N`/`#N` aliases, swipe/gesture/multi-touch, type/paste, recording, `--value`/`--label-regex`/`--frame`/`--duration`/`--wait-timeout`) rejects with the reason and the nearest alternative in the `hint`; read it instead of retrying. The `sim-use ios-device` namespace is the physical-only peer of `ios`/`android` (same verbs, plus ECID addressing and tree-tuning flags).

**Hard requirement for `ui` / `tap`:** the device must be paired, trusted, unlocked and in Developer Mode, and the foreground target app must be development-signed with `get-task-allow=true`. A Release-configuration binary installed with a Development profile is supported. Distribution/Ad Hoc, TestFlight, App Store and system apps are unsupported; do not retry them or claim success. sim-use itself installs and signs no runner and needs no Developer Disk Image. `screenshot` is exempt from the signing rule — it runs over CoreDevice and captures any screen, system apps included.

```bash
# Physical-device preflight — physical rows carry kind `physical`
sim-use devices

# Observe → act → verify, same loop and verbs as the simulator
sim-use ui --device <UDID>
sim-use tap --label "Friends" --element-type Button --device <UDID>
sim-use ui --device <UDID>

# For dynamic labels
sim-use tap --label-contains "Reply" --element-type Button --device <UDID>

# By stable identifier (the #id shown in ui) — positional or --id
sim-use tap '#BackButton' --device <UDID>

# Screenshot — any screen, not limited to development-signed apps
sim-use screenshot --output shot.png --device <UDID>
```

Rules for this experimental surface:

1. **Treat hierarchy errors as capability failures.** If the command says the hierarchy is unavailable, confirm the screen is unlocked and inspect the installed app's final `get-task-allow` entitlement. Do not fall back to coordinates or focus walking.
2. **Tap by `#id` or label, not `@N`.** Element handles expire with the DTX connection, so there is no `@N` alias (nor coordinates — no geometry). Use the `#id` shown in the outline (positional `#<id>` or `--id`) — it is stable and the best choice when a label is dynamic — or `--label` / `--label-contains`, with `--element-type` to disambiguate. The navigation-bar back button appears as a normal `Button "<previous screen title>" #BackButton`; go back by tapping `#BackButton` (or the shown label) like any other element — no special "back" verb.
3. **Always verify.** Activate is fire-and-forget. Re-run `sim-use ui` and confirm the expected state before continuing.
4. **Respect the capability rejections.** A `not supported on physical iOS devices` error is a statement about the channel, not a transient failure — follow its hint (usually `ui` + `tap '#<id>' / --label`) instead of retrying or substituting a lookalike form. `--json` works on every verb with the standard `{ok, data}` envelope; physical results carry `"kind":"physical"` and omit geometry fields (`screen`, `x`/`y`).
5. **Budget seconds, not milliseconds.** A full tree takes a few seconds. `sim-use ios-device ui --fast` is quicker but omits nested elements; do not poll in a tight loop.

If `ui` succeeds with zero elements or `tap` prints success for a missing/ambiguous label, treat it as a sim-use bug; the command is expected to fail loudly instead.

## 2. Pitfalls

Quick symptom index — see `references/pitfalls.md` for detailed recipes.

| Symptom | Cause | Fix |
|---|---|---|
| `tap --label` hits wrong element | Label collision (e.g. header and tab bar share text) | Add `--frame minY=0.7r` or `--element-type` to narrow |
| `tap @N` fails after navigation | Alias cache is stale | Re-run `ui` before tapping |
| `App:` line shows wrong app | System layer (alert, share sheet) is on top | Dismiss it first, then re-run `ui` |
| `multipleMatches` error | Several elements share the selector | Use `--frame`, `--element-type`, or a more specific selector |
| Tap lands but nothing happens | Animation in progress, or element not yet interactive | Add `--pre-delay 0.3` or `--wait-timeout 3` |
| iOS: `paste` drops text | Soft keyboard only; HID Cmd+V is ignored | Use `paste --via-menu --target-id <id>` |
| Android: `paste` denied | Background clipboard access blocked | Use `type` instead |
| Outline shows `U+FFFC` in label | iOS icon placeholder character | Match with `--label-regex` excluding the prefix |
| `[i] … covers ~N% of the screen` warning (text output, or `--json` top-level `advisory` key) | The selector resolved to a near-full-screen wrapper (common on Flutter/canvas UIs) and the tap hit its center, likely missing the intended control | Re-run `ui` and target the control via `@N`/`#<id>`, or pass explicit `-x/-y`/`--point` |
| `[i] Screen orientation could not be confirmed…` / `…coordinates may be stale…` advisory | Device/app is rotated (the `App:` header shows a tag like `(landscape-right)`) and orientation self-calibration couldn't verify the mapping, or the `@N` snapshot predates a rotation | Re-run `ui` and tap again; selectors handle rotation automatically once calibration succeeds. Explicit `-x/-y`/`--point` is device-native portrait space by default — on `swipe`/`touch`, pass `--coordinate-space ui` to use outline (visual-space) coordinates on a rotated device |

## 3. Crash awareness

See `references/crash-awareness.md` for the full protocol. Summary:

sim-use watches for the target process disappearing between commands. When it detects a crash:

```
================ PROCESS DISAPPEARED ================
com.example.app (pid 12345) was alive at the previous command and is GONE now.
```

On Android, `ui` also detects the AOSP system crash dialog directly from the accessibility tree.

**Mandatory response:**
1. **STOP.** Do not silently relaunch or continue.
2. Report the crash to the user with the banner text.
3. Wait for instructions before proceeding.

After an intentional relaunch, call `sim-use app-state --reset` to clear the signal.

## 4. Escalation

Stop and ask the user when:
- A selector collision cannot be resolved with available disambiguators.
- Preflight fails and autofix does not recover.
- The task requires a destructive action (deleting data, uninstalling an app).
- You've retried the same action 3 times without progress.

## 5. Exit checklist

Before reporting a task as complete:
1. Run `sim-use ui` (or `screenshot`) to capture the final state.
2. Confirm the screen matches the intended outcome.
3. If the outcome is ambiguous, show the final `ui` output or screenshot to the user.
