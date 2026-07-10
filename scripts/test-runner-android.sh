#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# sim-use Android E2E Test Runner
# Builds the sim-use CLI + Android playground fixture, installs it on a
# connected emulator/device, initialises the bridge, then runs the
# Android device E2E suites one-by-one with a pass/fail summary.
#
# Usage:
#   scripts/test-runner-android.sh                 # full build + all suites
#   scripts/test-runner-android.sh -t              # skip build, run suites
#   scripts/test-runner-android.sh -b              # build + install only
#   ANDROID_SERIAL=emulator-5555 scripts/test-runner-android.sh
#   scripts/test-runner-android.sh AndroidTapTests # single suite

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
PLAYGROUND_PACKAGE="com.linecorp.simuse.playground"
PLAYGROUND_APK="bridge/playground/build/outputs/apk/debug/playground-debug.apk"

ALL_SUITES=(
    "AndroidTapTests"
    "AndroidSwipeScrollTests"
    "AndroidTypeTests"
    "AndroidKeyboardStateTests"
    "AndroidMultiTouchTests"
    "AndroidButtonTests"
    "AndroidDescribeUITests"
)

print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }
print_header() {
    echo -e "\n${BLUE}================================================${NC}"
    echo -e "${BLUE}🤖 $1${NC}"
    echo -e "${BLUE}================================================${NC}\n"
}

show_usage() {
    echo "Usage: $0 [OPTIONS] [SUITE_FILTER]"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -b, --build-only    Build CLI + playground and install (skip tests)"
    echo "  -t, --tests-only    Only run tests (skip building/installing)"
    echo ""
    echo "Environment:"
    echo "  ANDROID_SERIAL      adb serial of the target device (default: emulator-5554)"
    echo ""
    echo "Suite filters (optional): ${ALL_SUITES[*]}"
}

BUILD_ONLY=false
TESTS_ONLY=false
SUITE_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_usage; exit 0 ;;
        -b|--build-only) BUILD_ONLY=true; shift ;;
        -t|--tests-only) TESTS_ONLY=true; shift ;;
        Android*) SUITE_FILTER="$1"; shift ;;
        *) print_error "Unknown option: $1"; show_usage; exit 1 ;;
    esac
done

# Resolve adb the same way scripts/build-bridge.sh resolves the SDK root.
resolve_adb() {
    local roots=("${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Library/Android/sdk")
    local root
    for root in "${roots[@]}"; do
        if [[ -n "$root" && -x "$root/platform-tools/adb" ]]; then
            echo "$root/platform-tools/adb"; return 0
        fi
    done
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    return 1
}

check_prerequisites() {
    print_header "Checking Prerequisites"

    if [[ ! -f "Package.swift" ]]; then
        print_error "Package.swift not found. Run from the sim-use project root."
        exit 1
    fi
    if ! command -v swift >/dev/null 2>&1; then
        print_error "swift not found. Please install Swift."
        exit 1
    fi
    if ! ADB="$(resolve_adb)"; then
        print_error "adb not found. Install Android platform-tools or set ANDROID_HOME."
        exit 1
    fi
    print_info "adb: $ADB"

    local state
    state="$("$ADB" -s "$ANDROID_SERIAL" get-state 2>/dev/null || echo "unknown")"
    if [[ "$state" != "device" ]]; then
        print_error "Device '$ANDROID_SERIAL' is not online (state: $state)."
        print_info "Attached devices:"
        "$ADB" devices
        exit 1
    fi
    print_success "Device $ANDROID_SERIAL is online"
}

build_sim_use() {
    print_header "Building sim-use Executable"
    swift build
    SIM_USE="$(swift build --show-bin-path)/sim-use"
    if [[ ! -x "$SIM_USE" ]]; then
        print_error "sim-use binary not found at $SIM_USE"
        exit 1
    fi
    print_success "sim-use built: $SIM_USE"
}

build_and_install_playground() {
    print_header "Building & Installing Playground APK"

    ./scripts/build-playground-android.sh
    if [[ ! -f "$PLAYGROUND_APK" ]]; then
        print_error "Playground APK missing at $PLAYGROUND_APK"
        exit 1
    fi

    print_info "Installing on $ANDROID_SERIAL..."
    "$ADB" -s "$ANDROID_SERIAL" install -r "$PLAYGROUND_APK" >/dev/null
    print_success "Playground installed ($PLAYGROUND_PACKAGE)"

    # The keyboard-state suite needs the soft IME to appear even when the
    # emulator advertises a hardware keyboard.
    "$ADB" -s "$ANDROID_SERIAL" shell settings put secure show_ime_with_hard_keyboard 1 || \
        print_warning "Could not set show_ime_with_hard_keyboard (keyboard suite may be flaky)"
}

init_bridge() {
    print_header "Initialising Device Bridge"
    # Idempotent — safe to re-run on an already-initialised device.
    if "$SIM_USE" android init --device "$ANDROID_SERIAL"; then
        print_success "Bridge ready on $ANDROID_SERIAL"
    else
        print_error "sim-use android init failed on $ANDROID_SERIAL"
        exit 1
    fi
}

run_suite() {
    local suite="$1"
    SIM_USE_E2E_ANDROID=1 ANDROID_SERIAL="$ANDROID_SERIAL" swift test --filter "$suite"
}

run_tests() {
    print_header "Running Android E2E Suites"

    local suites=()
    if [[ -n "$SUITE_FILTER" ]]; then
        suites=("$SUITE_FILTER")
    else
        suites=("${ALL_SUITES[@]}")
    fi

    local passed=()
    local failed=()
    for suite in "${suites[@]}"; do
        print_header "Running $suite"
        if run_suite "$suite"; then
            passed+=("$suite")
        else
            print_error "$suite failed"
            failed+=("$suite")
        fi
    done

    print_header "Android E2E Results"
    for suite in "${passed[@]}"; do print_success "$suite"; done
    for suite in "${failed[@]}"; do print_error "$suite"; done

    if [[ ${#failed[@]} -gt 0 ]]; then
        print_error "${#failed[@]} of ${#suites[@]} suites failed"
        exit 1
    fi
    print_success "All ${#suites[@]} suites passed"
}

main() {
    print_header "sim-use Android E2E Test Runner"
    check_prerequisites

    if [[ "$TESTS_ONLY" != true ]]; then
        build_sim_use
        build_and_install_playground
        init_bridge
    else
        SIM_USE="$(swift build --show-bin-path)/sim-use"
    fi

    if [[ "$BUILD_ONLY" != true ]]; then
        run_tests
    fi
}

main "$@"
