#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Convenience wrapper for the agent-eval suite (e2e/agent-evals/):
#   1. checks the environment is ready,
#   2. warns that each case spins a real `claude -p` agent (real API cost),
#   3. asks for confirmation (skippable with -y / non-interactive), then
#   4. runs the eval.
#
# Usage:
#   scripts/eval.sh                       # quick-tagged cases on every reachable platform
#   scripts/eval.sh -p ios                # a single platform
#   scripts/eval.sh -p android -t release # a specific tag
#   scripts/eval.sh -y ...                # skip the cost prompt (CI / release gate)
#   scripts/eval.sh -- --cases oss-ios-tap-three-times   # pass raw args to run.py
#
# Env: PLATFORM, TAGS, DEVICE, EVAL_ASSUME_YES mirror the flags (so
# `make eval PLATFORM=ios TAGS=release` works).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$repo_root/e2e/agent-evals/run.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf "${BLUE}ℹ️  %s${NC}\n" "$1"; }
ok()    { printf "${GREEN}✓ %s${NC}\n" "$1"; }
warn()  { printf "${YELLOW}⚠️  %s${NC}\n" "$1"; }
die()   { printf "${RED}✗ %s${NC}\n" "$1" >&2; exit 1; }

PLATFORM="${PLATFORM:-}"
TAGS="${TAGS:-quick}"
DEVICE="${DEVICE:-}"
ASSUME_YES="${EVAL_ASSUME_YES:-0}"
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--platform) PLATFORM="$2"; shift 2 ;;
    -t|--tags)     TAGS="$2"; shift 2 ;;
    -d|--device)   DEVICE="$2"; shift 2 ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    --)            shift ;;   # skip a stray separator (e.g. pnpm/make forwards one)
    *)             PASSTHROUGH+=("$1"); shift ;;
  esac
done

# ── 1. environment checks ────────────────────────────────────────────
info "Checking eval environment…"
command -v claude   >/dev/null || die "\`claude\` CLI not found on PATH — the eval agent needs it."
command -v sim-use  >/dev/null || die "\`sim-use\` not found on PATH (build with 'make build' and add .build/debug to PATH, or 'brew install')."
[[ -f "$runner" ]] || die "eval runner missing at $runner"
ok "claude + sim-use present"

# Which platforms have a reachable device? (auto-detect when --platform unset)
devices_json="$(sim-use devices --json 2>/dev/null || echo '{}')"
reachable() {
  python3 - "$1" <<'PY'
import json, sys, subprocess
plat = sys.argv[1]
out = subprocess.run(["sim-use","devices","--json"], capture_output=True, text=True).stdout
try: devs = json.loads(out).get("data",{}).get("devices",[])
except Exception: devs = []
hit = [d for d in devs if d.get("platform")==plat and d.get("state","").lower() in ("booted","device")]
sys.exit(0 if hit else 1)
PY
}

platforms=()
if [[ -n "$PLATFORM" ]]; then
  platforms=("$PLATFORM")
else
  for p in ios android; do reachable "$p" && platforms+=("$p") || true; done
  [[ ${#platforms[@]} -gt 0 ]] || die "no booted simulator / online emulator found — boot one, or pass -p <platform> -d <device>."
  info "Auto-detected reachable platform(s): ${platforms[*]}"
fi

# Playground fixture reminder (the runner errors clearly if it is missing).
warn "The Playground fixture app must be installed on the device:"
warn "  iOS     → scripts/test-runner.sh -b"
warn "  Android → make e2e-android  (builds + installs it)"

# ── 2. cost estimate ─────────────────────────────────────────────────
total=0
for p in "${platforms[@]}"; do
  n="$(python3 "$runner" --platform "$p" --tags "$TAGS" --count 2>/dev/null || echo 0)"
  info "  $p [$TAGS]: $n case(s)"
  total=$((total + n))
done
[[ "$total" -gt 0 ]] || die "0 cases selected for platform(s) '${platforms[*]}' tag(s) '$TAGS' - nothing to run."

hi=$(( total * 2 ))
echo
warn "This runs ${total} agent case(s). Each spins a real \`claude -p\` agent that"
warn "makes live API calls - expect roughly \$1-2 and 1-3 min PER CASE"
warn "(order-of-magnitude ~\$${total}-\$${hi} total). This is a real charge."

# ── 3. confirm ───────────────────────────────────────────────────────
if [[ "$ASSUME_YES" != "1" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "$(printf "${YELLOW}Proceed? [y/N] ${NC}")" reply
    [[ "$reply" =~ ^[Yy]$ ]] || { info "Aborted — no cost incurred."; exit 0; }
  else
    info "Non-interactive shell — proceeding (pass -y to silence this)."
  fi
fi

# ── 4. run ───────────────────────────────────────────────────────────
rc=0
for p in "${platforms[@]}"; do
  echo
  info "Running $p [$TAGS]…"
  args=(--platform "$p" --tags "$TAGS")
  [[ -n "$DEVICE" ]] && args+=(--device "$DEVICE")
  python3 "$runner" "${args[@]}" "${PASSTHROUGH[@]}" || rc=$?
done
exit $rc
