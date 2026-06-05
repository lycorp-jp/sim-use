#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end smoke test for the Android bridge + sim-use CLI.
#
# Walks a short happy-path scenario against a connected emulator /
# device so a code change can't ship a regression that breaks the
# full describe-ui → tap → type → screenshot → button loop.
#
# Pre-conditions:
#   * an Android device or emulator booted, reachable via adb
#   * sim-use built locally at ./.build/debug/sim-use
#   * the bridge APK already installed + accessibility service enabled
#     (run `sim-use android init --udid <SERIAL>` first if not)
#
# Usage:
#   scripts/smoke-android.sh [<serial>]
#
# `<serial>` defaults to the first booted emulator from `adb devices`.
# Exits non-zero on the first failed step so a CI gate can react.
#
# Runtime: < 30s on emulator-5554. Idempotent: safe to re-run.

set -euo pipefail

SIM_USE_BIN="${SIM_USE_BIN:-./.build/debug/sim-use}"
# Prefer the canonical `SIM_USE_ADB` env var (same name the Swift
# side and CLAUDE.md document); fall back to the legacy `ADB_BIN`
# spelling for back-compat with anyone who scripted against an
# earlier version of this file.
ADB_BIN="${SIM_USE_ADB:-${ADB_BIN:-$HOME/Library/Android/sdk/platform-tools/adb}}"

if [[ ! -x "$SIM_USE_BIN" ]]; then
    echo "smoke: sim-use binary not found at $SIM_USE_BIN — run \`swift build\` first" >&2
    exit 2
fi
if [[ ! -x "$ADB_BIN" ]]; then
    echo "smoke: adb not found at $ADB_BIN — set SIM_USE_ADB env var to override" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "smoke: python3 not on PATH — required for the --json envelope check" >&2
    exit 2
fi

# Resolve the serial from $1, $SIM_USE_UDID, or the first booted emu.
SERIAL="${1:-${SIM_USE_UDID:-}}"
if [[ -z "$SERIAL" ]]; then
    SERIAL="$("$ADB_BIN" devices | awk '$2=="device" && $1!="List" {print $1; exit}')"
fi
if [[ -z "$SERIAL" ]]; then
    echo "smoke: no Android device attached; pass <serial> explicitly or boot an emulator" >&2
    exit 2
fi

echo "smoke: target = $SERIAL"
TMP="$(mktemp -d -t simuse-smoke.XXXXXX)"
# Clean up the tmp dir on SIGINT / SIGTERM in addition to normal
# EXIT — otherwise a Ctrl+C mid-step leaks the dir.
trap 'rm -rf "$TMP"' EXIT INT TERM

step() {
    echo
    echo "── $1"
}

fail() {
    echo "smoke: FAIL — $1" >&2
    exit 1
}

# ── 1) ping ────────────────────────────────────────────────────────
step "ping bridge"
PING_OUT="$("$SIM_USE_BIN" android ping --udid "$SERIAL")"
echo "$PING_OUT"
grep -q "pong" <<<"$PING_OUT" || fail "ping did not return pong"
grep -q "protocol_version=" <<<"$PING_OUT" || fail "ping missing protocol_version"
grep -q "bridge_version=" <<<"$PING_OUT" || fail "ping missing bridge_version"

# ── 2) describe-ui ─────────────────────────────────────────────────
step "describe-ui"
OUTLINE="$TMP/outline.txt"
"$SIM_USE_BIN" describe-ui --udid "$SERIAL" > "$OUTLINE"
LINES="$(wc -l < "$OUTLINE")"
echo "  outline rows: $LINES"
[[ "$LINES" -gt 5 ]] || fail "outline suspiciously short ($LINES lines)"
grep -q "^App:" "$OUTLINE" || fail "outline missing 'App:' header"

