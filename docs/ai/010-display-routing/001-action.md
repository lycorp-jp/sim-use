# 010 — Display routing (iPhone Duo, Resize Mode, rotate, UI coordinates): Action log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-16 | S1: display topology from `devicectl device info displays`, `RoutingDisplay`, `ios fold`, `ios rotate`, honest refusals off the main display, screenshot of the routing display, skill floor 0.16.0 | #157 |
| 2026-10-16 | S2: touch input and AX hit-tests routed to the display that hosts the app (idb patch `display-routing.patch`), fixed calibrations off the main display, scene placement of inset scenes; closes #143 | #158 |
| 2026-10-16 | S3: explicit iOS coordinates default to UI space; `--coordinate-space native` opt-out; snapshot-first calibration confirmed by probes and the live root size | #161 |
| 2026-10-17 | CI: the macOS unit job hung from S3 on (a batch parsing test reached CoreSimulator); fixed on S3 and merged up the stack | #161 (`e0db3a6`) |
| 2026-10-17 | S4: evidence-gated `Trailing` / `Leading` outline regions for the iOS 27.1 SDK vertical bar; Playground `chrome-test` screen | #163 |
| 2026-10-17 | S5: `record-video` / `stream-video` capture the routing display (idb patch `display-video.patch`), packed BGRA rows | #164 |
| 2026-10-17 | S6: Device Hub closed — HID connection rebuilt once `dtuhidd` runs, routed touch starts `dtuhidd`, shared session connection; viewer output race and #162 test fixed | #165 |
| 2026-10-17 | S4 acceptance with a signed-in LINE (E57): a segmented control in an app header above a leading bar no longer hides the bar | #163 (`72954ac`), merged into #164 and #165 |
| 2026-10-17 | Device-Hub-open regression of S6: fold / rotate send a report once more when it had no effect, rotate waits for the interface too (E53–E56); the S6-001 batch E2E no longer taps the software keyboard | #165 |

