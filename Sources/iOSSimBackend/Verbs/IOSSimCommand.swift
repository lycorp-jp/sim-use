// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Public entry point: the `sim-use ios <sub>` namespace.
///
/// Mirrors `AndroidCommand` on the Android side. The unified
/// cross-platform top-level verbs (`tap`, `swipe`, `type`, `paste`,
/// `button`, `touch`, `describe-ui`, `screenshot`, `keyboard-state`,
/// `gesture`, `record-video`) route here for iOS UDIDs via
/// `PlatformRouter.resolve(udid:)`, so end users rarely type
/// `sim-use ios <verb>` directly for those — both forms work.
///
/// iOS-only verbs (no Android counterpart) are reached **only**
/// through this namespace — the top-level surface intentionally only
/// carries verbs that work on both platforms so agents can't mistake
/// these for platform-agnostic operations:
///
///   * `sim-use ios key`           (HID keycode press)
///   * `sim-use ios key-combo`     (HID modifier + key)
///   * `sim-use ios key-sequence`  (HID sequence of keycodes)
///   * `sim-use ios stream-video`  (live mjpeg/raw/bgra stream)
///   * `sim-use ios batch`         (HID-session-pinned step runner)
public struct IOSSimCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "iOS Simulator-specific subcommands.",
        discussion: """
        Cross-platform verbs (tap, swipe, type, paste, button, …) are
        also reachable here for symmetry with `sim-use android`, but the
        canonical form for those stays the top-level command. Verbs
        listed below have no Android counterpart and are reachable
        only via this namespace.
        """,
        subcommands: [
            // Cross-platform verbs — exposed here for parity with
            // `sim-use android <verb>`. The top-level `sim-use <verb>`
            // forwarder still works and routes here for iOS UDIDs.
            IOSSimTapCommand.self,
            IOSSimSwipeCommand.self,
            IOSSimTouchCommand.self,
            IOSSimTypeCommand.self,
            IOSSimPasteCommand.self,
            IOSSimButtonCommand.self,
            IOSSimDescribeUICommand.self,
            IOSSimScreenshotCommand.self,
            IOSSimKeyboardStateCommand.self,
            IOSSimGestureCommand.self,
            IOSSimMultiTouchCommand.self,
            IOSSimRecordVideoCommand.self,
            // iOS-only verbs — reachable only here.
            IOSSimKeyCommand.self,
            IOSSimKeyComboCommand.self,
            IOSSimKeySequenceCommand.self,
            IOSSimStreamVideoCommand.self,
            IOSSimBatchCommand.self,
        ]
    )

    public init() {}
}