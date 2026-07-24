---
name: run-evals
description: Prepare the environment and run the LLM-driven agent evals (e2e/agent-evals/) against a chosen sim-use binary. Use when the user runs `/run-evals` or asks to "run the agent evals", "run the LLM-driven tests", "eval the skill", or wants pre-release confidence that an agent reading the bundled skill still picks the right verbs. Costs real `claude -p` API calls — always confirm before spending.
---

This skill orchestrates the agent-eval suite: natural-language cases executed
by a headless `claude -p` agent using the bundled skill (`skills/sim-use/`)
against the Playground fixture apps, judged by deterministic post-condition
checks. It verifies the layer the scripted E2E suites cannot: that an agent
reading SKILL.md reaches for the right verbs and survives the documented
pitfalls. A failure here with a green scripted layer usually means
skill-prose drift, not a CLI bug.

Execution is delegated to `scripts/eval.sh` / `e2e/agent-evals/run.py` — do
not reimplement their logic. Case anatomy, tags, and authoring rules live in
`e2e/agent-evals/README.md`. Run from the repo root.

## Step 1: Decide WHICH sim-use is under test

The whole run — device probing, the agent's commands, the verification layer
— resolves `sim-use` from PATH unless overridden. Never let this be implicit:

1. Ask (or infer from the user's request) which binary to evaluate:
   - **Installed release** (default): whatever `sim-use` resolves to on PATH.
   - **A development build**: pass `-b <path>`, e.g.
     `-b .build/out/Products/Debug/sim-use` (SwiftBuild layout) or
     `-b .build/debug/sim-use` (classic). Build it first with `make build`.
2. Confirm the resolution and report it to the user before running:
   ```bash
   python3 -c 'import pathlib,shutil; print(pathlib.Path(shutil.which("sim-use")).resolve())'
   sim-use --version
   ```
   The wrapper prints `sim-use under test: <real path> (<version>)` and the
   run report records it under `sim-use under test:` — quote that line back
   in your summary so the human knows exactly what was evaluated.

## Step 2: Prepare devices and fixtures

For each platform you intend to cover (the wrapper auto-detects reachable
ones; use `-p ios|android` to restrict):

**iOS**
1. Device Hub (Xcode 27) must be CLOSED — `pgrep dtuhidd` must be empty. A
   simulator booted while Device Hub is open has legacy HID disconnected;
   sim-use's guard will (correctly) fail every case on it. If dtuhidd is
   running: quit Device Hub, then shutdown && boot the simulator.
2. Boot a simulator and wait: `xcrun simctl boot <UDID> && xcrun simctl bootstatus <UDID>`.
3. The Playground fixture must be installed. Check:
   `xcrun simctl listapps <UDID> | grep -c com.cameroncooke.SimUsePlayground`
   — if missing, install with `scripts/test-runner.sh -b` (builds sim-use +
   Playground, ~2-3 min).

**Android**
1. Start an emulator (not on PATH by default:
   `~/Library/Android/sdk/emulator/emulator -avd <AVD> &`), wait for
   `adb shell getprop sys.boot_completed` → `1`.
2. Both fixture packages must be present:
   `adb shell pm list packages | grep -c com.linecorp.simuse` should be 2
   (playground + device bridge). If missing, `make e2e-android` installs them.
3. A stale bridge from an older CLI version is fine — the version parity
   check fires and the agent is expected to recover via `sim-use android
   init` (that recovery is itself part of what the evals exercise).

## Step 3: Run

```bash
make eval                                  # quick tag, every reachable platform, asks before spending
make eval ARGS="-y -t quick"               # skip the cost prompt (release-gate style)
make eval ARGS="-p ios -b .build/out/Products/Debug/sim-use"   # dev build, one platform
scripts/eval.sh -- --cases <id>            # a single case (raw run.py args)
```

Cost: each case is a real `claude -p` agent (~1-3 min, real API charge; the
wrapper prints an estimate and asks unless `-y`). Never pass `-y` without the
user having approved the spend in this conversation.

## Step 4: Interpret and report

Reports land in `e2e/agent-evals/reports/<timestamp>/` (gitignored):
`report.md` (verdict table + env header), `verdicts.jsonl`, and one
stream-json transcript per case.

- **All PASS** → report the verdict table, the `sim-use under test` line, and
  the report path.
- **FAIL** → read the case's transcript before concluding anything. Classify:
  1. *Skill-prose drift* — the agent picked a wrong verb or missed a
     documented pitfall the skill should have steered around → fix
     `skills/sim-use/SKILL.md`, not the case.
  2. *CLI regression* — the right verb failed → treat as a product bug;
     reproduce it directly with sim-use before filing.
  3. *Environment/fixture noise* — reboot-settling, Playground missing,
     Device-Hub-poisoned boot → fix the environment and re-run; if the
     coupling is inherent, tag the case `fragile` (fragile-tagged cases never
     gate a run).
- **ERROR** → the harness itself broke (reset failed, `claude` missing);
  fix the environment, don't touch cases.

## Things to NOT do

- Don't run evals without stating which binary is under test.
- Don't pass `-y` unless the user already approved the cost.
- Don't edit or delete eval cases to make a run green — a red case is signal;
  classify it first (Step 4).
- Don't commit anything under `e2e/agent-evals/reports/` (gitignored on
  purpose).
