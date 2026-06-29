#!/usr/bin/env bash

# End-to-end dress rehearsal of the brew install path. Given a built
# tarball (produced by scripts/local-release.sh up to the tarball step),
# this script:
#
#   1. Creates a sandboxed local brew tap under
#      `$(brew --repository)/Library/Taps/sim-use-release-test/`.
#   2. Generates a side-channel formula `sim-use-dryrun` that points at
#      the local tarball via `file://`, with a class name + formula name
#      distinct from the real `sim-use` to avoid conflicting with the
#      developer's own brew-installed sim-use.
#   3. Runs `brew install` from that local tap.
#   4. Asserts the brew-installed binary matches the expected release
#      shape: APK present + bit-identical to the source APK, codesign
#      identity preserved (when --require-developer-id is set), spctl
#      assessment passes (when --require-spctl-accept is set).
#   5. Runs `brew test` to exercise the formula's self-test (catches
#      regressions in the `def test do` block of the real formula).
#   6. Cleans up: brew uninstall + untap + rm tap dir.
#
# This script is the canonical answer to "will brew install of this
# tarball preserve the upstream signature?" — it catches the failure
# mode v0.6.0 shipped with (brew's keg_relocate.rb stripping duplicate
# rpaths and ad-hoc resigning) before a real release is cut.
#
# Usage:
#   scripts/verify-brew-install.sh \
#       --archive dist/sim-use-v0.6.1.tar.gz \
#       --version 0.6.1 \
#       --require-developer-id \
#       --require-spctl-accept
#
# When called from scripts/local-release.sh (via --verify-brew-install),
# the assertion flags are derived from the release shape (--notarize
# implies both --require-developer-id and --require-spctl-accept).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Force brew to use its own ca-certificates bundle for every brew
# subprocess this script spawns (install / test / tap). `brew test` is a
# Homebrew *developer* command: before running the formula's `test do`
# block it calls `install_bundler_gems!(groups: ["formula_test"])`, which
# forks `bundle install` against Homebrew's own Gemfile to fetch its test
# harness (minitest etc.) from rubygems.org. On a network that does TLS
# inspection (e.g. a corporate proxy re-signing rubygems.org under a
# private root CA), Homebrew's vendored portable-ruby has no trust anchor
# for that chain and the bundler fork dies with `certificate verify
# failed (unable to get local issuer certificate)`, aborting brew test
# before our assertions ever run. Homebrew does NOT inherit an externally
# set SSL_CERT_FILE (it scrubs it from its env), but it does honor this
# HOMEBREW_-namespaced flag: brew.sh's setup_ca_certificates() then
# exports SSL_CERT_FILE / GIT_SSL_CAINFO pointing at
# "$(brew --prefix)/etc/ca-certificates/cert.pem", which is regenerated
# from the system keychain and so includes the corp root. Safe to default
# on everywhere: on an uninspected network it merely selects brew's own
# (standard-root) bundle. Export it empty to opt out.
export HOMEBREW_FORCE_BREWED_CA_CERTIFICATES="${HOMEBREW_FORCE_BREWED_CA_CERTIFICATES:-1}"

ARCHIVE=""
VERSION=""
REQUIRE_DEVELOPER_ID=false
REQUIRE_SPCTL_ACCEPT=false
EXPECTED_TEAM_ID="${SIM_USE_EXPECTED_TEAM_ID:-GFPYJQXRSN}"
KEEP_ON_FAILURE=true

# Sandboxed tap location. Picking a fresh owner namespace
# (`sim-use-release-test`) keeps the dryrun completely separated from
# the real `LINE-Client/line` tap on the developer's machine.
TAP_USER="sim-use-release-test"
TAP_NAME="dryrun"
TAP_REF="${TAP_USER}/${TAP_NAME}"
FORMULA_NAME="sim-use-dryrun"

