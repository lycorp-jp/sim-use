#!/usr/bin/env bash

# Build a release-shaped sim-use binary and install it locally for testing.
# Does NOT commit, tag, push, create GHE releases, or update homebrew.
#
# This is the local counterpart to `local-release.sh`: it builds the same
# artefacts (universal binary, frameworks, viewer SPA, Android bridge APK)
# but instead of tarring + uploading, it ad-hoc codesigns the staged payload
# and repoints the PATH binary so `sim-use --version` returns the target
# version immediately.
#
# Usage:
#   scripts/dev-install.sh --version 0.9.1          # full build + install
#   scripts/dev-install.sh --version 0.9.1 --skip-bridge --skip-viewer
#   scripts/dev-install.sh --restore                 # restore previous binary
#
# After local validation, run `/release` (the full pipeline) to ship.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION=""
SKIP_BRIDGE=false
SKIP_VIEWER=false
SKIP_BUILD=false
RESTORE=false
BACKUP_FILE="$REPO_ROOT/dist/.dev-install-backup"

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/dev-install.sh [OPTIONS]

Build + install:
  --version VERSION       Plain version, no leading 'v' (e.g. 0.9.1).
                          If omitted, derived from `git describe --tags --always`.

  --skip-bridge           Skip Android bridge APK rebuild.
  --skip-viewer           Skip Viewer SPA rebuild.
  --skip-build            Skip swift build; reuse existing build_products/.

Restore:
  --restore               Restore the sim-use PATH binary to its pre-dev-install
                          state. Reads the backup from dist/.dev-install-backup.

  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --skip-bridge) SKIP_BRIDGE=true; shift ;;
    --skip-viewer) SKIP_VIEWER=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --restore) RESTORE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

# ── Restore mode ──────────────────────────────────────────────────────

if [[ "$RESTORE" == "true" ]]; then
  [[ -f "$BACKUP_FILE" ]] || fail "No backup found at $BACKUP_FILE. Nothing to restore."
  LINK_PATH="$(sed -n '1p' "$BACKUP_FILE")"
  OLD_TARGET="$(sed -n '2p' "$BACKUP_FILE")"
  [[ -n "$LINK_PATH" && -n "$OLD_TARGET" ]] || fail "Backup file is malformed: $BACKUP_FILE"

  # Remove whatever dev-install placed (always a symlink we created).
  rm -f "$LINK_PATH"

  if [[ "$OLD_TARGET" == *.dev-install-backup ]]; then
    # Was a regular file (e.g. brew wrapper script); we moved it aside.
    if [[ -f "$OLD_TARGET" ]]; then
      mv "$OLD_TARGET" "$LINK_PATH"
      ok "Restored regular file: $LINK_PATH"
    else
      fail "Backup file $OLD_TARGET is missing. Reinstall via brew or recreate the symlink manually."
    fi
  elif [[ "$OLD_TARGET" == "__none__" ]]; then
    ok "Removed dev-install binary. (sim-use was not on PATH before dev-install.)"
  else
    # Was a symlink; recreate it.
    ln -s "$OLD_TARGET" "$LINK_PATH"
    ok "Restored: $LINK_PATH → $OLD_TARGET"
  fi

  rm -f "$BACKUP_FILE"
  echo ""
  if command -v sim-use >/dev/null 2>&1; then
    sim-use --version && ok "Restored binary works" || warn "Restored binary returned non-zero"
  else
    log "sim-use is no longer on PATH (expected if it was not installed before dev-install)."
  fi
  exit 0
fi

# ── Build + install mode ─────────────────────────────────────────────

# 1. Resolve version.
if [[ -z "$VERSION" ]]; then
  if VERSION="$(git describe --tags --always --dirty 2>/dev/null)"; then
    VERSION="${VERSION#v}"
    log "Resolved version from git describe: ${VERSION}"
  else
    fail "--version not provided and git describe failed"
  fi
fi

log "sim-use dev-install"
log "  version:  ${VERSION}"
log "  repo:     ${REPO_ROOT}"

# 2. Pre-flight.
command -v swift >/dev/null || fail "swift not on PATH"
command -v lipo >/dev/null  || fail "lipo not on PATH"

if [[ ! -d "build_products/Frameworks" ]]; then
  fail "build_products/Frameworks not found. Run 'scripts/build.sh frameworks install strip' first (~30 min)."
fi

# Locate the current PATH binary so we know what to replace.
LINK_PATH="$(command -v sim-use 2>/dev/null || true)"
if [[ -z "$LINK_PATH" ]]; then
  LINK_PATH="/opt/homebrew/bin/sim-use"
  warn "sim-use not on PATH; will install to $LINK_PATH"
fi

