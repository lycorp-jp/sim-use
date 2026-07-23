# Xcode 27 support: investigation, spikes, and the two-step plan

Work record for the 2026-07-22 investigation into Xcode 27 support, following
up on the June 2026 findings (SimulatorKit missing + dtuhidd keyboard
suppression; stop-gap = `XcodeCompatibility.assertSimulatorKitAvailable()` and
the `KeyboardHIDSuppression` guard on `type`).

Everything below was verified live on: Xcode 27.0 **Beta 4**, system
CoreSimulator **1169.1**, iPhone 17 Pro simulator on iOS 27.0 (24A5390f),
macOS 26.

## Decision (2026-07-22)

Two-step path:

1. **Near-term PR** — fix the SimulatorKit lookup path so sim-use is fully
   usable under Xcode 27 with the classic Simulator.app workflow (Device Hub
   closed). The spike below already validates the exact change.
2. **Project: migrate to latest idb** — adopt upstream's DTUHID transport so
   Device Hub workflows work too. Verified feasible end-to-end; this document
   is the project's starting brief. No code work yet.

## What changed between Beta 1 (June) and Beta 4 (July)

| Fact | June (Beta 1, CoreSimulator 1155.4) | Now (Beta 4, CoreSimulator 1169.1) |
|---|---|---|
| SimulatorKit.framework | absent from the entire system | **back**, moved to `Xcode.app/Contents/SharedFrameworks/` (the old `Contents/Developer/Library/PrivateFrameworks/` directory is gone entirely) |
| `SimDeviceLegacyHIDClient` | n/a | present, same Swift-mangled name as Xcode 26.5 (`_TtC12SimulatorKit24SimDeviceLegacyHIDClient`) |
| dtuhidd suppression scope | legacy **keyboard** only; touch unaffected | legacy **touch AND keyboard** both dead when suppressed |
| System CoreSimulator | 1155.4 | 1169.1 — installed globally by the Beta 4 installer, so **Xcode 26 sessions run it too** |

Note: installing an Xcode 27 beta upgrades `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`
for the whole machine. There is no way to stay on the old CoreSimulator while
Beta 4 is installed.

## dtuhidd behavior matrix (CoreSimulator 1169.1)

The suppression decision is made **at simulator boot**, based on whether a
CoreDevice HID client (in practice: Device Hub) is present at that moment.

| State | describe-ui (AX) | screenshot (framebuffer) | legacy tap | legacy type |
|---|---|---|---|---|
| Booted clean, Device Hub closed | OK | OK | OK | OK |
| Booted clean → Device Hub opened mid-session (dtuhidd spawns ~2 s) | OK | OK | **still OK** | **still OK** |
| Booted **while** Device Hub open | OK | OK | **silent no-op** | **silent no-op** |
| Device Hub quit (shuts down its sims) + fresh boot | OK | OK | restored | restored |

Consequences:

- The `KeyboardHIDSuppression` guard (checks "dtuhidd running now") is both
  **over-inclusive** (false-positives in the mid-session-attach state, where
  native `type` still works) and **under-inclusive** (in the suppressed state
  `tap` is also dead and has no guard at all). The correct model is
  boot-time-aware detection — which is what upstream's transport selection
  needs anyway (see below).
- Quitting Device Hub shuts down the simulators it manages (same as closing
  Simulator.app windows), so "quit + reboot" is one motion.
- **Xcode 26.5's classic Simulator.app does NOT spawn dtuhidd on 1169.1**
  (verified: open and attached for 20 s, dtuhidd never appeared). The
  recommended agent workflow remains: boot headless or view via classic
  Simulator.app, keep Device Hub closed.

## Upstream idb status (main @ `c51004c9`, 2026-07-21)

- **No release exists** — the latest GitHub release is still v1.1.8
  (2022-08) and the `facebook/homebrew-fb` formula is pinned to it. All
  Xcode 27 work lives on `main` only; we track by commit hash, which is what
  `IDB_GIT_REF` already does.
- **SimulatorKit relocation handled**: commit `98110129` (2026-06-09) loads
  SimulatorKit from `Contents/SharedFrameworks` first, falling back to the
  legacy path for Xcode ≤ 26, with `requiredClassNames: []`.
- **New `FBSimulatorDTUHIDTransport`** (series `b7077211`…`381ddd9f`,
  2026-06-15): talks XPC directly to `dtuhidd`'s
  `com.apple.coredevice.feature.remote.hid.digitizer` service via the private
  symbols `xpc_endpoint_create_mach_port_4sim` +
  `xpc_connection_enable_sim2host_4sim`. Covers touch, two-finger/pinch,
  hardware buttons, **keyboard**. Not covered: tvOS trackpad (dtuhidd doesn't
  expose it; stays Indigo-only), Apple Pay (double side-press, not a usage).
  An 80 ms drain runs once per gesture because dtuhidd resets its services
  the instant the host peer disconnects.
