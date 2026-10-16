# docs/ai — design and decision records

This directory records how sim-use is built and why. Each numbered folder holds
one topic: the plan or investigation that came before the work, and the
decisions and results that came after it. Humans and agents read it to answer
"why is it built this way?" without a search through git history.

sim-use uses AI-docs-driven development: a substantial change starts with a
record here, and a decision is written down when it is made. The rules are in
the `write-ai-docs` skill (`.agents/skills/write-ai-docs/SKILL.md`).

## Structure

```
docs/ai/NNN-<slug>/
  000-plan.md            # before the work: background, goals, approach, alternatives
                         # (000-investigation.md when the work starts as a root-cause hunt,
                         #  000-design.md for a backfilled or design-only record)
  001-action.md          # after the work: what shipped, PRs, deviations from the plan
  002-<topic>.md         # amendments: follow-up work, review rounds, corrections
                         # (a design or investigation record that already holds its outcome
                         #  has no action log; its amendments start at 001)
  <name>.md              # no number = living document (guide, runbook, contract), kept current
```

- Numbers are three digits, in the order the topics started, and are never
  reused.
- A numbered file records what was true when it was written. When a later
  finding makes it wrong, add a dated note at the top or in **Amendments**
  that says what changed and where. Do not silently rewrite history.
- A file without a number is a living document. Update it in place when the
  behavior it describes changes.
- `README.md`, `AGENTS.md` and `skills/sim-use/` describe current behavior for
  users and agents. History and decisions go here.

## Index

| # | Entry | Anchor | Topic |
| --- | --- | --- | --- |
| 001 | [daemon-and-hid-lifecycle](001-daemon-and-hid-lifecycle/000-design.md) | 2026-06-05 | Per-device daemon: no double delivery, idle timer, boot-identity and transport-window gates on HID reuse, version and connection-identity gates. Amendment: [HID from short-lived processes on dtuhidd](001-daemon-and-hid-lifecycle/001-dtuhidd-short-lived-clients.md) (#154) |
| 002 | [ios-orientation-self-calibration](002-ios-orientation-self-calibration/000-design.md) | 2026-07-08 | AX-to-HID coordinate calibration for rotated simulators (#34, #38; downscaled devices #90, #92). Amendment: [gesture presets and `--coordinate-space`](002-ios-orientation-self-calibration/001-gesture-presets-and-coordinate-space.md) (#73, #74, #144) |
| 003 | [e2e-confidence-suite](003-e2e-confidence-suite/000-design.md) | 2026-07-11 | Layered E2E and agent-eval suites, gating model, pre-release checklist |
| 004 | [tap-optiongroup-consolidation](004-tap-optiongroup-consolidation/000-plan.md) | 2026-07-13 | Shared OptionGroups for the tap family; no more field-by-field forwarder copies |
| 005 | [video-capture-stack](005-video-capture-stack/000-design.md) | 2026-07-17 | H.264 capture for `record-video` and `stream-video`, the `SimUseVideo` boundary, MPEG-TS, the stdout sink, GIF export |
| 006 | [xcode27-support](006-xcode27-support/000-investigation.md) | 2026-07-22 | Xcode 27 / dtuhidd investigation, SimulatorKit path fix, idb bump migration |
| 007 | [physical-ios-device-backend](007-physical-ios-device-backend/000-design.md) | 2026-08-10 | Physical iPhones and iPads over the accessibility audit daemon, devicectl screenshots, capability model, top-level routing |
| 008 | [linux-android-build](008-linux-android-build/000-design.md) | 2026-09-11 | Android-only Linux build, remote adb servers, connection-scoped daemon. Living guide: [linux-guide.md](008-linux-android-build/linux-guide.md) |
| 009 | [resizable-app-session](009-resizable-app-session/000-investigation.md) | 2026-10-09 | Xcode 27 Resize Mode: root cause, tier-1 guard (#150), path to real touch routing |
| 010 | [display-routing](010-display-routing/000-plan.md) | 2026-10-16 | Route touch, AX and screenshots to the display that hosts the app (iPhone Duo inner display, Resize Mode #143); fold and rotate verbs; side-rail outline regions (planned) |

## History

On 2026-10-14 the entries were numbered by the date their topic started.
`002`, `003`, `004`, `006` and `009` were first written as
`docs/ai/xxxx-<slug>/README.md`. `008` combines the former `docs/linux.md`
(now [linux-guide.md](008-linux-android-build/linux-guide.md)) with a design
record backfilled from #141 and #147. `001`, `005`, `007` and the amendment
`002/001` were backfilled on the same day from pull requests, issues, the code
and `CHANGELOG.md`; each backfilled file says so at the top.
