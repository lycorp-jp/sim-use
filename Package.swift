// swift-tools-version:5.10
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

// The FB* XCFrameworks built by `scripts/build.sh` are STATIC archives
// (upstream idb switched its frameworks to MACH_O_TYPE staticlib), so the
// FB* code links into the consuming binary and nothing is loaded at
// runtime. Two consequences wired up below:
//
// 1. The FB* Swift modules import the reverse-engineered private-framework
//    Clang modules bundled with idb (CoreSimulator, SimulatorKit, ...).
//    Every target that compiles `import FBControlCore` /
//    `import FBSimulatorControl` — directly or through iOSSimBackend's
//    swiftmodule — needs those module maps on the compiler search path.
//    `scripts/build.sh` stages them under build_products/PrivateHeaders/.
// 2. The static archives defer their CoreSimulator /
//    AccessibilityPlatformTranslation class references to the final link,
//    which must weak-link the .tbd stubs (the real frameworks are loaded
//    at runtime by FBSimulatorControlFrameworkLoader). `-ObjC` keeps the
//    archives' ObjC categories alive.
//
// Both flag sets use `Context.packageDirectory` because SwiftPM resolves
// relative compiler/linker arguments against an unspecified working
// directory that differs between the classic and SwiftBuild backends.
// unsafeFlags make this package unusable as a SwiftPM dependency of
// another package; sim-use is a root package (CLI tool), so that is fine.
let privateHeadersDir = "\(Context.packageDirectory)/build_products/PrivateHeaders"

// The bare -I is needed too: the private headers include their siblings
// framework-style (e.g. <CoreSimulator/NSObject-Protocol.h>), which
// resolves as a subdirectory of the PrivateHeaders root.
let privateModuleMapFlags: [String] = ["-Xcc", "-I\(privateHeadersDir)"] + [
    "CoreSimulator", "SimulatorApp", "SimulatorKit", "AXRuntime",
    "AccessibilityPlatformTranslation",
].flatMap {
    ["-Xcc", "-fmodule-map-file=\(privateHeadersDir)/\($0)/module.modulemap"]
}

let fbLinkerFlags: [String] = ["-Xlinker", "-ObjC"] + [
    "CoreSimulator", "AccessibilityPlatformTranslation",
].flatMap {
    ["-Xlinker", "-weak_library", "-Xlinker", "\(privateHeadersDir)/\($0)/\($0).tbd"]
}

let package = Package(
    name: "SimUse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "sim-use",
            targets: ["SimUse"]
        ),
        .library(
            name: "SimUseCore",
            targets: ["SimUseCore"]
        ),
        .library(
            name: "AndroidBackend",
            targets: ["AndroidBackend"]
        ),
        .library(
            name: "iOSSimBackend",
            targets: ["iOSSimBackend"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SimUseCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SimUseCore",
            // VERSION is consumed by the daemon (DaemonClient version-
            // check gate, DaemonServer ping response). Generating it
            // per-target is cheap and keeps the daemon dependency-free
            // of higher targets.
            plugins: ["VersionPlugin"]
        ),
        .target(
            name: "iOSSimBackend",
            dependencies: [
                "SimUseCore",
                "FBSimulatorControl",
                "FBControlCore",
                "XCTestBootstrap",
                "CompanionUtilities",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/iOSSimBackend",
            swiftSettings: [
                .unsafeFlags(privateModuleMapFlags)
            ],
            plugins: ["VersionPlugin"]
        ),
        .target(
            name: "AndroidBackend",
            dependencies: [
                "SimUseCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AndroidBackend",
            // Resources/ holds `sim-use-device-bridge.apk` at runtime
            // (built by `scripts/build-bridge.sh`). Copy the whole
            // directory so the SPM build doesn't require the APK to
            // exist at build time — `AndroidDeviceController` surfaces
            // a clear "Bridge APK not found" error when the resource
            // is missing.
            resources: [
                .copy("Resources"),
            ]
        ),
        .executableTarget(
            name: "SimUse",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SimUseCore",
                "AndroidBackend",
                "iOSSimBackend",
                "FBSimulatorControl",
                "FBControlCore",
                "XCTestBootstrap",
                "CompanionUtilities"
            ],
            path: "Sources/SimUse",
            resources: [
                .copy("Resources/skills"),
                // Built Viewer SPA assets (Vite output). Re-generated by
                // `scripts/build-viewer.sh`; committed so `swift build`
                // works without Node on contributor machines that don't
                // touch the Viewer. The `viewer` subcommand reads this
                // tree via `Bundle.module.resourceURL` and serves it
                // out of a local HTTP listener.
                .copy("Resources/viewer"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"] + privateModuleMapFlags)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-dead_strip",
                    "-Xlinker", "-headerpad_max_install_names",
                ] + fbLinkerFlags)
            ],
            plugins: ["VersionPlugin"]
        ),
        .testTarget(
            name: "SimUseTests",
            dependencies: ["SimUse", "iOSSimBackend", "SimUseCore"],
            path: "Tests",
            // `Tests/` is the umbrella path; the sub-target test
            // directories below sit under it as separate testTargets.
            // List them by name in `exclude` so SwiftPM doesn't double-
            // claim their sources. Add new test sub-directories here
            // when adding new testTargets, or move them out from under
            // `Tests/` to drop this maintenance burden.
            exclude: [
                "SimUseCoreTests",
                "AndroidBackendTests",
            ],
            resources: [
                .copy("README.md"),
                .copy("Fixtures")
            ],
            swiftSettings: [
                .unsafeFlags(privateModuleMapFlags)
            ],
            linkerSettings: [
                .unsafeFlags(fbLinkerFlags)
            ]
        ),
        .testTarget(
            name: "SimUseCoreTests",
            dependencies: ["SimUseCore"],
            path: "Tests/SimUseCoreTests"
        ),
        .testTarget(
            name: "AndroidBackendTests",
            dependencies: ["AndroidBackend", "SimUseCore"],
            path: "Tests/AndroidBackendTests"
            // `Fixtures/` here is empty (`.gitkeep` only) — listing
            // it as a resource would emit a SwiftPM warning. Add a
            // `.copy("Fixtures")` entry when real fixture files
            // land.
        ),
        .plugin(
            name: "VersionPlugin",
            capability: .buildTool(),
            path: "Plugins/VersionPlugin"
        ),
        .binaryTarget(
            name: "FBControlCore",
            path: "build_products/XCFrameworks/FBControlCore.xcframework"
        ),
        .binaryTarget(
            name: "FBSimulatorControl",
            path: "build_products/XCFrameworks/FBSimulatorControl.xcframework"
        ),
        .binaryTarget(
            name: "XCTestBootstrap",
            path: "build_products/XCFrameworks/XCTestBootstrap.xcframework"
        ),
        .binaryTarget(
            name: "CompanionUtilities",
            path: "build_products/XCFrameworks/CompanionUtilities.xcframework"
        ),
    ]
)
