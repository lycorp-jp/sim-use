#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# sim-use Test Runner Script
# Automates building sim-use executable, playground app, and running tests

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
SIMULATOR_UDID="${SIMULATOR_UDID:-}"
PLAYGROUND_PROJECT="Playgrounds/iOS/SimUsePlayground.xcodeproj"
PLAYGROUND_SCHEME="SimUsePlayground"
BUNDLE_ID="com.cameroncooke.SimUsePlayground"

# E2E matrix support (scripts/e2e-matrix.sh): when SIM_USE_TEST_DEVELOPER_DIR
# is set, simulator control and the playground build run against that Xcode
# while `swift build` / `swift test` stay on the xcode-select toolchain
# (build_products/ is toolchain-locked). Tests/TestUtilities.swift injects
# the same value as DEVELOPER_DIR into every process the suites spawn, so
# the sim-use binary under test resolves the same Xcode at runtime.
TARGET_DEVELOPER_DIR="${SIM_USE_TEST_DEVELOPER_DIR:-}"

# Per-Xcode playground DerivedData, so alternating matrix legs stay
# incremental instead of clobbering each other's caches.
PLAYGROUND_DD_ARGS=()
if [[ -n "$TARGET_DEVELOPER_DIR" ]]; then
    PLAYGROUND_DD_ARGS=(-derivedDataPath ".build/e2e-derived-data/${TARGET_DEVELOPER_DIR//\//-}")
fi

# The smoke tier: the minimal cross-environment slice the matrix runner
# uses on secondary legs — describe-ui, tap, type, and the scroll presets.
SMOKE_FILTERS=("DescribeUITests" "TapTests" "TypeTests" "GestureTests/scroll")

# Run a simulator/xcodebuild command against the target Xcode
# (passthrough when no matrix override is active).
run_target() {
    if [[ -n "$TARGET_DEVELOPER_DIR" ]]; then
        DEVELOPER_DIR="$TARGET_DEVELOPER_DIR" "$@"
    else
        "$@"
    fi
}

# Print colored messages
print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_header() {
    echo -e "\n${BLUE}================================================${NC}"
    echo -e "${BLUE}🎯 $1${NC}"
    echo -e "${BLUE}================================================${NC}\n"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [TEST_FILTER]"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -b, --build-only    Only build sim-use and playground app (skip tests)"
    echo "  -t, --tests-only    Only run tests (skip building)"
    echo "  -c, --clean         Clean build before building"
    echo "  -s, --sequential    Run suites one-by-one (single simulator-safe flow)"
    echo "  -v, --verbose       Verbose output"
    echo "      --smoke         Run the smoke tier only (describe-ui, tap, type, scroll)"
    echo ""
    echo "Test Filters (optional, repeatable):"
    echo "  Any 'swift test --filter' pattern: a suite name (TapTests), several"
    echo "  suites (TapTests TypeTests), or a case pattern (GestureTests/scroll)."
    echo ""
    echo "Environment:"
    echo "  SIMULATOR_UDID              Target simulator (default: newest available"
    echo "                              '$SIMULATOR_NAME')"
    echo "  SIM_USE_TEST_DEVELOPER_DIR  Xcode used for simctl / the playground build,"
    echo "                              injected as DEVELOPER_DIR into spawned sim-use"
    echo "                              processes (E2E matrix legs)"
    echo ""
    echo "Examples:"
    echo "  $0                  # Build everything and run all tests"
    echo "  $0 SwipeTests       # Build everything and run only swipe tests"
    echo "  $0 -t SwipeTests    # Skip building, run only swipe tests"
    echo "  $0 --smoke          # Build everything and run the smoke tier"
    echo "  $0 -b               # Only build, skip tests"
    echo "  $0 -c               # Clean build and run all tests"
}

# Parse command line arguments
BUILD_ONLY=false
TESTS_ONLY=false
CLEAN_BUILD=false
VERBOSE=false
SMOKE=false
TEST_FILTERS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -b|--build-only)
            BUILD_ONLY=true
            shift
            ;;
        -t|--tests-only)
            TESTS_ONLY=true
            shift
            ;;
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -s|--sequential)
            # Historical flag; sequential is the only mode now.
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --smoke)
            SMOKE=true
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            TEST_FILTERS+=("$1")
            shift
            ;;
    esac
done

