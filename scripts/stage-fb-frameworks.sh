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

config="${1:-Debug}"
slice="macos-arm64_x86_64"
products=".build/out/Products/${config}"
xcframeworks="$(pwd)/build_products/XCFrameworks"

mkdir -p "${products}/PackageFrameworks"
for f in FBControlCore FBSimulatorControl FBDeviceControl XCTestBootstrap; do
  ln -sfn "${xcframeworks}/${f}.xcframework/${slice}/${f}.framework" \
    "${products}/PackageFrameworks/${f}.framework"
done