usage() {
  cat <<'EOF'
Usage: scripts/verify-brew-install.sh [OPTIONS]

Required:
  --archive PATH         Path to the built tarball (e.g.
                         dist/sim-use-v0.6.1.tar.gz).
  --version VERSION      Plain version, no leading 'v' (e.g. 0.6.1).

Assertions (off by default — the brew install must succeed and the APK
must be present and bit-identical regardless):
  --require-developer-id     Assert codesign TeamIdentifier matches the
                             expected ID (default: GFPYJQXRSN, override
                             via SIM_USE_EXPECTED_TEAM_ID).
  --require-spctl-accept     Assert `spctl -a` accepts the installed
                             binary (Gatekeeper-style assessment).

Other:
  --cleanup-on-failure       Tear down the temporary tap + keg even when
                             a verification step fails. Default leaves
                             the dryrun install in place so the operator
                             can inspect it; cleanup still runs on
                             success.

  -h, --help                 Print this and exit.
EOF
}

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --require-developer-id) REQUIRE_DEVELOPER_ID=true; shift ;;
    --require-spctl-accept) REQUIRE_SPCTL_ACCEPT=true; shift ;;
    --cleanup-on-failure) KEEP_ON_FAILURE=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$ARCHIVE" ]] || { usage >&2; fail "--archive is required"; }
[[ -n "$VERSION" ]] || { usage >&2; fail "--version is required"; }
[[ -f "$ARCHIVE" ]] || fail "Archive not found: $ARCHIVE"
command -v brew >/dev/null || fail "brew not on PATH"

# Resolve archive to an absolute path. brew's file:// download strategy
# needs an absolute URL, and the trap cleanup below references it after
# we've cd'd around.
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"

# Compute the source APK sha256 from inside the archive so we can later
# assert the brew-installed APK is bit-identical. The build pipeline
# guarantees a clean copy of `Sources/AndroidBackend/Resources/sim-use-
# device-bridge.apk` into `SimUse_AndroidBackend.bundle/Resources/`, and
# we want the verification to detect any silent mutation across the
# stage → tar → brew install hops.
ARCHIVE_APK_SHA=""
log "Reading source APK sha256 from archive ${ARCHIVE}..."
TMP_APK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-verify-apk.XXXXXX")"
tar -xzf "$ARCHIVE" -C "$TMP_APK_DIR" \
    "SimUse_AndroidBackend.bundle/Resources/sim-use-device-bridge.apk" 2>/dev/null \
  || fail "Archive ${ARCHIVE} is missing SimUse_AndroidBackend.bundle/Resources/sim-use-device-bridge.apk"
ARCHIVE_APK_SHA="$(shasum -a 256 "$TMP_APK_DIR/SimUse_AndroidBackend.bundle/Resources/sim-use-device-bridge.apk" | awk '{print $1}')"
rm -rf "$TMP_APK_DIR"
ok "Source APK sha256: ${ARCHIVE_APK_SHA}"

ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
log "Archive sha256:    ${ARCHIVE_SHA256}"

# Tap directory layout follows brew's convention:
#   <BREW_REPO>/Library/Taps/<user>/homebrew-<name>/Formula/<formula>.rb
TAP_DIR="$(brew --repository)/Library/Taps/${TAP_USER}/homebrew-${TAP_NAME}"
FORMULA_PATH="${TAP_DIR}/Formula/${FORMULA_NAME}.rb"

cleanup() {
  local rc=$?
  if [[ $rc -ne 0 && "$KEEP_ON_FAILURE" == "true" ]]; then
    warn "verify-brew-install failed (exit $rc); leaving dryrun install in place for inspection."
    warn "  Tap:         ${TAP_REF}"
    warn "  Formula:     ${FORMULA_PATH}"
    warn "  Cellar:      $(brew --cellar 2>/dev/null)/${FORMULA_NAME}/${VERSION}"
    warn "Tear down manually with:"
    warn "  brew uninstall --force ${FORMULA_NAME} 2>/dev/null"
    warn "  brew untap ${TAP_REF} 2>/dev/null"
    warn "  rm -rf '${TAP_DIR}'"
    return $rc
  fi

  log "Cleaning up dryrun install..."
  brew uninstall --force "${FORMULA_NAME}" >/dev/null 2>&1 || true
  brew untap "${TAP_REF}" >/dev/null 2>&1 || true
  rm -rf "${TAP_DIR}"
  return $rc
}
trap cleanup EXIT

