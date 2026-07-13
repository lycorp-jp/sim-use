# Tap-family shared OptionGroups and forwarder copy elimination

Plan for issue #42 — consolidate the tap-family flag surface into shared
`OptionGroup`s and remove the forwarder copy hazard. Written before
implementation; sections marked *(plan)* describe intended work, not
shipped behavior. Prerequisites #40 (`tap --point`) and #41 (`android tap`
direct-init trap) are both merged.

## Problem

Three surfaces declare the same ~15 tap flags by hand, and the top-level
forwarders bridge them by constructing the backend command via its empty
`init()` and assigning every property individually:

| Surface | File | Role |
|---|---|---|
| `sim-use tap` | `Sources/SimUse/Commands/Tap.swift` | cross-platform forwarder (19-field copy in `executeIOSSim`) |
| `sim-use long-press` | `Sources/SimUse/Commands/LongPress.swift` | same copy block with `duration` carried through |
| `sim-use ios tap` | `Sources/iOSSimBackend/Verbs/IOSSimTapCommand.swift` | backend + the actual `execute()` |

A `ParsableArguments` property that is never assigned stays in
wrapper-definition state; the first read traps with ArgumentParser's
*"can't read a value from a parsable argument definition"* fatal — the
failure class of #41. The hazard: add a flag to the shared surface, forget
one `sub.field = field` line, and every existing test stays green. The
parity tests (`flagSurfaceParses`, `pointFlagParsesEverywhere` in
`Tests/TapForwarderTests.swift`) only pin that the same argv *parses* on
every surface; nothing executes the forwarder copy without a live device.

The pattern is repo-wide: **14 construct-and-assign sites across 13
forwarders** (Paste has two paths) — Tap, LongPress, Paste, Screenshot,
Swipe, Type, RecordVideo, MultiTouch, Button, Touch, DescribeUI,
KeyboardState, Gesture.

## Decision history

The issue proposed two layers: shared `OptionGroup`s (structural) plus a
reflection-based forwarder-completeness test (guardrail). A review comment
(@hiSandog) pushed further: the shared group should be *the* parsed value
passed into the backend, not copied into a reconstructed backend command —
and the missing test is one that asserts the backend receives the full
value object.

**Adopted, with one adjustment.** The clincher for the structural point is
in-repo precedent: `AndroidTapCommand.performTap(udid:alias:x:y:selector:duration:multiTouch:controller:)`
already is that pattern — a typed static entry point the forwarder calls
directly, with an injectable `controller` seam that
`androidTapDefaultMultiTouchDoesNotTrap` exercises without a device. The
iOS side gets the same shape. The adjustment: "execute a forwarded command
and assert" cannot run at unit level (the iOS entry point does real HID
dispatch), so real execution stays with the scripted E2E layer
(`make e2e-ios`) and the unit layer asserts at the entry-point boundary
instead. Once forwarders pass whole groups, tap-family completeness is a
compile-time property; the reflection guardrail covers the 13 forwarders
that keep the copy pattern until each is migrated.

## Plan

Three steps, each landable as its own PR, in this order.

### Step 1 — reflection guardrail *(plan)*

Safety net first: it protects both the 13 non-migrated forwarders and the
step-2/3 refactor itself.

- `Tests/` gains a generic `assertFullyInitialized(_: some ParsableArguments)`
  helper. It `Mirror`-walks the instance's property wrappers (`Argument`,
  `Option`, `Flag`, `OptionGroup`), recurses into nested
  `ParsableArguments`, and fails on any wrapper whose internal
  `_parsedValue` is still in `definition` state.
- **Fail closed:** an unrecognized wrapper shape (e.g. after an
  ArgumentParser upgrade renames internals) is a test *failure*, never a
  silent pass — the guard cannot rot into a no-op. The dependency is
  version-pinned, so this fires loudly at upgrade time, which is the
  acceptable trade-off for peeking at internals.
- Each forwarder's construct+copy block is extracted into a testable
  `makeIOSSubcommand()` (pure, no device access), and each forwarder gets
  one test: parse **any valid argv** → `makeIOSSubcommand()` →
  `assertFullyInitialized`. A maximal argv is neither possible (tap's
  targeting flags are mutually exclusive, and `parse` runs `validate()`)
  nor needed: parsing initializes *every* wrapper — absent flags land in
  their nil/default `.value` state — so a forgotten `sub.field = field`
  line stays in `.definition` state regardless of what the argv
  contained. Because `Mirror` enumerates whatever wrappers actually
  exist, future fields are covered automatically — no manual field list
  that can itself be forgotten.
- **Known limit:** the guard checks initialization, not value fidelity —
  copying from the wrong source field (`sub.pointX = pointY`) passes it.
  Value fidelity stays with the parity tests' field assertions.

### Step 2 — shared OptionGroups *(plan)*

Following the `MultiTouchOptions` / `SwipeCoordinateOptions` /
`DeviceOptions` / `JSONOutputOptions` precedent, two new groups under
`Sources/SimUseCore/Options/`:

- **`TapTargetingOptions`** — `-x`/`-y`/`--point`, the five selectors
  (`--id`/`--label`/`--value`/`--label-contains`/`--label-regex`),
  `--element-type`, `--frame`.
- **`TapTimingOptions`** — `--pre-delay`/`--post-delay`/`--wait-timeout`/
  `--poll-interval`.

