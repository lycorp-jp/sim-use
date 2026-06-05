// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android touch` — atomic touch-down + touch-up at one
/// coordinate. Android's gesture primitive
/// (`AccessibilityService.dispatchGesture`) is one-shot, so split
/// touch (separate down then up calls that hold a stroke open across
/// other commands) is not supported. The cross-platform top-level
/// forwarder rejects the split form on Android with a redirect; this
/// peer enforces the same rule via `validate()`.
public struct AndroidTouchCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "touch",
        abstract: "Atomic touch at (x, y) on the Android device. Use --down --up [--delay <seconds>]."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the touch point.")
    public var pointX: Double

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the touch point.")
    public var pointY: Double

    @Flag(name: .customLong("down"), help: "Perform touch down event.")
    public var touchDown: Bool = false

    @Flag(name: .customLong("up"), help: "Perform touch up event.")
    public var touchUp: Bool = false

    @Option(name: .customLong("delay"), help: "Hold duration in seconds between down and up (default 0.1).")
    public var delay: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        guard pointX >= 0, pointY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard touchDown && touchUp else {
            throw ValidationError(Self.splitFormRedirect(x: pointX, y: pointY, udid: device.resolved))
        }
        if let delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 10.0 else {
                throw ValidationError("Delay must not exceed 10 seconds.")
            }
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performTouch(udid: device.resolved, x: pointX, y: pointY, delay: delay)
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Touch at (\(Int(pointX.rounded())), \(Int(pointY.rounded()))) completed successfully")
    }

    /// Reusable Android touch entry point. Top-level cross-platform
    /// `Touch` forwards here for Android UDIDs so both
    /// `sim-use android touch` and `sim-use touch` go through one
    /// body. Symmetric to `AndroidTapCommand.performTap`.
    ///
    /// `holdMs` floors to 1 ms even when the caller passes
    /// `delay = 0`. On iOS the same shape collapses to a combined
    /// `tapAt`; Android emits a 1 ms-stroke swipe instead. The two
    /// strokes feel identical on a normal app but a gesture recogniser
    /// tuned to the iOS HID rhythm could observe the 1 ms gap as a
    /// real (degenerate) swipe. Accept the drift as the cost of
    /// routing atomic taps through `dispatchGesture`.
    public static func performTouch(
        udid: String,
        x: Double,
        y: Double,
        delay: Double?,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let holdSeconds = delay ?? 0.1
        let holdMs = max(1, Int((holdSeconds * 1000).rounded()))
        let xi = Int(x.rounded())
        let yi = Int(y.rounded())
        let client = controller.bridge(serial: udid)
        try client.swipe(startX: xi, startY: yi, endX: xi, endY: yi, durationMs: holdMs)
    }

    /// Standard redirect message surfaced when the user passes only
    /// `--down` or only `--up` on Android. Public so the cross-platform
    /// top-level forwarder can emit the same text.
    public static func splitFormRedirect(x: Double, y: Double, udid: String) -> String {
        let xi = Int(x.rounded())
        let yi = Int(y.rounded())
        return "Split touch form (--down or --up alone) is not supported on Android. "
            + "Use the atomic form `sim-use touch --x \(xi) --y \(yi) "
            + "--down --up --delay <seconds> --udid \(udid)` instead, "
            + "or `sim-use tap` for a simple tap."
    }
}