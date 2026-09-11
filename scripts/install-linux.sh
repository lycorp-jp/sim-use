#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build and install the Linux (Android-only) sim-use CLI.
#
# Builds the Android-only Linux target graph (see docs/linux.md). The
# install is two pieces that must travel together:
#
#   sim-use                            the executable
#   SimUse_AndroidBackend.resources/   the bundled device-bridge APK
#                                      (Bundle.module looks for it next
#                                      to the executable)
#
# The binary links the Swift runtime dynamically with an RPATH into the
# toolchain, so the toolchain directory must stay where it is. A
# --static-swift-stdlib build is not possible without a static libcurl,
# which FoundationNetworking needs.
#
# Usage:
#   scripts/install-linux.sh                 # build + install
#   scripts/install-linux.sh --skip-bridge   # reuse the existing APK
#
# Env:
#   SWIFT_TOOLCHAIN   toolchain root holding usr/bin/swift
#                     (default: the `swift` on PATH)
#   PREFIX            install root (default: ~/.local)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="${PREFIX:-$HOME/.local}"
libdir="$prefix/lib/sim-use"
bindir="$prefix/bin"
skip_bridge=false
[[ "${1:-}" == "--skip-bridge" ]] && skip_bridge=true

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── Swift toolchain ─────────────────────────────────────────────────
if [[ -n "${SWIFT_TOOLCHAIN:-}" ]]; then
  [[ -x "$SWIFT_TOOLCHAIN/usr/bin/swift" ]] || fail "No swift at $SWIFT_TOOLCHAIN/usr/bin/swift"
  export PATH="$SWIFT_TOOLCHAIN/usr/bin:$PATH"
fi
command -v swift >/dev/null || fail \
  "No Swift toolchain found. Install one from https://www.swift.org/install/linux/ and put it on PATH, or set SWIFT_TOOLCHAIN."
ok "swift: $(swift --version 2>&1 | head -1) ($(command -v swift))"

# ── Device bridge APK ───────────────────────────────────────────────
apk="$repo_root/Sources/AndroidBackend/Resources/sim-use-device-bridge.apk"
if [[ "$skip_bridge" == false || ! -f "$apk" ]]; then
  log "Building the device-bridge APK (needs JDK 17-21 + Android SDK)..."
  "$repo_root/scripts/build-bridge.sh"
fi
[[ -f "$apk" ]] || fail "Bridge APK missing: $apk"

# ── Build ───────────────────────────────────────────────────────────
log "Building sim-use (release)..."
(cd "$repo_root" && swift build -c release)
binary="$repo_root/.build/release/sim-use"
bundle="$repo_root/.build/release/SimUse_AndroidBackend.resources"
[[ -x "$binary" ]] || fail "Build produced no binary at $binary"
[[ -d "$bundle" ]] || fail "Build produced no resource bundle at $bundle"

# ── Install ─────────────────────────────────────────────────────────
log "Installing to $libdir ..."
mkdir -p "$libdir" "$bindir"
install -m 0755 "$binary" "$libdir/sim-use"
rm -rf "$libdir/SimUse_AndroidBackend.resources"
cp -R "$bundle" "$libdir/SimUse_AndroidBackend.resources"
ln -sfn "$libdir/sim-use" "$bindir/sim-use"

ok "Installed $("$bindir/sim-use" --version) -> $bindir/sim-use"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) printf '\033[1;33m⚠\033[0m %s\n' "$bindir is not on PATH — add it to your shell profile." >&2 ;;
esac
