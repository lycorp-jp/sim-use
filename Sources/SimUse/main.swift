// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import AppKit
import FBControlCore
import Darwin
import SimUseCore
import AndroidBackend
import iOSSimBackend

// MARK: - Main Entry Point
//
// `@main` lives on a thin shim (`EntryPoint`) that intercepts a few
// recognisable agent-typo mistakes before ArgumentParser sees them,
// emits a "did you mean …?" redirect, then exits early. Everything
// else falls through to `SimUse.main()` and the standard parser flow.
//
// The daemon-side command parser (used by `DaemonDispatch.handle` when
// the daemon server routes requests through ArgumentParser) is wired
// inside `Daemon.Start.run()`. The daemon SERVER process is always the
// one that needs it; client-side `daemon stop` / `daemon status` and
// non-daemon commands never touch DaemonDispatch.

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
    "stream-video": "sim-use ios stream-video",
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

        if let typed = CommandLine.arguments.dropFirst().first,
           let canonical = iOSOnlyVerbRedirects[typed] {
            FileHandle.standardError.write(Data("""
                Error: `sim-use \(typed)` is not a top-level command. \
                Did you mean `\(canonical)`?

                Hint: as of 0.5.x, the five iOS-only verbs (key, key-combo, \
                key-sequence, stream-video, batch) live exclusively under \
                `sim-use ios <verb>` — the top-level surface only carries \
                verbs that work on both iOS and Android. Re-run with the \
                `ios` namespace and your existing flags should keep working:

                    \(canonical) \(CommandLine.arguments.dropFirst(2).joined(separator: " "))

                """.utf8))
            Darwin.exit(64) // EX_USAGE
        }
        await SimUse.main()
    }
}

struct SimUse: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared
    static let simUseLogger = SimUseLogger()

    static let configuration = CommandConfiguration(
        abstract: "A utility to interact with iOS Simulators and extract accessibility information.",
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
            Screenshot.self,
            AppState.self,
            Viewer.self,
            // Daemon + spike helpers.
            Daemon.self,
            SpikeDaemon.self,
            // Platform-specific namespaces. The five iOS-only HID verbs
            // (key, key-combo, key-sequence, stream-video, batch) live
            // under `IOSSimCommand` only — the top-level surface only
            // carries verbs that work on both platforms.
            IOSSimCommand.self,
            AndroidCommand.self,
        ]
    )
}