if [[ "$SMOKE" == true ]]; then
    if [[ ${#TEST_FILTERS[@]} -gt 0 ]]; then
        print_error "--smoke and explicit test filters are mutually exclusive"
        exit 1
    fi
    TEST_FILTERS=("${SMOKE_FILTERS[@]}")
fi

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    # Check if we're in the right directory
    if [[ ! -f "Package.swift" ]]; then
        print_error "Package.swift not found. Please run this script from the sim-use project root."
        exit 1
    fi

    # Check if Xcode is available
    if ! command -v xcodebuild &> /dev/null; then
        print_error "xcodebuild not found. Please install Xcode."
        exit 1
    fi

    # Check if Swift is available
    if ! command -v swift &> /dev/null; then
        print_error "swift not found. Please install Swift."
        exit 1
    fi

    # Check if xcodegen is available (needed to generate the playground project)
    if ! command -v xcodegen &> /dev/null; then
        print_error "xcodegen not found. Install with: brew install xcodegen"
        exit 1
    fi

    print_success "All prerequisites satisfied"
}

# Function to boot simulator
boot_simulator() {
    print_header "Setting Up Simulator"

    if [[ -z "$SIMULATOR_UDID" ]]; then
        # Exact-name match ("iPhone 17 Pro" must not also catch "… Pro Max");
        # the newest available runtime wins (sections are listed oldest-first).
        SIMULATOR_UDID=$(run_target xcrun simctl list devices available \
            | grep -F "$SIMULATOR_NAME (" | grep -oE '[A-F0-9-]{36}' | tail -1)
    fi

    print_info "Checking simulator status..."
    SIMULATOR_STATUS=$(run_target xcrun simctl list devices | grep "$SIMULATOR_UDID" | grep -o "Booted\|Shutdown" || echo "NotFound")

    if [[ -z "$SIMULATOR_UDID" || "$SIMULATOR_STATUS" == "NotFound" ]]; then
        print_error "Simulator with UDID $SIMULATOR_UDID not found"
        print_info "Available simulators:"
        run_target xcrun simctl list devices | grep "iPhone"
        exit 1
    fi

    if [[ "$SIMULATOR_STATUS" != "Booted" ]]; then
        print_info "Booting simulator $SIMULATOR_NAME..."
        run_target xcrun simctl boot "$SIMULATOR_UDID"
        sleep 3
        print_success "Simulator booted"
    else
        print_success "Simulator already booted"
    fi
}

# Function to clean build
clean_build() {
    if [[ "$CLEAN_BUILD" == true ]]; then
        print_header "Cleaning Build"

        print_info "Cleaning Swift build..."
        swift package clean

        print_info "Cleaning Xcode build..."
        run_target xcodebuild clean -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID" "${PLAYGROUND_DD_ARGS[@]}"

        print_success "Build cleaned"
    fi
}

# Function to build sim-use executable
build_sim_use() {
    print_header "Building sim-use Executable"

    print_info "Building sim-use CLI tool..."
    if [[ "$VERBOSE" == true ]]; then
        swift build
    else
        swift build > /dev/null 2>&1
    fi

    local sim_use_bin_path
    sim_use_bin_path="$(swift build --show-bin-path)/sim-use"

    # Hand the resolved binary path to the test suites. Resolving it from
    # inside a running `swift test` deadlocks on SwiftBuild-backend
    # toolchains (Xcode 26.6+/27): the test run holds the package lock that
    # a child `swift build --show-bin-path` then waits on forever.
    export SIM_USE_TEST_BINARY="$sim_use_bin_path"

    # Verify the executable exists
    if [[ -f "$sim_use_bin_path" ]]; then
        print_success "sim-use executable built successfully"
        print_info "Location: $sim_use_bin_path"
    else
        print_error "Failed to build sim-use executable"
        exit 1
    fi
}

# Function to generate the Xcode project for the playground app
generate_playground_project() {
    print_header "Generating Playground Xcode Project"

    if [[ ! -f "Playgrounds/iOS/project.yml" ]]; then
        print_error "Playgrounds/iOS/project.yml not found."
        exit 1
    fi

    print_info "Running xcodegen..."
    (cd Playgrounds/iOS && xcodegen generate)
    print_success "Xcode project generated"
}

# Function to build and install playground app
build_playground_app() {
    print_header "Building and Installing Playground App"

    # Terminate existing app instance
    print_info "Terminating existing app instance..."
    run_target xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Build the app (not build-for-testing since this is a regular app)
    print_info "Building SimUsePlayground app..."
    if [[ "$VERBOSE" == true ]]; then
        run_target xcodebuild build \
            -project "$PLAYGROUND_PROJECT" \
            -scheme "$PLAYGROUND_SCHEME" \
            -destination "id=$SIMULATOR_UDID" \
            "${PLAYGROUND_DD_ARGS[@]}"
    else
        run_target xcodebuild build \
            -project "$PLAYGROUND_PROJECT" \
            -scheme "$PLAYGROUND_SCHEME" \
            -destination "id=$SIMULATOR_UDID" \
            "${PLAYGROUND_DD_ARGS[@]}" \
            -quiet > /dev/null 2>&1
    fi

    # Find the built app path using TARGET_BUILD_DIR + FULL_PRODUCT_NAME (more semantically correct)
    print_info "Getting app bundle path..."
    BUILD_SETTINGS=$(run_target xcodebuild -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID" "${PLAYGROUND_DD_ARGS[@]}" -showBuildSettings)
    TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | grep "TARGET_BUILD_DIR" | head -1 | sed 's/.*= //')
    FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | grep "FULL_PRODUCT_NAME" | head -1 | sed 's/.*= //')
    APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

    if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
        print_error "Built app not found at: $APP_PATH"
        print_info "TARGET_BUILD_DIR: $TARGET_BUILD_DIR"
        print_info "FULL_PRODUCT_NAME: $FULL_PRODUCT_NAME"
        exit 1
    fi

    # Install the app
    print_info "Installing SimUsePlayground app on simulator..."
    if [[ "$VERBOSE" == true ]]; then
        run_target xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
    else
        run_target xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH" > /dev/null 2>&1
    fi

    print_success "Playground app built and installed successfully"
    print_info "App path: $APP_PATH"
}

# Function to run tests
run_tests() {
    print_header "Running Tests"

    # Set up environment
    export SIMULATOR_UDID="$SIMULATOR_UDID"
    export SIM_USE_E2E=1

    print_info "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, SIM_USE_E2E=$SIM_USE_E2E"
    if [[ -n "$TARGET_DEVELOPER_DIR" ]]; then
        print_info "Target Xcode (via SIM_USE_TEST_DEVELOPER_DIR): $TARGET_DEVELOPER_DIR"
    fi

    run_swift_test() {
        local filter="$1"
        local cmd="swift test --filter '$filter'"

        if [[ "$VERBOSE" == true ]]; then
            cmd="$cmd --verbose"
        fi

        print_info "Test command: $cmd"
        eval "$cmd"
    }

    local suites=()
    if [[ ${#TEST_FILTERS[@]} -gt 0 ]]; then
        suites=("${TEST_FILTERS[@]}")
        if [[ "$SMOKE" == true ]]; then
            print_info "Running the smoke tier: ${suites[*]}"
        else
            print_info "Running selected filters: ${suites[*]}"
        fi
    else
        print_info "Running E2E suites one-by-one to avoid simulator contention"
        suites=(
            "BatchTests"
            "ButtonTests"
            "DescribeUITests"
            "GestureTests"
            "HIDRebootRecoveryTests"
            "InitTests"
            "KeyboardStateTests"
            "KeyComboTests"
            "KeySequenceTests"
            "KeyTests"
            "ListSimulatorsTests"
            "OrientationTests"
            "PasteTests"
            "PermissionAlertTests"
            "RecordVideoTests"
            "RemoteContentRecoveryTests"
            "ResizeModeTests"
            "ScreenshotTests"
            "StreamVideoDebugTest"
            "StreamVideoTests"
            "SwipeTests"
            "TapTests"
            "TouchTests"
            "TypeTests"
        )
    fi

    # Run every suite even after a failure so a single red suite does not
    # hide the state of the rest; report the full map at the end.
    local failed_suites=()
    local passed_suites=()
    echo ""
    for suite in "${suites[@]}"; do
        print_header "Running $suite"
        if run_swift_test "$suite"; then
            passed_suites+=("$suite")
        else
            print_error "$suite failed"
            failed_suites+=("$suite")
        fi
    done

    print_header "E2E suite results"
    for suite in "${passed_suites[@]}"; do
        print_success "$suite"
    done
    for suite in "${failed_suites[@]}"; do
        print_error "$suite"
    done
    if [[ ${#failed_suites[@]} -gt 0 ]]; then
        print_error "${#failed_suites[@]} of ${#suites[@]} suites failed"
        exit 1
    fi
    print_success "All ${#suites[@]} test suites passed"
}

# Function to show summary
show_summary() {
    print_header "Summary"

    if [[ "$BUILD_ONLY" == true ]]; then
        print_success "Build completed successfully"
        print_info "sim-use executable: $(swift build --show-bin-path)/sim-use"
        print_info "Playground app installed on: $SIMULATOR_NAME ($SIMULATOR_UDID)"
    elif [[ "$TESTS_ONLY" == true ]]; then
        if [[ ${#TEST_FILTERS[@]} -gt 0 ]]; then
            print_success "Test selection '${TEST_FILTERS[*]}' completed successfully"
        else
            print_success "All test suites completed successfully"
        fi
    else
        print_success "Build and test cycle completed successfully"
        print_info "sim-use executable: $(swift build --show-bin-path)/sim-use"
        print_info "Playground app: Installed and tested on $SIMULATOR_NAME"
        if [[ ${#TEST_FILTERS[@]} -gt 0 ]]; then
            print_info "Test selection: ${TEST_FILTERS[*]}"
        else
            print_info "Test coverage: All test suites"
        fi
    fi
}

# Main execution
main() {
    print_header "sim-use Test Runner"
    print_info "Starting automated build and test cycle..."

    # Always check prerequisites
    check_prerequisites

    # Always boot simulator (needed for both building and testing)
    boot_simulator

    if [[ "$TESTS_ONLY" != true ]]; then
        clean_build
        build_sim_use
        generate_playground_project
        build_playground_app
    fi

    if [[ "$BUILD_ONLY" != true ]]; then
        run_tests
    fi

    show_summary
}

# Run main function
main "$@"
