#!/usr/bin/env bash

# Build a portable sim-use bundle and a matching Homebrew formula on
# the developer's own machine.
#
# Distribution flow:
#   scripts/local-release.sh --version 0.9.0 \
#       --codesign-identity "Developer ID Application: NAVER Japan K.K. (GFPYJQXRSN)" \
#       --notarize --gh-release \
#       --tap-dir ~/Documents/lycorp-jp-homebrew-tap
#   ( review the staged tap repo + commit/push by hand )
#   brew tap lycorp-jp/tap
#   brew install sim-use

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION=""
OUTPUT_DIR="$REPO_ROOT/dist"
TAP_DIR=""
HOMEPAGE="https://github.com/lycorp-jp/sim-use"
RELEASE_HOST="github.com"
RELEASE_OWNER="lycorp-jp"
RELEASE_REPO="sim-use"
BUILD_FRAMEWORKS=false
SKIP_BUILD=false
SKIP_BRIDGE=false
SKIP_VIEWER=false
GH_RELEASE=false
GH_RELEASE_NOTES=""
GH_RELEASE_PRERELEASE=false
SIGN_IDENTITY="${SIM_USE_CODESIGN_IDENTITY:-}"
NOTARIZE=false
NOTARY_PROFILE="${SIM_USE_NOTARY_PROFILE:-}"
VERIFY_BREW_INSTALL=false

