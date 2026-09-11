# Linux (Android only)

sim-use builds on Linux with the Android backend only. The Android backend
drives the device through `adb` plus the in-device bridge APK's HTTP server and
needs none of the Apple frameworks the iOS side is built on, so `Package.swift`
declares a separate `#if os(Linux)` target graph: `SimUseCore`,
`AndroidBackend`, and the `SimUseLinux` executable.

## What is available

The Android verbs are registered at the top level under the same names as on
macOS — `ui` / `describe-ui`, `devices`, `tap`, `type`, `paste`,
`keyboard-state`, `swipe`, `button`, `touch`, `gesture`, `multi-touch`,
`screenshot` — plus the full `sim-use android <verb>` namespace and
`sim-use daemon`. The per-device daemon works as on macOS, so warm commands
keep their low latency.

Not available on Linux:

- `sim-use ios <verb>` and `sim-use ios-device <verb>`
- `record-video` / `stream-video` — host-side H.264 muxing and encoding use
  AVFoundation
- `long-press`, `app-state` — their Android paths live in the macOS
  cross-platform forwarders; use `tap --duration` / `touch` in the meantime
- `viewer`
- `init` (the agent-skill installer) — copy `skills/sim-use/` into your
  client's skill directory by hand

`sim-use devices` is the Android listing (`sim-use android devices`), not the
unified cross-platform schema.

## Build and install

Requirements: a Swift 6 toolchain for Linux (<https://www.swift.org/install/linux/>)
on `PATH`, plus JDK 17–21 and an Android SDK (`compileSdk=35`) to build the
bridge APK — see `AGENTS.md`.

```bash
scripts/install-linux.sh                 # bridge APK + release build + install
scripts/install-linux.sh --skip-bridge   # reuse the APK already in Sources/AndroidBackend/Resources
```

The script installs into `$PREFIX/lib/sim-use` (default `PREFIX=~/.local`) and
symlinks `$PREFIX/bin/sim-use`. It installs two things that must stay together:
the `sim-use` binary and the `SimUse_AndroidBackend.resources` bundle holding
the bridge APK, which `Bundle.module` looks up next to the executable. Set
`SWIFT_TOOLCHAIN` to a toolchain root if `swift` is not on `PATH`.

The binary links the Swift runtime dynamically, so the toolchain it was built
with must stay installed. `--static-swift-stdlib` does not work:
`FoundationNetworking` needs a static libcurl that the toolchains do not ship.

For development, `swift build` and `swift test` work directly (the `make`
targets are macOS-only).

## Usage

```bash
adb devices
sim-use android init --device <serial>   # install the bridge APK, enable its accessibility service
sim-use ui --device <serial>
sim-use tap @5 --device <serial>
```

`--json` returns the same `{"ok": …, "data": …}` envelope as on macOS.

## Remote adb server (WSL)

`adb forward` opens its listening port on the machine that runs the **adb
server**. When `ADB_SERVER_SOCKET` points at a remote server
(`tcp:<host>:<port>`), sim-use therefore talks to the bridge on that host
instead of `127.0.0.1`. Set `SIM_USE_BRIDGE_HOST` to override the host
explicitly. This applies on macOS too.

The common case is WSL, which has no USB access: WSL's `adb` points at the
Windows host's adb server so physical devices stay visible.

1. On Windows, start the server listening on all interfaces:
   `adb kill-server` then `adb -a -P 5037 nodaemon server`. Without `-a`, the
   server — and every forward it opens — binds to Windows loopback, which WSL
   cannot reach.
2. In WSL, point `adb` and sim-use at it:
   `export ADB_SERVER_SOCKET=tcp:$(ip route show default | awk '{print $3}'):5037`
   (under WSL's default NAT networking, the default gateway is the Windows
   host).

> **Security.** `adb -a` exposes the adb server — full shell access to every
> attached device — and the forwarded bridge port on **every** interface of the
> Windows host, and the bridge speaks plain HTTP. Only do this on a trusted
> network, and restrict inbound TCP 5037 and the forwarded ports to the WSL
> virtual network in Windows Firewall.

A device reached with `adb connect <ip>:5555` through a local adb server in WSL
needs none of this: the forward is local and the bridge host stays
`127.0.0.1`.
