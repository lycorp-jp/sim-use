// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `touch` verb. Mirrors the flag
/// surface of top-level `Touch` and is also reachable directly as
/// `sim-use ios touch`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
///
/// Supports both the atomic form (`--down --up [--delay]`) and the
/// split form (separate `--down` then `--up` calls that hold a touch
/// open across other commands). The split form has no Android peer —
/// the cross-platform forwarder rejects it on Android.
public struct IOSSimTouchCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        /// Excluded from the encoded `data` payload via `CodingKeys`
        /// — the envelope hoists it to the top-level `advisory` key.
        public var commandAdvisory: CommandAdvisory? = nil

        public init(commandAdvisory: CommandAdvisory? = nil) {
            self.commandAdvisory = commandAdvisory
        }

        private enum CodingKeys: CodingKey {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "touch",
        abstract: "Perform precise touch down/up events at specific coordinates.",
        discussion: """
        Perform low-level touch events for advanced gesture control on
        the iOS Simulator. Supports both the atomic form (`--down --up
        --delay`) and the split form (separate `--down` then `--up`
        calls that hold a touch open across other commands).

        Examples:
          sim-use ios touch --x 100 --y 200 --down --udid SIMULATOR_UDID
          sim-use ios touch --x 100 --y 200 --up --udid SIMULATOR_UDID
          sim-use ios touch --x 100 --y 200 --down --up --udid SIMULATOR_UDID
          sim-use ios touch --x 100 --y 200 --down --up --delay 1.0 --udid SIMULATOR_UDID
        """
    )

    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the touch point.")
    public var pointX: Double

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the touch point.")
    public var pointY: Double

    @Flag(name: .customLong("down"), help: "Perform touch down event.")
    public var touchDown: Bool = false

    @Flag(name: .customLong("up"), help: "Perform touch up event.")
    public var touchUp: Bool = false

    @Option(name: .customLong("delay"), help: "Delay between touch down and up events in seconds (if both are specified).")
    public var delay: Double?

    @Option(name: .customLong("coordinate-space"), help: "Space the coordinates are given in: 'native' (device-native portrait, the default) or 'ui' (visual space as printed by describe-ui; orientation-calibrated). 'ui' requires the atomic --down --up form — the split form could straddle a rotation and land the two halves in different spaces.")
    public var coordinateSpace: CoordinateSpace = .native

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    public func validate() throws {
        try Self.validateOptions(
            pointX: pointX, pointY: pointY,
            touchDown: touchDown,
            touchUp: touchUp,
            delay: delay,
            coordinateSpace: coordinateSpace
        )
    }

    /// Shared validation factored out as a static so the top-level
    /// cross-platform forwarder runs the same rules without
    /// re-implementing them.
    public static func validateOptions(
        pointX: Double,
        pointY: Double,
        touchDown: Bool,
        touchUp: Bool,
        delay: Double?,
        coordinateSpace: CoordinateSpace = .native
    ) throws {
        guard pointX >= 0, pointY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }

        guard touchDown || touchUp else {
            throw ValidationError("At least one of --down or --up must be specified.")
        }

        // A split touch (--down and --up in separate invocations) can
        // straddle a rotation: the two halves would calibrate
        // independently and land in different spaces. Restrict ui
        // coordinates to the atomic form.
        if coordinateSpace == .ui {
            guard touchDown && touchUp else {
                throw ValidationError("--coordinate-space ui requires the atomic --down --up form. Use native coordinates for split touches.")
            }
        }

        if let delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 10.0 else {
                throw ValidationError("Delay must not exceed 10 seconds.")
            }
            guard touchDown && touchUp else {
                throw ValidationError("Delay can only be used when both --down and --up are specified.")
            }
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        // Resizable app session (issue #143): touch HID cannot reach the app.
        try await ResizableAppSessionGuard.assertTouchInputReachesApp(udid: device.resolved, verb: "touch", logger: logger)

        logger.info().log("Performing touch events at (\(pointX), \(pointY))")

        // ui space is atomic-form-only (validated above), so a single
        // calibration covers both halves of the touch.
        var advisory: CommandAdvisory? = nil
        let point: (x: Double, y: Double)
        if coordinateSpace == .ui {
            let calibration = await UISpaceCalibrationLoader.load(
                udid: device.resolved,
                fallbackMessage: "Screen orientation could not be determined; --coordinate-space ui coordinates were dispatched as device-native portrait and may be wrong if the device is rotated.",
                logger: logger
            )
            advisory = calibration.advisory
            point = calibration.hidPoint(x: pointX, y: pointY)
            logger.info().log("Coordinates (HID space): (\(point.x), \(point.y))")
        } else {
            point = (pointX, pointY)
        }

        if touchDown && touchUp {
            // Send down and up as separate HID submissions so iOS
            // recognizers observe a real hold duration for long-press
            // gestures.
            let touchDelay = delay ?? 0.1

            logger.info().log("Touch down")
            try await HIDInteractor.performHIDEvent(
                FBSimulatorHIDEvent.touch(direction: .down, x: point.x, y: point.y),
                for: device.resolved,
                logger: logger
            )

            if touchDelay > 0 {
                logger.info().log("Delay: \(touchDelay) seconds")
                try await Task.sleep(nanoseconds: UInt64(touchDelay * 1_000_000_000))
            }

            logger.info().log("Touch up")
            try await HIDInteractor.performHIDEvent(
                FBSimulatorHIDEvent.touch(direction: .up, x: point.x, y: point.y),
                for: device.resolved,
                logger: logger
            )
        } else if touchDown {
            logger.info().log("Touch down")
            try await HIDInteractor.performHIDEvent(
                FBSimulatorHIDEvent.touch(direction: .down, x: point.x, y: point.y),
                for: device.resolved,
                logger: logger
            )
        } else {
            logger.info().log("Touch up")
            try await HIDInteractor.performHIDEvent(
                FBSimulatorHIDEvent.touch(direction: .up, x: point.x, y: point.y),
                for: device.resolved,
                logger: logger
            )
        }

        logger.info().log("Touch events completed successfully")
        return ExecutionResult(commandAdvisory: advisory)
    }
}