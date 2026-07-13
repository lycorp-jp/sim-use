# E2E confidence suite

Pre-release tests that verify **sim-use itself** — the CLI and the bundled
agent skill — against live devices. The Playground apps are controlled
fixtures whose only job is to echo input back as assertable accessibility
state; they are not the subject under test.

## Layers

| Layer | What it verifies | Fixture | Run with |
|---|---|---|---|
| Unit (`make test`) | parsing, dispatch, protocol — no device | fixtures/golden files | CI + local |
| iOS scripted E2E | every iOS verb/argument surface | `Playgrounds/iOS` | `make e2e-ios` (~15 min) |
| Android scripted E2E | every Android verb surface + bridge | `Playgrounds/Android` | `make e2e-android` |
| Agent evals | skill prose + agent-in-the-loop usability | Playground apps | `e2e/agent-evals/run.py` |

The scripted layers are deterministic and gate releases. The agent-eval layer
runs a headless `claude -p` with the OSS skill against natural-language
instructions and verifies end state deterministically — it catches
SKILL.md drift and agent-facing usability regressions that unit-level tests
cannot (wrong verb steering, stale examples, missing pitfalls).

## Gating model

E2E suites compile always and skip unless enabled — the established pattern:

- iOS: `SIM_USE_E2E=1` + `SIMULATOR_UDID` (`Tests/TestUtilities.swift`,
  `@Suite(.serialized, .enabled(if: isE2EEnabled))`)
- Android: `SIM_USE_E2E_ANDROID=1` + `ANDROID_SERIAL`
  (`Tests/AndroidTestSupport.swift`)

`scripts/test-runner.sh` (iOS) and `scripts/test-runner-android.sh` (Android)
run suites one-by-one to avoid device contention, keep going past failures,
and print a full pass/fail map (a release gate needs the whole picture, not
the first crash).

## History note

The iOS E2E suites existed since early versions but rotted invisibly: when
0.5.x moved the five iOS-only verbs under the `ios` namespace, four suites
(Key, KeyCombo, KeySequence, StreamVideo) kept invoking top-level forms and
failed forever after; the runner also aborted at the first failure and its
hardcoded list had drifted (missing suites, one misspelled so it silently ran
zero tests). That is the failure mode this suite's structure now defends
against: run everything, report everything, and keep the suite list honest.

## Coverage matrix

When adding or changing a verb, extend:

1. The platform E2E suite(s) for the verb (`Tests/<Verb>Tests.swift`,
   `Tests/Android<Verb>Tests.swift`) — cover each selector/argument family,
   not just the happy path.
2. A Playground surface that makes the effect observable (a counter or echo
   label), if none exists.
3. The suite list in the matching test-runner script.
4. README + `skills/sim-use/SKILL.md` (already required by CLAUDE.md).

Error-path coverage counts: e.g. Android `paste` asserting the documented
clipboard-restriction hint, batch `--continue-on-error` semantics, daemon
stop → transparent restart.

## Agent evals (`e2e/agent-evals/`)

Same case schema and verification approach as the (internal) LINE eval suite:
JSON cases with a natural-language `instruction` and machine-checkable
`verify` blocks; a throwaway workdir gets the repo's `skills/sim-use/`
installed; PASS/FAIL comes from re-querying the device after the agent
finishes, never from the agent's own claims. See `e2e/agent-evals/README.md`.

## Pre-release checklist

```bash
make test          # unit
make e2e           # iOS + Android scripted E2E in sequence (~20+ min; iOS alone ~15 min)
# (make e2e-ios / make e2e-android to run one platform)
python3 e2e/agent-evals/run.py --tags quick   # agent smoke
```
