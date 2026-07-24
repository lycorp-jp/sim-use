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
    public struct ExecutionResult: Codable {
        public let coordinates: SwipeCoordinates

        public init(coordinates: SwipeCoordinates) {
            self.coordinates = coordinates
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Perform a swipe gesture from one point to another on the screen."
    )

    @OptionGroup public var coordinates: SwipeCoordinateOptions

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

        let coords = try coordinates.resolve()
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0

        logger.info().log("Performing swipe from (\(coords.startX), \(coords.startY)) to (\(coords.endX), \(coords.endY))")
        logger.info().log("Duration: \(swipeDuration)s, Delta: \(swipeDelta)px")

        var events: [FBSimulatorHIDEvent] = []

        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }

        let swipeEvent = FBSimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
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
        return ExecutionResult(coordinates: coords)
    }
}