# Pre-flight teardown: a previous interrupted run may have left the tap
# or keg in place. Wipe them silently so this run starts from clean state.
brew uninstall --force "${FORMULA_NAME}" >/dev/null 2>&1 || true
brew untap "${TAP_REF}" >/dev/null 2>&1 || true
rm -rf "${TAP_DIR}"

log "Creating temporary tap at ${TAP_DIR}..."
mkdir -p "${TAP_DIR}/Formula"

# Generate the side-channel formula. Differences from the real formula:
#
#   * Class name `SimUseDryrun` and formula name `sim-use-dryrun` —
#     distinct from `SimUse`/`sim-use` so the real install (if present)
#     stays untouched. The keg path becomes
#     `${CELLAR}/sim-use-dryrun/${VERSION}/...` and brew won't symlink
#     anything called `sim-use` into `${BIN}/`.
#   * `url "file://<absolute-path>"` — bypass the gh-CLI download
#     strategy entirely; we have the tarball on disk.
#   * No `bin.write_exec_script` — we don't want a `bin/sim-use` symlink
#     fighting the developer's real install.
#   * The `def test do` block mirrors the real formula's APK existence
#     assertion so `brew test ${FORMULA_NAME}` exercises the same
#     contract.
cat > "${FORMULA_PATH}" <<RUBY
class SimUseDryrun < Formula
  desc "Dry-run install of sim-use for release verification (do not use)"
  homepage "https://git.linecorp.com/LINE-Client/sim-use"
  url "file://${ARCHIVE}"
  version "${VERSION}"
  sha256 "${ARCHIVE_SHA256}"
  license "MIT"
  depends_on macos: :sonoma

  def install
    libexec.install "sim-use",
                    "Frameworks",
                    "SimUse_SimUse.bundle",
                    "SimUse_AndroidBackend.bundle"
  end

  test do
    # Run the libexec binary directly since we did not write_exec_script.
    assert_match version.to_s, shell_output("#{libexec}/sim-use --version")
    assert_predicate libexec/"SimUse_AndroidBackend.bundle/Resources/sim-use-device-bridge.apk",
                     :exist?, "bundled Android bridge APK is missing"
  end
end
RUBY

# brew requires every tap to be a git repository. Initialise with one
# commit so brew's tap-walk doesn't trip on the unborn HEAD.
(
  cd "${TAP_DIR}"
  git init --quiet
  git -c user.email=verify@local -c user.name=verify add Formula/"${FORMULA_NAME}".rb
  git -c user.email=verify@local -c user.name=verify commit --quiet -m "sim-use-dryrun ${VERSION}"
)
ok "Tap initialised: ${TAP_REF}"

log "brew install ${TAP_REF}/${FORMULA_NAME}..."
brew install --formula "${TAP_REF}/${FORMULA_NAME}"

INSTALLED_KEG="$(brew --cellar)/${FORMULA_NAME}/${VERSION}"
INSTALLED_BIN="${INSTALLED_KEG}/libexec/sim-use"
INSTALLED_APK="${INSTALLED_KEG}/libexec/SimUse_AndroidBackend.bundle/Resources/sim-use-device-bridge.apk"
[[ -x "${INSTALLED_BIN}" ]] || fail "Installed binary missing or not executable at ${INSTALLED_BIN}"
[[ -f "${INSTALLED_APK}" ]] || fail "Installed APK missing at ${INSTALLED_APK}"
ok "brew install completed: ${INSTALLED_KEG}"

