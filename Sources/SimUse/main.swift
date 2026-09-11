// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import AppKit
import FBControlCore
import Darwin
import SimUseCore
import AndroidBackend
import iOSSimBackend
import iOSDeviceBackend

// MARK: - Main Entry Point
//
// `@main` lives on a thin shim (`EntryPoint`) that intercepts a few
// recognisable agent-typo mistakes before ArgumentParser sees them,
// emits a "did you mean …?" redirect, then exits early. Everything
// else falls through to `SimUse.main()` and the standard parser flow.
//
// The daemon-side command parser (used by `DaemonDispatch.handle` when
// the daemon server routes requests through ArgumentParser) is wired
// by `Daemon.installPlatformHooks`, which `Daemon.Start.run()` calls.
// The daemon SERVER process is always the one that needs it;
// client-side `daemon stop` / `daemon status` and non-daemon commands
// never touch DaemonDispatch.

/// iOS-only verb names that 0.5.x (pre-Path-B) exposed at the top
/// level. Typing `sim-use <verb>` for any of these today produces a
/// confusing "Unknown option '--udid'" error from ArgumentParser
/// because the verb name is interpreted as a positional argument to
/// the empty root command. We catch them here and redirect to the
/// canonical `sim-use ios <verb>` form, which preserves agent
/// recoverability after the surface reshape.
private let iOSOnlyVerbRedirects: [String: String] = [
    "key": "sim-use ios key",
    "key-combo": "sim-use ios key-combo",
    "key-sequence": "sim-use ios key-sequence",
    "batch": "sim-use ios batch",
]

@main
enum EntryPoint {
    static func main() async {
        // Wire the ping-time bridge-version check before any command
        // runs. Release builds (`vX.Y.Z` tags) install the expected
        // value; dev / dirty builds leave it nil so the check is a
        // no-op locally.
        BridgeClient.expectedBridgeVersion = ReleaseVersion.normalize(VERSION)
        Daemon.installPlatformHooks = installDaemonPlatformHooks

        if let typed = CommandLine.arguments.dropFirst().first,
           let canonical = iOSOnlyVerbRedirects[typed] {
            FileHandle.standardError.write(Data("""
                Error: `sim-use \(typed)` is not a top-level command. \
                Did you mean `\(canonical)`?

                Hint: as of 0.5.x, the iOS-only verbs (key, key-combo, \
                key-sequence, batch) live exclusively under \
                `sim-use ios <verb>` — the top-level surface only carries \
                verbs that work on both iOS and Android. Re-run with the \
                `ios` namespace and your existing flags should keep working:

                    \(canonical) \(CommandLine.arguments.dropFirst(2).joined(separator: " "))

                """.utf8))
            Darwin.exit(64) // EX_USAGE
        }
        await SimUse.main()
    }

    @MainActor
    private static func installDaemonPlatformHooks(deviceId: String) {
        // Wire SimUse's ArgumentParser as the daemon's command parser
        // so DaemonDispatch can route requests without owning a
        // back-reference to the top-level command tree.
        DaemonDispatch.commandParser = { args in
            try SimUse.parseAsRoot(args)
        }
        // Register the iOS-specific cleanup that fires when an iOS
        // verb raises `staleSimulator`. The daemon module lives in
        // SimUseCore and stays platform-neutral; the actual HID
        // teardown lives in iOSSimBackend. Android-only daemons
        // never raise `staleSimulator` so this hook is a no-op for
        // them — it's still installed to keep the code path uniform.
        DaemonDispatch.platformStaleCleanup = { udid in
            HIDInteractor.clearHIDConnection(for: udid)
        }
        // Wire the platform-appropriate live-app probe so the daemon
        // can detect a target process disappearing between commands
        // (issue #81). The daemon serves a single device, so the
        // probe is bound to this UDID/serial for its lifetime.
        if PlatformRouter.looksLikeAndroid(deviceId) {
            // `livenessSnapshot` caches the rarely-changing third-party
            // package allowlist, so each command costs one `adb shell`
            // (the fresh `ps`), not two (issue #81 perf follow-up).
            DaemonDispatch.livenessProbe = { AndroidProcessLister.livenessSnapshot(serial: deviceId) }
        } else {
            DaemonDispatch.livenessProbe = { BundleIdentifierResolver.appSnapshot(udid: deviceId) }
        }
    }
}

struct SimUse: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared
    static let simUseLogger = SimUseLogger()

    static let configuration = CommandConfiguration(
        abstract: "A utility to interact with iOS Simulators and Android emulators/devices and extract accessibility information.",
        version: VERSION,
        subcommands: [
            // Cross-platform verbs (top-level routes by UDID shape).
            DescribeUI.self,
            Devices.self,
            ListSimulators.self,
            Init.self,
            Tap.self,
            LongPress.self,
            Type.self,
            Paste.self,
            KeyboardState.self,
            Swipe.self,
            Button.self,
            Touch.self,
            Gesture.self,
            MultiTouch.self,
            RecordVideo.self,
            StreamVideo.self,
            Screenshot.self,
            AppState.self,
            Viewer.self,
            // Daemon + spike helpers.
            Daemon.self,
            SpikeDaemon.self,
            // Platform-specific namespaces. The four iOS-only HID verbs
            // (key, key-combo, key-sequence, batch) live under
            // `IOSSimCommand` only — the top-level surface only carries
            // verbs that work on both platforms.
            IOSSimCommand.self,
            IOSDeviceCommand.self,
            AndroidCommand.self,
        ]
    )
}