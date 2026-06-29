# sim-use

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

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
- [Install](#install)
- [Platforms](#platforms)
- [Commands](#commands)
- [Architecture](#architecture)
- [Tools/Viewer](#toolsviewer)
- [Contributing](#contributing)
- [Licence](#licence)


## The observe → act loop

sim-use is designed around a single loop pattern an agent can execute in ~300 ms per round trip:

1. `sim-use ui --device $UDID` — dumps the current screen as a compact outline (`@N` aliases per element, region banding, state tags) and writes a cache at `~/.sim-use/<UDID>/last-outline.json`.
2. `sim-use tap @<N> --device $UDID` — taps the Nth element from that snapshot, resolving through the cache without re-walking the AX tree.
3. `sim-use ui` again to verify the new state.

A worked round trip:

```text
$ sim-use ui --device $UDID
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

$ sim-use tap @9 --device $UDID          # open General
$ sim-use ui --device $UDID     # confirm the new screen
```

Four selector styles sit on top of the same cache:

| Form | Resolves via | When to prefer |
|---|---|---|
| `tap @N` | alias cache from last `ui` | Fastest; use right after `ui`, no drift detection |
| `tap #N` / `tap #N@M` | alias cache (list cluster detector) | Cell N of the dominant list (`#N`) or scoped to the M-th list (`#N@M`); same speed as `@N` |
| `tap #<id>` | live AX tree by `AXUniqueId` | Paste `#settingsButton` straight out of the outline; survives minor layout changes |
| `tap --id` / `--label` / `--value` | live AX tree lookup | Scripted flows; combine with `--wait-timeout` in `batch` to tolerate navigation animations |

`@N`, `#N`, `#N@M`, and `#<id>` are mutually exclusive with `-x/-y` and `--id/--label/--value`. Coordinate taps are the last resort for elements that expose no AX data.

The `#` prefix dispatches on its payload: a positive integer (optionally followed by `@<positive int>`) is a list-cell selector; anything else is treated as an `AXUniqueId`, so identifiers containing `@` (e.g. `#feed@home`) keep id semantics. `#3` and `#3@1` are exact synonyms for the dominant list.

The `--json` form of `ui` returns the same information as a structured envelope (`raw` tree + `outline` text + `entries` array) so an agent can parse aliases and entry metadata without re-parsing the text.


## Install

### Homebrew (recommended)

```bash
brew tap lycorp-jp/tap
brew install lycorp-jp/tap/sim-use
```

On Homebrew 6.0.5+, if you see an "untrusted tap" error, run `brew trust lycorp-jp/tap` first.

### Build from source

sim-use is a Swift package targeting **macOS 14+**, built with the latest Xcode toolchain. It links against XCFrameworks built from [Meta's idb](https://github.com/facebook/idb), which are produced locally by the build script (they are large and not checked into the repository).

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

For Android, run `sim-use android init --device <serial>` once to install the bridge APK. See `AGENTS.md` for Android toolchain setup.


## Commands

All device-scoped commands accept `--device <ID>` (optional when only one simulator is booted). Three command layers:

  * **Top-level** — cross-platform verbs: `ui`, `tap`, `swipe`, `type`, `paste`, `button`, `gesture`, `keyboard-state`, `screenshot`, `record-video`, `app-state`. Same flags on iOS and Android.
  * **`sim-use ios <verb>`** — iOS-only: `key`, `key-combo`, `key-sequence`, `stream-video`, `batch`.
  * **`sim-use android <verb>`** — Android-only: `init`, `devices`, `ping`.

Run `sim-use --help` or `sim-use <command> --help` for the full flag set.

```bash
sim-use devices
UDID="B34FF305-5EA8-412B-943F-1D0371CA17FF"
```

### Touch & gestures

```bash
sim-use tap -x 100 -y 200 --device $UDID
sim-use tap @5 --device $UDID                                 # alias cache
sim-use tap "#3" --device $UDID                               # 3rd cell of the dominant list
sim-use tap "#2@2" --device $UDID                             # 2nd cell of the 2nd detected list
sim-use tap "#settingsButton" --device $UDID                  # AXUniqueId
sim-use tap --id Safari --device $UDID
sim-use tap --label "Safari" --device $UDID
sim-use tap --value "On" --device $UDID

sim-use swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --device $UDID
sim-use swipe --start-x 50 --start-y 500 --end-x 350 --end-y 500 --duration 2.0 --delta 25 --device $UDID

# Low-level touch control
sim-use touch -x 150 -y 250 --down --device $UDID
sim-use touch -x 150 -y 250 --up --device $UDID
sim-use touch -x 150 -y 250 --down --up --delay 1.0 --device $UDID   # long press

# Gesture presets
sim-use gesture scroll-up --device $UDID
sim-use gesture swipe-from-left-edge --device $UDID
sim-use gesture scroll-down --pre-delay 0.5 --post-delay 1.0 --device $UDID
```

`--pre-delay` / `--post-delay` / `--duration` work on `tap`, `swipe`, and `gesture` alike for coarse timing control.

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
sim-use paste 'NEW' --replace --via-menu --target-id chatTextField --device $UDID
sim-use paste 'at xy' --via-menu --target-x 171 --target-y 513 --device $UDID
```

iOS 16+ gates the first paste per app session behind an "Allow Paste" prompt (modal dialog on iOS 16, inline bubble on iOS 17+). sim-use does not auto-dismiss it — approve once interactively (iOS grants a ~60 s grace window for the session) or pre-configure Settings → Paste from Other Apps per app.

### Keyboard state

Probe whether the software keyboard is visible. Primary use: pick between the `paste` Cmd+V default and `--via-menu` path.

```bash
# Text form — prints `soft` or `hidden`. Both exit 0; non-zero is reserved
# for probe failure (unreachable device, AX fetch error). Branch on stdout.
if [[ "$(sim-use keyboard-state --device $UDID)" == soft ]]; then
  sim-use paste "$TEXT" --via-menu --target-id chatTextField --device $UDID
else
  sim-use paste "$TEXT" --device $UDID
fi

# JSON envelope — consume data.visible; the envelope may carry diagnostic
# counters alongside it for debugging false positives/negatives
sim-use keyboard-state --json --device $UDID
# -> {"ok":true,"data":{"visible":true, ...}}
```

### Hardware buttons

```bash
sim-use button home --device $UDID
sim-use button lock --duration 2.0 --device $UDID     # long press
sim-use button siri --device $UDID
# Also: side-button, apple-pay
```

### Low-level keyboard (iOS-only)

These verbs speak USB HID keycodes — they live under `sim-use ios <verb>`
because Android keyboard input goes through a different abstraction
(`KeyEvent.KEYCODE_*` via `INJECT_EVENTS`). For Android text entry use
`sim-use type` or `sim-use paste`.

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

Run multiple steps in a single invocation. Batch reuses one HID session and one AX snapshot across steps, cutting round-trip cost on multi-step flows. iOS-only because the runner pins an iOS HID session across steps — Android steps each round-trip through the bridge already, so batching saves nothing there.

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
- `--ax-cache perBatch` (default) reuses one AX snapshot for the whole run; `--ax-cache perStep` refreshes between steps when the UI changes.

### Screenshot

```bash
sim-use screenshot --device $UDID                                 # auto-named
sim-use screenshot --output ~/Desktop/shot.png --device $UDID     # specific file
sim-use screenshot --output ~/Desktop/ --device $UDID             # directory
```

The output path goes to stdout; progress messages go to stderr.

### Video streaming & recording

```bash
# MJPEG stream (iOS-only — no Android stream-video implementation)
sim-use ios stream-video --device $UDID --fps 10 --format mjpeg > stream.mjpeg

# Pipe into ffmpeg
sim-use ios stream-video --device $UDID --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast out.mp4

# Record MP4 directly (cross-platform)
sim-use record-video --device $UDID --fps 15 --output recording.mp4
sim-use record-video --device $UDID --fps 10 --quality 60 --scale 0.5 --output low-bw.mp4
```

Press Ctrl+C to stop; sim-use finalises the MP4 before exiting.

### Accessibility inspection

```bash
sim-use ui --device $UDID                      # compact outline (default)
sim-use ui --json --device $UDID               # structured envelope
sim-use ui --point 100,200 --device $UDID      # specific point
```

The outline uses region banding (`[Top]` / `[Content]` / `[Bottom]` / declared `Group` regions) and `@N` / `#N` / `#N@M` / `#<id>` alias addressing.

A list cluster detector runs on every snapshot and attaches `#N` aliases to detected list cells. Outline lines for cells render as `@N #M` (dominant list) or `@N #M@S` (scope `S>1`); the `--json` envelope adds a sibling `lists` array, ordered by detector score, where each entry summarises one cluster as `{ scope, cellCount, cellHeight, containerRole, containerLabel, bbox, score }`. Per-cell membership is also surfaced through `entries[*].aliases.list = { scope, index }` so consumers can pivot on either shape. `lists[0]` is always the dominant cluster, or the array is empty when nothing list-shaped is on screen.

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


## Architecture

sim-use drives iOS Simulators through the lower-level XCFrameworks of Facebook's [idb](https://github.com/facebook/idb), Apple's Accessibility APIs, and the simulator HID pipeline. Android devices are driven through an on-device bridge APK that exposes the AccessibilityService tree and input injection over HTTP, tunnelled via `adb forward`.

- **Single binary, single invocation.** No RPC daemon to manage manually; the optional per-UDID background daemon is auto-spawned and opt-out (`SIM_USE_NO_DAEMON=1`).
- **Agent-first output.** `ui` emits a compact outline with stable `@N` / `#<id>` aliases designed to round-trip between an LLM and the simulator with minimal token cost.
- **Full HID surface.** Tap, swipe, touch, gesture presets, hardware buttons, key combos, and IME-safe Unicode paste all exposed as first-class commands.
- **Scriptable from day one.** Every command supports `--json` for machine consumption; `batch` collapses multi-step flows into a single invocation.


## Tools/Viewer

A local web app that renders `sim-use ui --json` onto a scaled SVG canvas — see which elements the accessibility tree exposes, spot blind spots, and tap directly from the browser.

```bash
cd Tools/Viewer && npm install
SIM_USE_BIN="$(pwd)/../../.build/debug/sim-use" npm run dev
# open http://127.0.0.1:5173
```

| Visual | Meaning |
|---|---|
| solid green stroke | element has `AXUniqueId` |
| dashed blue stroke | no `AXUniqueId` |
| red diagonal hatch | blind spot (no actionable element) |
| purple fill | user-selected element |

See [`Tools/Viewer/README.md`](Tools/Viewer/README.md) for details.


## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for development setup, coding conventions, and the DCO sign-off every contribution needs.


## Licence

sim-use is licensed under the **Apache License, Version 2.0** — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

sim-use began as a fork of [`cameroncooke/AXe`](https://github.com/cameroncooke/AXe) (MIT, © 2025 Cameron Cooke), cut from AXe v1.6.0 in April 2026 and substantially modified since. It also links against XCFrameworks built from [Meta's idb](https://github.com/facebook/idb) (MIT). The MIT License of both works permits this Apache-2.0 redistribution; their original notices are reproduced in [`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES).