All six PRs are one GitHub stack (#159), each based on the previous branch. Every PR had a review loop: S1 four rounds, S2 four (clean), S3 two (clean), S4 four (not clean only because a signed-in LINE check was blocked; done later, E57), S5 two (clean), S6 four (clean).

## Outcome (as of 2026-10-17)

- **Topology and posture:** `Sources/iOSSimBackend/Sim/SimulatorDisplayTopology.swift` reads the integrated and virtual displays; `Sources/iOSSimBackend/Sim/RoutingDisplay.swift` resolves the routing display (main, secondary, Resize Mode) and its HID route, fixed calibration and capture source. `sim-use ios fold` and `sim-use ios rotate` (`Sources/iOSSimBackend/Verbs/IOSSimFoldCommand.swift`, `IOSSimRotateCommand.swift`) send vendor-defined reports to `dtuhidd` (`Sources/iOSSimBackend/HID/VendorDefinedHID.swift`) on the iPhone Duo and a Purple GSEvent on single-display simulators.
- **Touch and AX:** `Sources/iOSSimBackend/HID/HIDInteractor.swift` routes each touch event to the routing display's digitizer; `Sources/iOSSimBackend/A11y/AccessibilityFetcher.swift` and `OrientationCalibrator.swift` run hit-tests on the routing display, take the orientation from CoreDevice off the main display and place inset scenes by probes. The idb changes are in `patches/idb/display-routing.patch`.
- **Coordinates:** `Sources/SimUseCore/CoordinateSpace.swift` — UI space is the default for every iOS verb with explicit coordinates; UI-space calibration tries the `describe-ui` snapshot first and uses it only when the live root size fits and probes confirm its elements (`UISpaceCalibrationLoader` in `Sources/iOSSimBackend/A11y/GestureOrientationMapping.swift`).
- **Outline:** `Sources/iOSSimBackend/Normalizer/OutlineSideBars.swift` detects the vertical bar; `OutlineFormatter.swift` lists it after the bands. Fixtures: `Tests/Fixtures/outline-side-bars/`. Playground screen: `Playgrounds/iOS/SimUsePlayground/Views/ChromeTestView.swift`.
- **Video:** `Sources/iOSSimBackend/Util/FBSimulator+CaptureSource.swift` and the idb patch `patches/idb/display-video.patch` (framebuffer port by pixel size, source crop, packed BGRA rows).
- **Lost posture reports:** `PostureController` sends a hinge or orientation report once more when the read-back shows no effect (`FoldExpectation.reportHadNoEffect`, `RotationPlanner.reportHadNoEffect` in `Sources/iOSSimBackend/Sim/DevicePosture.swift`); a rotation is the answer at once only when both the device orientation and the interface reached the target (`RotationPlanner.readBackSettled`).
- **Device Hub closed:** the HID connection cache records its transport and rebuilds an auto-selected Indigo connection once `dtuhidd` runs; routed touch starts `dtuhidd` through its XPC service; `HIDInteractor.Session` shares its connection by reference.

## Verification

Results produced during the work (details per slice in the PRs and in the plan's evidence tables E29–E52):

- `make test`: 1693 passed, 0 failed, three consecutive runs on the S6 head; 1698 passed after the posture fix.
- iPhone 17 / iOS 27.0, `make e2e-ios`: 29/29 with Device Hub quit (S6). With Device Hub reopened on the S6 head `50670a7`: 27/29 — `PasteTests` `--via-menu` (Device Hub overwrites the pasteboard, #153) and `ResizeModeTests.batchKeepsUpgradedConnection`, whose last tap hit the `g` key of the software keyboard that Device Hub shows (the field read `s6b782xg`; test fixed).
- iPhone Duo / iOS 27.1, `make e2e-ios-duo` (Playground built with Xcode 27.1, side bar required): 7/7 with Device Hub quit (second run; see open questions). With Device Hub reopened on `50670a7`: 5/7 — the same batch test, and `FoldTests.rotateInnerDisplay` (`ios rotate portrait` right after `fold open` left the interface landscape-left; E53–E56).
- After the posture fix, Device Hub open: `ResizeModeTests` on iPhone 17 and `FoldTests`, `RotateTests`, `ResizeModeTests` on the Duo all passed; the full `make e2e-ios-duo` then passed 7/7. `ios rotate` latency 3.4–3.9 s before and after (12 runs each).
- New E2E suites: `UICoordinateDefaultTests`, `SideBarOutlineTests`, `RoutedVideoTests`, plus new cases in `ResizeModeTests` and `FoldTests`. They were also run on iPhone 13 mini / iOS 26.5 and iPad Pro 13-inch / iOS 26.5 where relevant.
- Real apps: LINE 26.18.0 (iOS 27.0 SDK, inset scene) and LINE 26.17.0 built with Xcode 27.1 from the early-bird branch, welcome → login → back on both Duo displays; Settings (UIKit) on the cover display. Signed in (27.1 SDK build): home tab → chat tab → a chat → back on the cover (portrait, landscape-right) and the inner display (landscape-left, portrait), side regions checked in all six orientations (E57). After the side-bar fix: `make test` 1700 passed; `SideBarOutlineTests` green on the Duo and iPhone 17.
- GitHub CI green on the S3–S6 heads after the hang fix.

## Deviations from plan

- **S3 orientation source:** the plan said devicectl first. Measured cost made the selector calibration (probes, CoreDevice only when ambiguous) the choice, and the explicit-coordinate path reads the `describe-ui` snapshot first (decision rows S3).
- **S4 acceptance:** checked last, after the stack, when a test account was available (E57); it found the segmented-control case on the cover in landscape-right. iPad goldens were added after review.
- **S4 gating rule:** "anchor outside the top band" did not hold (E40); the final rule is in the S4 decision rows.
- **S5:** capture through an idb patch instead of `simctl recordVideo` (file-only, no `stream-video`); videos keep the panel's native orientation.
- **S6:** works with Device Hub closed instead of refusing; it also fixed a keyboard loss after `fold` / `rotate` that S1 had introduced for Hub-less boots.
- **Outside the plan:** the CI hang (S3 test), the Viewer output race, the #162 test and the lost fold / rotate reports (S1 behaviour, fixed on S6 after the Device-Hub-open regression) were fixed in the stack because they blocked clean verification.

## Open questions

- Plan open questions 3, 6–12 and 15–18 stay as written there (10 is a follow-up: CoreDevice orientation could replace the hit-test calibrator everywhere). Most relevant:
  - 15: `paste --via-menu` coordinates were not verified live with Device Hub open (#153).
  - 17: the `tap @N` alias path still calibrates from the snapshot without the in-place confirmation.
  - 18: partly resolved. Lost reports are sent again; right after an unfold the guest sometimes ignores orientation reports for more than 3 s (E56, 2 of 57 runs), cause unknown.
- Plan open question 1 is resolved by S6 for Device Hub closed. Simulator.app (Xcode 26.x) with an iPhone Duo was not tried.
- Android `fold` / `rotate`: #166.
- Related issues found during the work: #160 (`ui` crash with Control Center open), #162 (fixed in #165), #153 (Device Hub overwrites the pasteboard).
