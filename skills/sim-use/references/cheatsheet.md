# sim-use Command Cheatsheet

## Command namespaces

| Namespace | Scope | Examples |
|---|---|---|
| `sim-use <verb>` | Cross-platform (iOS + Android) | `ui`, `tap`, `swipe`, `type`, `paste`, `button`, `gesture`, `screenshot`, `record-video`, `app-state` |
| `sim-use ios <verb>` | iOS Simulator only | `key`, `key-combo`, `key-sequence`, `stream-video`, `batch` |
| `sim-use android <verb>` | Android device only | `init`, `devices`, `ping` |

## Device resolution

`--device` is optional. Resolution order: `--device` flag → `$SIM_USE_DEVICE` env → only live daemon → only booted simulator.

When multiple devices exist, pass `--device <UDID>` explicitly. Run `sim-use devices` to list all connected devices across platforms.

## Selectors

```bash
sim-use tap @5                          # alias from last `ui` snapshot
sim-use tap '#3'                        # 3rd cell of dominant list
sim-use tap '#2@2'                      # 2nd cell of 2nd list (quote for shell)
sim-use tap '#settingsButton'           # AXUniqueId (live AX lookup)
sim-use tap --id Safari                 # by accessibility identifier
sim-use tap --label "General"           # by exact label
sim-use tap --label-contains "Order"    # substring match
sim-use tap --label-regex '^Chat.*\d+$' # ICU regex
sim-use tap -x 100 -y 200              # absolute coordinates (last resort)
```

## Disambiguating with --frame

Narrow matches by screen region when selectors collide:

```bash
sim-use tap --label 'Tab' --frame minY=0.7r    # bottom 30% of screen
sim-use tap --label 'Tab' --frame maxY=0.2r    # top 20% of screen
sim-use tap --label 'OK' --frame 'minX=200,maxX=400,minY=600,maxY=700'
```

- Values: absolute pixels (`700`) or fraction with `r` suffix (`0.7r`).
- Keys: `minX`, `maxX`, `minY`, `maxY`. Each appears at most once.
- Composes with all selectors and `--element-type`.

## Text input

```bash
sim-use type 'Hello World!'                    # HID keyboard (ASCII)
echo "complex text" | sim-use type --stdin     # stdin for special chars
sim-use paste 'こんにちは 🎉'                    # pasteboard + Cmd+V (iOS)
sim-use paste 'text' --replace                  # Cmd+A then paste
sim-use paste 'text' --via-menu --target-id <id>  # iOS edit menu (soft keyboard)
```

- iOS: `paste` needs hardware keyboard connected; use `--via-menu` for soft-keyboard-only.
- Android: `paste` uses native `ACTION_PASTE`; `type` works for all unicode.

## Gestures and timing

```bash
sim-use gesture scroll-up           # scroll-up = content moves up = page down
sim-use gesture scroll-down         # page up
sim-use swipe --from 50,500 --to 350,500
sim-use long-press @5               # default 0.8s hold
sim-use long-press --label "Photos" # selector targeting
sim-use long-press @5 --duration 1.2  # custom hold time
sim-use tap @5 --duration 0.05      # brief hold for toggles/switches
sim-use tap @5 --pre-delay 0.3      # wait before tapping
```

`long-press` is sugar over `tap --duration 0.8`. Same targeting surface as `tap`. Use for action menus, launcher popups, drag-handle activation.

Note: some Android apps render long-press menus in a `PopupWindow` overlay that the bridge's `describe-ui` cannot walk — verify with a screenshot when this matters.

**Naming gotcha:** `scroll-up` scrolls the *content* up (like swiping up), which shows content *below* — it's "page down" in reading order.

## Pinch and rotate (two-finger gestures)

```bash
sim-use gesture pinch-out                             # zoom in (default scale 2.0)
sim-use gesture pinch-in                              # zoom out (default scale 0.5)
sim-use gesture pinch-out --scale 3.0 --radius 60     # wider zoom, smaller start circle
sim-use gesture rotate-cw                             # clockwise 90° (default)
sim-use gesture rotate-ccw --angle 45                 # counter-clockwise 45°
sim-use gesture pinch-out --center-x 200 --center-y 400  # off-center pivot
```

| Parameter | Default | Description |
|---|---|---|
| `--scale` | 2.0 (out) / 0.5 (in) | End radius / start radius ratio |
| `--angle` | 90 | Rotation sweep in degrees |
| `--center-x/y` | screen center | Pivot point (pixels) |
| `--radius` | 80 | Start radius (pixels) |
| `--steps` | 10 | Interpolated HID Move events (iOS only) |
| `--step-ms` | derived from duration/steps | Sleep between Move events (iOS only) |

## Multi-touch (low-level)

For gestures the presets don't cover, use `multi-touch` directly with two contact points:

