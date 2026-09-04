# sim-use

[English](README.md) | [한국어](README.ko.md)

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Tests](https://github.com/lycorp-jp/sim-use/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/lycorp-jp/sim-use/actions/workflows/tests.yml)

Give AI agents the ability to observe and act on iOS Simulator and Android emulator / device screens.

**Observe** — turn any screen into a token-efficient outline an LLM can reason about:

```text
$ sim-use ui
App: Settings  402x874

[Top  y<120]
  @1  StaticText  "Settings"
[Content  y=120..754]
  @5  SearchField  "Search"
  @7  Button  "Sign in to your iPhone"
  @9  Button  "General"
  @10 Button  "Display & Brightness"
  @11 Button  "Wallpaper"
  ...
[Bottom  y>754]
  @43 TabBar
```

**Act** — tap any element by its alias, no coordinates needed:

```text
$ sim-use tap @9
✓ Tap at (201.0, 452.0) completed successfully
```

Plan, code, **verify**, ship — teach this CLI to your agent and close the last gap in the agentic mobile development loop. Let agents verify what they built so you can focus on what matters.

`sim-use` is a cross-platform CLI that drives Apple's Accessibility APIs, the iOS Simulator HID pipeline, and Android's AccessibilityService through a single command surface. It emits a compact, agent-friendly screen description (`ui`) and an alias-cached tap shortcut (`tap @N`) so an LLM loop can observe → act in a few hundred milliseconds per round trip.


- [The observe → act loop](#the-observe--act-loop)
- [Why sim-use](#why-sim-use)
- [Install](#install)
- [Platforms](#platforms)
- [Commands](#commands)
- [Physical iOS devices](#physical-ios-devices)
- [Architecture](#architecture)
- [Viewer](#viewer)
- [Contributing](#contributing)
- [Licence](#licence)


## The observe → act loop

Every interaction follows the same cycle — observe, act, verify:

```bash
sim-use ui                  # 1. read the screen
sim-use tap @9              # 2. act on what you see
sim-use ui                  # 3. verify the result
```

Multiple selector styles for different needs:

| Selector | Example | Best for |
|---|---|---|
| `@N` alias | `tap @9` | Speed — cached from last `ui` |
| `#<id>` | `tap #settingsButton` | Stability — survives layout changes |
| `--label` | `tap --label "General"` | Scripted flows with `--wait-timeout` |
| `-x -y` / `--point` | `tap --point 100,200` | Last resort — no AX data |

AX-derived selectors work in any orientation — sim-use self-calibrates the
current rotation on each command (iOS). Explicit `-x/-y`/`--point` is
interpreted in the device-native portrait space.


## Why sim-use

- **Token-efficient.** The outline representation is ~16x more compact than a raw JSON accessibility tree. An LLM can read and reason about an entire screen in a few hundred tokens.
- **Nothing hidden.** sim-use walks the full accessibility tree including WebViews, system overlays, and embedded content — no elements are silently skipped. When the frontmost app exposes an empty tree because a remote process owns the visible UI (a system document picker, for example), `ui` automatically retries with cross-process discovery and flags the recovered, flat hierarchy via the `advisory` envelope key.
- **AI-native.** Designed from day one for agent loops, not human testers. Alias-cached taps (`@N`), structured `--json` envelopes with actionable `hint` fields on errors, and a bundled agent skill (`sim-use init --client claude`) that teaches your AI client the full command surface.
- **Fast.** A per-device background daemon amortises init cost across calls. After the first command, each observe-act round trip completes in ~300 ms.
- **Cross-platform.** One command surface drives both iOS Simulator and Android emulator/device. Same verbs, same flags, same `--json` shape — write one agent loop that works on both.


## Install

### Homebrew (recommended)

```bash
brew tap lycorp-jp/tap
brew install lycorp-jp/tap/sim-use
```

On Homebrew 6.0.5+, if you see an "untrusted tap" error, run `brew trust lycorp-jp/tap` first.

### Build from source

sim-use is a Swift package targeting **macOS 14+**, built with the latest Xcode toolchain. It links against static XCFrameworks built from [Meta's idb](https://github.com/facebook/idb), which are produced locally by the build script (they are large and not checked into the repository). The idb checkout generates its Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/lycorp-jp/sim-use.git
cd sim-use

# Build the required XCFrameworks (first time only)
./scripts/build.sh dev

# Build sim-use itself
make build
.build/debug/sim-use --help

# Other Makefile targets
make test    # run tests
make clean
```

The XCFrameworks are built without library evolution, so their Swift
modules are locked to the toolchain that produced them — re-run
`./scripts/build.sh dev` after switching Xcode versions.

### Xcode 27 (beta)

Xcode 27 betas are fully supported from Beta 4 on (earlier betas ship no
usable `SimulatorKit.framework`), including simulators booted while
Device Hub is open — the HID transport is selected automatically per
boot. Note that Xcode 27 no longer bundles Simulator.app; the one from an
Xcode 26.x install still works, as does Device Hub itself.

### Agent skill

To install the bundled agent skill into your AI client's skill directory:

```bash
sim-use init                        # auto-detect installed clients
sim-use init --client claude        # non-interactive
sim-use init --dest ~/.claude/skills
sim-use init --print                # print skill content without installing
sim-use init --uninstall --client claude
```


## Platforms

sim-use drives both **iOS Simulators** and **Android devices / emulators** through the same command surface. The device ID shape decides which backend handles the call:

  * `1A2B3C4D-...` (UUID) → iOS Simulator
  * `emulator-5554` / `R5CT1ABCD12` / `192.168.1.5:5555` → Android device
  * `00008130-...` (8-16 hex) / 40-hex → physical iPhone/iPad (restricted verb set)

For Android, run `sim-use android init --device <serial>` once to install the bridge APK. See `AGENTS.md` for Android toolchain setup.

**Physical iPhones and iPads** (experimental) route through the same top-level verbs — `sim-use ui`, `sim-use tap '#<id>' / --label` and `sim-use screenshot` work against a plugged-in device's UDID. The channel exposes no element geometry, so it trades coordinate taps, swipes and gestures for accessibility actions, and the remaining verbs reject with the reason and the nearest alternative — never assume capability parity; see the [capability matrix](#physical-ios-devices). sim-use installs and signs no runner and needs no Developer Disk Image; `ui`/`tap` need the foreground app to be development-signed (`get-task-allow=true`), `screenshot` captures any screen.


## Commands

All device-scoped commands accept `--device <ID>` (optional when only one simulator is booted). Three command layers:

  * **Top-level** — cross-platform verbs: `ui`, `tap`, `long-press`, `swipe`, `touch`, `multi-touch`, `type`, `paste`, `button`, `gesture`, `keyboard-state`, `screenshot`, `record-video`, `stream-video`, `app-state`. Same flags on iOS and Android; physical iOS devices route through `ui`, `tap` and `screenshot` only (the rest reject with the reason — see the [capability matrix](#physical-ios-devices)).
  * **`sim-use ios <verb>`** — iOS-Simulator-only: `key`, `key-combo`, `key-sequence`, `batch`.
  * **`sim-use android <verb>`** — Android-only: `init`, `devices`, `ping`, `scroll`.
  * **`sim-use ios-device <verb>`** — physical-iOS-only: `devices`, `ui`, `screenshot`, `tap` (experimental). Peer of `ios`/`android`; also accepts ECIDs and the hierarchy tuning flags the top level doesn't carry.

Run `sim-use --help` or `sim-use <command> --help` for the full flag set.

```bash
sim-use devices
# PLATFORM  KIND       STATE   NAME               UDID                                  RUNTIME
# ios       simulator  Booted  iPhone 17 Pro Max  B34FF305-5EA8-412B-943F-1D0371CA17FF  iOS 27.0
# ios       physical   Booted  My iPhone          00008130-00066D2A10EB8D3A             iOS 26.6
# android   emulator   device  Medium_Phone       emulator-5554                         Android
UDID="B34FF305-5EA8-412B-943F-1D0371CA17FF"
```

One listing covers every target: iOS Simulators (`simctl`), Android devices and emulators (`adb`), and USB-attached physical iPhones/iPads (`FBDeviceControl`). `KIND` — `simulator` / `emulator` / `physical` — is orthogonal to `PLATFORM` and also appears as `kind` in `--json`; capabilities follow the kind (see [Physical iOS devices](#physical-ios-devices) for what physical iOS supports). `--no-physical-ios` skips the FBDeviceControl side entirely (~1 s saved when no device is attached) — the Viewer passes it, since it drives coordinate taps and video streaming, neither of which physical iOS supports.

### Touch & gestures

```bash
sim-use tap @5 --device $UDID                                 # alias from the last `ui`
sim-use tap "#3" --device $UDID                               # 3rd cell of the dominant list ("#2@2": 2nd cell, 2nd list)
sim-use tap "#settingsButton" --device $UDID                  # AXUniqueId
sim-use tap --label "Safari" --device $UDID                   # also: --id, --value
sim-use tap -x 100 -y 200 --device $UDID                      # raw point (or --point 100,200)

sim-use swipe --from 100,300 --to 300,100 --device $UDID      # positional "100,300 300,100" works too
sim-use swipe --from 50,500 --to 350,500 --duration 2.0 --delta 25 --device $UDID

# Low-level touch control
sim-use touch -x 150 -y 250 --down --device $UDID             # then: touch ... --up
sim-use touch -x 150 -y 250 --down --up --delay 1.0 --device $UDID   # long press

# Gesture presets
sim-use gesture scroll-up --device $UDID
sim-use gesture swipe-from-left-edge --device $UDID
sim-use gesture scroll-down --pre-delay 0.5 --post-delay 1.0 --device $UDID
```

`--pre-delay` / `--post-delay` / `--duration` work on `tap`, `swipe`, and `gesture` alike for coarse timing control.

Single-finger presets (`scroll-*`, `swipe-from-*-edge`) name **visual** directions and are orientation-aware on iOS: their canvas size and rotation are auto-detected per command, so `scroll-up` scrolls the on-screen content up whether the device is portrait, landscape, or upside-down. Explicit `swipe`/`touch` coordinates remain device-native portrait space by default; pass `--coordinate-space ui` to give them in the visual space `ui` prints instead (orientation-calibrated per command; `touch` supports this in the atomic `--down --up` form only). Pinch/rotate presets remain untransformed. On Android the flag is accepted and ignored — display coordinates already rotate with the UI.

### Text input

```bash
sim-use type 'Hello World!' --device $UDID
echo "complex text" | sim-use type --stdin --device $UDID
sim-use type --file input.txt --device $UDID
```

### Paste (IME-safe Unicode)

`sim-use paste` writes text to the simulator pasteboard (`simctl pbcopy`) and issues Cmd+V, so characters reach the focused field without going through the keyboard. This bypasses host IME composition (e.g. Japanese kana remapping ASCII keys) and accepts arbitrary Unicode the HID keycode table cannot express (CJK, emoji, diacritics).

```bash
sim-use paste 'ABC 日本語 🎉' --device $UDID             # at caret
sim-use paste 'new content' --replace --device $UDID   # Cmd+A + paste

printf '%s' "$CONTENT" | sim-use paste --stdin --device $UDID
sim-use paste --file body.txt --device $UDID
```

The default Cmd+V path needs a connected hardware keyboard on the simulator (Simulator.app: I/O > Keyboard > Connect Hardware Keyboard = ON). Under soft-keyboard-only mode HID Cmd+V is dropped — switch to `--via-menu`, which long-presses the target and taps the iOS edit-menu "Paste" button:

```bash
sim-use paste 'ABC 日本語' --via-menu --target-id chatTextField --device $UDID
sim-use paste 'at xy' --replace --via-menu --target-x 171 --target-y 513 --device $UDID
```

iOS 16+ gates the first paste per app session behind an "Allow Paste" prompt (modal dialog on iOS 16, inline bubble on iOS 17+). sim-use does not auto-dismiss it — approve once interactively (iOS grants a ~60 s grace window for the session) or pre-configure Settings → Paste from Other Apps per app.

### Keyboard state

Probe whether the software keyboard is visible. Primary use: pick between the `paste` Cmd+V default and `--via-menu` path.

```bash
# Prints `soft` or `hidden` (both exit 0; non-zero = probe failure). Branch on stdout:
if [[ "$(sim-use keyboard-state --device $UDID)" == soft ]]; then
  sim-use paste "$TEXT" --via-menu --target-id chatTextField --device $UDID
else
  sim-use paste "$TEXT" --device $UDID
fi

sim-use keyboard-state --json --device $UDID   # -> {"ok":true,"data":{"visible":true, ...}}
```

### Hardware buttons

```bash
sim-use button home --device $UDID
sim-use button lock --duration 2.0 --device $UDID     # long press
sim-use button siri --device $UDID
# Also: side-button, apple-pay
```

### Low-level keyboard (iOS-only)

These verbs speak USB HID keycodes, which have no Android counterpart —
for Android text entry use `sim-use type` or `sim-use paste`.

```bash
# Individual key presses by HID keycode
sim-use ios key 40 --device $UDID                                     # Enter
sim-use ios key 42 --duration 1.0 --device $UDID                      # hold Backspace

# Sequences and modifier combos
sim-use ios key-sequence --keycodes 11,8,15,15,18 --device $UDID      # "hello"
sim-use ios key-combo --modifiers 227 --key 4 --device $UDID          # Cmd+A
sim-use ios key-combo --modifiers 227,225 --key 4 --device $UDID      # Cmd+Shift+A
```

### Batch chaining (iOS-only)

Run multiple steps in a single invocation. Batch reuses one HID session and one AX snapshot across steps, cutting round-trip cost on multi-step flows (Android steps each round-trip through the bridge already, so batching would save nothing there).

```bash
sim-use ios batch --device $UDID \
  --step "tap --id SearchField" \
  --step "type 'hello world'" \
  --step "key 40"

# With element waiting — selector taps poll until the element appears
sim-use ios batch --device $UDID \
  --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id WelcomeMessage"

# From file (one step per line)
sim-use ios batch --device $UDID --file steps.txt
```

Key semantics:

- Exactly one step source per run: `--step`, `--file`, or `--stdin`.
- Fail-fast by default; `--continue-on-error` switches to best-effort.
- `--wait-timeout <seconds>` makes selector taps poll for the element to appear — primary mechanism for multi-screen flows.
- `--ax-cache perBatch` (default) reuses one AX snapshot for the whole run; `--ax-cache perStep` refreshes between steps when the UI changes; `--ax-cache none` disables snapshot reuse entirely. `--wait-timeout` polling always refetches.

### Screenshot

```bash
sim-use screenshot --device $UDID                                 # auto-named
sim-use screenshot --output ~/Desktop/shot.png --device $UDID     # specific file
sim-use screenshot --output ~/Desktop/ --device $UDID             # directory
```

The output path goes to stdout; progress messages go to stderr.

### Video streaming & recording

```bash
# MJPEG stream (cross-platform)
sim-use stream-video --device $UDID --fps 10 --format mjpeg > stream.mjpeg

# Pipe into ffmpeg
sim-use stream-video --device $UDID --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast out.mp4

# Native H.264 live stream (Android-only): adb screenrecord passthrough —
# variable frame rate, cheap, high quality. Preview it live in ffplay:
sim-use stream-video --device emulator-5554 --format h264 | \
  ffplay -f h264 -probesize 32 -fflags nobuffer -

# Record MP4 directly (cross-platform)
sim-use record-video --device $UDID --output recording.mp4            # 30 fps default
sim-use record-video --device $UDID --fps 60 --output smooth.mp4      # up to 60 fps
sim-use record-video --device $UDID --quality 60 --scale 0.5 --output low-bw.mp4

# Record an animated GIF (cross-platform) — auto-plays inline in PRs / issues / chat
sim-use record-video --device $UDID --output demo.gif                 # format inferred from extension
sim-use record-video --device $UDID --format gif                      # sim-use-video-<timestamp>.gif
sim-use record-video --device $UDID --format gif --fps 15 --scale 0.4 --output demo.gif
```

`record-video` captures a real H.264 stream and muxes it straight into the
MP4 (passthrough — no per-frame screenshot re-encoding). iOS records at a
constant `--fps` (default 30, max 60); Android records at the device's
native variable frame rate (`--fps` ignored, `--quality` → bitrate,
`--scale` → size) and stitches across the `screenrecord` per-invocation
limit on API < 34 automatically. Rotating the display mid-recording stops
capture on Android (an MP4 track can't change frame size). Press Ctrl+C to
stop; sim-use finalises the MP4 before exiting.

`--format gif` (or a `.gif` `--output` extension) records the same H.264
stream to an intermediate MP4, then transcodes it into a looping GIF once
recording stops — sampling at `--fps` (GIF default 10, capped at 50 by the
format's centisecond delay floor) and scaling at `--scale` (GIF default
0.5), since full-rate full-scale GIFs get enormous. Per-frame delays
follow the source timestamps, so Android's variable frame rate stays true
to wall-clock. If the transcode fails, the intermediate MP4 is preserved
and its path reported, so the footage is never lost. GIF is meant for
short clips: the encoder holds every frame in memory until the file is
written, so for sessions beyond a few hundred frames prefer a lower
`--fps` or `--format mp4`. Because the GIF loops forever, `--gif-markers`
can bracket the clip with START/END marker cards (~1 s each) so the
boundary is visible.

### Accessibility inspection

```bash
sim-use ui --device $UDID                      # compact outline (default)
sim-use ui --json --device $UDID               # structured envelope
sim-use ui --json --no-raw --device $UDID      # envelope without the raw tree (much smaller)
sim-use ui --point 100,200 --device $UDID      # specific point (same UI space as outline frames)
```

The `--json` envelope carries the raw accessibility tree under `data.raw` by default; `--no-raw` drops it while keeping `outline` / `entries` / `lists` intact — prefer it in agent loops where the raw tree is only debugging ballast.

The outline uses region banding (`[Top]` / `[Content]` / `[Bottom]` / declared `Group` regions) and `@N` / `#N` / `#N@M` / `#<id>` alias addressing. When the device is rotated, the `App:` header carries an orientation tag (e.g. `(landscape-right)`) and the `--json` envelope an `orientation` field.

A list cluster detector runs on every snapshot and attaches `#N` aliases to detected list cells — outline lines render as `@N #M` (dominant list) or `@N #M@S` (scope `S>1`). The `--json` envelope adds a `lists` array (one summary per cluster, ordered by detector score, dominant first) and per-cell membership under `entries[*].aliases.list`.

### App state & crash detection

```bash
sim-use app-state --device $UDID                              # list running apps
sim-use app-state --bundle-id com.example.app --device $UDID  # running | not_running
sim-use app-state --reset --device $UDID                      # re-baseline crash detection
```

While the daemon drives a device, it watches for the target process disappearing between commands and surfaces a banner on the next `ui` call. The signal is process liveness (not foreground identity), so backgrounding for a permission dialog or share sheet never false-fires. On Android, `ui` also detects the AOSP system crash dialog directly from the accessibility tree. Call `app-state --reset` after an intentional relaunch; `SIM_USE_NO_CRASH_DETECT=1` disables detection entirely.

### Daemon

UDID-scoped commands auto-spawn a per-UDID background daemon on first use and reuse it on subsequent calls, amortising FBSimulatorControl / accessibility init (~200 ms per `ui`-shaped call). Scripts do not need to manage the daemon.

```bash
sim-use daemon status
sim-use daemon stop --device $UDID
sim-use daemon stop --all

# Force in-process execution for a single call (diagnostics)
SIM_USE_NO_DAEMON=1 sim-use ui --device $UDID
```

Daemons self-exit after 600 s of idle and log to `/tmp/sim-use-<uid>/<UDID>.log`. Streaming commands (`screenshot`, `record-video`, `stream-video`) always run in-process regardless.


## Physical iOS devices

> **Experimental:** this surface intentionally supports development-signed target apps only. Its commands and compatibility may change while the device matrix grows.

A connected iPhone or iPad is driven through its accessibility audit daemon over usbmux lockdown. sim-use installs no XCUITest runner, performs no signing and needs no Developer Disk Image. The foreground target app must already be signed with a Development provisioning profile whose final code-sign entitlements contain `get-task-allow=true`, and the device must be paired, trusted, unlocked and in Developer Mode. A Release-configuration build remains supported when installed with a Development profile.

Distribution/Ad Hoc, TestFlight, App Store and system apps do not expose the hierarchy or actions required by this channel. `ui` and `tap` fail with an entitlement-oriented diagnostic instead of reporting an empty tree or a successful action.

Verify the app before installing it when in doubt:

```bash
codesign -d --entitlements :- /path/to/MyApp.app
# ... <key>get-task-allow</key><true/> ...
```

The top-level verbs route a physical UDID automatically — the same observe → act → verify loop as every other target:

```bash
sim-use devices                      # physical devices appear with kind `physical`
# ios  physical  Booted  My iPhone  00008140-000210603A40801C  iOS 27.0
UDID="00008140-000210603A40801C"

sim-use ui --device $UDID
# Button  "Chats Button, Selected"
# Button  "Friends"
# Button  "Settings"  #settingsButton
# ...
# 117 elements (316 nodes) in 6647 ms

sim-use tap --label "Friends" --element-type Button --device $UDID
# Sent Activate to 'Friends' [Button]

# Dynamic labels can use the regular substring selector vocabulary.
sim-use tap --label-contains "Reply" --element-type Button --device $UDID

# Or target the stable accessibility identifier shown as #id.
sim-use tap '#BackButton' --device $UDID

# Screenshot — any screen, not limited to development-signed apps. Prints the
# absolute saved path on stdout (plus a confirmation on stderr).
sim-use screenshot --device $UDID
# /Users/me/Device Screenshot - My iPhone - 2026-08-27 at 09.34.10.png

# --json everywhere, shared {ok, data} envelope.
sim-use tap '#BackButton' --json --device $UDID
# {"ok":true,"data":{"action":"Activate","identifier":"BackButton","kind":"physical","label":"sim-use Playground","role":"Button"}}
```

The `sim-use ios-device` namespace remains as the physical-only peer of `ios`/`android` — same three verbs plus `devices`, and additionally accepts ECIDs (shape-based routing can't recognise a bare ECID) and hierarchy tuning flags (`--fast`, `--concurrency`, `--connections`).

A device is addressed by UDID or ECID, and `--device` is optional only when exactly one is attached (top-level auto-resolution still picks booted simulators only). A freshly attached device may be listed by ECID until a session has opened (AMDevice publishes the lockdown UDID lazily). Run `ui` again after every action: accessibility actions are fire-and-forget, so the follow-up read is the authoritative verification.

### Capability matrix

**Never assume capability parity with the simulator.** Only three verbs route; everything else fails with the reason and the nearest alternative (as a `hint` in `--json`):

| Verb | Simulator | Android | Physical iOS |
|---|---|---|---|
| `ui` / `describe-ui` | ✅ | ✅ | ✅ outline + `#id`s only — no `@N` aliases, frames, or `--point` |
| `tap` | ✅ | ✅ | ✅ `#<id>` / `--id` / `--label` / `--label-contains` / `--element-type` only |
| `screenshot` | ✅ | ✅ | ✅ any screen (CoreDevice) |
| `swipe`, `gesture`, `touch`, `multi-touch`, `long-press` | ✅ | ✅ | ❌ no coordinate input or geometry |
| `tap -x/-y/--point`, `@N` / `#N` aliases, `--value`, `--label-regex`, `--frame`, `--duration`, `--wait-timeout` | ✅ | ✅ | ❌ rejected per form |
| `type`, `paste` | ✅ | ✅ | ❌ no text-input channel yet |
| `button`, `keyboard-state` | ✅ | ✅ | ❌ |
| `record-video`, `stream-video` | ✅ | ✅ | ❌ use `screenshot` |
| `ios key` / `key-combo` / `key-sequence` / `batch` | ✅ | ❌ | ❌ |
| `app-state` | ✅ | ✅ | ❌ |

Pass a physical UDID to a `sim-use ios <verb>` (simulator-only by contract) and it fails fast with a pointer back to the routed verbs.

This channel deliberately differs from the simulator backend:

  * **No element geometry.** There is no coordinate tap, `swipe`, `gesture` or `multi-touch`. Only the exposed `tap` accessibility action is currently supported; the other verbs reject a physical UDID with the reason and the nearest alternative rather than degrading silently.
  * **No `@N` aliases, but stable `#id`s.** Element handles encode a live pointer and expire with their DTX connection, so — like the missing geometry — the cross-invocation `@N` alias cannot be backed faithfully and the outline advertises none. The stable accessibility identifier *can*: the outline shows each element's `#id`, and `tap` accepts it as a positional `#<id>` or `--id` (mirroring the simulator), alongside `--label` / `--label-contains` / `--element-type`. Prefer the `#id` when a label is dynamic — a navigation-bar back button is labelled with the previous screen's title but keeps `#BackButton`, and is an ordinary, tappable row in the outline.
  * **Screenshots go over CoreDevice, not the audit daemon.** `screenshot` shells out to `xcrun devicectl device capture screenshot`, a separate channel with different rules: it is not limited to development-signed foreground apps and captures whatever is on screen, SpringBoard and system apps included. Screen *recording* exists on the same channel (`devicectl device capture screen-record`) but is capability-gated per device (CoreDevice can report "Screen Recording is not supported by this device") and is not exposed yet.
  * **No recording yet.** Screen recording is not exposed (see the CoreDevice capability gate above). `--json` *is* supported on every `ios-device` verb, with the same `{ok, data}` envelope as the rest of the CLI: `devices` returns unified device rows (the `deviceId` / `kind` / `runtime` schema of top-level `sim-use devices --json`), `ui` returns the outline text plus structured rows (`depth` / `role` / `label` / `#identifier`) with element/node counts and timing, `tap` returns the matched element, and `screenshot` returns the saved path. Errors carry a machine-readable `hint` alongside the message.
  * **Slower snapshots.** A full tree costs a few seconds. `ui --fast` stops at labelled elements and is roughly 40% quicker, at the cost of about a quarter of the elements.
  * **Reading order, not screen order.** With no frames to sort by, the outline follows accessibility nesting and reading order.


## Architecture

sim-use drives iOS Simulators through the lower-level XCFrameworks of Facebook's [idb](https://github.com/facebook/idb) (statically linked), Apple's Accessibility APIs, and the simulator HID pipeline. Android devices are driven through an on-device bridge APK that exposes the AccessibilityService tree and input injection over HTTP, tunnelled via `adb forward`. Physical iOS devices go through a third path: idb's `FBDeviceControl` opens a lockdown service connection, over which sim-use speaks Apple's DTX message protocol to the accessibility audit daemon (screen capture instead shells out to Xcode's `devicectl`). Everything ships as a single binary, and every surface — simulator, Android and physical iOS — supports `--json` with the shared `{ok, data}` envelope.


## Viewer

A local web app that renders `sim-use ui --json` onto a scaled SVG canvas — see which elements the accessibility tree exposes, spot blind spots, and tap directly from the browser.

```bash
sim-use viewer
```

No Node or npm needed — the SPA is bundled into the binary. Opens your browser automatically. For front-end development on the Viewer itself, see [`Tools/Viewer/README.md`](Tools/Viewer/README.md).


## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for development setup, coding conventions, and the DCO sign-off every contribution needs.


## Licence

sim-use is licensed under the **Apache License, Version 2.0** — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

sim-use began as a fork of [`cameroncooke/AXe`](https://github.com/cameroncooke/AXe) (MIT, © 2025 Cameron Cooke), cut from AXe v1.6.0 in April 2026 and substantially modified since. It also links against XCFrameworks built from [Meta's idb](https://github.com/facebook/idb) (MIT). The MIT License of both works permits this Apache-2.0 redistribution; their original notices are reproduced in [`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES).