usage() {
  cat <<'EOF'
Usage: scripts/local-release.sh [OPTIONS]

Required (one of):
  --version VERSION         Plain version, no leading 'v' (e.g. 0.1.0)
                            If omitted, derived from `git describe --tags --always --dirty`.

Output:
  --output-dir DIR          Where to write tarball + formula
                            (default: ./dist)
  --tap-dir DIR             If given, copy the formula into <DIR>/Formula/sim-use.rb.
                            Tarball stays in --output-dir; user reviews + commits the
                            formula and uploads the tarball to GitHub separately.

GitHub release upload:
  --gh-release              Run `gh release create` (or `gh release upload` if the
                            tag already exists) to attach the tarball as a release asset.
  --gh-release-notes FILE   Markdown file used as the release body
                            (default: auto-generated stub).
  --gh-release-prerelease   Mark the GitHub release as a pre-release.

Build inputs:
  --build-frameworks        Force-rebuild the IDB frameworks
                            (slow, ~30 min, requires a populated idb_checkout/).
                            Default: reuse build_products/Frameworks/ if present.
  --skip-build              Skip the swift build step entirely. Assumes
                            build_products/sim-use is already a universal binary
                            with Frameworks/ rpath wired up.
                            Use after a previous run that already built; not for fresh trees.
  --skip-bridge             Skip the Android bridge APK rebuild. Use only when
                            you have just rebuilt it manually and want to save
                            ~1s; the resulting tarball still must contain a
                            valid APK (verify-stage will fail otherwise).
  --skip-viewer             Skip the Viewer SPA rebuild. Use only when you have
                            just rebuilt it manually (or the dist already
                            reflects your working tree); the resulting tarball
                            still must contain Resources/viewer/index.html
                            (the assert below catches an empty dir).

Code signing (optional):
  --codesign-identity ID    Override SIM_USE_CODESIGN_IDENTITY env var.
                            If neither is set, the executable ships unsigned and
                            relies on the formula's post_install ad-hoc re-sign.

Notarization (optional):
  --notarize                Submit the signed payload to Apple notary and wait
                            for an Accepted ruling. Requires --codesign-identity
                            (or SIM_USE_CODESIGN_IDENTITY) — Apple notary only
                            accepts Developer ID Application signatures. When
                            enabled, the homebrew tarball preserves the upstream
                            signature (no ad-hoc on the user side).
  --notary-profile NAME     Keychain profile name created via
                            'xcrun notarytool store-credentials NAME ...'.
                            Defaults to SIM_USE_NOTARY_PROFILE, then 'sim-use-notary'.

Brew install dress rehearsal (optional):
  --verify-brew-install     After staging + signing + (optional) notarize + tar,
                            install the tarball via a sandboxed local brew tap
                            and assert the installed binary carries the expected
                            signature. Catches the v0.6.0-class regression where
                            brew's relocate pass silently strips Developer ID
                            (see scripts/verify-brew-install.sh). When --notarize
                            is also set, the verifier additionally asserts the
                            spctl assessment passes.

Repo metadata:
  --homepage URL            (default: https://github.com/lycorp-jp/sim-use)
  --release-host HOST       Release host (default: github.com)
  --release-owner OWNER     Release org (default: lycorp-jp)
  --release-repo REPO       Release repo (default: sim-use)

  -h, --help

ENV:
  SIM_USE_CODESIGN_IDENTITY    Apple Developer ID for the executable.
  SIM_USE_NOTARY_PROFILE       Default keychain profile for --notarize.
EOF
}

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Print the body of the CHANGELOG.md section for $2 (a plain or v-prefixed
# version) from changelog file $1 — everything between its `## [x.y.z]`
# heading and the next `## [` heading, with leading/trailing blank lines
# trimmed. Empty output (no such section) is a soft failure the caller
# falls back on. Used to render the GitHub release body from the change log.
extract_changelog_section() {
  local changelog="$1" version="$2"
  [[ -f "$changelog" ]] || return 0
  awk -v ver="$version" '
    BEGIN { tgt = ver; sub(/^v/, "", tgt); found = 0; started = 0 }
    /^##[[:space:]]+\[/ {
      if (found) { exit }
      h = $0; sub(/^##[[:space:]]+\[/, "", h); sub(/\].*/, "", h); sub(/^v/, "", h)
      if (h == tgt) { found = 1 }
      next
    }
    found {
      if (!started && $0 ~ /^[[:space:]]*$/) { next }   # skip leading blanks
      started = 1
      print
    }
  ' "$changelog"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --tap-dir) TAP_DIR="${2:-}"; shift 2 ;;
    --gh-release) GH_RELEASE=true; shift ;;
    --gh-release-notes) GH_RELEASE_NOTES="${2:-}"; shift 2 ;;
    --gh-release-prerelease) GH_RELEASE_PRERELEASE=true; shift ;;
    --build-frameworks) BUILD_FRAMEWORKS=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --skip-bridge) SKIP_BRIDGE=true; shift ;;
    --skip-viewer) SKIP_VIEWER=true; shift ;;
    --codesign-identity) SIGN_IDENTITY="${2:-}"; shift 2 ;;
    --notarize) NOTARIZE=true; shift ;;
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    --verify-brew-install) VERIFY_BREW_INSTALL=true; shift ;;
    --homepage) HOMEPAGE="${2:-}"; shift 2 ;;
    --release-host) RELEASE_HOST="${2:-}"; shift 2 ;;
    --release-owner) RELEASE_OWNER="${2:-}"; shift 2 ;;
    --release-repo) RELEASE_REPO="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

# 1. Resolve version.
if [[ -z "$VERSION" ]]; then
  if VERSION="$(git describe --tags --always --dirty 2>/dev/null)"; then
    VERSION="${VERSION#v}"
    log "Resolved version from git describe: ${VERSION}"
  else
    fail "--version not provided and git describe failed"
  fi
fi
TAG="v${VERSION}"
ASSET_NAME="sim-use-${TAG}.tar.gz"

log "sim-use local release"
log "  version:     ${VERSION}"
log "  tag/asset:   ${TAG} / ${ASSET_NAME}"
log "  output:      ${OUTPUT_DIR}"
[[ -n "$TAP_DIR" ]] && log "  tap-dir:     ${TAP_DIR}"
[[ "$GH_RELEASE" == "true" ]] && log "  gh-release:  ${RELEASE_HOST}/${RELEASE_OWNER}/${RELEASE_REPO}"
[[ -n "$SIGN_IDENTITY" ]] && log "  codesign:    ${SIGN_IDENTITY}" || warn "no codesign identity — relying on brew formula post_install ad-hoc re-sign"
if [[ "$NOTARIZE" == "true" ]]; then
  [[ -n "$SIGN_IDENTITY" ]] || fail "--notarize requires --codesign-identity (or SIM_USE_CODESIGN_IDENTITY env). Apple notary only accepts Developer ID Application signatures."
  [[ -n "$NOTARY_PROFILE" ]] || NOTARY_PROFILE="sim-use-notary"
  command -v xcrun >/dev/null || fail "xcrun not on PATH (Xcode Command Line Tools required for --notarize)."
  log "  notarize:    profile '${NOTARY_PROFILE}'"