# APK bit-identical check. The build pipeline asserts the APK at
# stage-time; this re-assertion catches any mutation between stage → tar
# → brew install (e.g. brew accidentally relocating the bundle's contents).
INSTALLED_APK_SHA="$(shasum -a 256 "${INSTALLED_APK}" | awk '{print $1}')"
if [[ "${INSTALLED_APK_SHA}" != "${ARCHIVE_APK_SHA}" ]]; then
  fail "Brew-installed APK sha256 (${INSTALLED_APK_SHA}) differs from archive APK sha256 (${ARCHIVE_APK_SHA}). Something rewrote the APK during brew install."
fi
ok "APK bit-identical to source (sha256 ${INSTALLED_APK_SHA})"

# Codesign assessment. Capture the full -dvv output once; downstream
# checks read it without re-shelling.
SIG_INFO="$(codesign -dvv "${INSTALLED_BIN}" 2>&1)"

if [[ "${REQUIRE_DEVELOPER_ID}" == "true" ]]; then
  log "Asserting Developer ID signature is preserved..."
  if ! grep -q "TeamIdentifier=${EXPECTED_TEAM_ID}" <<<"${SIG_INFO}"; then
    echo "${SIG_INFO}" >&2
    fail "Brew install stripped the Developer ID signature. Expected TeamIdentifier=${EXPECTED_TEAM_ID}, got the codesign output above. This is the canonical symptom of brew's keg_relocate.rb deleting a duplicate rpath and ad-hoc resigning the binary — check scripts/release-artifacts.sh::verify_stage caught a duplicate, and scripts/build.sh::build_sim_use_executable emits only unique rpaths."
  fi
  if ! grep -q "Authority=Developer ID Application" <<<"${SIG_INFO}"; then
    echo "${SIG_INFO}" >&2
    fail "Brew-installed binary lacks 'Authority=Developer ID Application' in codesign output. Signing identity may have been replaced."
  fi
  ok "Developer ID signature preserved (TeamIdentifier=${EXPECTED_TEAM_ID})"
else
  log "Codesign output (Developer ID assertion not requested):"
  printf '%s\n' "${SIG_INFO}" | grep -E "Signature|Identifier|TeamIdentifier|Authority" || true
fi

if [[ "${REQUIRE_SPCTL_ACCEPT}" == "true" ]]; then
  log "Asserting spctl assessment passes..."
  # spctl is designed to assess `.app` bundles. For a flat CLI Mach-O it
  # always exits non-zero with `rejected (the code is valid but does not
  # seem to be an app)` — counter-intuitive, but the "the code is valid"
  # phrase is spctl's affirmation that the signature + notary chain are
  # reachable. The actual failure mode we care about is when spctl can't
  # confirm validity — typically `a sealed resource is missing or
  # invalid` or a bare `rejected` without the "code is valid" qualifier.
  # The accompanying `origin=Developer ID Application: ...` line is
  # spctl's report of which authority signed the binary; mirror that
  # against EXPECTED_TEAM_ID as the load-bearing check.
  set +e
  spctl_out="$(spctl -a -vv "${INSTALLED_BIN}" 2>&1)"
  set -e
  if grep -q "the code is valid" <<<"${spctl_out}" \
     && grep -q "origin=Developer ID Application:.*(${EXPECTED_TEAM_ID})" <<<"${spctl_out}"; then
    ok "spctl confirms code is valid + signed by ${EXPECTED_TEAM_ID}"
  elif grep -q "accepted" <<<"${spctl_out}"; then
    ok "spctl accepted: ${spctl_out}"
  else
    echo "${spctl_out}" >&2
    fail "spctl could not confirm the brew-installed binary's signature chain. Output above. Notarization stapling may not have survived brew install."
  fi
fi

log "Running brew test ${FORMULA_NAME}..."
brew test "${FORMULA_NAME}"
ok "brew test passed"

ok "verify-brew-install succeeded: brew install path preserves the release shape."
