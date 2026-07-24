#!/usr/bin/env bash

set -euo pipefail

# Shared payload helper
# shellcheck source=./release-payload.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-payload.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/release-artifacts.sh extract-stage --package-zip ZIP --stage-dir DIR
  scripts/release-artifacts.sh stage-build-output --build-output-dir DIR --stage-dir DIR
  scripts/release-artifacts.sh verify-stage --stage-dir DIR
  scripts/release-artifacts.sh create-universal-archive --stage-dir DIR --archive PATH
  scripts/release-artifacts.sh create-homebrew-archive --stage-dir DIR --archive PATH
  scripts/release-artifacts.sh smoke-test-stage --stage-dir DIR
  scripts/release-artifacts.sh smoke-test-archive --archive PATH
EOF
}

fail() {
  echo "❌ $*" >&2
  exit 1
}

require_arg() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "Missing required argument: $name"
}

verify_arch() {
  local binary_path="$1"
  local expected_arch="$2"

  [[ -f "$binary_path" ]] || fail "Binary not found: $binary_path"

  local arch_info
  arch_info="$(lipo -info "$binary_path" 2>/dev/null || true)"
  [[ "$arch_info" == *"$expected_arch"* ]] || fail "Missing architecture '$expected_arch' in $binary_path"
}

strip_signatures() {
  local stage_dir="$1"

  while IFS= read -r -d '' file_path; do
    if file "$file_path" | grep -q "Mach-O"; then
      codesign --remove-signature "$file_path" 2>/dev/null || true
    fi
  done < <(find "$stage_dir" -type f -print0)

  while IFS= read -r -d '' bundle_path; do
    codesign --remove-signature "$bundle_path" 2>/dev/null || true
  done < <(find "$stage_dir" \( -type d -name "*.framework" -o -type d -name "*.bundle" \) -print0)
}

extract_stage() {
  local package_zip="$1"
  local stage_dir="$2"
  local extract_root

  [[ -f "$package_zip" ]] || fail "Package zip not found: $package_zip"

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"

  extract_root="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-release-stage.XXXXXX")"

  ditto -x -k "$package_zip" "$extract_root"

  local top_level_dir_count
  local top_level_file_count
  local package_root

  top_level_dir_count="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  top_level_file_count="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')"

  if [[ "$top_level_dir_count" -eq 1 && "$top_level_file_count" -eq 0 ]]; then
    package_root="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | head -1)"
  else
    package_root="$extract_root"
  fi

  copy_release_payload "$package_root" "$stage_dir"
  rm -rf "$extract_root"
  echo "✅ Extracted staged payload to $stage_dir"
}

stage_build_output() {
  local build_output_dir="$1"
  local stage_dir="$2"

  copy_release_payload "$build_output_dir" "$stage_dir"
  echo "✅ Materialized staged payload from build output to $stage_dir"
}

# Resource root of a staged SwiftPM resource bundle. The classic SwiftPM
# backend lays resources flat at the bundle root; the SwiftBuild backend
# (Xcode 26.6+/27 toolchains) produces macOS-shaped bundles with resources
# under Contents/Resources. Runtime lookups go through the Bundle API and
# are layout-agnostic, so the stage checks must accept both shapes.
bundle_resource_root() {
  local bundle_dir="$1"
  if [[ -d "$bundle_dir/Contents/Resources" ]]; then
    echo "$bundle_dir/Contents/Resources"
  else
    echo "$bundle_dir"
  fi
}