fi

# 2. Pre-flight.
command -v swift >/dev/null || fail "swift not on PATH"
command -v lipo >/dev/null  || fail "lipo not on PATH"
command -v shasum >/dev/null || fail "shasum not on PATH"
[[ "$GH_RELEASE" == "true" ]] && { command -v gh >/dev/null || fail "gh CLI required for --gh-release"; }

# Bridge protocol_version parity: the Kotlin source and the Swift
# client must agree on the wire protocol_version before we ship,
# otherwise the released sim-use either refuses its own bundled APK
# (`BridgeError.protocolMismatch` on every `sim-use android init`)
# or, worse, silently speaks a different wire shape on an upgrade
# path. Cheap to run, expensive to ship wrong — gate at pre-flight.
./scripts/check-protocol-parity.sh \
  || fail "Bridge protocol_version drift between Kotlin and Swift — abort release. See script output for the mismatched values."

# Bridge versionName parity with the CLI's release version. The CLI
# enforces this at runtime via `BridgeClient.expectedBridgeVersion`,
# so shipping a tarball where the bundled APK's versionName differs
# from the CLI tag is a guaranteed footgun: the freshly-installed
# bridge would fail the ping-time check with `bridgeVersionMismatch`
# until the user re-ran `sim-use android init` (which doesn't help
# because the APK on disk *is* the mismatched one). Gate at pre-flight
# so the release skill notices an out-of-sync gradle file before
# building anything.
GRADLE_FILE="bridge/app/build.gradle.kts"
GRADLE_VERSION_NAME="$(awk -F'"' '/^[[:space:]]*versionName[[:space:]]*=/{print $2; exit}' "$GRADLE_FILE")"
if [[ -z "$GRADLE_VERSION_NAME" ]]; then
  fail "$GRADLE_FILE: could not parse versionName. The release script's awk-based parse expects a literal \`versionName = \"X.Y.Z\"\` line; if the format changed, update both ends."
fi
if [[ "$GRADLE_VERSION_NAME" != "$VERSION" ]]; then
  fail "$GRADLE_FILE has versionName = \"$GRADLE_VERSION_NAME\" but the release is $VERSION. Update versionName + bump versionCode (any monotonic increment is fine — typically +1) and commit before re-running. The /release skill does this alongside the CHANGELOG edit; manual releases must do it by hand."
fi
log "Bridge APK versionName matches CLI release: $GRADLE_VERSION_NAME"

if [[ ! -d "build_products/Frameworks" ]]; then
  if [[ "$BUILD_FRAMEWORKS" == "true" ]]; then
    log "Building IDB frameworks (this will take a while)..."
    [[ -d "idb_checkout/.git" ]] || scripts/build.sh setup
    scripts/build.sh frameworks
    scripts/build.sh install
    scripts/build.sh strip
    [[ -n "$SIGN_IDENTITY" ]] && SIM_USE_CODESIGN_IDENTITY="$SIGN_IDENTITY" scripts/build.sh sign-frameworks || true
  else
    fail "build_products/Frameworks not found. Run with --build-frameworks (slow, ~30 min) or pre-populate via 'scripts/build.sh frameworks install strip'."
  fi
fi

