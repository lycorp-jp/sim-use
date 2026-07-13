# Agent evals

Natural-language eval cases for the **bundled agent skill**
(`skills/sim-use/`), run by a headless agent (`claude -p`) against the
Playground fixture apps. Deterministic post-condition checks decide PASS/FAIL
— the agent's own success claim is recorded but never trusted.

The scripted E2E suites (`make e2e-ios`, `make e2e-android`, or `make e2e` for
both) verify that each CLI verb works; this layer verifies the piece those
suites cannot: that an agent
reading SKILL.md actually reaches for the right verbs and survives the
documented pitfalls (US-ASCII `type` vs `paste`, alias staleness, scroll
direction semantics, daemon hiccups). A failure here with a green scripted
layer usually means skill-prose drift, not a CLI bug.

## Running

Easiest — `make eval` checks the environment, prints a cost estimate, and
asks before spending anything (each case makes real `claude -p` API calls):

```bash
make eval                                   # quick-tagged cases on every reachable platform
make eval PLATFORM=ios TAGS=release         # one platform / tag
make eval ARGS="-y -p android"              # -y skips the prompt (CI / release gate)
```

Prereq the wrapper reminds you about: the Playground fixture must be installed
(`scripts/test-runner.sh -b` for iOS; `make e2e-android` for Android).

Or call the runner directly for full control:

```bash
python3 e2e/agent-evals/run.py --platform ios --tags quick
python3 e2e/agent-evals/run.py --platform android --device emulator-5554
python3 e2e/agent-evals/run.py --list
```

Reports land in `e2e/agent-evals/reports/<timestamp>/` (gitignored):
`report.md`, `verdicts.jsonl`, one stream-json transcript per case.

## Case anatomy

`cases/<platform>/<id>.json`:

- `precondition.screen` — the runner deep-links the Playground there before
  the agent starts (cheap, focused). Omit it to make navigation part of the
  task.
- `instruction` — user intent only; never name verbs or element ids (verb
  choice is what's being evaluated). `{device}` / `{artifacts}` are
  substituted.
- `verify` — end-state checks re-queried from the device after the agent
  exits: `element_exists`/`element_absent` (by `id`, `label_contains`, or
  `outline_regex`), `element_selected`, `label_of`, `app_foreground`,
  `file_exists`, `transcript_regex`, `shell`.
- Tags: `quick` (smoke subset) / `release` (pre-release set).

Gotcha: several original Playground screens set a screen-level
`.accessibilityIdentifier` on their root view, which clobbers child
identifiers — assert those screens via `outline_regex` on label text, not by
child id.

## Adding cases

Prefer one behavior per case, an exact expected count/string in the fixture
(“Tap Count: 3”), and `transcript_regex` when the path matters (e.g. the agent
must have used `paste`, or a single `ios batch` invocation). Keep instructions
platform-neutral where the same behavior exists on both platforms.
