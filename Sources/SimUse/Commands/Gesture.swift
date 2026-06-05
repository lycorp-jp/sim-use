// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `gesture` verb. Owns the flag surface
/// and resolves the target platform, then delegates to the per-backend
/// command (`IOSSimGestureCommand` for iOS Simulator UDIDs,
/// `AndroidGestureCommand.performGesture` for adb serials).
///
/// `--delta` is iOS-HID-specific and silently ignored on Android
/// (dispatchGesture interpolates the stroke internally).
struct Gesture: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimGestureCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Perform preset gesture patterns on the simulator.",
        discussion: """
        Execute common gesture patterns without specifying coordinates.

        Single-finger presets:
          scroll-up, scroll-down, scroll-left, scroll-right
          swipe-from-left-edge, swipe-from-right-edge
          swipe-from-top-edge, swipe-from-bottom-edge

        Two-finger presets (use --scale / --angle / --center-x /
        --center-y / --radius to control geometry; --delta is ignored):
          pinch-in, pinch-out, rotate-cw, rotate-ccw

        Examples:
          sim-use gesture scroll-up --udid SIMULATOR_UDID
          sim-use gesture scroll-down --duration 1.5 --udid SIMULATOR_UDID
          sim-use gesture swipe-from-left-edge --screen-width 430 --screen-height 932 --udid SIMULATOR_UDID
          sim-use gesture pinch-out --scale 2.5 --radius 100 --udid SIMULATOR_UDID
          sim-use gesture rotate-cw --angle 45 --udid SIMULATOR_UDID

        Platforms:
          * iOS — coordinates default to iPhone 15 (390×844); pass --screen-width
            and --screen-height for other devices. HID granularity is controlled
            by --delta (single-finger) or --steps / --step-ms (multi-touch).
          * Android — coordinates default to the device's real display in pixels
            (auto-detected via the bridge). --delta, --steps, --step-ms are
            iOS-HID-specific and silently ignored on Android, since
            dispatchGesture interpolates the stroke internally.
        """
    )

    @Argument(help: "The gesture preset to perform.")
    var preset: GesturePreset

    @Option(name: .customLong("screen-width"), help: "Screen width in points (default: 390 for iPhone 15).")
    var screenWidth: Double?

    @Option(name: .customLong("screen-height"), help: "Screen height in points (default: 844 for iPhone 15).")
    var screenHeight: Double?

    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds. Defaults to the preset baseline (0.3s edge / 0.5s scroll+pinch+rotate), except rotate presets auto-extend to |angle|/180s for sweeps > 90° so angular velocity stays near 180°/sec (recogniser sweet spot). Pass explicitly to override.")
    var duration: Double?

    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels for single-finger presets (uses preset default if not specified). Ignored for pinch / rotate presets.")
    var delta: Double?

    @Option(name: .customLong("scale"), help: "Pinch scale ratio (end radius / start radius). Defaults: 2.0 for pinch-out, 0.5 for pinch-in. Ignored for non-pinch presets.")
    var scale: Double?

    @Option(name: .customLong("angle"), help: "Rotation sweep in degrees for rotate-cw / rotate-ccw. Default 90.0. Ignored for non-rotate presets.")
    var angle: Double?

    @Option(name: .customLong("center-x"), help: "Pivot X for pinch / rotate presets (pixels). Defaults to screen center.")
    var centerX: Double?

    @Option(name: .customLong("center-y"), help: "Pivot Y for pinch / rotate presets (pixels). Defaults to screen center.")
    var centerY: Double?

    @Option(name: .customLong("radius"), help: "Start radius for pinch / rotate presets (pixels). Default 80.")
    var radius: Double?

    @Option(name: .customLong("steps"), help: "Number of interpolated HID Move events between Down and Up for multi-touch presets (iOS only). Default 10.")
    var steps: Int = 10

    @Option(name: .customLong("step-ms"), help: "Sleep between Move events in milliseconds for multi-touch presets (iOS only). Derived from --duration / --steps when omitted.")
    var stepMs: Int?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the gesture in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the gesture in seconds.")
    var postDelay: Double?

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    func validate() throws {
        try IOSSimGestureCommand.validateOptions(
            preset: preset,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            duration: duration,
            delta: delta,
            scale: scale,
            angle: angle,
            centerX: centerX,
            centerY: centerY,
            radius: radius,
            steps: steps,
            stepMs: stepMs,
            preDelay: preDelay,
            postDelay: postDelay
        )
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try await executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        var sub = IOSSimGestureCommand()
        sub.preset = preset
        sub.screenWidth = screenWidth
        sub.screenHeight = screenHeight
        sub.duration = duration
        sub.delta = delta
        sub.scale = scale
        sub.angle = angle
        sub.centerX = centerX
        sub.centerY = centerY
        sub.radius = radius
        sub.steps = steps
        sub.stepMs = stepMs
        sub.preDelay = preDelay
        sub.postDelay = postDelay
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    /// Android dispatch. Pre/post-delays use `Task.sleep` here (rather
    /// than the Thread.sleep used inside `AndroidGestureCommand
    /// .performGesture`) so the async runtime sees the cancellation
    /// point and `Ctrl+C` propagates cleanly. The bridge stroke itself
    /// is the shared body — same call shape as `sim-use android
    /// gesture`.
    private func executeAndroid() async throws -> ExecutionResult {
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        try AndroidGestureCommand.performGesture(
            udid: device.resolved,
            preset: preset,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            duration: duration,
            scale: scale,
            angle: angle,
            centerX: centerX,
            centerY: centerY,
            radius: radius,
            preDelay: nil,
            postDelay: nil
        )
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return ExecutionResult()
    }
}