# 2b. Refresh the Android bridge APK. SwiftPM bundles whatever lives at
# `Sources/AndroidBackend/Resources/sim-use-device-bridge.apk` into the
# `SimUse_AndroidBackend.bundle` resource bundle at `swift build` time;
# if the APK is stale (or absent) the resulting tarball still ships but
# `sim-use android init` will fail at runtime with "Bridge APK not found
# in module bundle". We rebuild unconditionally because:
#   * bridge build is fast (~1s up-to-date, ~10s clean)
#   * a release cut on a workstation that hasn't run build-bridge.sh
#     recently is the canonical way to silently miss this
#   * the script auto-detects JBR / Android SDK so no extra setup needed
# `--skip-bridge` exists for the legitimate case where you just rebuilt
# manually and want to shave a second.
#
# `--skip-build --skip-bridge` is the canonical "I'm re-staging an
# already-built tree" combo; both flags must agree because `swift build`
# is what copies the freshly-built APK into `SimUse_AndroidBackend.bundle`
# — rebuilding the APK without rebuilding Swift would leave the bundle
# pointing at the old one and `verify-stage` would happily ship stale
# bytes. The check below is just doc-level; the actual coupling is:
#   `--skip-bridge` + `!--skip-build` → swift build picks up the existing
#                                       APK on disk (the path swift build
#                                       always uses); fine.
#   `!--skip-bridge` + `--skip-build` → bridge built fresh but swift
#                                       build skipped → bundle stale.
#                                       Warn loudly so the user notices.
if [[ "$SKIP_BRIDGE" == "true" ]]; then
  log "Skipping Android bridge APK rebuild (--skip-bridge)"
  [[ -f "Sources/AndroidBackend/Resources/sim-use-device-bridge.apk" ]] \
    || fail "--skip-bridge set but Sources/AndroidBackend/Resources/sim-use-device-bridge.apk is missing. Run scripts/build-bridge.sh first."
else
  log "Rebuilding Android bridge APK..."
  ./scripts/build-bridge.sh
  if [[ "$SKIP_BUILD" == "true" ]]; then
    log "WARNING: rebuilt bridge APK but --skip-build is set — \
the staged tarball will use the OLD APK from build_products/. \
Re-run without --skip-build (or pair with --skip-bridge) to ship the fresh APK."
  fi
fi

# 2c. Refresh the Viewer SPA. Same shape as the bridge step above:
# `Sources/SimUse/Resources/viewer/` is gitignored (only `.gitkeep` is
# tracked), so a release cut on a workstation that hasn't run
# `build-viewer.sh` recently would otherwise silently ship an empty
# `sim-use viewer` (the command would refuse to start with "assets not
# bundled"). Vite build is cheap (~250ms incremental) — rebuild
# unconditionally unless --skip-viewer was passed.
#
# `--skip-viewer` + `--skip-build` is the canonical "I'm re-staging" combo;
# the same coupling caveat as the bridge applies — rebuilding the SPA
# without rebuilding Swift would leave `build_products/SimUse_SimUse.bundle`
# pointing at the old SPA.
if [[ "$SKIP_VIEWER" == "true" ]]; then
  log "Skipping Viewer SPA rebuild (--skip-viewer)"
  [[ -f "Sources/SimUse/Resources/viewer/index.html" ]] \
    || fail "--skip-viewer set but Sources/SimUse/Resources/viewer/index.html is missing. Run scripts/build-viewer.sh first."
else
  log "Rebuilding Viewer SPA..."
  ./scripts/build-viewer.sh
  if [[ "$SKIP_BUILD" == "true" ]]; then
    log "WARNING: rebuilt Viewer SPA but --skip-build is set — \
the staged tarball will use the OLD SPA from build_products/. \
Re-run without --skip-build (or pair with --skip-viewer) to ship the fresh SPA."
  fi
fi

# 3. Build the universal sim-use executable.
# scripts/build.sh executable runs: swift package clean → swift build (arm64+x86_64)
# → lipo → install_name_tool fixups (@executable_path/Frameworks rpath, strip Xcode rpath).
# That last fixup is the difference between "runs from .build/release" and
# "runs after being copied anywhere else on disk".
if [[ "$SKIP_BUILD" == "true" ]]; then
  [[ -x "build_products/sim-use" ]] || fail "--skip-build set but build_products/sim-use missing"
  log "Skipping swift build, reusing build_products/sim-use"