verify_stage() {
  local stage_dir="$1"
  local android_bundle
  local apk_path
  local apk_bytes

  [[ -d "$stage_dir" ]] || fail "Stage directory not found: $stage_dir"
  [[ -x "$stage_dir/sim-use" ]] || fail "Stage is missing executable sim-use"
  [[ -d "$stage_dir/SimUse_SimUse.bundle" ]] || fail "Stage is missing SimUse_SimUse.bundle"

  # Viewer SPA contract. SwiftPM's `.copy("Resources/viewer")` in
  # Package.swift (target "SimUse") drops the directory at the bundle's
  # resource root, so the entry point lands at
  # `<resource root>/viewer/index.html` (see bundle_resource_root for
  # the flat vs Contents/Resources layouts). If a future Package.swift
  # change reshapes that, this check trips — canonical "release went
  # out without `sim-use viewer`" failure mode.
  local simuse_resources
  simuse_resources="$(bundle_resource_root "$stage_dir/SimUse_SimUse.bundle")"
  local viewer_index="$simuse_resources/viewer/index.html"
  [[ -f "$viewer_index" ]] \
    || fail "Stage is missing Viewer SPA at ${viewer_index}. Run scripts/build-viewer.sh then re-stage."
  local viewer_asset_count
  viewer_asset_count="$(find "$simuse_resources/viewer/assets" -type f 2>/dev/null | wc -l | tr -d ' ')"
  (( viewer_asset_count > 0 )) || fail "Stage has no Viewer assets under ${simuse_resources}/viewer/assets/. Run scripts/build-viewer.sh then re-stage."

  # AndroidBackend bundle + bundled APK contract. SwiftPM's `.copy("Resources")`
  # declaration in Package.swift (target "AndroidBackend") preserves the
  # directory verbatim, so the APK lands at
  # `<resource root>/Resources/sim-use-device-bridge.apk`.
  # If a future Package.swift change switches the declaration shape or
  # SwiftPM changes its `.copy` semantics, this check will fail loudly —
  # that's the intended signal. A missing APK here is the canonical
  # "release went out without Android support" failure mode.
  android_bundle="$stage_dir/SimUse_AndroidBackend.bundle"
  [[ -d "$android_bundle" ]] || fail "Stage is missing SimUse_AndroidBackend.bundle (no Android bridge APK will ship)"
  apk_path="$(bundle_resource_root "$android_bundle")/Resources/sim-use-device-bridge.apk"
  [[ -f "$apk_path" ]] || fail "Stage is missing sim-use-device-bridge.apk at ${apk_path}. Run scripts/build-bridge.sh then re-stage."
  apk_bytes="$(wc -c < "$apk_path" | tr -d ' ')"
  (( apk_bytes > 100000 )) || fail "Staged APK suspiciously small (${apk_bytes} bytes) at ${apk_path}"
  # APKs are zip files; first 2 bytes are "PK". Read raw bytes
  # directly rather than the previous `head -c 4 | od -An -c |
  # tr -d ' ' | grep '^PK'` pipeline which collapsed octal
  # escapes (worked for our path but obscured what was being
  # checked).
  local apk_magic
  apk_magic="$(head -c 2 "$apk_path")"
  [[ "$apk_magic" == "PK" ]] \
    || fail "Staged APK at ${apk_path} does not look like a zip file (first 2 bytes != 'PK')"

  verify_arch "$stage_dir/sim-use" "arm64"
  verify_arch "$stage_dir/sim-use" "x86_64"

  # Reject any executable whose rpath set contains duplicates (after
  # normalising @loader_path == @executable_path for the main binary, the
  # way Homebrew's relocate pass does). Homebrew's keg_relocate.rb deletes
  # duplicate rpaths and ad-hoc resigns the binary on any modification —
  # destroying the upstream Developer ID + Apple notary signature we
  # spent the previous stage attaching. Catching the duplicate at the
  # stage step turns a silent "user-installed sim-use is ad-hoc" footgun
  # into a loud build-time failure with the canonical fix
  # (`scripts/build.sh::build_sim_use_executable` rpath block).
  local -a raw_rpaths normalized_rpaths
  local rpath norm dup_rpaths
  mapfile -t raw_rpaths < <(otool -arch arm64 -l "$stage_dir/sim-use" 2>/dev/null | awk '/LC_RPATH/{r=1} r==1 && /path/{print $2; r=0}')
  for rpath in "${raw_rpaths[@]}"; do
    norm="$rpath"
    norm="${norm//@loader_path/__EXE__}"
    norm="${norm//@executable_path/__EXE__}"
    normalized_rpaths+=("$norm")
  done
  dup_rpaths="$(printf '%s\n' "${normalized_rpaths[@]}" | sort | uniq -d | tr '\n' ' ')"
  if [[ -n "${dup_rpaths// /}" ]]; then
    fail "Executable has duplicate rpaths (post-normalisation): ${dup_rpaths%% }. Homebrew's relocate pass will strip duplicates and ad-hoc resign, destroying any Developer ID + notary signature. Fix the rpath block in scripts/build.sh::build_sim_use_executable so the emitted set is unique after @loader_path/@executable_path collapse."
  fi

  echo "✅ Verified staged payload contract and architectures (incl. Android bridge APK ${apk_bytes} bytes, Viewer ${viewer_asset_count} assets)"
}

