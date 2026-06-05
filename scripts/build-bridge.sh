#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the sim-use-device-bridge APK and copy it into the SwiftPM
# resource directory consumed by `AndroidBackend`. The release scripts
# rely on this script to refresh the bundled APK before `swift build`
# picks it up — so it
# needs to be self-sufficient: detect a suitable JDK + Android SDK on
# the host, or fail loudly with a clear remediation hint.
#
# Detection order (skip a step by setting the matching env var):
#
#   JDK            JAVA_HOME → Android Studio JBR (~/Applications + /Applications)
#                  → /usr/libexec/java_home → `java` on PATH. Must be
#                  JDK 17–21 (Gradle 8.7 caps at 21).
#
#   Android SDK    ANDROID_SDK_ROOT → ANDROID_HOME → ~/Library/Android/sdk.
#                  Exported as ANDROID_HOME for child gradle if discovered.
#
#   Gradle         bridge/gradlew (wrapper, preferred). System `gradle`
#                  is used only when the wrapper is missing.
#
# Usage:
#   scripts/build-bridge.sh           # build and copy APK
#   scripts/build-bridge.sh --check   # report tool detection only, no build
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bridge_dir="$repo_root/bridge"
output_apk="$bridge_dir/app/build/outputs/apk/release/app-release.apk"
resource_dir="$repo_root/Sources/AndroidBackend/Resources"
resource_apk="$resource_dir/sim-use-device-bridge.apk"

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
fi

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── JDK detection ───────────────────────────────────────────────────
# Gradle 8.7 (used by the bridge wrapper) supports JDK 8 through 21.
# Practically we want 17–21: the bridge's compileOptions pin
# sourceCompatibility = 17, and the Kotlin Android plugin won't accept
# anything below 17. JDK 22+ would work on newer Gradle but breaks 8.7.
discover_java_home() {
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    echo "$JAVA_HOME"
    return 0
  fi
  local candidates=(
    "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    "/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}/bin/java" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  if command -v /usr/libexec/java_home >/dev/null 2>&1; then
    # Walk the supported range from highest to lowest so a host
    # with multiple JDKs picks the newest acceptable version
    # rather than skipping straight from 17 to 21 (the old loop
    # missed any developer with only JDK 18 / 19 / 20 installed
    # and threw a "no JDK found" even though Gradle 8.7 happily
    # accepts those).
    for v in 21 20 19 18 17; do
      if /usr/libexec/java_home -v "$v" >/dev/null 2>&1; then
        /usr/libexec/java_home -v "$v" && return 0
      fi
    done
  fi
  if command -v java >/dev/null 2>&1; then
    local java_bin
    java_bin="$(command -v java)"
    # Resolve symlinks (`brew install openjdk` puts a shim that
    # points to the real home one directory above bin/). macOS
    # stock doesn't include `realpath`; fall back to a Python
    # `os.path.realpath` shim which is cross-platform.
    if command -v realpath >/dev/null 2>&1; then
      java_bin="$(realpath "$java_bin")"
    elif command -v python3 >/dev/null 2>&1; then
      java_bin="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$java_bin")"
    fi
    echo "$(dirname "$(dirname "$java_bin")")"
    return 0
  fi
  return 1
}

validate_java_version() {
  local java_home="$1"
  local version_line major
  version_line="$("${java_home}/bin/java" -version 2>&1 | head -1)"
  major="$(printf '%s\n' "$version_line" \
    | sed -E 's/^[^"]*"([0-9]+)([.\\-].*)?".*$/\1/')"
  if ! [[ "$major" =~ ^[0-9]+$ ]]; then
    fail "Could not parse JDK version from: ${version_line}"
  fi
  if (( major < 17 )); then
    fail "JDK at ${java_home} is too old (major=${major}). Bridge requires JDK 17+; Gradle 8.7 caps at 21. Install Android Studio (bundles JBR 21) or 'brew install openjdk@17'."
  fi
  if (( major > 21 )); then
    fail "JDK at ${java_home} is too new (major=${major}). Gradle 8.7 (bridge/gradle/wrapper) caps at JDK 21. Set JAVA_HOME to a JDK 17–21, e.g. \$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home."
  fi
  echo "$major"
}

# ── Android SDK detection ───────────────────────────────────────────
discover_android_sdk() {
  if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT" ]]; then
    echo "$ANDROID_SDK_ROOT"
    return 0
  fi
  if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME" ]]; then
    echo "$ANDROID_HOME"
    return 0
  fi
  if [[ -d "$HOME/Library/Android/sdk" ]]; then
    echo "$HOME/Library/Android/sdk"
    return 0
  fi
  return 1
}

# ── Resolve toolchain ───────────────────────────────────────────────
log "Resolving JDK..."
if ! JAVA_HOME_RESOLVED="$(discover_java_home)"; then
  fail "No JDK found. Install Android Studio (bundles JBR 21) or 'brew install openjdk@17', then re-run."
fi
JAVA_MAJOR="$(validate_java_version "$JAVA_HOME_RESOLVED")"
ok "  JAVA_HOME=${JAVA_HOME_RESOLVED} (JDK ${JAVA_MAJOR})"
export JAVA_HOME="$JAVA_HOME_RESOLVED"
export PATH="${JAVA_HOME}/bin:${PATH}"

log "Resolving Android SDK..."
if ! ANDROID_SDK_RESOLVED="$(discover_android_sdk)"; then
  fail "Android SDK not found. Install via Android Studio (default path: ~/Library/Android/sdk) or set ANDROID_SDK_ROOT."
fi
ok "  ANDROID_HOME=${ANDROID_SDK_RESOLVED}"
export ANDROID_HOME="$ANDROID_SDK_RESOLVED"
export ANDROID_SDK_ROOT="$ANDROID_SDK_RESOLVED"

# ── Resolve Gradle ──────────────────────────────────────────────────
gradle_cmd=""
if [[ -x "$bridge_dir/gradlew" ]]; then
  gradle_cmd="$bridge_dir/gradlew"
  ok "  gradle: $bridge_dir/gradlew (wrapper)"
elif command -v gradle >/dev/null 2>&1; then
  gradle_cmd="gradle"
  ok "  gradle: system 'gradle' on PATH"
else
  fail "Neither bridge/gradlew nor system gradle found. The gradle wrapper should be committed; check 'git status' for bridge/gradle/wrapper/."
fi

if [[ "$check_only" == "true" ]]; then
  ok "Toolchain check passed. Run without --check to actually build."
  exit 0
fi

# ── Build APK ───────────────────────────────────────────────────────
log "Assembling release APK..."
(cd "$bridge_dir" && "$gradle_cmd" :app:assembleRelease)

if [[ ! -f "$output_apk" ]]; then
  fail "APK not produced at $output_apk (gradle reported success but file is missing — inspect bridge/app/build/outputs/)"
fi

mkdir -p "$resource_dir"
cp "$output_apk" "$resource_apk"

apk_bytes=$(wc -c < "$resource_apk" | tr -d '[:space:]')
ok "Copied APK to $resource_apk (${apk_bytes} bytes)"