else
  log "Building sim-use universal executable..."
  SIM_USE_VERSION="$VERSION" scripts/build.sh executable
fi

# Code-sign the binary + frameworks when an identity is supplied. When
# --notarize is also set, frameworks are mandatory (Apple notary inspects
# every embedded Mach-O); we sign them even if the IDB build path
# already did to make this script self-sufficient.
if [[ -n "$SIGN_IDENTITY" ]]; then
  log "Code signing frameworks with identity: ${SIGN_IDENTITY}"
  SIM_USE_CODESIGN_IDENTITY="$SIGN_IDENTITY" scripts/build.sh sign-frameworks
  log "Code signing executable with identity: ${SIGN_IDENTITY}"
  SIM_USE_CODESIGN_IDENTITY="$SIGN_IDENTITY" scripts/build.sh sign-executable
fi

# 4. Stage payload (binary + Frameworks/ + resource bundle) and verify
# the universal arch contract before we tar it up.
mkdir -p "$OUTPUT_DIR"
STAGE_DIR="$OUTPUT_DIR/stage"
log "Staging release payload at ${STAGE_DIR}..."
scripts/release-artifacts.sh stage-build-output \
  --build-output-dir "$REPO_ROOT/build_products" \
  --stage-dir "$STAGE_DIR"
scripts/release-artifacts.sh verify-stage --stage-dir "$STAGE_DIR"

# 4b. Notarize (optional). Submit the staged payload to Apple notary,
# wait for an Accepted ruling, abort otherwise. We zip the staged dir
# (the same bytes that ship in the tarball), so Apple records the exact
# hash users will see. No on-disk staple — notarytool can't staple a
# flat Mach-O CLI; Gatekeeper queries Apple's notarization-records
# database online by hash.
if [[ "$NOTARIZE" == "true" ]]; then
  log "Submitting payload to Apple notary (profile: ${NOTARY_PROFILE})..."
  NOTARIZE_ZIP="${OUTPUT_DIR}/sim-use-notarize-${TAG}.zip"
  NOTARY_LOG="${OUTPUT_DIR}/notary-${TAG}.log"
  rm -f "$NOTARIZE_ZIP" "$NOTARY_LOG"
  ditto -c -k --keepParent "$STAGE_DIR" "$NOTARIZE_ZIP"
  if xcrun notarytool submit "$NOTARIZE_ZIP" \
       --keychain-profile "$NOTARY_PROFILE" \
       --wait > "$NOTARY_LOG" 2>&1; then
    cat "$NOTARY_LOG"
    grep -q "status: Accepted" "$NOTARY_LOG" \
      || fail "Notarization did not return 'Accepted'. See $NOTARY_LOG."
  else
    cat "$NOTARY_LOG"
    fail "notarytool submit failed. See $NOTARY_LOG."
  fi
  rm -f "$NOTARIZE_ZIP"
  ok "Notarization Accepted"
fi

# 5. Create the release tarball. When notarized, preserve the Developer ID
# signature on disk so brew install ships the Apple-validated binary.
# Otherwise strip signatures so the formula's post_install ad-hoc re-sign
# owns the on-disk signature (legacy path; same handling for signed and
# unsigned upstream binaries).
ARCHIVE_PATH="$OUTPUT_DIR/$ASSET_NAME"
if [[ "$NOTARIZE" == "true" ]]; then
  log "Creating tarball ${ARCHIVE_PATH} (preserving Developer ID + notarization)..."
  scripts/release-artifacts.sh create-universal-archive \
    --stage-dir "$STAGE_DIR" \
    --archive "$ARCHIVE_PATH"
else
  log "Creating tarball ${ARCHIVE_PATH} (signatures stripped, ad-hoc on user side)..."
  scripts/release-artifacts.sh create-homebrew-archive \
    --stage-dir "$STAGE_DIR" \
    --archive "$ARCHIVE_PATH"
fi

