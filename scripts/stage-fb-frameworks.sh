#!/bin/bash
# Newer SwiftPM (the SwiftBuild backend used by Xcode 26.6+ / Xcode 27
# toolchains) lays products out under .build/out/Products/<config> and emits
# no LC_RPATH entries for binary-target XCFrameworks — so the sim-use binary
# and the SimUseTests bundle fail to dlopen the FB* frameworks at load time.
# dyld does still search the sibling PackageFrameworks directory, so stage
# symlinks to the frameworks there. Pre-creates the directory so it also
# works on a fresh checkout where `swift test` builds and loads in one go.
# Harmless no-op content for the classic .build/<config> layout (<= 26.5),
# which keeps working through its own rpaths.
set -euo pipefail

# Run relative to the repository root regardless of the caller's CWD.
cd "$(dirname "$0")/.."

# Scope: the dev loop (Debug builds via make/the E2E runners). Pass a
# configuration as $1 for other cases (e.g. a manual
# `swift build -c release` needs "Release"); local release-config builds
# are also covered by the rpath entries Package.swift emits.
config="${1:-Debug}"
slice="macos-arm64_x86_64"
products=".build/out/Products/${config}"
xcframeworks="$(pwd)/build_products/XCFrameworks"

# Nothing to stage before scripts/build.sh has produced the XCFrameworks
# (and without them the build would fail anyway); also avoids dangling
# symlinks on a fresh checkout.
[ -d "${xcframeworks}" ] || exit 0

# The directory is created even if the current toolchain uses the classic
# layout (which never reads it): the layout cannot be known without
# building, and pre-creating keeps a fresh-clone `swift test` working on
# SwiftBuild toolchains, where build and bundle-load happen in one go.
mkdir -p "${products}/PackageFrameworks"
for f in FBControlCore FBSimulatorControl FBDeviceControl XCTestBootstrap; do
  ln -sfn "${xcframeworks}/${f}.xcframework/${slice}/${f}.framework" \
    "${products}/PackageFrameworks/${f}.framework"
done