# 3. Build bridge APK.
if [[ "$SKIP_BRIDGE" == "true" ]]; then
  log "Skipping Android bridge APK rebuild (--skip-bridge)"
  [[ -f "Sources/AndroidBackend/Resources/sim-use-device-bridge.apk" ]] \
    || fail "--skip-bridge set but APK is missing. Run scripts/build-bridge.sh first."
else
  log "Rebuilding Android bridge APK..."
  ./scripts/build-bridge.sh
fi

# 4. Build Viewer SPA.
if [[ "$SKIP_VIEWER" == "true" ]]; then
  log "Skipping Viewer SPA rebuild (--skip-viewer)"
  [[ -f "Sources/SimUse/Resources/viewer/index.html" ]] \
    || fail "--skip-viewer set but viewer is missing. Run scripts/build-viewer.sh first."
else
  log "Rebuilding Viewer SPA..."
  ./scripts/build-viewer.sh
fi

# 5. Build universal executable.
if [[ "$SKIP_BUILD" == "true" ]]; then
  [[ -x "build_products/sim-use" ]] || fail "--skip-build set but build_products/sim-use missing."
  log "Skipping swift build, reusing build_products/sim-use"
else
  log "Building sim-use universal executable (version=${VERSION})..."
  SIM_USE_VERSION="$VERSION" scripts/build.sh executable
fi

# 6. Stage payload.
STAGE_DIR="$REPO_ROOT/dist/stage"
log "Staging release payload at ${STAGE_DIR}..."
scripts/release-artifacts.sh stage-build-output \
  --build-output-dir "$REPO_ROOT/build_products" \
  --stage-dir "$STAGE_DIR"
scripts/release-artifacts.sh verify-stage --stage-dir "$STAGE_DIR"

# 7. Ad-hoc codesign the staged payload so it runs on arm64 macOS.
# lipo + install_name_tool invalidate the compiler's ad-hoc signature;
# re-sign everything before linking it into PATH.
log "Ad-hoc codesigning staged payload..."
for fw in "$STAGE_DIR"/Frameworks/*.framework; do
  codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1
done
codesign --force --sign - --timestamp=none "$STAGE_DIR/sim-use" >/dev/null 2>&1
ok "Staged payload codesigned (ad-hoc)"

# 8. Smoke-test before replacing PATH binary.
"$STAGE_DIR/sim-use" --version >/dev/null \
  || fail "Staged binary failed to run. Check codesigning."
STAGED_VERSION="$("$STAGE_DIR/sim-use" --version)"
ok "Staged binary reports: ${STAGED_VERSION}"

# 9. Back up current link target, then replace.
mkdir -p "$(dirname "$BACKUP_FILE")"
if [[ -L "$LINK_PATH" ]]; then
  OLD_TARGET="$(readlink "$LINK_PATH")"
  printf '%s\n%s\n' "$LINK_PATH" "$OLD_TARGET" > "$BACKUP_FILE"
  ok "Backed up: $LINK_PATH → $OLD_TARGET"
elif [[ -e "$LINK_PATH" ]]; then
  # Regular file or wrapper script — back up the path but note it's not a symlink.
  printf '%s\n%s\n' "$LINK_PATH" "__regular_file__" > "$BACKUP_FILE"
  warn "$LINK_PATH is not a symlink. Creating symlink will shadow it."
  warn "The original file is preserved; use --restore to recover."
  mv "$LINK_PATH" "${LINK_PATH}.dev-install-backup"
  printf '%s\n%s\n' "$LINK_PATH" "${LINK_PATH}.dev-install-backup" > "$BACKUP_FILE"
else
  ok "$LINK_PATH does not exist yet; creating fresh."
  printf '%s\n%s\n' "$LINK_PATH" "__none__" > "$BACKUP_FILE"
fi

ln -sf "$STAGE_DIR/sim-use" "$LINK_PATH"
ok "Installed: $LINK_PATH → $STAGE_DIR/sim-use"

# 10. Final verification.
INSTALLED_VERSION="$(sim-use --version 2>/dev/null || true)"
if [[ "$INSTALLED_VERSION" == *"$VERSION"* ]]; then
  ok "sim-use --version → ${INSTALLED_VERSION}"
else
  warn "sim-use --version returned '${INSTALLED_VERSION}' (expected to contain '${VERSION}')"
fi

cat <<EOF

────────────────────────────────────────
  sim-use ${VERSION} installed locally
────────────────────────────────────────

  Binary:   $STAGE_DIR/sim-use
  Link:     $LINK_PATH → $STAGE_DIR/sim-use
  Version:  ${INSTALLED_VERSION}

  Test the release build, then:
    /release        — ship for real (CHANGELOG, tag, GHE, brew)

  To restore the previous binary:
    scripts/dev-install.sh --restore

EOF