- **Pluggable transport architecture is the load-bearing design, not a
  transition artifact**: `FBSimulatorHIDTransport` protocol with two
  first-class backends (`FBSimulatorIndigoHIDTransport` = legacy
  SimulatorKit path, still the default; `FBSimulatorDTUHIDTransport`), a
  transport-agnostic event layer (`FBSimulatorHIDEvent`), automatic selection
  (`FBSimulator.defaultHIDTransport`: dtuhidd present in the sim's
  launchd_sim subtree AND loaded CoreSimulator ≥ 1155.4 → `.dtuhid`, else
  `.indigo`), and an explicit override (`FBSimulatorHIDTransportType`).
  Orientation (Purple/GSEvent) and shake/lock (Darwin notifications) sit
  outside the transport by design. Capabilities are added per-transport with
  explicit `notImplemented…` errors — no silent fallback.
- **Native multi-touch upstream**: `FBSimulatorHIDEvent.twoFingerTouch` +
  `pinchAt` on both transports. Our local `patches/idb/multi-touch-spike.patch`
  becomes droppable on the bump — replaced by upstream API.
- **Upstream does NOT know legacy touch is suppressed too**: the doc comment
  in `FBSimulatorHIDSelection.swift` still says "(touch and the other
  services are unaffected)", the Indigo transport only fail-louds on
  keyboard, and every version reference is 1155.4. Their default path is
  covered by accident-of-design (auto-selection routes to DTUHID whenever
  dtuhidd runs), but forced-`.indigo` touch in the suppressed state no-ops
  silently.
- **Repo churn since our pin `76639e4d` (2025-05-29)** — the bump is a
  migration, not a version bump: HID layer and much of FBControlCore
  Swiftified; build system moved to XcodeGen (`project.yml`) producing
  **static frameworks**; `idb_companion` → `Companion`,
  `IDBCompanionUtilities` → `CompanionUtilities`; video layer rewritten in
  async Swift; new IDB API / repl / telemetry subsystems; Swift 6.4 build
  fixes (2026-07-21).

## Spike 1 — SimulatorKit path fix (validated; becomes the near-term PR)

