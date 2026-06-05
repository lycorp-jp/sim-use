// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `touch` verb. Owns the flag surface and
/// resolves the target platform, then delegates to the per-backend
/// command struct (`IOSSimTouchCommand` for iOS Simulator UDIDs,
/// `AndroidTouchCommand.performTouch` for adb serials).
///
/// Platform support is asymmetric:
///   * iOS — full support, both the atomic form (`--down --up --delay`)
///     and the split form (separate `--down` or `--up` calls).
///   * Android — only the atomic form. Split form is rejected during
///     deferred-argument resolution with a redirect message produced
///     by `AndroidTouchCommand.splitFormRedirect`.
struct Touch: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimTouchCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Perform precise touch down/up events at specific coordinates.",
        discussion: """
        Perform low-level touch events for advanced gesture control.
        You can either perform a single touch down, touch up, or both.

        Examples:
          sim-use touch --x 100 --y 200 --down --udid SIMULATOR_UDID        # Touch down at (100, 200)
          sim-use touch --x 100 --y 200 --up --udid SIMULATOR_UDID          # Touch up at (100, 200)
          sim-use touch --x 100 --y 200 --down --up --udid SIMULATOR_UDID   # Touch down then up (like tap)
          sim-use touch --x 100 --y 200 --down --up --delay 1.0 --udid SIMULATOR_UDID # Long press (hold for 1s)

        Platforms:
          * iOS — full support: both the atomic form (`--down --up --delay`)
            and the split form (separate `--down` then `--up` calls that
            hold a touch open across other commands).
          * Android — only the atomic form is supported. Android's gesture
            primitive (`AccessibilityService.dispatchGesture`) is one-shot;
            it has no API to keep a stroke open across separate calls.
            `--down` or `--up` alone will exit with a redirect to the
            atomic form.
        """
    )

    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the touch point.")
    var pointX: Double

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the touch point.")
    var pointY: Double

    @Flag(name: .customLong("down"), help: "Perform touch down event.")
    var touchDown: Bool = false

    @Flag(name: .customLong("up"), help: "Perform touch up event.")
    var touchUp: Bool = false

    @Option(name: .customLong("delay"), help: "Delay between touch down and up events in seconds (if both are specified).")
    var delay: Double?

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
        if PlatformRouter.looksLikeAndroid(device.resolved) {
            try rejectAndroidSplitForm()
        }
    }

    private func rejectAndroidSplitForm() throws {
        if !(touchDown && touchUp) {
            throw ValidationError(AndroidTouchCommand.splitFormRedirect(
                x: pointX, y: pointY, udid: device.resolved
            ))
        }
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    func validate() throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: pointX, pointY: pointY,
            touchDown: touchDown,
            touchUp: touchUp,
            delay: delay
        )
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        var sub = IOSSimTouchCommand()
        sub.pointX = pointX
        sub.pointY = pointY
        sub.touchDown = touchDown
        sub.touchUp = touchUp
        sub.delay = delay
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    private func executeAndroid() throws -> ExecutionResult {
        // `resolveDeferredArguments` already rejected the split form on
        // Android; we know `touchDown && touchUp` by this point.
        try AndroidTouchCommand.performTouch(
            udid: device.resolved,
            x: pointX, y: pointY,
            delay: delay
        )
        return ExecutionResult()
    }
}