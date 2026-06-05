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
sim-use swipe --start-x 50 --start-y 500 --end-x 350 --end-y 500
sim-use long-press @5               # default 0.8s hold
sim-use tap @5 --duration 0.05      # brief hold for toggles/switches
sim-use tap @5 --pre-delay 0.3      # wait before tapping
```

**Naming gotcha:** `scroll-up` scrolls the *content* up (like swiping up), which shows content *below* — it's "page down" in reading order.

## Screenshots and video

```bash
sim-use screenshot --output shot.png
sim-use record-video --output recording.mp4 --fps 15   # Ctrl+C to stop
sim-use ios stream-video --fps 10 --format mjpeg        # iOS only
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

## Daemon

```bash
sim-use daemon status
sim-use daemon stop --device <UDID>
sim-use daemon stop --all
SIM_USE_NO_DAEMON=1 sim-use ui     # bypass daemon for one call
```

Daemon is iOS-only (auto-spawned, 600s idle TTL). Android commands go through adb directly.

## --json envelope

Every command supports `--json`. Shape: `{ "ok": true/false, "data": {...}, "error": "...", "hint": "..." }`.

The `hint` field on errors contains actionable guidance (e.g. candidate labels on `multipleMatches`). Use it for self-correcting retries.

For `ui --json`, prefer `data.outline` / `data.entries` / `data.lists`. The `data.raw` field is the full AX tree (~3x larger); omit with `jq 'del(.data.raw)'` in agent loops.