```bash
# Pinch-zoom in by moving two fingers apart vertically
sim-use multi-touch \
  --x1 195 --y1 472 --x1-end 195 --y1-end 322 \
  --x2 195 --y2 472 --x2-end 195 --y2-end 622 \
  --steps 10 --step-ms 30
```

Also available: `tap --fingers 2` and `long-press --fingers 2` for two-finger tap/hold.

## Touch (low-level, single finger)

```bash
sim-use touch -x 150 -y 250 --down                # touch down only
sim-use touch -x 150 -y 250 --up                  # touch up only
sim-use touch -x 150 -y 250 --down --up            # tap
sim-use touch -x 150 -y 250 --down --up --delay 1.0  # long press
```

## Screenshots and video

```bash
sim-use screenshot --output shot.png
sim-use record-video --output recording.mp4 --fps 15   # Ctrl+C to stop
sim-use ios stream-video --fps 10 --format mjpeg        # iOS only
```

### Stopping a backgrounded recording

Send `SIGTERM` and `wait` — do **not** `SIGKILL`, which skips the MP4 trailer and produces an unplayable file.

```bash
sim-use record-video --output recording.mp4 &
PID=$!
# ... drive the simulator ...
kill -TERM "$PID"
wait "$PID"               # blocks ~50–150 ms while the trailer is written
```

## Batch (iOS only)

```bash
sim-use ios batch --device <UDID> \
  --step "tap --id SearchField" \
  --step "type 'query'" \
  --step "key 40" \
  --wait-timeout 5
```

- One step source per run: `--step`, `--file`, or `--stdin`.
- `--wait-timeout` makes selector taps poll for the element.
- `--ax-cache perStep` refreshes the AX snapshot between steps.
- Do not put `--device` inside step lines.
- See `references/batch-reference.md` for full semantics, flags, and examples.

## Daemon

```bash
sim-use daemon status
sim-use daemon stop --device <UDID>
sim-use daemon stop --all
SIM_USE_NO_DAEMON=1 sim-use ui     # bypass daemon for one call
```

Daemon is iOS-only (auto-spawned, 600s idle TTL). Android commands go through adb directly.

## iOS keyboard (HID keycodes)

```bash
sim-use ios key 40                                    # Enter
sim-use ios key 42 --duration 1.0                     # Hold Backspace
sim-use ios key-sequence --keycodes 11,8,15,15,18     # "hello"
sim-use ios key-combo --modifiers 227 --key 4         # Cmd+A
sim-use ios key-combo --modifiers 227 --key 6         # Cmd+C
sim-use ios key-combo --modifiers 227 --key 25        # Cmd+V
sim-use ios key-combo --modifiers 227,225 --key 4     # Cmd+Shift+A
```

### Common keycodes

| Key | Code | Key | Code | Key | Code |
|---|---|---|---|---|---|
| Enter | 40 | Escape | 41 | Backspace | 42 |
| Tab | 43 | Space | 44 | a | 4 |
| LeftGUI (Cmd) | 227 | LeftShift | 225 | LeftCtrl | 224 |
| LeftAlt | 226 | F1 | 58 | F12 | 69 |

## Timing parameters

| Parameter | Range | Description | Available on |
|---|---|---|---|
| `--pre-delay` | 0–10s | Delay before action | tap, swipe, gesture |
| `--post-delay` | 0–10s | Delay after action | tap, swipe, gesture |
| `--duration` | 0–10s | Action duration | swipe, gesture, button, key, tap (opt-in for toggles) |
| `--delay` | 0–5s | Between-item delay | key-sequence, touch |

## UDID auto-resolution

`--device` is optional. Resolution order:

1. Explicit `--device <UDID>` flag
2. `$SIM_USE_DEVICE` environment variable
3. The only live sim-use daemon under `/tmp/sim-use-<uid>/` (<1 ms)
4. The only simulator with `state == "Booted"` via `xcrun simctl list` (~150 ms)

Edge cases:
- **Stale daemon**: if you shut down a simulator outside sim-use but its daemon is still alive, the next command fails loudly — run `sim-use daemon stop --all` then retry.
- **Multiple daemons + multiple booted**: falls through to step 4 and errors with a disambiguation message listing all booted devices.
- For CI fan-out (many simulators in parallel), keep `--device` explicit.

## --json envelope

Every command supports `--json`. Shape: `{ "ok": true/false, "data": {...}, "error": "...", "hint": "..." }`.

The `hint` field on errors contains actionable guidance (e.g. candidate labels on `multipleMatches`). Use it for self-correcting retries.

For `ui --json`, prefer `data.outline` / `data.entries` / `data.lists`. The `data.raw` field is the full AX tree (~3x larger); omit with `jq 'del(.data.raw)'` in agent loops.
