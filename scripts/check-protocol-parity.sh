#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Verify that the bridge wire protocol_version is synchronised between
# the Kotlin source (`bridge/app/build.gradle.kts` →
# `BuildConfig.PROTOCOL_VERSION`) and the Swift source
# (`Sources/AndroidBackend/Bridge/BridgeClient.swift` →
# `BridgeClient.expectedProtocolVersion`).
#
# Drift between the two halves means the client and the bridge disagree
# on what wire shape they speak; runtime detection (BridgeClient pings,
# `BridgeError.protocolMismatch`) catches it after the fact, but the
# canonical way to keep them aligned is for the human who bumps one to
# bump the other in the same commit. This script makes the requirement
# mechanical: run it before a release cut, in CI, or as a pre-commit
# hook to refuse a drifted tree.
#
# Exits 0 on parity, non-zero with a diagnostic on drift or missing
# source files. No dependencies beyond a POSIX shell + grep + sed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRADLE="${ROOT}/bridge/app/build.gradle.kts"
SWIFT="${ROOT}/Sources/AndroidBackend/Bridge/BridgeClient.swift"

[[ -f "$GRADLE" ]] || { echo "error: $GRADLE not found" >&2; exit 2; }
[[ -f "$SWIFT"  ]] || { echo "error: $SWIFT not found"  >&2; exit 2; }

# Kotlin side: `buildConfigField("int", "PROTOCOL_VERSION", "1")` —
# capture the third argument's integer literal. We anchor on the field
# name so unrelated `buildConfigField` lines (if any are ever added)
# can't shadow it.
KOTLIN_VER="$(
  grep -E 'buildConfigField\(.*"PROTOCOL_VERSION"' "$GRADLE" \
    | sed -E 's/.*"PROTOCOL_VERSION"[^"]*"([0-9]+)".*/\1/' \
    | head -n1
)"

# Swift side: `public static let expectedProtocolVersion = 1`. Capture
# the integer literal on the RHS. Anchored on the identifier so a
# future overload or doc comment mentioning the same name doesn't
# match.
SWIFT_VER="$(
  grep -E 'expectedProtocolVersion[[:space:]]*=[[:space:]]*[0-9]+' "$SWIFT" \
    | sed -E 's/.*expectedProtocolVersion[[:space:]]*=[[:space:]]*([0-9]+).*/\1/' \
    | head -n1
)"

if [[ -z "$KOTLIN_VER" ]]; then
  echo "error: could not parse PROTOCOL_VERSION from $GRADLE" >&2
  exit 3
fi
if [[ -z "$SWIFT_VER" ]]; then
  echo "error: could not parse expectedProtocolVersion from $SWIFT" >&2
  exit 3
fi

if [[ "$KOTLIN_VER" != "$SWIFT_VER" ]]; then
  cat >&2 <<EOF
error: bridge protocol_version drift detected
  Kotlin (bridge):  $KOTLIN_VER  ($GRADLE)
  Swift  (client):  $SWIFT_VER  ($SWIFT)
Bump both halves in the same commit. AGENTS.md → "Bridge wire spec".
EOF
  exit 1
fi

echo "✓ Bridge protocol_version in sync: $KOTLIN_VER"