create_archive() {
  local stage_dir="$1"
  local archive_path="$2"
  local strip_before_archive="$3"
  local archive_root

  verify_stage "$stage_dir"

  archive_root="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-release-archive.XXXXXX")"

  cp -R "$stage_dir"/. "$archive_root"/

  if [[ "$strip_before_archive" == "true" ]]; then
    strip_signatures "$archive_root"
  fi

  rm -f "$archive_path"
  mkdir -p "$(dirname "$archive_path")"
  tar -czf "$archive_path" -C "$archive_root" .
  rm -rf "$archive_root"
  echo "✅ Created archive: $archive_path"
}

smoke_test_stage() {
  local stage_dir="$1"

  verify_stage "$stage_dir"
  "$stage_dir/sim-use" --version >/dev/null
  "$stage_dir/sim-use" init --print | grep -q "name: sim-use"
  echo "✅ Smoke-tested staged payload"
}

smoke_test_archive() {
  local archive_path="$1"
  local stage_dir

  [[ -f "$archive_path" ]] || fail "Archive not found: $archive_path"

  stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-release-smoke.XXXXXX")"

  tar -xzf "$archive_path" -C "$stage_dir"
  smoke_test_stage "$stage_dir"
  rm -rf "$stage_dir"
  echo "✅ Smoke-tested archive: $archive_path"
}

command_name="${1:-}"
shift || true

package_zip=""
build_output_dir=""
stage_dir=""
archive_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-zip)
      package_zip="${2:-}"
      shift 2
      ;;
    --build-output-dir)
      build_output_dir="${2:-}"
      shift 2
      ;;
    --stage-dir)
      stage_dir="${2:-}"
      shift 2
      ;;
    --archive)
      archive_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "$command_name" in
  extract-stage)
    require_arg --package-zip "$package_zip"
    require_arg --stage-dir "$stage_dir"
    extract_stage "$package_zip" "$stage_dir"
    ;;
  stage-build-output)
    require_arg --build-output-dir "$build_output_dir"
    require_arg --stage-dir "$stage_dir"
    stage_build_output "$build_output_dir" "$stage_dir"
    ;;
  verify-stage)
    require_arg --stage-dir "$stage_dir"
    verify_stage "$stage_dir"
    ;;
  create-universal-archive)
    require_arg --stage-dir "$stage_dir"
    require_arg --archive "$archive_path"
    create_archive "$stage_dir" "$archive_path" false
    ;;
  create-homebrew-archive)
    require_arg --stage-dir "$stage_dir"
    require_arg --archive "$archive_path"
    create_archive "$stage_dir" "$archive_path" true
    ;;
  smoke-test-stage)
    require_arg --stage-dir "$stage_dir"
    smoke_test_stage "$stage_dir"
    ;;
  smoke-test-archive)
    require_arg --archive "$archive_path"
    smoke_test_archive "$archive_path"
    ;;
  ''|-h|--help|help)
    usage
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
