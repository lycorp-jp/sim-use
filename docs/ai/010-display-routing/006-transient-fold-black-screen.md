# 010.006 — Transient Duo black screen during display switching

## Context

Observed on 2026-11-19 during verification for 0.16.1. The Duo used iOS 27.1
(24A94425), with Xcode 27.1 runtime tools. The current CLI was built with
Xcode 27.0 at `ec6b43a`. The installed 0.16.0 CLI was also checked.

The failure occurred before the final screenshot in
`FoldTests.screenshotFoldTransitions`. It is separate from the wrong-framebuffer
capture fixed in [005-cover-screenshot.md](005-cover-screenshot.md).

## Observations

| Check | Result |
| --- | --- |
| Automated closed, open, closed sequence | The final close timed out. CoreDevice still reported the inner display as active and the cover as inactive. |
| Independent `devicectl device info displays` query | Confirmed the inner-display state reported by sim-use. This did not establish whether the visible image was valid. |
| Original device, daemon restart, and a new Duo device | The same close timeout occurred. A cold boot could restore the cover, but did not make the complete sequence reliable. |
| Installed 0.16.0 CLI on the original device | Also failed to confirm the cover after a close. The fold-control implementation was unchanged in the pending release. |
| Simulator window open, with the maintainer watching | The maintainer saw a black screen after the CLI close timed out. |
| Manual controls | The maintainer also saw a black screen at first. After unfolding, opening Safari, and folding again, switching worked. It then also worked from Home. |
| CLI close after that manual recovery | Passed with `confirmed: true`. CoreDevice reported the cover active and the inner display inactive. A 1398x2034 screenshot showed the Home screen without a black image. |
| Automated sequence after the manual recovery | Failed again with the same close timeout. The separate `ScreenshotTests` selection passed all 10 tests. |

Step-by-step captures before and after recovery also showed a valid cover image
at 1398x2034 and a valid inner image at 2853x2007. A successful capture in one
state does not prove that the transition to the other state works.

The earlier runtime-path error was resolved by unmounting and scanning the
existing iOS 27.1 runtime image. The display-switch failure remained after
that repair. No device content was erased.

## Reproduction

Use the selected Xcode's runtime tools and a booted Duo. `UDID` below is the
target simulator identifier. Do not add an app launch between the steps when
comparing with the original observation.

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1.0.app/Contents/Developer
SIM_USE=.build/out/Products/Debug/sim-use

"$SIM_USE" ios fold closed --device "$UDID" --json
"$SIM_USE" screenshot --device "$UDID" --output /tmp/duo-cover-before.png
"$SIM_USE" ios fold open --device "$UDID" --json
"$SIM_USE" screenshot --device "$UDID" --output /tmp/duo-inner.png
"$SIM_USE" ios fold closed --device "$UDID" --json
xcrun devicectl device info displays --device "$UDID" --json-output - --quiet
```

The failed command reported:

```text
Sent hinge 0° ... but the primary display did not become active within 6 s
(inner display active; landscape-left).
```

The automated check was run with:

```bash
SIMULATOR_UDID="$UDID" make e2e-ios-duo \
  ARGS='FoldTests/screenshotFoldTransitions ScreenshotTests'
```

Local logs are retained under `dist/release-validation-v0.16.1-20261119/`.
Interactive captures are under `.build/release-validation/v0.16.1/live-duo/`.
These local artifacts are not committed.

## Assessment

An iOS or Simulator display-switch issue is plausible: the manual controls
also failed, the prior release showed the same CLI failure, and normal
operation returned without a sim-use code change. The root cause is not
established. These observations do not rule out the shared HID/CoreDevice
path or prove that opening Safari caused the recovery.

The vendor-report timing observations in E53–E56 of
[000-plan.md](000-plan.md) are related evidence, not proof of the same cause.
An active-display flag alone must not be described as a healthy visible image.

## Decision

- Retain this as an observation for further investigation.
- Do not change fold, screenshot, or retry behavior from this evidence alone.
- Defer a skill pitfall and any app-opening step in verification until more
  observations establish when they are needed and what they change.
- Continue the 0.16.1 release with the maintainer's acceptance of this known
  display-switch failure. Preserve the red test result; this is a release
  exception, not a passing test or a permanent gate waiver.

## Open questions

- Does the failure depend on transition timing, the foreground app, first-use
  state, or the Simulator/Device Hub host?
- Does opening an app cause recovery, or did another state change or elapsed
  time allow the next transition to work?
- Does the same behavior occur on other Duo runtime builds?
- Should repeated evidence lead to a user pitfall, an explicit verification
  setup step, or a change in sim-use?