Changes (shipped in PR #56):

- `patches/idb/xcode27-simulatorkit-sharedframeworks.patch` — backport of
  upstream `98110129` onto our pinned idb ref: prefer
  `<developerDir>/../SharedFrameworks/SimulatorKit.framework` (standardized,
  via absolute-path `frameworkWithPath:`), fall back to the legacy relative
  path.
- `Sources/iOSSimBackend/Sim/XcodeCompatibility.swift` — the stop-gap
  assertion now accepts either location.

Verification performed (all with `DEVELOPER_DIR` → Beta 4, equivalent to
`xcode-select`-ing it):

| Check | Result |
|---|---|
| iOS 27.0 simulator boots (headless) | OK |
| `describe-ui` | OK — full AX tree |
| `tap @N` | OK — Settings opened |
| `type` (native keyboard HID, Device Hub closed) | OK — characters verified in Safari's URL field, not just exit 0 |
| `screenshot` | OK — 1206×2622 PNG |
| Control: unpatched release build, same env | fails with the stop-gap "SimulatorKit is not present" error — proving the patch is what fixes it |
| `make test` | 1094 passed |

Remaining scope for the PR: update the `KeyboardHIDSuppression` guard message
(in the suppressed state *tap* is now also dead — the message should say so),
CHANGELOG, README notes on the Xcode 27 workflow (Device Hub closed;
classic Simulator.app is safe), and an `e2e-ios` run on Xcode 26.x for
regression. Agent-facing guidance shipped as a pitfall entry in
`skills/sim-use/SKILL.md` + `references/pitfalls.md` (the suppressed-state
silent tap no-op has no runtime guard, so the skill is where an agent
learns the symptom); it is written as a temporary limitation and will be
rewritten with the idb-migration work, which changes the whole Device Hub
story.

### New-toolchain build/test infra breakages found while running the matrix

The Xcode 26.6+ / Xcode 27 toolchains switch SwiftPM to the SwiftBuild
backend (products under `.build/out/Products/<config>`), which broke the dev
loop in two independent ways — both pre-existing on `main` (reproduced there
with Xcode 26.6) and both fixed in the step-1 PR:

1. **No `LC_RPATH` for binary-target XCFrameworks**: the sim-use binary and
   the SimUseTests bundle carry zero rpath entries, so dlopen of the FB*
   frameworks fails at load. Two-layer fix: `Package.swift` emits explicit
   rpath entries per XCFramework slice (`@loader_path`-relative for the
   classic and SwiftBuild layouts, plus a repo-root-relative fallback for
   custom `--scratch-path` runs started from the repo root) so bare
   `swift test --filter …` works with no prior staging — review-verified
   against a fresh scratch directory; and `scripts/stage-fb-frameworks.sh`
   stages `PackageFrameworks/` symlinks as belt-and-suspenders (wired into
   `make build`, `make test`, and both E2E runners). Known residual gap:
   an external `--scratch-path` run started from *outside* the repo root
   has no resolvable relative anchor. The rpath entries are deliberately
   dev-loop-only: release staging strips them
   (`remove_build_products_rpaths` in `scripts/build.sh`) because a shipped
   binary would otherwise search `build_products/…` — including a
   CWD-relative entry — ahead of `@executable_path/Frameworks` and load
   dev-built frameworks when run from a checkout. Adjacent watch item: the
   release build (`scripts/local-release.sh`) would hit the same
   missing-rpath issue if ever cut on a SwiftBuild-backend toolchain —
   releases are on 26.x today; re-check before moving the release
   toolchain.
2. **In-test `swift build --show-bin-path` deadlocks**: the E2E suites used
   it (via `TestUtilities.getSimUsePath()`) to locate the sim-use binary
   while running *inside* `swift test`; the SwiftBuild backend holds the
   package lock for the whole test run, so the child invocation waits
   forever (observed as N idle `swift-build --show-bin-path` processes under
   `swiftpm-testing-helper`). Fixed by resolving the path in the runners
   (outside the lock) and exporting `SIM_USE_TEST_BINARY`, which
   `getSimUsePath()` now prefers.

(An earlier suspicion that `swift test --enable-code-coverage` itself hangs
on the Beta 4 toolchain turned out to be breakage 2 in disguise — the
E2E-gated suites resolve the binary during collection even in unit-test
runs. With both fixes in, `make test` passes 1094 tests on 26.5, 26.6, and
27 Beta 4 alike.)

## Spike 2 — latest idb verified end-to-end under Device Hub

Built `FBSimulatorControl` from idb main `c51004c9` with the Beta 4 toolchain
(Swift 6.4) and drove `FBSimulatorHID` from a ~70-line standalone harness
(appendix), using sim-use `describe-ui` (AX — immune to HID suppression) as
the judge.

Results in the **suppressed-at-boot** state (booted with Device Hub open —
the state where our pinned-idb tap and type are both silently dead):

| Operation (latest idb) | Result |
|---|---|
| `auto` transport tap | delivered (auto-selected `.dtuhid`) |
| forced `.dtuhid` tap | delivered — exited Safari tab overview, focused the URL bar |
| forced `.dtuhid` keyboard usages | delivered — `value="wifi"` landed in the URL bar |
| Messages: conversation list → thread → focus field → keyboard | all delivered (`value="Hello"`) |
| Settings: General → About (two-level navigation) | delivered |
| Photos: Collections tab switch | delivered |
| SpringBoard notification-permission alert: "Allow" | delivered (cross-process system UI) |
| forced `.indigo` (fresh process) | throws `clientClassUnavailable` — see bug 1 |

Conclusion: **the idb bump fully solves the Device Hub problem** (touch and
keyboard both), via the DTU transport plus automatic selection.

## Bugs found

### 1. Upstream: Indigo transport constructs the HID client before SimulatorKit loads

Reported as [facebook/idb#941](https://github.com/facebook/idb/issues/941).

`FBSimulatorIndigoHIDTransport.indigo(for:)` evaluates
`FBSimulatorIndigoHIDClient(for:)` (which does
`objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient")`) **before**
`FBSimulatorIndigoHID()` (which loads SimulatorKit via the
`xcodeFrameworks` loader). Any fresh process that has not pre-loaded
SimulatorKit throws `clientClassUnavailable` on the whole Indigo path —
including `FBSimulatorHID(for:)` with default (auto) selection in the clean
state. It is masked inside `idb_companion` because
`FBIDBCommandExecutor.connectToHID()` pre-loads `xcodeFrameworks`, which is
why Meta doesn't see it.

**At migration time, re-check:**

1. Has facebook/idb#941 been fixed on main? (Look for a frameworks load at
   the top of `indigo(for:)` in
   `FBSimulatorControl/HID/FBSimulatorIndigoHIDTransport.swift`, or a
   reorder.)
2. Regardless of the answer, sim-use must keep an explicit
   `FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks()`
   before any `FBSimulatorHID` construction (today this lives in
   `GlobalSetup.swift` / `HIDInteractor`). Do not drop it during the
   migration even if upstream fixes the ordering — it is also what surfaces
   a clean, early error when SimulatorKit is genuinely absent.

### 2. Ours: daemon holds a stale HID connection across simulator reboot

Reported as [lycorp-jp/sim-use#55](https://github.com/lycorp-jp/sim-use/issues/55).
Fixable on the current codebase, independent of the Xcode 27 work.

After `simctl shutdown && boot`, the per-UDID daemon keeps serving HID verbs
over the previous boot's connection: `tap` reports success, nothing is
delivered, AX keeps working (so the outline looks alive). `sim-use daemon
stop --device <UDID>` restores function. `HIDPerformRecovery` /
`HIDBootIdentity` don't cover the scenario. Reproduced twice during this
investigation.

## Step 2 project brief: idb bump migration checklist

Prerequisites / re-verification at project start:

1. Re-run the upstream survey: new commits on `main` touching
   `FBSimulatorControl/HID/`, status of facebook/idb#941, any release/tag
   (unlikely), CoreSimulator version on the then-current Xcode 27 beta
   (suppression scope may shift again — re-run the dtuhidd matrix above).
2. Re-validate the harness (appendix) against then-current main — it is the
   fastest end-to-end probe of the DTU transport.

Migration work items (from today's findings):

- **Build system**: upstream now uses XcodeGen (`project.yml`) and produces
  **static frameworks**; `scripts/build.sh`'s XCFramework packaging must be
  reworked accordingly. Known trap: `./build.sh build FBSimulatorControl`
  fails unless the `CompanionUtilities` scheme is built first
  (`FBSimulator.h` imports `CompanionUtilities-Swift.h`; upstream's
  `build_all_frameworks` misses it). Consumers link with `-ObjC`, all four
  frameworks (FBSimulatorControl / FBControlCore / CompanionUtilities /
  XCTestBootstrap), `-weak_library
  PrivateHeaders/{CoreSimulator,AccessibilityPlatformTranslation}/*.tbd`,
  and the five PrivateHeaders module maps (see appendix for the exact
  command).
- **Patches**: drop `multi-touch-spike.patch` (upstream has native
  two-finger/pinch); drop `xcode27-simulatorkit-sharedframeworks.patch`
  (upstream `98110129` supersedes it); re-evaluate `headerpad-shims.patch`
  and `fbprocess-runtime-rename.patch` against the restructured repo.
- **GlobalSetup / HIDInteractor**: keep the explicit `xcodeFrameworks`
  pre-load (bug 1); adapt to the Swiftified API
  (`FBSimulatorHID(for:transport:)`, `FBSimulatorHIDEvent`, async `send`).
- **Retire `KeyboardHIDSuppression`**: superseded by upstream's transport
  auto-selection. Consider exposing a debug flag for forcing a transport.
- **Retire / narrow `XcodeCompatibility.assertSimulatorKitAvailable`**: with
  upstream's dual-path loader it only needs to produce a friendly error when
  SimulatorKit is missing from both locations (Beta-1-like toolchains).
- **Orientation calibration**: verify `OrientationCalibration.hidPoint`
  holds on the DTU transport (it normalizes with the same
  `FBSimulatorIndigoHID.screenRatio` helper as Indigo, so likely yes — but
  E2E it, including rotation cases).
- **Daemon**: fix or verify lycorp-jp/sim-use#55 first so migration testing
  isn't confused by stale-connection artifacts (it bit us twice during this
  investigation).
- **E2E**: full `make e2e-ios` on Xcode 26.x and a manual matrix on Xcode 27
  (clean boot / Device-Hub-open boot / mid-session attach), plus multi-touch
  verbs through the new upstream API.

## Appendix: standalone verification harness

Build the frameworks (Beta 4 toolchain; from an idb checkout at main):

```bash
xcodebuild ONLY_ACTIVE_ARCH=YES -project FBSimulatorControl.xcodeproj \
  -scheme CompanionUtilities -sdk macosx -derivedDataPath ./Build -configuration Debug build
xcodebuild ONLY_ACTIVE_ARCH=YES -project FBSimulatorControl.xcodeproj \
  -scheme FBSimulatorControl -sdk macosx -derivedDataPath ./Build -configuration Debug build
# (generate the project first with `./build.sh generate` if FBSimulatorControl.xcodeproj is absent;
#  requires `brew install xcodegen`)
```

Compile the harness (`P` = products dir, `D` = idb checkout root):

```bash
P=$D/Build/Build/Products/Debug
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer \
xcrun swiftc -parse-as-library -o hid-harness hid-harness.swift \
  -F "$P" -Xlinker -ObjC \
  -framework FBSimulatorControl -framework FBControlCore \
  -framework CompanionUtilities -framework XCTestBootstrap \
  -Xlinker -weak_library -Xlinker $D/PrivateHeaders/CoreSimulator/CoreSimulator.tbd \
  -Xlinker -weak_library -Xlinker $D/PrivateHeaders/AccessibilityPlatformTranslation/AccessibilityPlatformTranslation.tbd \
  -Xcc -I$D/PrivateHeaders \
  -Xcc -fmodule-map-file=$D/PrivateHeaders/CoreSimulator/module.modulemap \
  -Xcc -fmodule-map-file=$D/PrivateHeaders/SimulatorApp/module.modulemap \
  -Xcc -fmodule-map-file=$D/PrivateHeaders/SimulatorKit/module.modulemap \
  -Xcc -fmodule-map-file=$D/PrivateHeaders/AXRuntime/module.modulemap \
  -Xcc -fmodule-map-file=$D/PrivateHeaders/AccessibilityPlatformTranslation/module.modulemap
```

Usage (`key` takes USB HID usage codes; h-e-l-l-o = `11 8 15 15 18`):

```bash
./hid-harness <udid> <auto|indigo|dtuhid> tap <x> <y>
./hid-harness <udid> <auto|indigo|dtuhid> key <usage> [<usage>...]
```

`hid-harness.swift`:

```swift
// Minimal harness driving idb main's FBSimulatorHID directly, to verify
// the DTUHID transport against a simulator in the dtuhidd-suppressed state.
import FBControlCore
import FBSimulatorControl
import Foundation

@main
struct Harness {
  static func main() async {
    let args = CommandLine.arguments
    guard args.count >= 4 else {
      print("usage: hid-harness <udid> <auto|indigo|dtuhid> tap <x> <y> | key <usage...>")
      exit(2)
    }
    let udid = args[1]
    let transportArg = args[2]
    let verb = args[3]

    do {
      let logger = FBControlCoreGlobalConfiguration.defaultLogger
      try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
      let config = FBSimulatorControlConfiguration(deviceSetPath: nil, logger: logger, reporter: nil)
      let set = try FBSimulatorControl.withConfiguration(config).set
      guard let simulator = set.simulator(withUDID: udid) else {
        print("FAIL: simulator not found: \(udid)")
        exit(1)
      }

      let transport: FBSimulatorHIDTransportType?
      switch transportArg {
      case "indigo": transport = .indigo
      case "dtuhid": transport = .dtuhid
      case "auto": transport = nil
      default:
        print("unknown transport: \(transportArg)")
        exit(2)
      }

      let hid = try FBSimulatorHID(for: simulator, transport: transport)

      switch verb {
      case "tap":
        guard args.count >= 6, let x = Double(args[4]), let y = Double(args[5]) else {
          print("usage: tap <x> <y>")
          exit(2)
        }
        try await hid.send(event: .tapAt(x: x, y: y), logger: logger)
      case "key":
        let codes = args[4...].compactMap { UInt32($0) }
        guard !codes.isEmpty else {
          print("usage: key <usage...>")
          exit(2)
        }
        try await hid.send(
          event: .shortKeyPressSequence(codes.map { NSNumber(value: $0) }), logger: logger)
      default:
        print("unknown verb: \(verb)")
        exit(2)
      }

      hid.disconnect()
      print("OK: \(verb) sent via \(transportArg) transport")
      exit(0)
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
```

Judge the result from a separate terminal with the AX side (immune to HID
suppression): `sim-use describe-ui --device <udid>`. When rebooting the
simulator between experiments, run `sim-use daemon stop --device <udid>`
first (bug 2 above).

## Addendum (2026-07-23, issue #60)

The type-only dtuhidd guard described above is superseded. Live A/B testing
(same device, same runtime) confirmed the boot-time rule — booted-under-Hub
drops all legacy HID silently; Hub attached after a clean boot keeps working —
and that dtuhidd *presence* alone therefore cannot be the predicate. The guard
now keys on dtuhidd's start time relative to its parent `launchd_sim`
(boot-attach window 15 s; measured 1 s poisoned vs ≥ 34 s benign), lives at
`HIDInteractor.makeSession` so every HID verb is covered, and no longer
false-positives on the attach-after-boot state. See
`DeviceHubHIDSuppression.swift` and issue #60.