# 6. sha256 the archive — this hash gets baked into the formula.
SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
echo "$SHA256  $ASSET_NAME" > "${ARCHIVE_PATH}.sha256"
ok "sha256: ${SHA256}"

# 7. Generate formula. --notarized drops the post_install ad-hoc resign
# block so the on-disk Developer ID signature stays intact.
FORMULA_PATH="$OUTPUT_DIR/sim-use.rb"
log "Generating formula at ${FORMULA_PATH}..."
RELEASE_URL="https://github.com/${RELEASE_OWNER}/${RELEASE_REPO}/releases/download/${TAG}/${ASSET_NAME}"
scripts/generate-homebrew-formula.sh \
  --formula-class SimUse \
  --homepage "$HOMEPAGE" \
  --version "$VERSION" \
  --url "$RELEASE_URL" \
  --sha256 "$SHA256" \
  --license "Apache-2.0" \
  > "$FORMULA_PATH"
command -v ruby >/dev/null && ruby -c "$FORMULA_PATH" >/dev/null && ok "formula syntax check passed"

# 8. Smoke-test the archive. The notarized path runs the binary as it
# ships (Developer ID signature intact). The legacy ad-hoc path mirrors
# the formula's post_install re-sign because create-homebrew-archive
# stripped the on-disk signatures.
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-local-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR"' EXIT
tar -xzf "$ARCHIVE_PATH" -C "$SMOKE_DIR"
if [[ "$NOTARIZE" == "true" ]]; then
  log "Smoke-testing archive (Developer ID-signed, no ad-hoc resign)..."
  codesign --verify --deep --strict "$SMOKE_DIR/sim-use" \
    || fail "Tarball binary failed codesign --verify."
