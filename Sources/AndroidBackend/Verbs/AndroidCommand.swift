// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Public entry point: the `sim-use android <sub>` namespace.
///
/// The unified top-level verbs (`describe-ui`, `tap`, `swipe`, …) route
/// to this backend internally based on UDID shape. The subcommands
/// registered here are the canonical Android-side implementations
/// each verb forwards into. Mirrors how iOSSimBackend lays out one
/// command per file under `Sources/iOSSimBackend/Verbs/`.
public struct AndroidCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Android-specific subcommands (init, describe-ui, devices, tap, …)",
        subcommands: [
            AndroidInitCommand.self,
            AndroidDevicesCommand.self,
            AndroidDescribeUICommand.self,
            AndroidPingCommand.self,
            AndroidTapCommand.self,
            AndroidSwipeCommand.self,
            AndroidTouchCommand.self,
            AndroidPasteCommand.self,
            AndroidKeyboardStateCommand.self,
            AndroidGestureCommand.self,
            AndroidMultiTouchCommand.self,
            AndroidScrollCommand.self,
            AndroidButtonCommand.self,
            AndroidScreenshotCommand.self,
            AndroidTypeCommand.self,
        ]
    )

    public init() {}
}