# ── 3) describe-ui --json ──────────────────────────────────────────
step "describe-ui --json"
JSON="$TMP/outline.json"
"$SIM_USE_BIN" describe-ui --udid "$SERIAL" --json > "$JSON"
python3 -c "
import json, sys
with open('$JSON') as f: d = json.load(f)
data = d.get('data', {})
assert data.get('platform') == 'android', 'platform != android'
assert data.get('appPackage'), 'appPackage empty'
assert data.get('outline'), 'outline empty'
assert isinstance(data.get('entries'), list) and data['entries'], 'entries empty'
print(f\"  platform={data['platform']} package={data['appPackage']} entries={len(data['entries'])}\")
" || fail "--json envelope malformed"

# ── 4) screenshot ─────────────────────────────────────────────────
step "screenshot"
SHOT="$TMP/shot.png"
"$SIM_USE_BIN" screenshot --udid "$SERIAL" --output "$SHOT"
SIZE="$(stat -f%z "$SHOT" 2>/dev/null || stat -c%s "$SHOT")"
echo "  PNG size: $SIZE bytes"
[[ "$SIZE" -gt 10000 ]] || fail "screenshot suspiciously small ($SIZE bytes)"
file "$SHOT" | grep -q "PNG image data" || fail "screenshot output is not a PNG"

# ── 5) button home (cross-platform top-level verb) ────────────────
step "button home"
"$SIM_USE_BIN" button home --udid "$SERIAL"
sleep 1
"$SIM_USE_BIN" describe-ui --udid "$SERIAL" > "$TMP/post-home.txt"
HOME_LINES="$(wc -l < "$TMP/post-home.txt")"
echo "  outline rows after home: $HOME_LINES"
[[ "$HOME_LINES" -gt 5 ]] || fail "describe-ui after home returned suspicious output"

# ── 6) button back / recents validation (Android-only verbs) ──────
step "button back / recents (Android-only)"
"$SIM_USE_BIN" button back --udid "$SERIAL"
"$SIM_USE_BIN" button recents --udid "$SERIAL"
sleep 1
"$SIM_USE_BIN" button home --udid "$SERIAL" # back to home for cleanliness

# ── 7) cross-platform error reporting ─────────────────────────────
step "cross-platform error reporting"
if "$SIM_USE_BIN" button siri --udid "$SERIAL" 2>"$TMP/err.txt"; then
    fail "button siri should have errored on Android UDID"
fi
grep -q "not supported on Android" "$TMP/err.txt" || fail "Android+siri did not produce expected error message"
echo "  android+siri error: ok"

# ── 8) multi-touch (opt-in; requires Google Maps installed) ──────
# Two-finger gestures need a recogniser that responds visibly. Google
# Maps is the canonical test app; if it's not installed, skip the
# multi-touch block rather than fail (CI emulators without Play
# services don't have it).
MAPS_PKG="${MAPS_PKG:-com.google.android.apps.maps}"
if "$ADB_BIN" -s "$SERIAL" shell pm list packages "$MAPS_PKG" 2>/dev/null | grep -q "package:$MAPS_PKG"; then
    step "multi-touch on Google Maps"
    "$ADB_BIN" -s "$SERIAL" shell monkey -p "$MAPS_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
    sleep 3
    "$SIM_USE_BIN" describe-ui --udid "$SERIAL" > "$TMP/mt-before.txt"

    # pinch-out: zooms the map in. Relies on display-aware adaptive
    # defaults — radius scales to ~20% of min(width, height), so we
    # don't hand-tune per emulator resolution any more.
    "$SIM_USE_BIN" gesture pinch-out --scale 2.5 --udid "$SERIAL"
    sleep 1
    "$SIM_USE_BIN" describe-ui --udid "$SERIAL" > "$TMP/mt-pinch.txt"
    PINCH_DIFF="$(diff "$TMP/mt-before.txt" "$TMP/mt-pinch.txt" | wc -l | tr -d ' ')"
    echo "  pinch-out diff lines: $PINCH_DIFF"
    # Threshold deliberately permissive (3 lines = one text-truncation
    # change in unified diff). Google Maps doesn't surface tile content
    # in the a11y tree, so an observable pinch may only flicker a
    # single chrome label (e.g. the "Latest in the area" panel resizing
    # past its truncation budget). The screenshot would change far
    # more — but we'd rather not bake an image-hash dependency into
    # the smoke.
    [[ "$PINCH_DIFF" -gt 3 ]] || fail "pinch-out produced no observable UI change on Maps"

    # rotate-cw: rotates the map; observable via diff (rotated map
    # surfaces new street labels at different angles). Default
    # --duration (0.5s for a 90° sweep, the adaptive baseline) is
    # enough — recogniser tracks 90°/0.5s reliably on Android.
    "$SIM_USE_BIN" gesture rotate-cw --angle 90 --udid "$SERIAL"
    sleep 1
    "$SIM_USE_BIN" describe-ui --udid "$SERIAL" > "$TMP/mt-rotate.txt"
    ROT_DIFF="$(diff "$TMP/mt-pinch.txt" "$TMP/mt-rotate.txt" | wc -l | tr -d ' ')"
    echo "  rotate-cw diff lines: $ROT_DIFF"
    [[ "$ROT_DIFF" -gt 2 ]] || fail "rotate-cw produced no observable UI change on Maps"

    # tap --fingers 2: zooms out one level.
    "$SIM_USE_BIN" describe-ui --udid "$SERIAL" > "$TMP/mt-twoftap-before.txt"
    DISPLAY_W="$("$ADB_BIN" -s "$SERIAL" shell wm size | awk -F'[x ]' '/Physical size/ {print $3}')"
    DISPLAY_H="$("$ADB_BIN" -s "$SERIAL" shell wm size | awk -F'[x ]' '/Physical size/ {print $4}')"
    CX=$(( DISPLAY_W / 2 ))
    CY=$(( DISPLAY_H / 2 ))
    "$SIM_USE_BIN" tap -x "$CX" -y "$CY" --fingers 2 --finger-distance 200 --udid "$SERIAL"
    sleep 1
    "$SIM_USE_BIN" describe-ui --udid "$SERIAL" > "$TMP/mt-twoftap.txt"
    TAP2_DIFF="$(diff "$TMP/mt-twoftap-before.txt" "$TMP/mt-twoftap.txt" | wc -l | tr -d ' ')"
    echo "  two-finger tap diff lines: $TAP2_DIFF"
    [[ "$TAP2_DIFF" -gt 2 ]] || fail "two-finger tap produced no observable UI change on Maps"

    # multi-touch start == end (mirrors two-finger tap).
    "$SIM_USE_BIN" multi-touch \
        --x1 "$CX" --y1 "$CY" --x2 $((CX + 200)) --y2 "$CY" \
        --x1-end "$CX" --y1-end "$CY" --x2-end $((CX + 200)) --y2-end "$CY" \
        --duration 0.15 --udid "$SERIAL"
    echo "  multi-touch start==end dispatched"

    # multi-touch linear trajectory — two-finger vertical pan.
    "$SIM_USE_BIN" multi-touch \
        --x1 "$CX" --y1 $((CY + 200)) --x2 $((CX + 200)) --y2 $((CY + 200)) \
        --x1-end "$CX" --y1-end $((CY - 200)) --x2-end $((CX + 200)) --y2-end $((CY - 200)) \
        --duration 0.4 --udid "$SERIAL"
    echo "  multi-touch trajectory dispatched"

    # long-press --fingers 2 — execute, no state assertion.
    "$SIM_USE_BIN" long-press -x "$CX" -y "$CY" --fingers 2 --duration 1.0 --udid "$SERIAL"
    echo "  long-press --fingers 2 dispatched"
else
    echo
    echo "── multi-touch: SKIPPED (Google Maps '$MAPS_PKG' not installed)"
fi

# ── 9) outline regression — known LINE landmarks (opt-in) ────────
# LINE-specific assertions only fire when explicitly opted in via
# `SMOKE_LINE_SHELL=1`. Without the gate, a future LINE refactor
# that renames `bnb_button_clickable_area` (or just removes the
# resource id) would silently fail the generic smoke run, even
# though the smoke loop itself is supposed to be product-neutral.
if [[ "${SMOKE_LINE_SHELL:-0}" == "1" ]]; then
    step "outline content sanity (LINE shell)"
    grep -q "bnb_button_clickable_area" "$OUTLINE" \
        || fail "SMOKE_LINE_SHELL=1 but bottom-nav clickable_area missing — open LINE first"
    grep -q "Home tab" "$OUTLINE" || fail "bottom nav present but 'Home tab' label missing"
    echo "  LINE bottom-nav landmarks present"
fi

echo
echo "smoke: PASS — all checks green"