else
  log "Smoke-testing archive (with ad-hoc re-sign, matching brew post_install)..."
  for fw in "$SMOKE_DIR"/Frameworks/*.framework; do
    codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1
  done
  codesign --force --sign - --timestamp=none "$SMOKE_DIR/sim-use" >/dev/null 2>&1
fi
"$SMOKE_DIR/sim-use" --version >/dev/null
"$SMOKE_DIR/sim-use" init --print | grep -q "name: sim-use"
ok "Archive smoke test passed"

# 8b. Brew install dress rehearsal (optional). Installs the just-built
# tarball via a sandboxed local brew tap so we can assert the brew
# install path actually preserves the signature we worked to attach.
# This is the gate that would have caught the v0.6.0 regression where
# brew's keg_relocate.rb stripped a duplicate rpath and ad-hoc resigned
# the binary, voiding the Apple notary chain. Runs before the GitHub
# upload so a failure aborts the release while everything is still
# local + reversible.
if [[ "$VERIFY_BREW_INSTALL" == "true" ]]; then
  VERIFY_FLAGS=()
  # --notarize implies the tarball should keep its Developer ID + spctl
  # acceptance through brew install. Without --notarize, the tarball
  # ships signature-stripped (create-homebrew-archive), so we only
  # exercise the brew install mechanics, not the signature preservation.
  if [[ "$NOTARIZE" == "true" ]]; then
    VERIFY_FLAGS+=(--require-developer-id --require-spctl-accept)
  fi
  log "Running brew install dress rehearsal..."
  scripts/verify-brew-install.sh \
    --archive "$ARCHIVE_PATH" \
    --version "$VERSION" \
    "${VERIFY_FLAGS[@]}"
fi

# 9. GitHub release upload (optional). If the tag already exists we upload
# additional assets to it; otherwise we create the release.
if [[ "$GH_RELEASE" == "true" ]]; then
  REPO_SLUG="${RELEASE_OWNER}/${RELEASE_REPO}"
  log "Uploading to GitHub release ${TAG} on ${REPO_SLUG}..."

  # Resolve the release body. Prefer an explicit --gh-release-notes file;
  # otherwise render it from the CHANGELOG.md section for this version so the
  # GitHub page carries the real change log instead of a placeholder. Fall back
  # to a one-line note only when no section exists (e.g. a hotfix tag with no
  # CHANGELOG entry yet).
  NOTES_ARG=()
  NOTES_TMP=""
  if [[ -n "$GH_RELEASE_NOTES" ]]; then
    NOTES_ARG+=(--notes-file "$GH_RELEASE_NOTES")
  else
    CHANGELOG_SECTION="$(extract_changelog_section "CHANGELOG.md" "$VERSION")"
    if [[ -n "${CHANGELOG_SECTION//[$' \t\n']/}" ]]; then
      NOTES_TMP="$(mktemp "${TMPDIR:-/tmp}/sim-use-relnotes.XXXXXX")"
      printf '%s\n' "$CHANGELOG_SECTION" >"$NOTES_TMP"
      NOTES_ARG+=(--notes-file "$NOTES_TMP")
      log "Release notes rendered from CHANGELOG.md [${VERSION}]"
    else
      warn "No CHANGELOG.md section for ${VERSION}; using placeholder release notes"
      NOTES_ARG+=(--notes "Automated local release of sim-use ${TAG}.")
    fi
  fi
  [[ "$GH_RELEASE_PRERELEASE" == "true" ]] && NOTES_ARG+=(--prerelease)

  if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ARCHIVE_PATH" "${ARCHIVE_PATH}.sha256" \
      --repo "$REPO_SLUG" --clobber
    # Refresh the body too, so a re-run repairs a previously-placeholder release.
    gh release edit "$TAG" --repo "$REPO_SLUG" "${NOTES_ARG[@]}"
    ok "Uploaded assets and refreshed notes on existing release ${TAG}"
  else
    gh release create "$TAG" \
      "$ARCHIVE_PATH" "${ARCHIVE_PATH}.sha256" \
      --repo "$REPO_SLUG" \
      --title "sim-use ${TAG}" \
      "${NOTES_ARG[@]}"
    ok "Created release ${TAG}"
  fi
  [[ -n "$NOTES_TMP" ]] && rm -f "$NOTES_TMP"
fi

# 10. Tap drop-in (optional). Copy formula only; tarball lives on the GitHub
# release page. We deliberately do not commit/push — release notes,
# version-bump conventions, and tap-repo etiquette are user concerns.
if [[ -n "$TAP_DIR" ]]; then
  [[ -d "$TAP_DIR" ]] || fail "--tap-dir does not exist: $TAP_DIR"
  mkdir -p "$TAP_DIR/Formula"
  cp "$FORMULA_PATH" "$TAP_DIR/Formula/sim-use.rb"
  ok "Copied formula to ${TAP_DIR}/Formula/sim-use.rb"
fi

# 11. Summary.
cat <<EOF

────────────────────────────────────────
✅ sim-use ${TAG} ready for distribution
────────────────────────────────────────

  Archive:   $ARCHIVE_PATH
  sha256:    $SHA256
  Formula:   $FORMULA_PATH

EOF

if [[ "$GH_RELEASE" != "true" ]]; then
  cat <<EOF
Next: upload the tarball to the GitHub release page so the formula's
download URL resolves:

  gh release create ${TAG} \\
    "$ARCHIVE_PATH" \\
    --repo ${RELEASE_OWNER}/${RELEASE_REPO} \\
    --title "sim-use ${TAG}"

Or rerun this script with --gh-release.

EOF
fi

if [[ -z "$TAP_DIR" ]]; then
  cat <<EOF
Then drop the formula into the ${RELEASE_OWNER}/homebrew-tap repo:

  cp $FORMULA_PATH \\
    <homebrew-tap-clone>/Formula/sim-use.rb
  cd <homebrew-tap-clone> && git add Formula/sim-use.rb && git commit && git push

(or rerun with --tap-dir <homebrew-tap-clone>)

EOF
else
  cat <<EOF
Then commit + push the tap:

  cd ${TAP_DIR}
  git add Formula/sim-use.rb
  git commit -m "sim-use ${TAG}"
  git push

EOF
fi

cat <<EOF
End-user install:

  brew tap ${RELEASE_OWNER}/tap
  brew install ${RELEASE_OWNER}/tap/sim-use
EOF
