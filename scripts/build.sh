#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Builds the required IDB Frameworks for the sim-use project.

set -e
set -o pipefail

# Environment and Configuration
IDB_CHECKOUT_DIR="${IDB_CHECKOUT_DIR:-./idb_checkout}"
IDB_GIT_REF="${IDB_GIT_REF:-76639e4d0e1741adf391cab36f19fbc59378153e}"
IDB_PATCHES_DIR="${IDB_PATCHES_DIR:-./patches/idb}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-./build_products}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-./build_derived_data}"
BUILD_XCFRAMEWORK_DIR="${BUILD_XCFRAMEWORK_DIR:-${BUILD_OUTPUT_DIR}/XCFrameworks}"
FBSIMCONTROL_PROJECT="${IDB_CHECKOUT_DIR}/FBSimulatorControl.xcodeproj"
TEMP_DIR="${TEMP_DIR:-$(mktemp -d)}"

# Resolve a framework's Mach-O binary across the possible Versions/ layouts.
resolve_framework_binary() {
  local framework_path="$1"
  local framework_name="$2"
  local candidates=(
    "$framework_path/Versions/A/$framework_name"
    "$framework_path/Versions/Current/$framework_name"
    "$framework_path/$framework_name"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

FRAMEWORK_SDK="macosx"
FRAMEWORK_CONFIGURATION="Release"

# Codesigning configuration. Defaults to ad-hoc signing ("-"), which works on
# any machine without a provisioned certificate — correct for local dev builds
# and CI. For a distributable, notarizable build, export your own Developer ID:
#   export SIM_USE_CODESIGN_IDENTITY="Developer ID Application: <Name> (<TeamID>)"
DEFAULT_CODESIGN_IDENTITY="-"
CODESIGN_IDENTITY="${SIM_USE_CODESIGN_IDENTITY:-$DEFAULT_CODESIGN_IDENTITY}"


# --- Helper Functions ---

# Temporarily disable xcpretty to see actual errors in CI
# if hash xcpretty 2>/dev/null; then
#   HAS_XCPRETTY=true
# fi

# Function to print a section header with emoji
function print_section() {
  local emoji="$1"
  local title="$2"
  echo ""
  echo ""
  echo "${emoji} ${title}"
  echo "$(printf '·%.0s' {1..60})"
}

# Function to print a subsection header
function print_subsection() {
  local emoji="$1"
  local title="$2"
  echo ""
  echo "${emoji} ${title}"
}

# Function to print success message
function print_success() {
  local message="$1"
  echo "✅ ${message}"
}

# Function to print info message
function print_info() {
  local message="$1"
  echo "ℹ️  ${message}"
}

# Function to print warning message
function print_warning() {
  local message="$1"
  echo "⚠️  ${message}"
}

function codesign_with_retry() {
  local max_attempts=5
  local delay=10
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if codesign "$@" 2>&1; then
      return 0
    fi
    local exit_code=$?
    if [ $attempt -lt $max_attempts ]; then
      print_warning "codesign failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  echo "❌ Error: codesign failed after $max_attempts attempts"
  return 1
}

function verify_macho_has_arch() {
  local binary_path="$1"
  local expected_arch="$2"

  if [[ ! -f "$binary_path" ]]; then
    echo "❌ Error: Binary not found for architecture verification: $binary_path"
    exit 1
  fi

  local arch_info
  arch_info=$(lipo -info "$binary_path" 2>/dev/null || true)
  if [[ "$arch_info" != *"$expected_arch"* ]]; then
    echo "❌ Error: Missing architecture '${expected_arch}' in $binary_path"
    echo "   lipo output: ${arch_info:-<empty>}"
    exit 1
  fi
}

# Function to invoke xcodebuild, optionally with xcpretty
function invoke_xcodebuild() {
  local arguments=("$@")
  print_info "Executing: xcodebuild ${arguments[*]}"

  local exit_code
  if [[ -n $HAS_XCPRETTY ]]; then
    NSUnbufferedIO=YES xcodebuild "${arguments[@]}" | xcpretty -c
    exit_code=${PIPESTATUS[0]}
  else
    xcodebuild "${arguments[@]}" 2>&1
    exit_code=$?
  fi

  return $exit_code
}

function swift_build_bin_path() {
  local build_config="$1"
  local target_arch="$2"
  swift build --configuration "$build_config" --arch "$target_arch" --show-bin-path
}

function copy_resource_bundle() {
  local output_base_dir="$1"
  local bundle_name="$2"
  local optional_flag="${3:-required}"
  local bundle_dest="${output_base_dir}/${bundle_name}"
  local bundle_source=""
  local candidate_dir=""

  for candidate_dir in \
    "$(swift_build_bin_path "release" "arm64")" \
    "$(swift_build_bin_path "release" "x86_64")"
  do
    if [[ -d "${candidate_dir}/${bundle_name}" ]]; then
      bundle_source="${candidate_dir}/${bundle_name}"
      break
    fi
  done

  if [[ -z "$bundle_source" ]]; then
    if [[ "$optional_flag" == "optional" ]]; then
      echo "⚠️  Optional resource bundle '${bundle_name}' not found in Swift build outputs; skipping" >&2
      return 0
    fi
    echo "❌ Error: resource bundle '${bundle_name}' not found in Swift build outputs"
    exit 1
  fi

  rm -rf "$bundle_dest"
  cp -R "$bundle_source" "$bundle_dest"
  print_success "resource bundle ${bundle_name} installed to ${bundle_dest}"
}

# Stage every SwiftPM-emitted resource bundle the build needs.
# `SimUse_SimUse.bundle` carries the iOS / shared assets and has always
# shipped. `SimUse_AndroidBackend.bundle` carries the bundled device-bridge
# APK so `sim-use android init` can push it to the device — without this
# stage step the built sim-use silently lacks Android support.
function copy_all_resource_bundles() {
  local output_base_dir="$1"
  copy_resource_bundle "$output_base_dir" "SimUse_SimUse.bundle"
  copy_resource_bundle "$output_base_dir" "SimUse_AndroidBackend.bundle"
}

function clone_idb_repo() {
  if [ ! -d $IDB_CHECKOUT_DIR ]; then
    print_info "Creating $IDB_DIRECTORY directory and cloning idb repository..."
    git clone https://github.com/facebook/idb.git $IDB_CHECKOUT_DIR
    (cd $IDB_CHECKOUT_DIR && git checkout "$IDB_GIT_REF")
    print_success "idb repository cloned at $IDB_GIT_REF."
    apply_idb_patches
  else
    print_info "Updating idb repository to $IDB_GIT_REF..."
    (cd $IDB_CHECKOUT_DIR && git fetch --all --tags --prune && git reset --hard "$IDB_GIT_REF")
    print_success "idb repository updated to $IDB_GIT_REF."
    apply_idb_patches
  fi
}

function apply_idb_patches() {
  if [ ! -d "$IDB_PATCHES_DIR" ]; then
    return
  fi

  shopt -s nullglob
  local patches=("$IDB_PATCHES_DIR"/*.patch)
  if [ ${#patches[@]} -eq 0 ]; then
    shopt -u nullglob
    return
  fi

  print_info "Applying local patches to idb repository..."
  # Ensure we start from a clean working tree so patches apply consistently.
  (cd "$IDB_CHECKOUT_DIR" && git checkout -- . >/dev/null 2>&1 && git clean -fd >/dev/null 2>&1) || true

  local patch_file
  for patch_file in "${patches[@]}"; do
    local patch_abs
    patch_abs="$(cd "$(dirname "$patch_file")" && pwd)/$(basename "$patch_file")"
    print_info "  → $(basename "$patch_file")"
    # First verify patch applies cleanly with git apply --check
    if ! (cd "$IDB_CHECKOUT_DIR" && git apply --check "$patch_abs" 2>/dev/null); then
      echo "❌ Error: Patch $(basename "$patch_file") does not apply cleanly."
      echo "   The upstream IDB source may have changed. Please update the patch."
      exit 1
    fi
    # Apply the patch
    if ! (cd "$IDB_CHECKOUT_DIR" && git apply "$patch_abs"); then
      echo "❌ Error: Failed to apply patch $(basename "$patch_file")"
      exit 1
    fi
  done
  shopt -u nullglob
}

# Function to build a single framework
# $1: Scheme name
# $2: Project file path
# $3: Base output directory (for .framework and .xcframework)
function framework_build() {
  local scheme_name="$1"
  local project_file="$2"
  local output_base_dir="$3"

  print_subsection "🔨" "Building framework: ${scheme_name}"
  print_info "Project: ${project_file}"

  invoke_xcodebuild \
    -project "${project_file}" \
    -scheme "${scheme_name}" \
    -sdk "${FRAMEWORK_SDK}" \
    -destination "generic/platform=macOS" \
    -configuration "${FRAMEWORK_CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    build \
    SKIP_INSTALL=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    GCC_WARN_ABOUT_MISSING_FIELD_INITIALIZERS=NO \
    CLANG_WARN_DOCUMENTATION_COMMENTS=NO \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=NO \
    OTHER_LDFLAGS='$(inherited) -Wl,-headerpad_max_install_names'
  local build_exit_code=$?

  if [ $build_exit_code -eq 0 ]; then
    print_success "Framework ${scheme_name} built successfully!"
  else
    echo "❌ Error: Framework ${scheme_name} build failed with exit code ${build_exit_code}"
    exit $build_exit_code
  fi
}

# Function to install a single framework to Frameworks/
# $1: Scheme name (used to find the .framework in derived data)
# $2: Base output directory
function install_framework() {
  local scheme_name="$1"
  local output_base_dir="$2"
  local built_framework_path="${DERIVED_DATA_PATH}/Build/Products/${FRAMEWORK_CONFIGURATION}/${scheme_name}.framework"
  local final_framework_install_dir="${output_base_dir}/Frameworks"

  print_info "Installing framework ${scheme_name}.framework to ${final_framework_install_dir}..."
  if [[ ! -d "${built_framework_path}" ]]; then
    echo "❌ Error: Built framework not found at ${built_framework_path} for installation."
    exit 1
  fi

  mkdir -p "${final_framework_install_dir}"
  print_info "Copying ${built_framework_path} to ${final_framework_install_dir}/"
  cp -R "${built_framework_path}" "${final_framework_install_dir}/"
  print_success "Framework ${scheme_name}.framework installed to ${final_framework_install_dir}/"
}

# Function to create a single XCFramework
# $1: Scheme name
# $2: Base output directory (where XCFrameworks/ subdirectory will be created)
function create_xcframework() {
  local scheme_name="$1"
  local output_base_dir="$2"
  local signed_framework_path="${output_base_dir}/Frameworks/${scheme_name}.framework"
  local final_xcframework_output_dir="${output_base_dir}/XCFrameworks"
  local xcframework_path="${final_xcframework_output_dir}/${scheme_name}.xcframework"

  print_subsection "📦" "Creating XCFramework for ${scheme_name}"
  if [[ ! -d "${signed_framework_path}" ]]; then
    echo "❌ Error: Signed framework not found at ${signed_framework_path} for XCFramework creation."
    exit 1
  fi

  mkdir -p "${final_xcframework_output_dir}"
  rm -rf "${xcframework_path}"

  print_info "Packaging ${signed_framework_path} into ${xcframework_path}"
  invoke_xcodebuild \
    -create-xcframework \
    -framework "${signed_framework_path}" \
    -output "${xcframework_path}"
  local xcframework_exit_code=$?

  if [ $xcframework_exit_code -eq 0 ]; then
    print_success "XCFramework ${scheme_name}.xcframework created at ${xcframework_path}"
  else
    echo "❌ Error: XCFramework creation for ${scheme_name} failed with exit code ${xcframework_exit_code}"
    exit $xcframework_exit_code
  fi
}

# Function to strip a framework of nested frameworks
# $1: Base output directory
# $2: Framework path
function strip_framework() {
  local output_base_dir="$1"
  local framework_path="${output_base_dir}/Frameworks/${2}"

  if [ -d "$framework_path" ]; then
    print_info "Stripping Framework $framework_path"
    rm -r "$framework_path"
  fi
}

# Function to resign a framework with Developer ID
# $1: Base output directory
# $2: Framework name (e.g., "FBSimulatorControl.framework")
function resign_framework() {
  local output_base_dir="$1"
  local framework_name="$2"
  local framework_path="${output_base_dir}/Frameworks/${framework_name}"

  if [ -d "$framework_path" ]; then
    print_info "Resigning framework: ${framework_name}"

    # First, sign all dynamic libraries and binaries inside the framework
    print_info "Signing embedded binaries in ${framework_name}..."

    # Find and sign all .dylib files recursively
    find "$framework_path" -name "*.dylib" -type f | while read -r dylib_path; do
      print_info "  Signing dylib: $(basename "$dylib_path")"
      codesign_with_retry --force \
        --sign "${CODESIGN_IDENTITY}" \
        --options runtime \
        --timestamp \
        --verbose \
        "$dylib_path"

      if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to sign dylib: $dylib_path"
        exit 1
      fi
    done

    # Remove any existing signature from the main framework binary first
    print_info "Removing existing signature from ${framework_name}..."
    codesign --remove-signature "$framework_path" 2>/dev/null || true

    # Sign the main framework bundle with specific notarization-compatible options
    print_info "Signing main framework bundle: ${framework_name}"
    codesign_with_retry --force \
      --sign "${CODESIGN_IDENTITY}" \
      --options runtime \
      --entitlements scripts/entitlements.plist \
      --timestamp \
      --verbose \
      "$framework_path"

    if [ $? -eq 0 ]; then
      print_success "Framework ${framework_name} resigned successfully"

      # Verify the signature with strictest verification
      print_info "Performing strict verification for ${framework_name}..."
      codesign -vvv --strict "$framework_path"

      if [ $? -eq 0 ]; then
        print_success "Signature verification passed for ${framework_name}"

        # Display signature details
        print_info "Signature details for ${framework_name}:"
        codesign -dv "$framework_path" 2>&1 | grep -E "(Identifier|TeamIdentifier|Authority|Timestamp)" || true
      else
        echo "❌ Error: Signature verification failed for ${framework_name}"
        exit 1
      fi
    else
      echo "❌ Error: Failed to resign framework ${framework_name}"
      exit 1
    fi
  else
    print_warning "Framework not found: $framework_path"
  fi
}

# Function to resign an XCFramework with Developer ID
# $1: Base output directory
# $2: XCFramework name (e.g., "FBSimulatorControl.xcframework")
function resign_xcframework() {
  local output_base_dir="$1"
  local xcframework_name="$2"
  local xcframework_path="${output_base_dir}/XCFrameworks/${xcframework_name}"

  if [ -d "$xcframework_path" ]; then
    print_info "Resigning XCFramework: ${xcframework_name}"

    # Sign XCFramework with Developer ID and runtime hardening
    codesign_with_retry --force \
      --sign "${CODESIGN_IDENTITY}" \
      --options runtime \
      --deep \
      --timestamp \
      "$xcframework_path"

    if [ $? -eq 0 ]; then
      print_success "XCFramework ${xcframework_name} resigned successfully"

      # Verify the signature with strictest verification and deep checking
      print_info "Performing strict verification for XCFramework ${xcframework_name}..."
      codesign -vvv --deep "$xcframework_path"

      if [ $? -eq 0 ]; then
        print_success "XCFramework signature verification passed for ${xcframework_name}"

        # Display signature details
        print_info "XCFramework signature details for ${xcframework_name}:"
        codesign -dv --deep "$xcframework_path" 2>&1 | grep -E "(Identifier|TeamIdentifier|Authority)" || true
      else
        echo "❌ Error: XCFramework signature verification failed for ${xcframework_name}"
        exit 1
      fi
    else
      echo "❌ Error: Failed to resign XCFramework ${xcframework_name}"
      exit 1
    fi
  else
    print_warning "XCFramework not found: $xcframework_path"
  fi
}

function remove_rpaths_matching() {
  local target="$1"
  local pattern="$2"
  if [[ ! -f "$target" ]]; then
    return
  fi

  local rpaths
  rpaths=$(otool -l "$target" 2>/dev/null | awk 'BEGIN{r=0} /LC_RPATH/{r=1} r==1 && /path/{print $2; r=0}' | grep "$pattern" || true)
  if [[ -n "$rpaths" ]]; then
    while IFS= read -r path; do
      install_name_tool -delete_rpath "$path" "$target" || true
    done <<< "$rpaths"
  fi
}

function remove_xcode_rpaths() {
  remove_rpaths_matching "$1" "/Applications/Xcode"
}

function remove_build_products_rpaths() {
  remove_rpaths_matching "$1" "build_products"
}

function sanitize_framework_rpaths() {
  local frameworks_dir="$1"
  if [[ ! -d "$frameworks_dir" ]]; then
    print_warning "Frameworks directory not found: $frameworks_dir"
    return
  fi

  print_info "Removing Xcode toolchain rpaths from framework binaries..."
  local found=false
  while IFS= read -r -d '' file; do
    if file "$file" | grep -q "Mach-O"; then
      found=true
      remove_xcode_rpaths "$file"
    fi
  done < <(find "$frameworks_dir" -type f -print0)

  if [[ "$found" == "false" ]]; then
    print_warning "No Mach-O files found under ${frameworks_dir}"
  fi
}

# Function to build the sim-use executable using Swift Package Manager
# $1: Base output directory
function build_sim_use_executable() {
  local output_base_dir="$1"
  local build_config="release"
  local executable_dest="${output_base_dir}/sim-use"
  local arm64_executable="${output_base_dir}/sim-use-arm64"
  local x64_executable="${output_base_dir}/sim-use-x86_64"
  local arm64_bin_path
  local x64_bin_path

  print_subsection "⚡" "Building sim-use executable"
  print_info "Using Swift Package Manager to build sim-use..."

  # Clean any existing build products to ensure fresh build
  print_info "Cleaning previous build products..."
  swift package clean

  print_info "Building arm64 executable..."
  swift build --configuration "${build_config}" --arch arm64
  arm64_bin_path="$(swift_build_bin_path "$build_config" "arm64")/sim-use"
  if [[ ! -f "${arm64_bin_path}" ]]; then
    echo "❌ Error: arm64 sim-use executable not found at ${arm64_bin_path}"
    exit 1
  fi
  cp "${arm64_bin_path}" "${arm64_executable}"

  print_info "Building x86_64 executable..."
  swift build --configuration "${build_config}" --arch x86_64
  x64_bin_path="$(swift_build_bin_path "$build_config" "x86_64")/sim-use"
  if [[ ! -f "${x64_bin_path}" ]]; then
    echo "❌ Error: x86_64 sim-use executable not found at ${x64_bin_path}"
    exit 1
  fi
  cp "${x64_bin_path}" "${x64_executable}"

  print_info "Creating universal executable with lipo..."
  lipo -create -output "${executable_dest}" "${arm64_executable}" "${x64_executable}"
  rm -f "${arm64_executable}" "${x64_executable}"

  copy_all_resource_bundles "${output_base_dir}"

  verify_macho_has_arch "${executable_dest}" "arm64"
  verify_macho_has_arch "${executable_dest}" "x86_64"
  print_success "sim-use executable installed to ${executable_dest}"

  # Configure the executable's rpath set for framework loading.
  #
  # The set must satisfy two constraints simultaneously:
  #   1. dyld can resolve `@rpath/<Name>.framework/Versions/A/<Name>` loads
  #      (every framework load in this binary is in that form — see `otool
  #      -L`).
  #   2. Homebrew's keg_relocate.rb (extend/os/mac/keg_relocate.rb, the
  #      block at `each_linkage_for(file, :rpaths,
  #      resolve_variable_references: true)`) finds **no two rpaths
  #      resolving to the same path**. The moment it deletes a duplicate
  #      it flips `needs_codesigning = true` and ad-hoc resigns the
  #      binary, destroying the upstream Developer ID + Apple notary
  #      signature we worked to ship.
  #
  # Both `@loader_path` and `@executable_path` resolve to the executable's
  # own directory (loader_path == executable_path for the main binary), so
  # keeping both is a duplicate brew strips. Same for
  # `@executable_path/Frameworks` vs `@loader_path/Frameworks`. The
  # minimal brew-safe set:
  #
  #   /usr/lib/swift              # Swift stdlib fallback (SwiftPM emits)
  #   @loader_path                # SwiftPM emits; alone, kept
  #   @executable_path/Frameworks # we add; resolves all @rpath/*.framework
  #                               # loads to libexec/Frameworks/ once brew
  #                               # installs the payload
  #
  # We explicitly delete the bare `@executable_path` (SwiftPM emits it,
  # duplicate with `@loader_path`) and never add `@loader_path/Frameworks`
  # (would duplicate `@executable_path/Frameworks`).
  print_info "Configuring executable rpath for organized framework loading..."

  install_name_tool -delete_rpath "@executable_path"            "${executable_dest}" 2>/dev/null || true
  install_name_tool -delete_rpath "@executable_path/Frameworks" "${executable_dest}" 2>/dev/null || true
  install_name_tool -delete_rpath "@loader_path/Frameworks"     "${executable_dest}" 2>/dev/null || true

  install_name_tool -add_rpath "@executable_path/Frameworks" "${executable_dest}"
  print_success "Added rpath: @executable_path/Frameworks"

  # Strip any Xcode toolchain rpaths that can trigger Homebrew relocation
  remove_xcode_rpaths "${executable_dest}"

  # Strip the dev-loop rpaths Package.swift emits for the SwiftBuild-backend
  # toolchains (build_products/… XCFramework slices; one entry per framework
  # is CWD-relative). dyld searches them BEFORE the appended
  # @executable_path/Frameworks, so a shipped binary run from a directory
  # holding dev-built frameworks — this repository's root, for one — would
  # silently load those instead of the bundled ones (brew ad-hoc resigns the
  # binary, so no library validation blocks the swap). Dev builds keep the
  # entries; only the staged release binary is scrubbed.
  remove_build_products_rpaths "${executable_dest}"

  # Verify rpath configuration
  print_info "Verifying rpath configuration..."
  local rpath_output=$(otool -l "${executable_dest}" | grep -A2 LC_RPATH | grep path | awk '{print $2}')
  if [[ -n "$rpath_output" ]]; then
    print_success "Executable rpath configuration verified:"
    echo "$rpath_output" | while read -r path; do
      print_info "  → ${path}"
    done
  else
    print_warning "No rpath entries found in executable"
  fi

  print_success "Executable rpath configured for organized framework deployment"
}

function verify_xcframework_inputs() {
  local output_base_dir="$1"
  local xcframeworks_dir="${output_base_dir}/XCFrameworks"
  local expected_frameworks=("FBControlCore" "XCTestBootstrap" "FBSimulatorControl" "FBDeviceControl")

  print_subsection "🧪" "Validating XCFramework inputs"

  if [[ ! -d "${xcframeworks_dir}" ]]; then
    echo "❌ Error: XCFrameworks directory not found under ${output_base_dir}"
    exit 1
  fi

  for framework_name in "${expected_frameworks[@]}"; do
    local xcframework_path="${xcframeworks_dir}/${framework_name}.xcframework"
    if [[ ! -d "${xcframework_path}" ]]; then
      echo "❌ Error: Expected XCFramework missing from ${xcframeworks_dir}: ${framework_name}.xcframework"
      exit 1
    fi
    local framework_binary
    framework_binary="$(find "${xcframework_path}" -type f -name "${framework_name}" -path "*/macos-*/*.framework/*" | head -1)"
    if [[ -z "${framework_binary}" ]]; then
      echo "❌ Error: Could not locate framework binary inside ${xcframework_path}"
      exit 1
    fi
    verify_macho_has_arch "${framework_binary}" "arm64"
    verify_macho_has_arch "${framework_binary}" "x86_64"
  done

  print_success "XCFramework inputs include arm64 and x86_64 slices"
}

function verify_release_architectures() {
  local output_base_dir="$1"
  local frameworks_dir="${output_base_dir}/Frameworks"
  local executable_path="${output_base_dir}/sim-use"
  local expected_frameworks=("FBControlCore" "XCTestBootstrap" "FBSimulatorControl" "FBDeviceControl")

  print_subsection "🧪" "Validating release artifact architectures"
  verify_macho_has_arch "${executable_path}" "arm64"
  verify_macho_has_arch "${executable_path}" "x86_64"

  if [[ ! -d "${frameworks_dir}" ]]; then
    echo "❌ Error: Frameworks directory not found under ${output_base_dir}"
    exit 1
  fi

  for framework_name in "${expected_frameworks[@]}"; do
    local framework_path="${frameworks_dir}/${framework_name}.framework"
    if [[ ! -d "${framework_path}" ]]; then
      echo "❌ Error: Expected framework missing from ${frameworks_dir}: ${framework_name}.framework"
      exit 1
    fi
    local framework_binary
    framework_binary="$(resolve_framework_binary "${framework_path}" "${framework_name}" || true)"
    if [[ -z "${framework_binary}" ]]; then
      echo "❌ Error: Could not locate framework binary in ${framework_path}"
      exit 1
    fi
    verify_macho_has_arch "${framework_binary}" "arm64"
    verify_macho_has_arch "${framework_binary}" "x86_64"
  done

  print_success "Release artifacts include arm64 and x86_64 slices"
}

# Function to sign the sim-use executable with Developer ID
# $1: Base output directory
function sign_sim_use_executable() {
  local output_base_dir="$1"
  local executable_path="${output_base_dir}/sim-use"

  if [ -f "$executable_path" ]; then
    print_info "Signing sim-use executable: ${executable_path}"

    # Sign with Developer ID and runtime hardening
    codesign_with_retry --force \
      --sign "${CODESIGN_IDENTITY}" \
      --options runtime \
      --entitlements scripts/entitlements.plist \
      --timestamp \
      "$executable_path"

    if [ $? -eq 0 ]; then
      print_success "sim-use executable signed successfully"

      # Verify the signature with strictest verification
      print_info "Performing strict verification for sim-use executable..."
      codesign -vvv "$executable_path"

      if [ $? -eq 0 ]; then
        print_success "sim-use executable signature verification passed"

        # Display signature details
        print_info "sim-use executable signature details:"
        codesign -dv "$executable_path" 2>&1 | grep -E "(Identifier|TeamIdentifier|Authority)" || true
      else
        echo "❌ Error: sim-use executable signature verification failed"
        exit 1
      fi
    else
      echo "❌ Error: Failed to sign sim-use executable"
      exit 1
    fi
  else
    print_warning "sim-use executable not found: $executable_path"
  fi
}

# Function to print usage information
function print_usage() {
cat <<EOF
./build.sh usage:
  ./build.sh [<command>] [<options>]*

Commands:
  help
    Print this usage information.

  setup
    Clone the IDB repository and set up directories.

  clean
    Clean previous build products and derived data.

  frameworks
    Build all IDB frameworks (FBControlCore, XCTestBootstrap, FBSimulatorControl, FBDeviceControl).

  install
    Install built frameworks to the Frameworks directory.

  strip
    Strip nested frameworks from the built frameworks.

  sign-frameworks
    Code sign all frameworks with Developer ID.

  xcframeworks
    Create XCFrameworks from the built frameworks.

  sign-xcframeworks
    Code sign all XCFrameworks with Developer ID.

  executable
    Build the sim-use executable using Swift Package Manager.

  sign-executable
    Code sign the sim-use executable with Developer ID.

  verify-xcframeworks
    Verify XCFramework inputs include arm64 and x86_64 slices.

  verify-arches
    Verify executable and frameworks include arm64 and x86_64 slices.

  build (default)
    Run all build steps from setup through the signed executable.

Environment Variables:
  IDB_CHECKOUT_DIR       Directory for IDB repository (default: ./idb_checkout)
  BUILD_OUTPUT_DIR       Directory for build outputs (default: ./build_products)
  DERIVED_DATA_PATH      Directory for derived data (default: ./build_derived_data)
  TEMP_DIR               Temporary directory (default: system temp)

Examples:
  ./build.sh                    # Build everything (default)
  ./build.sh help               # Show this help
  ./build.sh frameworks         # Only build frameworks
  ./build.sh sign-frameworks    # Only sign frameworks
EOF
}

# Individual command functions
function cmd_setup() {
  print_section "📥" "Repository Setup"
  clone_idb_repo
}

function cmd_clean() {
  print_section "🧹" "Cleaning Previous Build Products"
  print_info "Cleaning previous build products and derived data..."
  rm -rf "${BUILD_OUTPUT_DIR}"
  rm -rf "${DERIVED_DATA_PATH}"
  mkdir -p "${BUILD_OUTPUT_DIR}"
  mkdir -p "${BUILD_XCFRAMEWORK_DIR}"
  mkdir -p "${DERIVED_DATA_PATH}"
  print_success "Build directories cleaned and recreated"
}

function cmd_frameworks() {
  print_section "🔧" "Building Frameworks"
  framework_build "FBControlCore" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "XCTestBootstrap" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "FBSimulatorControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "FBDeviceControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
}

function cmd_install() {
  print_section "📦" "Installing Frameworks"
  install_framework "FBControlCore" "${BUILD_OUTPUT_DIR}"
  install_framework "XCTestBootstrap" "${BUILD_OUTPUT_DIR}"
  install_framework "FBSimulatorControl" "${BUILD_OUTPUT_DIR}"
  install_framework "FBDeviceControl" "${BUILD_OUTPUT_DIR}"
}

function cmd_strip() {
  print_section "✂️" "Stripping Nested Frameworks"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.framework/Versions/Current/Frameworks/XCTestBootstrap.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.framework/Versions/Current/Frameworks/FBControlCore.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.framework/Versions/Current/Frameworks/XCTestBootstrap.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.framework/Versions/Current/Frameworks/FBControlCore.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "XCTestBootstrap.framework/Versions/Current/Frameworks/FBControlCore.framework"
}

function cmd_sign_frameworks() {
  print_section "🔒" "Resigning Frameworks"
  print_info "Resigning frameworks..."
  sanitize_framework_rpaths "${BUILD_OUTPUT_DIR}/Frameworks"
  resign_framework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.framework"
  resign_framework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.framework"
  resign_framework "${BUILD_OUTPUT_DIR}" "XCTestBootstrap.framework"
  resign_framework "${BUILD_OUTPUT_DIR}" "FBControlCore.framework"
  print_success "Frameworks resigned successfully"
}

function cmd_xcframeworks() {
  print_section "📦" "Creating XCFrameworks"
  create_xcframework "FBControlCore" "${BUILD_OUTPUT_DIR}"
  create_xcframework "XCTestBootstrap" "${BUILD_OUTPUT_DIR}"
  create_xcframework "FBSimulatorControl" "${BUILD_OUTPUT_DIR}"
  create_xcframework "FBDeviceControl" "${BUILD_OUTPUT_DIR}"
}

function cmd_sign_xcframeworks() {
  print_section "🔒" "Resigning XCFrameworks"
  print_info "Resigning XCFrameworks with Developer ID..."
  resign_xcframework "${BUILD_OUTPUT_DIR}" "FBControlCore.xcframework"
  resign_xcframework "${BUILD_OUTPUT_DIR}" "XCTestBootstrap.xcframework"
  resign_xcframework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.xcframework"
  resign_xcframework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.xcframework"
  print_success "XCFrameworks resigned successfully"
}

function cmd_executable() {
  print_section "⚡" "Building sim-use Executable"
  build_sim_use_executable "${BUILD_OUTPUT_DIR}"
}

function cmd_sign_executable() {
  print_section "🔒" "Signing sim-use Executable"
  sign_sim_use_executable "${BUILD_OUTPUT_DIR}"
}

function cmd_verify_xcframeworks() {
  print_section "🧪" "Verifying XCFramework Inputs"
  verify_xcframework_inputs "${BUILD_OUTPUT_DIR}"
}

function cmd_verify_arches() {
  print_section "🧪" "Verifying Architecture Slices"
  verify_release_architectures "${BUILD_OUTPUT_DIR}"
}

function cmd_build() {
  print_section "🚀" "IDB Framework Builder for sim-use Project"

  print_info "IDB Checkout Directory: ${IDB_CHECKOUT_DIR}"
  print_info "Build Output Directory: ${BUILD_OUTPUT_DIR}"
  print_info "Derived Data Path: ${DERIVED_DATA_PATH}"
  print_info "XCFramework Output Directory: ${BUILD_XCFRAMEWORK_DIR}"
  print_info "Temporary Directory: ${TEMP_DIR}"
  print_info "IDB Project: ${FBSIMCONTROL_PROJECT}"

  # Run all steps
  cmd_setup
  cmd_clean
  cmd_frameworks
  cmd_install
  cmd_strip
  cmd_sign_frameworks
  cmd_xcframeworks
  cmd_sign_xcframeworks
  cmd_executable
  cmd_sign_executable

  print_section "🎉" "Build Complete!"
  print_success "All framework builds, XCFramework creation, and the sim-use executable completed."
  print_info "📦 XCFrameworks are located in ${BUILD_XCFRAMEWORK_DIR}"
  echo ""
  echo "🏁 Build process finished successfully!"
  echo ""
}

# Parse command line arguments
COMMAND="${1:-build}"

case $COMMAND in
  help)
    print_usage
    exit 0;;
  setup)
    cmd_setup;;
  clean)
    cmd_clean;;
  frameworks)
    cmd_frameworks;;
  install)
    cmd_install;;
  strip)
    cmd_strip;;
  sign-frameworks)
    cmd_sign_frameworks;;
  xcframeworks)
    cmd_xcframeworks;;
  sign-xcframeworks)
    cmd_sign_xcframeworks;;
  dev)
    cmd_setup
    cmd_clean
    cmd_frameworks
    cmd_install
    cmd_strip
    cmd_sign_frameworks
    cmd_xcframeworks
    cmd_sign_xcframeworks;;
  executable)
    cmd_executable;;
  sign-executable)
    cmd_sign_executable;;
  verify-xcframeworks)
    cmd_verify_xcframeworks;;
  verify-arches)
    cmd_verify_arches;;
  build)
    cmd_build;;
  *)
    echo "Unknown command: $COMMAND"
    echo ""
    print_usage
    exit 1;;
esac

exit 0