`IOSSimTapCommand.validateOptions` splits onto the groups, mirroring
`MultiTouchOptions.validate()`: selector/coordinate/frame exclusivity
rules → `TapTargetingOptions.validate(alias:)` — the alias-conflict and
frame×alias rules cross the group boundary (the positional stays
per-command), so `alias` comes in as a parameter; delay/poll range rules →
`TapTimingOptions.validate()`. The `--duration` range check stays with the
commands that own the flag.

**ArgumentParser (pinned 1.5.0) does not auto-validate option groups** —
only the root command's `validate()` runs (`CommandParser.swift:188`);
the repo already calls `multiTouch.validate()` explicitly for exactly
this reason. Each of the three surfaces must call the group validators
from its own `validate()`; forgetting one silently drops validation on
that surface while parsing still succeeds. The validation-parity tests
below exist to catch precisely this failure mode.

Deliberate per-command leftovers (the exceptions need a reason; this is
it):

- **`--duration`** — differs between `tap` (nil default, latency-focused
  help) and `long-press` (0.8 default, threshold-focused help).
- **`alias` positional** — stays per-command by default (verb-specific
  help wording). Whether it joins the group is decided in the same
  golden-file diff review that pins the ordering delta below.

**Known surface deltas** (accepted, pinned by the help golden-file diff):

1. *Wording* — the issue's scope note says help text must not change, but
   `Tap` and `LongPress` currently word their flag help by verb ("Tap the
   center…" vs "Long-press the center…"). Sharing a group forces one
   wording; it becomes verb-neutral ("Target the element matching
   AXLabel…") rather than being worked around with generic help
   parameterization.
2. *Ordering* — `--duration` currently renders between `--post-delay` and
   `--wait-timeout` in help output; with the timing flags grouped and
   `--duration` per-command it must move relative to the group block.
   Grouping reorders the help listing; the diff review checks
   flag-by-flag content, not position.

Flag names, defaults, validation messages, and `--json` envelopes remain
byte-identical.

### Step 3 — tap-family executor entry point *(plan)*

Mirror the Android shape on the iOS side:

```swift
extension IOSSimTapCommand {
    public static func performTap(
        alias: String?,
        targeting: TapTargetingOptions,
        timing: TapTimingOptions,
        duration: Double?,
        multiTouch: MultiTouchOptions,
        device: DeviceOptions,
        json: JSONOutputOptions
    ) async throws -> ExecutionResult
}
```

- `IOSSimTapCommand.execute()` becomes a thin call passing its own parsed
  values — `sim-use ios tap` behavior unchanged.
- `Tap.executeIOSSim` / `LongPress.executeIOSSim` call `performTap`
  directly. **The construct-and-assign block is deleted for the tap
  family**; no `IOSSimTapCommand` instance is ever hand-built, so the
  uninitialized-wrapper state cannot exist on this path.
- The step-1 guardrail tests for `Tap`/`LongPress` are deleted together
  with the copy code they guard.
- The daemon path is unaffected: the daemon re-parses argv in its own
  process, so execution always starts from a properly parsed instance.

New group fields now appear on every surface and flow through forwarding
with zero forwarder edits; the residual risk is confined to the two
explicit loose parameters (`alias`, `duration`), which are visible in the
function signature rather than buried in a 19-line copy block.

## Testing

| Layer | What | When |
|---|---|---|
| Existing parity tests | same argv parses on all surfaces (`flagSurfaceParses`, `pointFlagParsesEverywhere`) | keep, unchanged |
| Step-1 guardrail | valid argv → `makeIOSSubcommand()` → `assertFullyInitialized`, per forwarder | new; tap-family cases retired in step 3 |
| Validation unit tests | move with the logic onto `TapTargetingOptions` / `TapTimingOptions`; error messages pinned byte-identical | step 2 |
| Validation-parity tests | table-driven: same invalid argv → same `ValidationError` text on all three surfaces (catches a surface that forgot to call a group validator) | step 2, new |
| Help output check | capture `--help` for `tap` / `long-press` / `ios tap` before step 2; diff after — only the two documented deltas (verb-neutral wording, group reordering) may appear | step 2 |
| Scripted E2E | `make e2e-ios` exercises real forwarded execution (HID dispatch) — this is where the comment's "execute a forwarded command" lives | before each PR merge |
| Live spot-check | `tap @N`, `long-press --label …`, `tap --point x,y` on a booted simulator | per CLAUDE.md verification baseline |

Each step must pass `make build` + `make test` standalone. CHANGELOG:
one `### Changed` entry under `[Unreleased]` when step 2 lands (help
wording unification is the only user-visible delta); steps 1 and 3 are
internal.

## Scope notes

- **`AndroidTapCommand` stays out of the shared targeting group** — it
  takes Int pixel coordinates and has Android-only `--value-contains` /
  `--value-regex`. Whether it later shares the group with extras alongside
  is a separate decision.
- Pre-existing inconsistency, noted but not fixed here: the top-level
  `tap` forwarder hardcodes `valueContains: nil, valueRegex: nil` when
  building `AndroidSelector`, so those selectors exist only on
  `sim-use android tap`.
- The other 13 forwarders keep construct-and-assign + guardrail;
  migrating each verb to an executor entry point is follow-up work,
  verb-by-verb, in separate issues.

## Open items

- Decide during step 2 whether `alias` joins `TapTargetingOptions`
  (folded into the help golden-file diff review).
- File follow-up issues for executor-pattern migration of the remaining
  verbs once the tap family proves the shape.
- Consider whether `TapTimingOptions` fits any Android verbs when the
  Android grouping question is revisited.
