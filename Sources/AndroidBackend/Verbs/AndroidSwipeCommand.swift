// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android swipe` — single-stroke gesture.
///
/// Coordinate flags come from the shared `SwipeCoordinateOptions`
/// group, so the surface is identical to the top-level cross-platform
/// `sim-use swipe` verb and `sim-use ios swipe` — an agent that already
/// speaks one form can drop `android` in front without re-learning the
/// argument shape. `--duration` is in SECONDS (0.5.x shipped it in
/// milliseconds; validate() caps it at 10 s so legacy ms values fail
/// loudly instead of producing multi-minute swipes).
///
public struct AndroidSwipeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Swipe between two coordinates on the Android device."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @OptionGroup public var coordinates: SwipeCoordinateOptions

    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds (default 0.3).")
    public var duration: Double = 0.3

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    public var postDelay: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    /// Carries the resolved coordinates so `format(_:)` renders from
    /// the execution result instead of re-resolving the raw flags.
    public struct ExecutionResult: Codable {
        public let coordinates: SwipeCoordinates

        public init(coordinates: SwipeCoordinates) {
            self.coordinates = coordinates
        }
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        _ = try coordinates.resolve()
        guard duration >= 0 else {
            throw ValidationError("--duration must be non-negative.")
        }
        // Same ceiling as `android tap` / `android multi-touch`. Also
        // the guard that keeps a millisecond value passed by habit
        // (0.5.x shipped `--duration` in ms; `adb shell input swipe`
        // still uses ms) from silently becoming a multi-minute swipe.
        guard duration <= 10.0 else {
            throw ValidationError("--duration must be between 0 and 10 seconds (seconds, not milliseconds — pass 0.3 for a 300 ms swipe).")
        }
        if let preDelay, preDelay < 0 {
            throw ValidationError("--pre-delay must be non-negative.")
        }
        if let postDelay, postDelay < 0 {
            throw ValidationError("--post-delay must be non-negative.")
        }
    }

    public func resolvedCoordinates() throws -> SwipeCoordinates {
        try coordinates.resolve()
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let coords = try coordinates.resolve()
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        let durationMs = max(1, Int((duration * 1000).rounded()))
        try Self.performSwipe(
            udid: device.resolved,
            startX: coords.roundedStartX, startY: coords.roundedStartY,
            endX: coords.roundedEndX, endY: coords.roundedEndY,
            durationMs: durationMs
        )
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return ExecutionResult(coordinates: coords)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        let summary = result.coordinates.displaySummary
        let durationMs = max(1, Int((duration * 1000).rounded()))
        return CommandOutput(
            stdout: "✓ Swipe \(summary) completed successfully\n",
            stderr: "swipe \(summary) duration=\(durationMs)ms\n"
        )
    }

    /// Reusable Android swipe entry point. Top-level cross-platform
    /// `Swipe` forwards here for Android UDIDs so both
    /// `sim-use android swipe` and `sim-use swipe` go through one body.
    /// Symmetric to `AndroidTapCommand.performTap`.
    public static func performSwipe(
        udid: String,
        startX: Int,
        startY: Int,
        endX: Int,
        endY: Int,
        durationMs: Int,
        controller: AndroidDeviceController = AndroidDeviceController()
    ) throws {
        let client = controller.bridge(serial: udid)
        try client.swipe(startX: startX, startY: startY, endX: endX, endY: endY, durationMs: durationMs)
    }
}
