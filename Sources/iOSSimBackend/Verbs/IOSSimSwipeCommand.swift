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
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Perform a swipe gesture from one point to another on the screen."
    )

    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point.")
    public var startX: Double

    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point.")
    public var startY: Double

    @Option(name: .customLong("end-x"), help: "The X coordinate of the ending point.")
    public var endX: Double

    @Option(name: .customLong("end-y"), help: "The Y coordinate of the ending point.")
    public var endY: Double

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
        let sx = Int(startX.rounded())
        let sy = Int(startY.rounded())
        let ex = Int(endX.rounded())
        let ey = Int(endY.rounded())
        return .line("✓ Swipe (\(sx),\(sy)) → (\(ex),\(ey)) completed successfully")
    }

    public func validate() throws {
        try Self.validateOptions(
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            duration: duration,
            delta: delta,
            preDelay: preDelay,
            postDelay: postDelay
        )
    }

    /// Shared validation factored out as a static so the top-level
    /// cross-platform forwarder runs the same rules without
    /// re-implementing them.
    public static func validateOptions(
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double,
        duration: Double?,
        delta: Double?,
        preDelay: Double?,
        postDelay: Double?
    ) throws {
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }

        if let duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
        }

        if let delta {
            guard delta > 0 else {
                throw ValidationError("Delta must be greater than 0.")
            }
        }

        guard startX != endX || startY != endY else {
            throw ValidationError("Start and end points must be different.")
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

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0

        logger.info().log("Performing swipe from (\(startX), \(startY)) to (\(endX), \(endY))")
        logger.info().log("Duration: \(swipeDuration)s, Delta: \(swipeDelta)px")

        var events: [FBSimulatorHIDEvent] = []

        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }

        let swipeEvent = FBSimulatorHIDEvent.swipe(
            startX,
            yStart: startY,
            xEnd: endX,
            yEnd: endY,
            delta: swipeDelta,
            duration: swipeDuration
        )
        events.append(swipeEvent)

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }

        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent(events: events)

        try await HIDInteractor.performHIDEvent(
            finalEvent,
            for: device.resolved,
            logger: logger
        )

        logger.info().log("Swipe gesture completed successfully")
        return ExecutionResult()
    }
}