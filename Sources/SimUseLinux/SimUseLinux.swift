// SPDX-License-Identifier: Apache-2.0
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore

// MARK: - Main Entry Point
//
// Linux counterpart of `Sources/SimUse/main.swift` for the Android-only
// build (see the `#if os(Linux)` manifest in Package.swift).

@main
enum EntryPoint {
    static func main() async {
        // Same bridge-version gate the macOS entry point installs: a
        // release build pins the APK it expects, dev builds skip it.
        BridgeClient.expectedBridgeVersion = ReleaseVersion.normalize(VERSION)
        Daemon.installPlatformHooks = installDaemonPlatformHooks
        await SimUseLinux.main()
    }

    @MainActor
    private static func installDaemonPlatformHooks(deviceId: String) {
        DaemonDispatch.commandParser = { args in
            try SimUseLinux.parseAsRoot(args)
        }
        // No `platformStaleCleanup`: that tears down cached iOS HID
        // connections, and Android holds no such handle.
        //
        // `livenessSnapshot` caches the rarely-changing third-party
        // package allowlist, so each command costs one `adb shell`
        // (the fresh `ps`), not two (issue #81 perf follow-up).
        DaemonDispatch.livenessProbe = { AndroidProcessLister.livenessSnapshot(serial: deviceId) }
    }
}

/// Root command of the Linux build.
///
/// The macOS root registers cross-platform forwarders that route to the
/// iOS or Android backend by UDID shape. With no iOS backend there is
/// nothing to route, so the Android implementations of those verbs are
/// registered at the top level under the same names — `sim-use ui`,
/// `sim-use tap`, `sim-use screenshot` behave as they do on macOS against
/// an adb serial. The `android` namespace is registered too, so
/// `sim-use android init` and the other Android-only verbs keep working.
struct SimUseLinux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim-use",
        abstract: "Observe and act on Android device / emulator screens (Linux build — Android only).",
        discussion: """
        This build ships the Android backend only. iOS verbs, video \
        capture (`record-video`, `stream-video`), `long-press`, \
        `app-state`, the Viewer and the skill installer (`init`) are \
        macOS-only and are absent here.

        First run against a device:

            adb devices
            sim-use android init --device <serial>
            sim-use ui --device <serial>
            sim-use tap @5 --device <serial>
        """,
        version: VERSION,
        subcommands: [
            AndroidDescribeUICommand.self,
            AndroidDevicesCommand.self,
            AndroidTapCommand.self,
            AndroidTypeCommand.self,
            AndroidPasteCommand.self,
            AndroidKeyboardStateCommand.self,
            AndroidSwipeCommand.self,
            AndroidButtonCommand.self,
            AndroidTouchCommand.self,
            AndroidGestureCommand.self,
            AndroidMultiTouchCommand.self,
            AndroidScreenshotCommand.self,
            Daemon.self,
            AndroidCommand.self,
        ]
    )
}
