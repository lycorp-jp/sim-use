# 010.005 — Explicit cover-display screenshots

## Context

On 2026-11-14, sim-use 0.16.0 on Xcode 27.2 (27B52), iOS 27.2,
returned a 2007x2853 black inner-display image while the Duo cover was active.
The worktree at f506259 uses the same screenshot dispatch.

## Reproduction and evidence

With a booted Duo, run `sim-use ios fold closed --device <UDID>`, then
`sim-use screenshot --device <UDID> --output /tmp/cover.png`.
After the fold settles, the image is black and has the inner panel size.
An immediate capture can instead contain the previous inner-display frame.
`xcrun simctl io <UDID> screenshot --display=LCD /tmp/control.png` returns
the visible cover UI at 1398x2034.

The routing resolver correctly identifies the cover as `.main`. The screenshot
command then calls idb's default capture. `FBFramebuffer.mainScreenSurface`
selects the first class-0 display; it does not select the CoreDevice primary
UUID. The observed default framebuffer is the inner panel on this runtime.

## Decision

Keep input and accessibility routing unchanged. For `.main` screenshots on
multi-display devices, select the primary integrated display explicitly and
reuse `DisplayScreenshot.capture`. Keep the existing single-display fallback
and secondary/Resize Mode capture paths. Do not infer a target from black
pixels, names, or hard-coded display IDs.

## Verification plan

Add a live regression that captures closed, open, then closed again, checking
PNG dimensions after each transition. Observe it fail before the fix and pass
afterwards. Run `make build`, `make test`, and live single-display screenshots.
Inspect the fixed cover image. Restore the Duo's original open posture.

## Implementation and verification

`IOSSimScreenshotCommand` now uses the primary display UUID for the
multi-display `.main` case. `FoldTests.screenshotFoldTransitions` checks
closed/open/closed captures without launching or modifying an app.

- `make build`: passed after rebuilding the FB* frameworks with Xcode 27.2
  and applying the repository's existing idb patches. One existing
  `OrientationCalibrator.swift` CoreGraphics import warning remains.
- Regression with `SIM_USE_TEST_BINARY=/opt/homebrew/bin/sim-use` (0.16.0):
  failed both closed assertions; the open assertion passed.
- The same test with `.build/debug/sim-use`: passed (12.194 seconds).
- Live cover screenshot with `--json`: `ok: true`, 1398x2034, visible app
  content confirmed by image inspection.
- Live iPhone 18 Pro screenshot: 1206x2622. Duo restored to its original
  open posture; final inner screenshot: 2853x2007.

The regression command uses `SIM_USE_E2E=1 SIMULATOR_UDID=<UDID>
SIM_USE_TEST_BINARY=<binary> swift test --filter
FoldTests/screenshotFoldTransitions`.

Full device E2E, Resize Mode, and video capture were not exercised by this
change. Homebrew remains at 0.16.0; the fixed executable is the local build.

### Test-runner boundary (2026-11-15)

`make test` built successfully but stalled before XCTest tests started.
A process sample showed `XCTestDriver._prepareTestConfigurationAndIDESession`
waiting on an `XCTFuture`; the next XCTest bundle stalled at startup too.
The run was terminated, so `make test` is not a pass. The formatter's
`status: success` described build output, not completion of that run.

`swift test --skip-build --disable-xctest --enable-code-coverage` then passed
all 1,254 Swift Testing tests in 14.379 seconds. XCTest-based suites remain
unverified in this Xcode 27.2 environment. No test-runner code was changed.

### Portrait single-display regression (2026-11-15)

Tested the booted iPhone 18 Pro on iOS 27.2 with Xcode 27.2. CoreDevice
reported one integrated LCD, `rot0`, and a separate virtual Resizable display.
The virtual display does not satisfy `isMultiDisplay`.

- `ui` reported Glyphon at 402x874 points.
- Local and system (`simctl io screenshot`) captures were 1206x2622 pixels.
  Both images were inspected: portrait layout and visible content matched.
  Their decoded sRGB mean channel difference was 0.835/255; they were not
  pixel-identical (the text caret also differed between captures).
- Sequential 0.16.0 and fixed-build screenshots had exactly identical
  decoded RGB values across all 3,162,132 pixels.
- All three `ScreenshotTests` passed with the fixed build: explicit file,
  JSON envelope and an existing output directory.

The JSON E2E initially failed only with the local Debug build because
`CommandRunner` appends stderr diagnostics to stdout. The standalone stdout
was valid JSON. The release binary passed the original test. The JSON test
now excludes stderr before decoding, consistent with other JSON E2E commands;
no product JSON or logging behavior changed. The corrected suite passed in
2.087 seconds.

The screenshot implementation changes only the multi-integrated-display
`.main` case. Single-display simulator capture still uses idb; the additional
topology lookup reads the monitor cache. Android and physical-device screenshot
backends, touch, AX and video code are unchanged. Other device families and
older runtimes were not live-tested in this follow-up. Topology-query failure
still uses the previous default-framebuffer fallback.
