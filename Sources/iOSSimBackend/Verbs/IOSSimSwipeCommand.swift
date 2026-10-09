// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `swipe` verb. Mirrors the flag
/// surface of top-level `Swipe` and is also reachable directly as
/// `sim-use ios swipe`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
public struct IOSSimSwipeCommand: SimUseExecutableCommand {
    /// Carries the resolved coordinates so `format(_:)` renders from
    /// the execution result instead of re-resolving the raw flags —
    /// same shape as `IOSSimTapCommand.ExecutionResult`.
    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        public let coordinates: SwipeCoordinates
        /// Excluded from the encoded `data` payload via `CodingKeys`
        /// — the envelope hoists it to the top-level `advisory` key.
        public var commandAdvisory: CommandAdvisory? = nil

        public init(coordinates: SwipeCoordinates, commandAdvisory: CommandAdvisory? = nil) {
            self.coordinates = coordinates
            self.commandAdvisory = commandAdvisory
        }

        private enum CodingKeys: String, CodingKey {
            case coordinates
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Perform a swipe gesture from one point to another on the screen."
    )

    @OptionGroup public var coordinates: SwipeCoordinateOptions

    @Option(name: .customLong("coordinate-space"), help: "Space the coordinates are given in: 'native' (device-native portrait, the default and historical contract) or 'ui' (visual space as printed by describe-ui; orientation-calibrated per command so outline coordinates stay correct on a rotated device).")
    public var coordinateSpace: CoordinateSpace = .native

    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds.")
    public var duration: Double?

    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels.")
    public var delta: Double?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    public var postDelay: Double?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    /// Match the top-level `Swipe` and `AndroidSwipeCommand` so direct
    /// `sim-use ios swipe` calls aren't silent on success.
    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Swipe \(result.coordinates.displaySummary) completed successfully")
    }

    public func validate() throws {
        _ = try coordinates.resolve()
        try Self.validateTimingOptions(
            duration: duration,
            delta: delta,
            preDelay: preDelay,
            postDelay: postDelay
        )
    }

    /// Timing/granularity rules factored out as a static so the
    /// top-level cross-platform forwarder runs the same checks without
    /// re-implementing them. Coordinate rules live in
    /// `SwipeCoordinateOptions.resolve()`.
    public static func validateTimingOptions(
        duration: Double?,
        delta: Double?,
        preDelay: Double?,
        postDelay: Double?
    ) throws {
        if let duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            // Same ceiling as pre/post-delay and the Android verbs.
            // Also catches millisecond values passed by habit from
            // `adb shell input swipe` — those belong in seconds here.
            guard duration <= 10.0 else {
                throw ValidationError("Duration must be at most 10 seconds. Durations are in seconds, not milliseconds — pass 0.3 for a 300 ms swipe.")
            }
        }

        if let delta {
            guard delta > 0 else {
                throw ValidationError("Delta must be greater than 0.")
            }
        }

        if let preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }

        if let postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }
    }

    public func resolvedCoordinates() throws -> SwipeCoordinates {
        try coordinates.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        // Resizable app session (issue #143): touch HID cannot reach the app.
        try await ResizableAppSessionGuard.assertTouchInputReachesApp(udid: device.resolved, verb: "swipe", logger: logger)

        let coords = try coordinates.resolve()
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0

        logger.info().log("Performing swipe from (\(coords.startX), \(coords.startY)) to (\(coords.endX), \(coords.endY))")
        logger.info().log("Duration: \(swipeDuration)s, Delta: \(swipeDelta)px")

        // Native (the default) dispatches the user's coordinates
        // untouched — the historical contract. ui opts them into the
        // visual space describe-ui prints (issue #66 PR B).
        var advisory: CommandAdvisory? = nil
        let dispatch: (startX: Double, startY: Double, endX: Double, endY: Double)
        if coordinateSpace == .ui {
            let calibration = await UISpaceCalibrationLoader.load(
                udid: device.resolved,
                fallbackMessage: "Screen orientation could not be determined; --coordinate-space ui coordinates were dispatched as device-native portrait and may be wrong if the device is rotated.",
                logger: logger
            )
            advisory = calibration.advisory
            let start = calibration.hidPoint(x: coords.startX, y: coords.startY)
            let end = calibration.hidPoint(x: coords.endX, y: coords.endY)
            dispatch = (start.x, start.y, end.x, end.y)
            logger.info().log("Coordinates (HID space): (\(dispatch.startX), \(dispatch.startY)) to (\(dispatch.endX), \(dispatch.endY))")
        } else {
            dispatch = (coords.startX, coords.startY, coords.endX, coords.endY)
        }

        var events: [FBSimulatorHIDEvent] = []

        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }

        let swipeEvent = FBSimulatorHIDEvent.swipe(
            dispatch.startX,
            yStart: dispatch.startY,
            xEnd: dispatch.endX,
            yEnd: dispatch.endY,
            delta: swipeDelta,
            duration: swipeDuration
        )
        events.append(swipeEvent)

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }

        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent.composite(events)

        try await HIDInteractor.performHIDEvent(
            finalEvent,
            for: device.resolved,
            logger: logger
        )

        logger.info().log("Swipe gesture completed successfully")
        return ExecutionResult(coordinates: coords, commandAdvisory: advisory)
    }
}
