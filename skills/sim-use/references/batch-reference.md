# sim-use Batch Reference

Use this reference when generating or reviewing `sim-use ios batch` commands.

## Supported step commands
- `tap`
- `swipe`
- `gesture`
- `touch`
- `type`
- `button`
- `key`
- `key-sequence`
- `key-combo`
- `sleep <seconds>` (batch pseudo-step)

## Batch flags
- `--device <UDID>`: required simulator target.
- `--step "..."`: repeatable inline step source.
- `--file <path>`: read one step per line from file.
- `--stdin`: read one step per line from stdin.
- `--continue-on-error`: keep running after a failed step; report failures at end.
- `--ax-cache perBatch|perStep|none`: selector tap AX snapshot reuse policy. `perBatch` (default) resolves every selector against one snapshot fetched at first use; `perStep` refetches at each step; `none` never caches. `--wait-timeout` polling always refetches (and updates the cache).
- `--type-submission chunked|composite`: submission mode for `type` steps.
- `--type-chunk-size <n>`: chunk size when using chunked submission.
- `--wait-timeout <seconds>`: maximum seconds to poll for selector-based elements before failing (0 = no waiting, default).
- `--poll-interval <seconds>`: seconds between accessibility tree polls when `--wait-timeout` is active (default 0.25).
- `--verbose`: enable detailed stderr logs for troubleshooting (default quiet output).

## Input rules
- Use exactly one source: `--step` OR `--file` OR `--stdin`.
- Empty lines are ignored.
- `#` comment lines are ignored in file/stdin input.
- Do not pass `--device` inside step lines; keep it at batch command level.

## Example: inline steps
```bash
sim-use ios batch --device SIMULATOR_UDID \
  --step "tap --id EmailField" \
  --step "type 'cam@example.com'" \
  --step "key 43" \
  --step "type 'super-secret'" \
  --step "key 40"
```

## Example: stdin steps
```bash
cat <<'EOF' | sim-use ios batch --device SIMULATOR_UDID --stdin
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
EOF
```

## Example: file steps
`login.steps`
```text
# login flow
tap --id EmailField
type 'cam@example.com'
key 43
type 'super-secret'
key 40
```

Run:
```bash
sim-use ios batch --device SIMULATOR_UDID --file login.steps
```

## Example: explicit timing and policy
```bash
sim-use ios batch --device SIMULATOR_UDID \
  --ax-cache perStep \
  --type-submission chunked \
  --type-chunk-size 150 \
  --continue-on-error \
  --step "tap --label Settings" \
  --step "sleep 0.5" \
  --step "tap --id SaveButton"
```

## Example: multi-screen flow with element waiting
```bash
sim-use ios batch --device SIMULATOR_UDID \
  --wait-timeout 5 \
  --step "tap --id LoginButton" \
  --step "tap --id WelcomeMessage"
```

The second step polls for up to 5 seconds for `WelcomeMessage` to appear after the login tap triggers navigation.

If label selectors are ambiguous and sim-use reports no `AXUniqueId` values for matches, switch that step to coordinates (`tap -x/-y`).
