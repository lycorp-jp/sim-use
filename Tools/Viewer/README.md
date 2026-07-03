# sim-use Viewer

A local web app that renders `sim-use ui --json` onto a scaled SVG canvas so you can see, side-by-side with your running simulator, which UI elements the accessibility tree actually exposed.

## Running it (end users)

The Viewer is bundled into the `sim-use` binary. No Node, no `npm install`:

```sh
sim-use viewer
```

This boots a 127.0.0.1-only HTTP server (auto-port; pass `--port N` to pin), opens your default browser (suppress with `--no-open`), and serves the built SPA out of the binary's resources.

## Working on the Viewer front-end

For React / SPA development you still want hot-reload + source maps, which means running Vite alongside the API server:

```sh
cd Tools/Viewer
npm install        # one-off
npm run dev
```

This starts two processes:

- `sim-use viewer --no-open --port 4000` on `http://127.0.0.1:4000` (the real `/api/*` server)
- Vite dev server on `http://127.0.0.1:5173`

Open `http://127.0.0.1:5173`. `/api/*` calls are proxied to `sim-use viewer`, so dev mode exercises the production code path. `sim-use` must be on `PATH`; to use a local build, run `SIM_USE_BIN=/path/to/sim-use npm run dev`.

When you're happy with the change, regenerate the bundled SPA assets:

```sh
make viewer        # or: scripts/build-viewer.sh
```

## API endpoints

- `GET /api/devices` — list booted simulators and connected Android devices.
- `GET /api/snapshot?deviceId=<DEVICE_ID>` — `sim-use ui --json` → `{ screen, entries, outline, capturedAt }`. `udid=` is still accepted as a deprecated alias.
- `POST /api/tap` — replay `sim-use tap @N` on the selected element.

## Controls

- **Device** — pick a booted simulator or connected device.
- **Play / Stop** — start / stop interval sampling. First click also fires an immediate shot.
- **Interval select** — sampling period (1s / 2s / 5s).
- **T** — replay `sim-use tap` on the selected element.
- **Up / Down** — step through outline entries.
- Click any box in the canvas, or any `@N` line in the outline pane, to cross-highlight.

## Visual conventions

| Condition | Style |
|---|---|
| has `AXUniqueId` | solid green stroke (`#2ecc71`) |
| no `AXUniqueId` | dashed blue stroke (`#4a90e2`) |
| blind spot (no actionable element) | red stroke + diagonal hatch (`#d94040`) |
| `disabled` | gray, reduced opacity |
| AX `selected` | gold, thicker stroke (`#f1c40f`) |
| user-selected | purple stroke + fill (`#8b6fc0`) |

Dashed horizontal lines at `y=120` and `y=H-120` mark the Top / Content / Bottom y-band boundaries.
