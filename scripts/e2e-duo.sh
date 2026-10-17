#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# Runs the iOS E2E suites that cover multi-display simulators on an iPhone
# Duo (docs/ai/010-display-routing). The default suite list also contains
# them, but they skip on a single-display simulator; this wrapper picks a
# Duo so they run.
#
#   SIMULATOR_UDID               use this simulator instead of picking one
#   SIM_USE_TEST_DEVELOPER_DIR   Xcode used for simctl and the Playground build.
#                                Default: the newest installed Xcode 27.1 or later,
#                                whose SDK adapts the app fully to the Duo. An
#                                Xcode 27.0 build keeps out of the cover display's
#                                status bar strip, and an older SDK runs centred.
#
# Arguments are suite filters passed to scripts/test-runner.sh; without
# them the display-routing suites and the suites whose expectations do not
# depend on an iPhone layout run. DescribeUITests and SwipeTests pin iPhone 17
# frames, TypeTests a US keyboard layout, and TapTests taps the back button by
# its title, which an iOS 27.1 SDK app on the Duo cover display does not show:
# the button moves into the vertical bar with an empty label.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${SIMULATOR_UDID:-}" ]]; then
    # Prefer a booted iPhone Duo, then any available one.
    SIMULATOR_UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if "iPhone Duo" in d["name"]]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")
')
fi
if [[ -z "$SIMULATOR_UDID" ]]; then
    echo "No iPhone Duo simulator found. Install the iOS 27.1 runtime (Xcode 27.1+) and create one, or set SIMULATOR_UDID." >&2
    exit 1
fi
export SIMULATOR_UDID

if [[ -z "${SIM_USE_TEST_DEVELOPER_DIR:-}" ]]; then
    best=""
    best_version=""
    for app in /Applications/Xcode*.app; do
        version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
        [[ -z "$version" ]] && continue
        # Keep the highest version that is 27.1 or later.
        if [[ "$(printf '%s\n%s\n' "27.1" "$version" | sort -V | head -1)" == "27.1" ]] &&
           [[ -z "$best_version" || "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -1)" == "$version" ]]; then
            best="$app/Contents/Developer"
            best_version="$version"
        fi
    done
    if [[ -n "$best" ]]; then
        export SIM_USE_TEST_DEVELOPER_DIR="$best"
        echo "Using Xcode $best_version for simctl and the Playground build ($best)"
    fi
fi

# A Playground built with the iOS 27.1 SDK or later shows the vertical bar
# on the cover display, so SideBarOutlineTests must find it there.
playground_xcode_version=$(defaults read "${SIM_USE_TEST_DEVELOPER_DIR:-$(xcode-select -p)}/../Info" CFBundleShortVersionString 2>/dev/null || true)
if [[ -n "$playground_xcode_version" && "$(printf '%s\n%s\n' "27.1" "$playground_xcode_version" | sort -V | head -1)" == "27.1" ]]; then
    export SIM_USE_E2E_EXPECT_SIDE_BAR=1
fi

if [[ $# -eq 0 ]]; then
    set -- FoldTests RotateTests ResizeModeTests ScreenshotTests UICoordinateDefaultTests SideBarOutlineTests RoutedVideoTests
fi
exec ./scripts/test-runner.sh "$@"
