#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the Viewer SPA (Tools/Viewer) and sync the Vite output into the
# SwiftPM resource directory consumed by `SimUse`. The `sim-use viewer`
# subcommand reads from `Sources/SimUse/Resources/viewer/` at runtime via
# `Bundle.module`; the release pipeline runs this script before
# `swift build` so the tarball ships the latest SPA.
#
# Node is only required to run this script — once the dist is committed,
# `swift build` works on machines without Node installed. That's the
# point: end users never need Node, only contributors who touch the
# Viewer source do.
#
# Usage:
#   scripts/build-viewer.sh           # build and sync
#   scripts/build-viewer.sh --check   # report tool detection only
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
viewer_dir="$repo_root/Tools/Viewer"
resource_dir="$repo_root/Sources/SimUse/Resources/viewer"

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
fi

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  fail "node not found on PATH. Install Node 18+ (e.g. via Homebrew: brew install node) and re-run."
fi
node_version="$(node --version)"
ok "node ${node_version}"

if ! command -v npm >/dev/null 2>&1; then
  fail "npm not found on PATH (should ship with node)."
fi
ok "npm $(npm --version)"

if [[ "$check_only" == "true" ]]; then
  exit 0
fi

cd "$viewer_dir"

if [[ ! -d node_modules ]]; then
  log "installing Viewer dependencies (npm ci)"
  npm ci --silent
  ok "dependencies installed"
fi

log "building Viewer (vite build)"
npm run build --silent
ok "Vite build complete"

mkdir -p "$resource_dir"
log "syncing dist/ → Sources/SimUse/Resources/viewer/"
# --delete removes stale chunks from previous builds whose hashed names
# no longer match. Otherwise old assets would accumulate in the resource
# bundle and bloat the tarball. --exclude=.gitkeep preserves the tracked
# placeholder that keeps the directory present in git checkouts where
# no Viewer build has run yet (the dist itself is gitignored).
rsync -a --delete --exclude='.gitkeep' "$viewer_dir/dist/" "$resource_dir/"
ok "synced $(find "$resource_dir" -type f | wc -l | tr -d ' ') files"
